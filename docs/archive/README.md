# Archived variants — reference only, NOT deployed

These templates are kept for provenance. **Neither is wired into the shipping stack.**
The deployable template is `cfn/main-template.yaml` at the repo root.

## `variant-mrsc-exp2.main-template.yaml`

Experiment 2 implemented as **DynamoDB MRSC Region isolation** using the FIS action
`aws:dynamodb:global-table-pause-replication`, alarming on
`AWS/DynamoDB FaultInjectionServiceInducedErrors`.

Every API shape and metric dimension in it was verified against AWS documentation:

- `MultiRegionConsistency: STRONG` and `GlobalTableWitnesses` (max 1) are real
  `AWS::DynamoDB::GlobalTable` properties.
- MRSC requires **exactly three Regions** in one Region set — two replicas plus one
  witness. All three ACGR pairs fit inside a set (IAD/PDX → witness `us-east-2`;
  LHR/FRA → `eu-west-1` or `eu-west-3`; NRT/KIX → `ap-northeast-2`).
- `FaultInjectionServiceInducedErrors` is published only on the
  `TableName` + `Operation` dimension pair, and is a labelled subset of `SystemErrors`.
- On an MRSC table, pausing replication makes writes and **strongly consistent** reads
  fail with FIS-injected HTTP 500s. Eventually consistent reads are still served — which
  is why that variant's Lambda reads with `ConsistentRead=True`.

**Why it is not shipping:** the shipping Experiment 2 (network disruption plus a
call-logger Lambda invoked directly from the flow → `ContactFlowErrors`) is validated
against real inbound calls. The MRSC variant is documentation-verified but has never been
run. It also forces two significant costs: a third witness Region, and replacement of
`ConnectChaosCustomers`, because MRSC cannot be applied to an existing table in place.

Consider promoting it only after it has been exercised end to end on real telephony.

## `variant-agentqueue-exp4.deployed-london.yaml`

The template recovered from the **London stack as actually deployed**
(`aws cloudformation get-template`, account 101506645078, `eu-west-2`). It is the
validated baseline plus an `AgentQueueArn` parameter and an `EnableAgentTransfer`
condition: the primary IVR flow transfers the caller to a **staffed** queue after Lex, so
Experiment 4 depends on an agent not answering within 20 s to produce
`AWS/Connect MissedCalls`.

This parameter exists in **no** GitLab branch — it was deployed from work that was never
pushed. It is archived here so that work is not lost.

**Why it is not shipping:** it needs a human agent to deliberately not answer, which is
not reproducible for a reader following the runbook. The shipping Experiment 4 instead
transfers to a queue with **no routing profile**, so contacts provably accumulate
`LongestQueueWaitTime` with no human involvement.

> Note: this file came back from the CloudFormation API with the original template's
> box-drawing characters mangled to `?`. Treat it as a record of *structure and logic*,
> not as a byte-accurate source file.
