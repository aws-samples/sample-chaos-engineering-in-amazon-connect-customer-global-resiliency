# Contact Flow Reference Files

> **⚠️ These JSON files are reference copies only.** They are NOT used during deployment and may diverge from the authoritative inline versions in `cfn/main-template.yaml`.

The actual contact flows are deployed inline via CloudFormation (`AWS::Connect::ContactFlow` resources in `cfn/main-template.yaml`). The inline versions are the **single source of truth**.

## Key Differences from Inline CFN Versions

These reference files include `TransferContactToQueue` blocks with `PLACEHOLDER_QUEUE_ID` values to illustrate a production-like flow. The inline CFN versions omit queue transfers and disconnect directly after the message — this keeps the sample self-contained without requiring pre-existing queues in the Connect instance.

If you want queue-based routing in your deployment, update the **inline CFN content** (not these files) and supply valid Queue IDs for your Connect instance.

## Files

| File | Description |
|------|-------------|
| `main-ivr-flow.json` | Main IVR flow — greets caller, invokes Lex bot, routes to agent |
| `chaos-test-flow.json` | Chaos test flow — simplified flow for fault injection testing |

## Updating Flows

If you modify the contact flow logic, update the **inline `Content` property in `cfn/main-template.yaml`** — that is what CloudFormation deploys. Optionally update the reference files here for documentation purposes, but they have no effect on deployment.
