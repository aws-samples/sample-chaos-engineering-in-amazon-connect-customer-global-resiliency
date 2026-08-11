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
  bare UUID ONLY in the region it was created in - from the replica Region that call
  returns ResourceNotFoundException, which silently disabled traffic transition from the surviving
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
import time

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Full ARN, never the bare UUID. A TDG resolves by bare ID only in its home region; the
# replica Region gets ResourceNotFoundException.
TRAFFIC_DISTRIBUTION_GROUP_ARN = os.environ['TRAFFIC_DISTRIBUTION_GROUP_ARN']
MY_REGION = os.environ['MY_REGION']
SOURCE_REGION = os.environ['SOURCE_REGION']
REPLICA_REGION = os.environ['REPLICA_REGION']

# Deliberate dwell before repairing, so the imreplica Region can be experienced. Detection
# already costs ~90s of Connect metric latency; this is added on top.
REGION_SWITCH_DELAY_SECONDS = int(os.environ.get('REGION_SWITCH_DELAY_SECONDS', '0'))

if not TRAFFIC_DISTRIBUTION_GROUP_ARN.startswith('arn:'):
    raise ValueError(
        'TRAFFIC_DISTRIBUTION_GROUP_ARN must be a full ARN, not a bare UUID: '
        f'{TRAFFIC_DISTRIBUTION_GROUP_ARN!r}. A bare ID only resolves in the TDG home '
        'region, so the replica Region could not transition traffic.'
    )

connect_client = boto3.client('connect')
cloudwatch_client = boto3.client('cloudwatch')


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

    other_region = REPLICA_REGION if MY_REGION == SOURCE_REGION else SOURCE_REGION
    alarm_name = event.get('detail', {}).get('alarmName')
    return shift_traffic(away_from=MY_REGION, towards=other_region, alarm_name=alarm_name)


def shift_traffic(away_from, towards, alarm_name=None):
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
        # than to silently skip a real traffic transition.
        logger.warning(f"GetTrafficDistribution failed; proceeding with write. {exc}")

    # Deliberate dwell: let callers actually experience the imreplica Region.
    if REGION_SWITCH_DELAY_SECONDS > 0:
        logger.info(
            f"Holding traffic transition for {REGION_SWITCH_DELAY_SECONDS}s so the imreplica Region can be "
            f"experienced (RegionSwitchDelaySeconds). Will then shift {away_from} -> {towards}."
        )
        time.sleep(REGION_SWITCH_DELAY_SECONDS)

        # Re-check the CONDITION first. A sleeping invocation is otherwise immune to
        # anything that happens during the dwell: an operator reset, or the fault being
        # remediated. Waking up and failing over then moves traffic away from a region that
        # is now healthy. This also debounces transient blips that clear within the dwell.
        if alarm_name:
            try:
                resp = cloudwatch_client.describe_alarms(
                    AlarmNames=[alarm_name], AlarmTypes=['CompositeAlarm', 'MetricAlarm'])
                states = ([a['StateValue'] for a in resp.get('CompositeAlarms', [])]
                          + [a['StateValue'] for a in resp.get('MetricAlarms', [])])
                if states and 'ALARM' not in states:
                    logger.info(
                        f"{alarm_name} is now {states[0]} after the {REGION_SWITCH_DELAY_SECONDS}s "
                        f"dwell - the impairment cleared or was reset. Not failing over."
                    )
                    return {
                        'statusCode': 200,
                        'body': json.dumps({'action': 'NOOP_ALARM_CLEARED_DURING_DELAY',
                                            'alarm': alarm_name, 'state': states[0]})
                    }
            except ClientError as exc:
                logger.warning(f"Post-delay DescribeAlarms failed; proceeding. {exc}")

        # Then re-check the traffic itself, in case the replica Region's handler already moved
        # it while we waited - writing blindly would undo a more recent decision.
        try:
            current = connect_client.get_traffic_distribution(Id=TRAFFIC_DISTRIBUTION_GROUP_ARN)
            existing = {
                row['Region']: row.get('Percentage', 0)
                for row in current.get('TelephonyConfig', {}).get('Distributions', [])
            }
            if existing.get(away_from, 100) == 0:
                logger.info(
                    f"After the dwell, {away_from} is already at 0% - another actor shifted "
                    f"traffic meanwhile. Leaving {existing} untouched."
                )
                return {
                    'statusCode': 200,
                    'body': json.dumps({'action': 'NOOP_SHIFTED_DURING_DELAY',
                                        'state': existing})
                }
        except ClientError as exc:
            logger.warning(f"Post-delay GetTrafficDistribution failed; proceeding. {exc}")

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
                'action': 'TRAFFIC_TRANSITION',
                'away_from': away_from,
                'towards': towards,
            })
        }
    except ClientError as exc:
        logger.error(f"UpdateTrafficDistribution failed: {exc}")
        raise
