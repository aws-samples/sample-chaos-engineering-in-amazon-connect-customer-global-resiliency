"""
Synthetic Traffic Generator for Amazon Connect Customer FIS Chaos Engineering Sample.

This Lambda generates synthetic CloudWatch metric data points that simulate
real Amazon Connect Customer traffic. Use it to exercise the alarm -> composite alarm -> EventBridge ->
TrafficShiftHandler chain without placing phone calls.

What it does NOT do: it never runs a contact flow, so it cannot prove that a flow takes its
Error branch or that a fault is attributed to the right component. Only real calls do that.

Each fault type emits the exact metric (namespace, name and dimensions) that one experiment's
alarm in cfn/main-template.yaml watches:

    lambda    AWS/Connect ContactFlowErrors, ContactFlowName=ConnectChaos-Exp1-Lambda    (Exp 1)
    dynamodb  AWS/Connect ContactFlowErrors, ContactFlowName=ConnectChaos-Exp2-DynamoDB  (Exp 2)
    lex       AWS/Lambda  Duration ~31 s on LexFulfillmentHandler                        (Exp 3)
    flow      AWS/Connect LongestQueueWaitTime on ConnectChaos-Overflow                  (Exp 4)

Deployment: Optional (EnableTrafficGenerator=true).

Environment Variables:
    CONNECT_INSTANCE_ID: Connect instance ID for metric dimensions
    LEX_BOT_ID: Lex V2 Bot ID (healthy-mode Lex latency metric dimension)
    LEX_BOT_ALIAS_ID: Lex V2 Bot Alias ID
    LAMBDA_FUNCTION_NAME: LexFulfillmentHandler function name
    QUEUE_NAME / QUEUE_WAIT_SECONDS: overflow queue name and the wait to report (Exp 4)
    CALLS_PER_MINUTE: Number of simulated calls per invocation (default: 10)
    MODE: "healthy" (normal metrics) or "faulty" (error metrics for testing alarms)
    FAULT_TYPE: Which experiment to simulate — "lambda", "dynamodb", "lex", "flow", or "all"
"""

import os
import json
import random
from datetime import datetime, timezone

import boto3

cloudwatch = boto3.client("cloudwatch")


def put_metric(namespace, metric_name, dimensions, value=1.0, unit="Count"):
    """Emit a single CloudWatch metric data point."""
    cloudwatch.put_metric_data(
        Namespace=namespace,
        MetricData=[
            {
                "MetricName": metric_name,
                "Dimensions": [{"Name": k, "Value": v} for k, v in dimensions.items()],
                "Timestamp": datetime.now(timezone.utc),
                "Value": value,
                "Unit": unit,
            }
        ],
    )


def generate_healthy_traffic(instance_id, bot_id, bot_alias_id, function_name, count):
    """Emit metrics that represent normal, healthy call flow."""
    for _ in range(count):
        # Successful Lambda invocations
        put_metric(
            "AWS/Lambda",
            "Invocations",
            {"FunctionName": function_name},
        )
        # Successful Lex sessions (matching alarm dimension set)
        put_metric(
            "AWS/Lex",
            "SuccessfulRequestLatency",
            {
                "BotId": bot_id,
                "BotAliasId": bot_alias_id,
                "Operation": "RecognizeUtterance",
                "InputMode": "Speech",
                "LocaleId": "en_US",
            },
            value=random.uniform(200, 800),
            unit="Milliseconds",
        )
        # Calls handled
        put_metric(
            "AWS/Connect",
            "CallsPerInterval",
            {"InstanceId": instance_id, "MetricGroup": "VoiceCalls"},
        )


# ContactFlowName values of the Exp 1 and Exp 2 flows. They MUST match the ContactFlowName
# dimension of AlarmExp1Lambda / AlarmExp2DynamoDB in cfn/main-template.yaml, otherwise the
# alarm never sees the datapoints.
EXP1_FLOW_NAME = "ConnectChaos-Exp1-Lambda"
EXP2_FLOW_NAME = "ConnectChaos-Exp2-DynamoDB"


def _put_contact_flow_errors(instance_id, flow_name, count):
    """Emit AWS/Connect ContactFlowErrors for one named flow."""
    for _ in range(count):
        put_metric(
            "AWS/Connect",
            "ContactFlowErrors",
            {
                "InstanceId": instance_id,
                "MetricGroup": "ContactFlow",
                "ContactFlowName": flow_name,
            },
        )


def generate_lambda_errors(instance_id, count):
    """Simulate Experiment 1: the account-lookup Lambda fails inside the Exp 1 flow."""
    _put_contact_flow_errors(instance_id, EXP1_FLOW_NAME, count)


def generate_contact_flow_errors(instance_id, count):
    """Simulate Experiment 2: the call-logger write fails inside the Exp 2 flow."""
    _put_contact_flow_errors(instance_id, EXP2_FLOW_NAME, count)


def generate_lex_codehook_latency(function_name, count):
    """Simulate Experiment 3: Lex fulfillment code-hook latency.

    Exp 3's alarm watches AWS/Lambda Duration (Maximum) for LexFulfillmentHandler,
    because the FIS invocation-add-delay fault makes the code hook slow rather than failing it.
    We therefore emit a high Duration datapoint (~31s, mirroring the injected delay)
    so the alarm fires.
    """
    for _ in range(count):
        put_metric(
            "AWS/Lambda",
            "Duration",
            {"FunctionName": function_name},
            value=random.uniform(30000, 32000),
            unit="Milliseconds",
        )


def generate_queue_wait(instance_id, queue_name, wait_seconds, count):
    """Simulate Experiment 4: contacts backing up in the no-agent overflow queue.

    Emits LongestQueueWaitTime (Seconds) with the verified dimension set
    InstanceId + MetricGroup=Queue + QueueName, matching the Exp 4 alarm exactly.
    """
    for _ in range(count):
        put_metric(
            "AWS/Connect",
            "LongestQueueWaitTime",
            {"InstanceId": instance_id, "MetricGroup": "Queue", "QueueName": queue_name},
            value=float(wait_seconds),
            unit="Seconds",
        )


def handler(event, context):
    """
    Lambda handler for synthetic traffic generation.

    Can be invoked manually, on a schedule (EventBridge), or via the CLI:
        aws lambda invoke --function-name ConnectChaos-TrafficGenerator-<region> \\
            --payload '{"mode": "faulty", "fault_type": "lambda", "count": 10}' \\
            /dev/stdout

    Event overrides (optional):
        mode: "healthy" or "faulty"
        fault_type: "lambda", "dynamodb", "lex", "flow", or "all"
        count: number of metric data points to emit
    """
    # Configuration from env vars (with event overrides)
    instance_id = os.environ["CONNECT_INSTANCE_ID"]
    bot_id = os.environ.get("LEX_BOT_ID", "placeholder-bot-id")
    bot_alias_id = os.environ.get("LEX_BOT_ALIAS_ID", "placeholder-alias-id")
    function_name = os.environ.get("LAMBDA_FUNCTION_NAME", "LexFulfillmentHandler")

    queue_name = os.environ.get("QUEUE_NAME", "ConnectChaos-Overflow")
    queue_wait_seconds = int(os.environ.get("QUEUE_WAIT_SECONDS", "120"))

    mode = event.get("mode", os.environ.get("MODE", "healthy"))
    fault_type = event.get("fault_type", os.environ.get("FAULT_TYPE", "all"))
    count = int(event.get("count", os.environ.get("CALLS_PER_MINUTE", "10")))

    results = {"mode": mode, "count": count, "metrics_emitted": []}

    if mode == "healthy":
        generate_healthy_traffic(instance_id, bot_id, bot_alias_id, function_name, count)
        results["metrics_emitted"] = ["Invocations", "SuccessfulRequestLatency", "CallsPerInterval"]

    elif mode == "faulty":
        if fault_type in ("lambda", "all"):
            generate_lambda_errors(instance_id, count)
            results["metrics_emitted"].append("Connect/ContactFlowErrors (Exp1-Lambda flow)")

        if fault_type in ("dynamodb", "all"):
            generate_contact_flow_errors(instance_id, count)
            results["metrics_emitted"].append("Connect/ContactFlowErrors (Exp2-DynamoDB flow)")

        if fault_type in ("lex", "all"):
            generate_lex_codehook_latency(function_name, count)
            results["metrics_emitted"].append("Lambda/Duration (Lex code hook)")

        if fault_type in ("flow", "all"):
            generate_queue_wait(instance_id, queue_name, queue_wait_seconds, count)
            results["metrics_emitted"].append("Connect/LongestQueueWaitTime")

    else:
        return {"statusCode": 400, "body": f"Unknown mode: {mode}. Use 'healthy' or 'faulty'."}

    print(json.dumps(results))
    return {"statusCode": 200, "body": results}
