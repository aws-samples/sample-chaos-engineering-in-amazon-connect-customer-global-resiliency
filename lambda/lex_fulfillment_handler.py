"""
LexFulfillmentHandler Lambda

This Lambda is attached to the Lex V2 bot as a FulfillmentCodeHook.
It performs:
  1. Customer lookup in DynamoDB (intent-based routing)
  2. Chaos flag check (for Experiment 4 — custom contact flow fault)
  3. Returns response to Lex (which passes it back to Connect contact flow)

The chaos flag check is intentionally placed AFTER the customer lookup so that
FIS Experiments 1-3 produce their expected metrics without being masked by the
chaos flag path. Only Experiment 4 (chaos flag enabled) triggers the Failed state.

FIS Targeting:
  - Experiment 1: aws:lambda:invocation-error targets this function directly
  - Experiment 2: aws:network:disrupt-connectivity blocks DDB access from this function's VPC subnet
  - Experiment 3: aws:lambda:invocation-add-delay adds delay > function timeout
  - Experiment 4: Chaos flag in DDB causes this function to return a Failed state to Lex

CloudWatch Metrics Produced on Failure:
  - AWS/Lambda: Errors (Exp 1, 2, 3)
  - AWS/Lex: RuntimeLambdaErrors (Exp 1, 2, 3 — voice path)
  - AWS/Connect: MissedCalls (Exp 4 — custom flow logic)

Note: Experiment 2's distinct metric, AWS/Connect ContactFlowErrors, is NOT produced by
this fulfillment code hook. A DDB failure reached through Lex is handled by the flow's Lex
block error branch and surfaces as Lambda Errors / RuntimeLambdaErrors instead. Exp 2's
ContactFlowErrors is produced by the separate call_logger.py Lambda, which the flow
invokes directly via an "Invoke AWS Lambda function" block.
"""

import os
import json
import logging
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, ConnectTimeoutError, ReadTimeoutError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables set by CFN
TABLE_NAME = os.environ['CUSTOMER_TABLE_NAME']
CHAOS_TABLE_NAME = os.environ['CHAOS_TABLE_NAME']
# Lambda sets AWS_REGION in every execution environment. Used to scope Experiment 4's chaos
# flag per region so the fault is regional rather than replicated.
REGION = os.environ.get('AWS_REGION', 'unknown')

# Short, bounded DynamoDB timeouts so Experiment 2 (network disruption) fails FAST
# and CATCHABLY instead of hanging until the 8s Lambda timeout. If the DDB call
# hangs to the Lambda timeout, the failure is recorded as an AWS/Lambda "timeout"
# (an AWS/Lambda Errors datapoint) rather than surfacing as a clean Lex code-hook
# error -> contact-flow error branch -> AWS/Connect ContactFlowErrors. With a ~2s
# connect/read timeout and no retries, the boto3 call raises within ~2s, the
# handler's except catches it and re-raises, Lex sees a prompt code-hook error, and
# the flow's Error branch fires (producing ContactFlowErrors as Experiment 2 intends).
_DDB_CONFIG = Config(
    connect_timeout=2,
    read_timeout=2,
    retries={'total_max_attempts': 1},
)

dynamodb = boto3.resource('dynamodb', config=_DDB_CONFIG)
customer_table = dynamodb.Table(TABLE_NAME)
chaos_table = dynamodb.Table(CHAOS_TABLE_NAME)


def lambda_handler(event, context):
    """
    Lex V2 FulfillmentCodeHook handler.
    
    Expected Lex V2 event structure:
    {
        "sessionState": {...},
        "interpretations": [...],
        "inputTranscript": "...",
        "invocationSource": "FulfillmentCodeHook",
        "sessionId": "...",
        "bot": {"id": "...", "name": "...", "aliasId": "...", "localeId": "en_US"},
        ...
    }
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    intent_name = event['sessionState']['intent']['name']
    slots = event['sessionState']['intent']['slots']
    invocation_source = event.get('invocationSource', 'FulfillmentCodeHook')
    
    logger.info(f"Intent: {intent_name}, Slots: {json.dumps(slots)}, Source: {invocation_source}")
    
    # ─────────────────────────────────────────────────────────────
    # MAIN LOGIC: Customer lookup / order check in DynamoDB
    # Experiment 2 (DDB network disruption) will cause this to fail
    # and raise an exception — producing RuntimeLambdaErrors in Lex.
    #
    # NOTE: We do the customer lookup BEFORE the chaos flag check so
    # that FIS Experiments 1/2/3 produce their expected metrics cleanly
    # without being masked by the chaos flag path.
    # ─────────────────────────────────────────────────────────────
    if intent_name == 'LookupCustomer':
        return handle_lookup_customer(intent_name, slots)
    elif intent_name == 'CheckOrderStatus':
        return handle_check_order(intent_name, slots)
    else:
        return handle_fallback(intent_name)


def handle_lookup_customer(intent_name, slots):
    """Look up customer by account number in DynamoDB."""
    account_number = get_slot_value(slots, 'AccountNumber')
    
    if not account_number:
        return build_lex_response(
            intent_name=intent_name,
            fulfillment_state='Failed',
            message="I couldn't find your account number. Please try again."
        )
    
    try:
        response = customer_table.get_item(
            Key={'account_id': account_number}
        )
        item = response.get('Item')
        
        # ─────────────────────────────────────────────────────────
        # EXPERIMENT 4 CHECK: Read chaos flag from DDB
        # Placed AFTER the customer lookup so that:
        #   - Exp 2 (DDB disruption) raises before we get here
        #   - Exp 1/3 (Lambda error/timeout) never reach this code
        #   - Only Exp 4 (chaos flag) triggers the Failed path below
        # ─────────────────────────────────────────────────────────
        chaos_enabled = _check_chaos_flag()
        if chaos_enabled:
            logger.warning(f"CHAOS FLAG ENABLED for {REGION} — returning Failed state to Lex")
            return build_lex_response(
                intent_name=intent_name,
                fulfillment_state='Failed',
                message="We're experiencing technical difficulties. Please try again later."
            )
        
        if item:
            customer_name = item.get('customer_name', 'valued customer')
            return build_lex_response(
                intent_name=intent_name,
                fulfillment_state='Fulfilled',
                message=f"Welcome back, {customer_name}. I've pulled up your account. How can I help you today?"
            )
        else:
            return build_lex_response(
                intent_name=intent_name,
                fulfillment_state='Fulfilled',
                message="I couldn't find an account with that number. Let me transfer you to an agent."
            )
            
    except (ClientError, ConnectTimeoutError, ReadTimeoutError) as e:
        # This path is hit during Experiment 2 (DDB network disruption)
        logger.error(f"DynamoDB error: {str(e)}")
        raise  # Re-raise so Lambda reports an error → Lex sees RuntimeLambdaErrors


def handle_check_order(intent_name, slots):
    """Check order status in DynamoDB."""
    order_id = get_slot_value(slots, 'OrderId')
    
    if not order_id:
        return build_lex_response(
            intent_name=intent_name,
            fulfillment_state='Failed',
            message="I need your order ID to look that up."
        )
    
    try:
        response = customer_table.get_item(
            Key={'account_id': f"ORDER#{order_id}"}
        )
        item = response.get('Item')
        
        # Chaos flag check (same rationale as handle_lookup_customer)
        chaos_enabled = _check_chaos_flag()
        if chaos_enabled:
            logger.warning(f"CHAOS FLAG ENABLED for {REGION} — returning Failed state to Lex")
            return build_lex_response(
                intent_name=intent_name,
                fulfillment_state='Failed',
                message="We're experiencing technical difficulties. Please try again later."
            )
        
        if item:
            status = item.get('order_status', 'processing')
            return build_lex_response(
                intent_name=intent_name,
                fulfillment_state='Fulfilled',
                message=f"Your order {order_id} is currently {status}."
            )
        else:
            return build_lex_response(
                intent_name=intent_name,
                fulfillment_state='Fulfilled',
                message=f"I couldn't find order {order_id}. Let me transfer you to support."
            )
            
    except (ClientError, ConnectTimeoutError, ReadTimeoutError) as e:
        logger.error(f"DynamoDB error: {str(e)}")
        raise


def _check_chaos_flag():
    """
    Read THIS REGION's chaos flag from the DynamoDB config table.

    The key is region-scoped on purpose: `chaos_flag#<region>`.

    The config table is a Global Table, so a single shared key would replicate the fault to
    the paired Region and Experiment 4 could never demonstrate recovery - failover would move
    the caller to a Region reading the same "broken" row, queueing into the same unstaffed
    queue. Scoping by region makes the fault genuinely regional, like Exps 1-3, so the paired
    Region serves normally after failover. Replication still happens and is now harmless: the
    row copies across, but each Region only ever reads its own key.

    Returns True if chaos is enabled for this region, False otherwise.
    If the config table is unreachable (e.g. during Exp 2's DynamoDB disruption), returns
    False so the error propagates from the customer lookup instead.
    """
    flag_key = f'chaos_flag#{REGION}'
    try:
        chaos_response = chaos_table.get_item(
            Key={'config_key': flag_key}
        )
        chaos_item = chaos_response.get('Item', {})
        return chaos_item.get('enabled', False)
    except (ClientError, ConnectTimeoutError, ReadTimeoutError) as e:
        # If we can't read chaos table, assume chaos is NOT enabled.
        # During Exp 2, DDB is unreachable — but the customer lookup
        # already raised before we got here, so this path is only hit
        # if the chaos config table specifically is unreachable while
        # the customer table is fine (unlikely in practice).
        logger.warning(f"Could not read chaos config {flag_key}: {str(e)}")
        return False


def handle_fallback(intent_name):
    """Handle unrecognized intents."""
    return build_lex_response(
        intent_name=intent_name,
        fulfillment_state='Failed',
        message="I'm sorry, I didn't understand that. Let me transfer you to an agent."
    )


def get_slot_value(slots, slot_name):
    """Extract resolved slot value from Lex V2 slot structure."""
    slot = slots.get(slot_name)
    if slot and slot.get('value'):
        return slot['value'].get('interpretedValue') or slot['value'].get('originalValue')
    return None


def build_lex_response(intent_name, fulfillment_state, message):
    """
    Build Lex V2 fulfillment response.
    
    fulfillment_state: 'Fulfilled' or 'Failed'
    When 'Failed' → Lex routes to Failure response path
    → Contact flow sees error → ContactFlowErrors or MissedCalls fires
    """
    return {
        "sessionState": {
            "dialogAction": {
                "type": "Close"
            },
            "intent": {
                "name": intent_name,
                "state": fulfillment_state
            }
        },
        "messages": [
            {
                "contentType": "PlainText",
                "content": message
            }
        ]
    }
