"""
TrafficShiftHandler Lambda — Deployed in BOTH regions.

Each region's instance shifts traffic AWAY from itself.
Triggered by EventBridge when the regional Composite Alarm enters ALARM state.

Idempotency:
  Before issuing UpdateTrafficDistribution we call GetTrafficDistribution to read
  the current state. If MY_REGION is already at 0% we skip the API call. This
  protects against:
    1. Both regions detecting the same multi-region event and racing each other.
    2. Repeated EventBridge invocations on the same alarm transition.
    3. Manual operator action having already shifted traffic.

Identifier:
  The TDG is addressed by its full ARN. An ACGR traffic distribution group resolves by
  bare UUID ONLY in the region it was created in - from the paired region that call
  returns ResourceNotFoundException, which silently disabled failover from the surviving
  region. This is asserted at import time so a regression fails fast and loudly rather
  than only during an incident.

Region-pair correctness:
  ACGR's TelephonyConfig.Distributions array MUST sum to exactly 100 across
  exactly the two pair regions, in 10% increments. We always write a complete
  two-row Distributions array.
"""

import os
import json
import logging
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Full ARN, never the bare UUID. A TDG resolves by bare ID only in its home region; the
# paired region gets ResourceNotFoundException. See FIXES.md Fix 17.
TRAFFIC_DISTRIBUTION_GROUP_ARN = os.environ['TRAFFIC_DISTRIBUTION_GROUP_ARN']
MY_REGION = os.environ['MY_REGION']
PRIMARY_REGION = os.environ['PRIMARY_REGION']
PAIRED_REGION = os.environ['PAIRED_REGION']

if not TRAFFIC_DISTRIBUTION_GROUP_ARN.startswith('arn:'):
    raise ValueError(
        'TRAFFIC_DISTRIBUTION_GROUP_ARN must be a full ARN, not a bare UUID: '
        f'{TRAFFIC_DISTRIBUTION_GROUP_ARN!r}. A bare ID only resolves in the TDG home '
        'region, so the paired region could not fail over. See FIXES.md Fix 17.'
    )

connect_client = boto3.client('connect')


def lambda_handler(event, context):
    """Shift traffic AWAY from MY_REGION when the regional composite alarm transitions to ALARM."""
    logger.info(f"Event: {json.dumps(event)}")
    alarm_state = event.get('detail', {}).get('state', {}).get('value', '')
    logger.info(f"Alarm state: {alarm_state}, My region: {MY_REGION}")

    if alarm_state != 'ALARM':
        # OK / INSUFFICIENT_DATA / etc — recovery is intentionally manual to give
        # operators time to validate that the underlying issue is fully resolved
        # before customers are routed back.
        logger.info(f"Non-ALARM state ({alarm_state}); no action.")
        return {'statusCode': 200, 'body': f'No action for state: {alarm_state}'}

    other_region = PAIRED_REGION if MY_REGION == PRIMARY_REGION else PRIMARY_REGION
    return shift_traffic(away_from=MY_REGION, towards=other_region)


def shift_traffic(away_from, towards):
    """Idempotently set TDG distribution to 0/100 (away_from = 0%)."""
    # Idempotency guard: skip the write if the TDG is already shifted away from this region.
    try:
        current = connect_client.get_traffic_distribution(Id=TRAFFIC_DISTRIBUTION_GROUP_ARN)
        existing = {
            row['Region']: row.get('Percentage', 0)
            for row in current.get('TelephonyConfig', {}).get('Distributions', [])
        }
        if existing.get(away_from, 100) == 0 and existing.get(towards, 0) == 100:
            logger.info(
                f"TDG already shifted: {away_from}=0%, {towards}=100% — no-op."
            )
            return {
                'statusCode': 200,
                'body': json.dumps({'action': 'NOOP_ALREADY_SHIFTED', 'state': existing})
            }
    except ClientError as exc:
        # If the read fails we fall through to the write — better to over-write
        # than to silently skip a real failover.
        logger.warning(f"GetTrafficDistribution failed; proceeding with write. {exc}")

    try:
        connect_client.update_traffic_distribution(
            Id=TRAFFIC_DISTRIBUTION_GROUP_ARN,
            TelephonyConfig={
                'Distributions': [
                    {'Region': away_from, 'Percentage': 0},
                    {'Region': towards, 'Percentage': 100},
                ]
            }
        )
        logger.info(f"Traffic shifted: {away_from}=0%, {towards}=100%")
        return {
            'statusCode': 200,
            'body': json.dumps({
                'action': 'FAILOVER',
                'away_from': away_from,
                'towards': towards,
            })
        }
    except ClientError as exc:
        logger.error(f"UpdateTrafficDistribution failed: {exc}")
        raise
