"""
ConnectChaos-AccountLookup Lambda

Invoked DIRECTLY by the contact flow via an "Invoke AWS Lambda function"
(InvokeLambdaFunction) block, immediately after a "Store customer input"
(GetParticipantInput, StoreInput=True) block that collects the account number as DTMF.

Real-world use case
-------------------
Touch-tone account lookup: the caller keys their account number, the flow resolves it to a
customer record, and the IVR greets them by name. DTMF rather than speech is deliberate --
it is what most production IVRs use for account numbers, and it removes automatic speech
recognition as a variable. During testing, ASR turned "one two three four five" into both
"120345" and "0", which looks exactly like a broken lookup.

Relationship to FIS Experiment 1
--------------------------------
Experiment 1 applies aws:lambda:invocation-error (preventExecution) to THIS function via the
FIS Lambda extension. The invocation fails without the handler running, Connect routes the
contact down the InvokeLambdaFunction block's Error branch, and AWS/Connect
ContactFlowErrors increments for THIS flow -- giving Experiment 1 a Connect-native metric
with a ContactFlowName dimension no other experiment shares.

That is why "not found" is NOT an exception here. The Error branch is reserved for genuine
faults. A wrong account number, or no input at all, must return normally with a status the
flow can branch on with a Compare block; otherwise a caller mistyping their account number
would be indistinguishable from an injected fault, and the experiment's central claim --
that the flow error attributes to the fault -- would be false.

Status values returned (flow branches on $.External.status via a Compare block):
  FOUND         customer resolved; customer_name is set
  NOT_FOUND     well-formed account number with no matching record
  INVALID_INPUT missing input, a DTMF timeout, or a non-numeric value

DynamoDB failures DO propagate, so a genuine data-plane outage still reaches the Error
branch.

Event shape
-----------
{
  "Details": {
    "ContactData": {"ContactId": "...", "Channel": "VOICE", ...},
    "Parameters": {"AccountId": "12345"}      <- LambdaInvocationAttributes
  },
  "Name": "ContactFlowEvent"
}

Return: a flat map of string -> string. The flow's block is configured with
ResponseValidation.ResponseType = STRING_MAP, so nested values are not permitted.
"""

import json
import logging
import os

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ['CUSTOMER_TABLE_NAME']
REGION = os.environ.get('AWS_REGION', 'unknown')

# Bounded timeouts, matching call_logger.py: this function is invoked directly by the flow
# under Connect's hard 8s InvokeLambdaFunction limit, so a DynamoDB problem must surface as
# a fast, clean error rather than hanging to the Lambda timeout.
#
# NOTE: unlike LexFulfillmentHandler, whose 40s timeout is load-bearing for Experiment 3,
# nothing here depends on a long timeout. Experiment 1 prevents execution entirely, so these
# timeouts are never reached during the experiment. Do NOT add fast-fail timeouts to the Lex
# code hook: Experiment 3 needs its ~31s delay to return cleanly, not error.
_DDB_CONFIG = Config(
    connect_timeout=2,
    read_timeout=2,
    retries={'total_max_attempts': 1},
)

dynamodb = boto3.resource('dynamodb', config=_DDB_CONFIG)
customer_table = dynamodb.Table(TABLE_NAME)

# "Store customer input" does NOT take an error branch when the caller enters nothing. It
# takes the Success branch with the Stored customer input attribute set to the literal
# string "Timeout".
# https://docs.aws.amazon.com/connect/latest/adminguide/store-customer-input.html
_DTMF_TIMEOUT_SENTINEL = 'Timeout'


def _account_id(event):
    """Read the DTMF digits passed via LambdaInvocationAttributes."""
    params = event.get('Details', {}).get('Parameters') or {}
    return (params.get('AccountId') or '').strip()


def lambda_handler(event, context):
    """Resolve a DTMF-entered account number to a customer name."""
    logger.info(f"Received Connect event: {json.dumps(event)}")

    account_id = _account_id(event)

    if not account_id or account_id == _DTMF_TIMEOUT_SENTINEL:
        logger.info(f"No usable account input (value={account_id!r}) - INVALID_INPUT")
        return {'status': 'INVALID_INPUT', 'customer_name': '', 'region': REGION}

    if not account_id.isdigit():
        logger.info(f"Account input is not numeric (value={account_id!r}) - INVALID_INPUT")
        return {'status': 'INVALID_INPUT', 'customer_name': '', 'region': REGION}

    # A ClientError / timeout here propagates on purpose: Connect records a failed
    # invocation and routes the contact down the block's Error branch, which is what
    # increments AWS/Connect ContactFlowErrors.
    response = customer_table.get_item(Key={'account_id': account_id})
    item = response.get('Item')

    if not item:
        logger.info(f"No customer for account_id={account_id} - NOT_FOUND")
        return {'status': 'NOT_FOUND', 'customer_name': '', 'region': REGION}

    customer_name = str(item.get('customer_name', ''))
    logger.info(f"Resolved account_id={account_id} to {customer_name!r} in {REGION}")
    return {'status': 'FOUND', 'customer_name': customer_name, 'region': REGION}
