"""
ConnectChaos-CallLogger Lambda

Invoked DIRECTLY by the Amazon Connect contact flow via an "Invoke AWS Lambda
function" (InvokeLambdaFunction) block at the very start of the call — NOT through
Lex.

Real-world use case
-------------------
This is a genuine contact-center building block: log every inbound contact to
DynamoDB before servicing it. A record like this backs interaction history,
callback de-duplication, repeat-caller detection, and (in regulated industries)
compliance/audit requirements where the interaction MUST be recorded before the
customer is serviced. Writing it keyed on the Connect ContactId with the caller's
number, the dialed number, channel, and a timestamp is a typical "first block in
the flow" pattern.

The table (<StackName>-CallLog, from CALL_LOG_TABLE_NAME) is a DynamoDB Global Table, so call records written
in the primary region are replicated to the paired region — after ACGR fails
telephony over, the receiving region still has (and keeps appending to) the same
call log.

Relationship to FIS Experiment 2
--------------------------------
Because the flow treats this write as a required step, a DynamoDB outage makes it
fail. This function runs in the SAME VPC subnets FIS Experiment 2 disrupts
(aws:network:disrupt-connectivity, scope=dynamodb), so when the experiment severs
the DynamoDB path the put_item raises within ~2s. The function does NOT swallow the
error, so Amazon Connect records a failed invocation and routes the contact down
the InvokeLambdaFunction block's Error branch — which is what increments the
AWS/Connect ContactFlowErrors metric that Experiment 2 is designed to observe.

(A DDB failure reached through the Lex fulfillment code hook instead surfaces as
AWS/Lambda Errors + AWS/Lex RuntimeLambdaErrors and is handled by the Lex block's
own error branch — it does NOT produce ContactFlowErrors.)

Event shape (Amazon Connect Lambda invocation)
-----------------------------------------------
{
  "Details": {
    "ContactData": {
      "ContactId": "...",
      "Channel": "VOICE",
      "InstanceARN": "arn:aws:connect:...:instance/...",
      "InitiationMethod": "INBOUND",
      "CustomerEndpoint": {"Address": "+1...", "Type": "TELEPHONE_NUMBER"},
      "SystemEndpoint":   {"Address": "+1...", "Type": "TELEPHONE_NUMBER"},
      ...
    },
    "Parameters": { ... }
  },
  "Name": "ContactFlowEvent"
}

Return: a flat map of string -> string (Amazon Connect requirement).
"""

import os
import json
import time
import logging
from datetime import datetime, timezone

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ['CALL_LOG_TABLE_NAME']
REGION = os.environ.get('AWS_REGION', 'unknown')

# Retain call-log records for 90 days via a DynamoDB TTL attribute (expires_at).
_TTL_DAYS = int(os.environ.get('CALL_LOG_TTL_DAYS', '90'))

# Short, bounded DynamoDB timeouts so Experiment 2 (network disruption) fails FAST
# (~2s) and well within Connect's 8s InvokeLambdaFunction limit. Without this the
# write would hang to the Lambda timeout; Connect would still take the Error branch,
# but slower and reported as a Lambda timeout rather than a clean, fast write error.
_DDB_CONFIG = Config(
    connect_timeout=2,
    read_timeout=2,
    retries={'total_max_attempts': 1},
)

dynamodb = boto3.resource('dynamodb', config=_DDB_CONFIG)
call_log_table = dynamodb.Table(TABLE_NAME)


def _endpoint_address(contact_data, key):
    """Safely pull an endpoint address (e.g. CustomerEndpoint.Address) from ContactData."""
    endpoint = contact_data.get(key) or {}
    return endpoint.get('Address', 'unknown')


def lambda_handler(event, context):
    """Persist the inbound contact to DynamoDB, then let the flow continue."""
    logger.info(f"Received Connect event: {json.dumps(event)}")

    contact_data = event.get('Details', {}).get('ContactData', {})

    contact_id = contact_data.get('ContactId', context.aws_request_id)
    ani = _endpoint_address(contact_data, 'CustomerEndpoint')   # caller's number
    dnis = _endpoint_address(contact_data, 'SystemEndpoint')    # number they dialed
    now = datetime.now(timezone.utc)

    item = {
        'contact_id': contact_id,
        'received_at': now.isoformat(),
        'ani': ani,
        'dnis': dnis,
        'channel': contact_data.get('Channel', 'unknown'),
        'initiation_method': contact_data.get('InitiationMethod', 'unknown'),
        'instance_arn': contact_data.get('InstanceARN', 'unknown'),
        'received_in_region': REGION,
        'expires_at': int(time.time()) + _TTL_DAYS * 86400,
    }

    # Any exception (network disruption during FIS Exp 2, timeout, throttling)
    # propagates on purpose so Amazon Connect records a failed invocation and routes
    # the contact down the block's Error branch, incrementing AWS/Connect
    # ContactFlowErrors.
    call_log_table.put_item(Item=item)

    logger.info(f"Logged contact {contact_id} (ANI={ani}, region={REGION})")
    # Amazon Connect requires a flat map of string values.
    return {'logged': 'true', 'contactId': contact_id}
