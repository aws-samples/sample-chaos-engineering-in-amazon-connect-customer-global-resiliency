# Deployment Fixes & Findings

This document records defects found while deploying and testing this sample against a
real ACGR-paired Amazon Connect instance (London `eu-west-2` ↔ Frankfurt `eu-central-1`),
the fixes applied to `cfn/main-template.yaml`, and important findings that are **not**
bugs (so they aren't "fixed" by mistake later).

## Summary

| # | Component | Symptom | Fix |
|---|-----------|---------|-----|
| 1 | Composite alarm | `CREATE_FAILED`: "Could not save the composite alarm as alarms [...] in the alarm rule do not exist" | Explicit `DependsOn` on the 4 child alarms |
| 2 | Contact flows | `InvalidContactFlowException` on `MainIVRFlow` / `ChaosTestFlow` | Add required prompt (`Text`) to the `ConnectParticipantWithLexBot` block |
| 3 | Lex bot | Locale build fails: "Slot ids [...] don't define a slot priority" → alias unbuilt/unusable | Add `SlotPriorities` to both intents |
| 4 | FIS config bucket | Paired-region deploy fails: "Bucket name should be between 3 and 63 characters long" | Shorten bucket name prefix to `ccfis-` |
| 5 | Connect ↔ Lex | Flows deploy but Lex is never reachable from Connect at call time | Add `AWS::Connect::IntegrationAssociation` (type `LEX_BOT`) |
| 6 | Experiment 2 metric | Exp 2 (DDB disruption) never produced `ContactFlowErrors` — it failed over via `Lambda-Errors` instead | Invoke a dedicated call-logger Lambda **directly from the flow** so its DDB failure takes a flow Error branch |
| 7 | Experiment 3 metric | Exp 3 (Lex delay) never produced `RuntimeLambdaErrors` on a real call — that metric isn't emitted for Connect's `StartConversation` voice path | Re-target the Exp 3 alarm to `LexFulfillmentHandler` **Duration** (the injected delay is directly observable) |

---

## Fix 1 — Composite alarm missing `DependsOn` (deploy blocker)

**Symptom (reproduced verbatim from a clean clone):**

```
CompositeAlarm  CREATE_FAILED
Resource handler returned message: "Could not save the composite alarm as alarms
[arn:...:alarm:ConnectChaos-Lex-RuntimeLambdaErrors-eu-west-2,
 arn:...:alarm:ConnectChaos-Lambda-Errors-eu-west-2] in the alarm rule do not exist
(Service: AmazonCloudWatch; Status Code: 400; Error Code: ValidationError)"
```

**Root cause:** `CompositeAlarm.AlarmRule` references the four child alarms by **name**
inside a `!Sub` string literal. CloudFormation only infers resource dependencies from
`Ref`/`GetAtt`/`Sub` *variable* references — not from names embedded in a literal — so it
creates the composite alarm in parallel with (and often before) its members. CloudWatch
then rejects the rule because the referenced alarms don't exist yet. Because it's a race,
the specific alarm(s) named as "missing" vary run to run.

**Fix:** explicit `DependsOn: [AlarmLambdaErrors, AlarmContactFlowErrors, AlarmLexRuntimeErrors, AlarmMissedCalls]` on `CompositeAlarm`.

---

## Fix 2 — Contact flow Lex block missing required prompt (deploy blocker)

**Symptom:** both `MainIVRFlow` and `ChaosTestFlow` fail with
`Service returned error code InvalidContactFlowException` (generic; CloudFormation hides
the detail).

**Root cause (found via `aws connect create-contact-flow ... --cli-error-format json`):**

```
"At least one of the following properties must be set. Properties:
 [Parameters.PromptId, Parameters.Text, Parameters.SSML, Parameters.Media,
  Parameters.LexInitializationData], Path: Actions[1]"
```

`Actions[1]` is the `ConnectParticipantWithLexBot` ("Get customer input") block, which
only set `LexV2Bot.AliasArn`. Connect requires the block to also carry a prompt.

**Fix:** add `"Text": "How can I help you today? ..."` to the Lex block `Parameters` in
both flows. (Verified against the Connect API — the flow then creates successfully.)

---

## Fix 3 — Lex intents missing `SlotPriorities` (runtime blocker)

**Symptom:** the CloudFormation `AWS::Lex::Bot` resource reaches `CREATE_COMPLETE`, but the
`en_US` locale build **fails** asynchronously:

```
Slot ids [OrderId] in intent CheckOrderStatus don't define a slot priority...
Slot ids [AccountNumber] in intent LookupCustomer don't define a slot priority...
```

The bot alias is therefore never built. Any runtime call is rejected with
"The alias isn't built."

**Root cause:** Lex V2 requires a `SlotPriorities` entry for every slot in an intent; the
intents defined slots but no priorities.

**Fix:** add `SlotPriorities` (Priority 1) for `AccountNumber` (LookupCustomer) and
`OrderId` (CheckOrderStatus). With priorities present from the first deploy, the version
builds cleanly and the alias is usable — verified with `lexv2-runtime recognize-text`.

> Note: when this was fixed on an *already-deployed* broken stack, the existing immutable
> bot version was stuck `Failed` and had to be replaced by renaming the `BotVersion`
> logical id. On a **clean** deploy with `SlotPriorities` present this is unnecessary — the
> first version builds correctly — so no version-rename workaround is included here.

---

## Fix 4 — FIS config bucket name exceeds S3's 63-char limit in some regions

**Symptom:** primary region (`eu-west-2`) deploys, but the paired region
(`eu-central-1`) fails on `FISConfigBucket`:

```
Bucket name should be between 3 and 63 characters long
```

**Root cause:** the name `connect-chaos-fis-${AccountId}-${Region}-${StackName}` is
18 + 12 + 1 + region + 1 + stackname chars. For `eu-central-1` with stack name
`connect-chaos-sample` that's **64** chars (over the limit); `eu-west-2` (shorter region
name) was 61 and slipped through. `ap-northeast-3` would also overflow.

**Fix:** shorten the static prefix to `ccfis-`, keeping account/region/stackname for
uniqueness while staying within 63 chars across all supported regions.

---

## Fix 5 — Missing Lex `IntegrationAssociation` (runtime correctness)

**Root cause:** the template never associates the Lex bot alias with the Connect instance.
A Lex V2 bot must be associated with the instance for a contact flow to invoke it at call
time. (This does not block flow *creation* — Connect accepts the flow content — but the
bot would be unreachable from Connect during a real call.)

**Fix:** add an `AWS::Connect::IntegrationAssociation` (`IntegrationType: LEX_BOT`,
`IntegrationArn` = bot alias ARN) in the primary region, and make both flows `DependsOn`
it. ACGR / Lex Global Resiliency handle the paired region.

---

## Fix 6 — Experiment 2 never produced `ContactFlowErrors` (metric-mismatch bug)

**Symptom:** running Experiment 2 (`aws:network:disrupt-connectivity`, `scope=dynamodb`)
against a **real inbound call** did fail traffic over to the paired region — but via the
**`ConnectChaos-Lambda-Errors`** alarm, never **`ConnectChaos-ContactFlow-Errors`**. The
sample (README experiments table, alarm name, dashboard panel, composite rule, and the
`ContactFlowErrorsThreshold` parameter) explicitly commits to Exp 2 being observable as
`AWS/Connect ContactFlowErrors`, so failing over on the wrong metric is a defect.

**Root cause:** the original design routed the DDB call **through the Lex fulfillment
code hook**. When FIS severs DDB connectivity, that path produces:

- `AWS/Lambda Errors` (the fulfillment Lambda raises), and
- `AWS/Lex RuntimeLambdaErrors` (Lex sees the code-hook error),

but **not** `ContactFlowErrors`. `ContactFlowErrors` is only incremented when Amazon
Connect routes a contact **down a block's Error branch**
([re:Post](https://repost.aws/knowledge-center/connect-contact-flow-errors)). The flow's
`ConnectParticipantWithLexBot` ("Get customer input") block *handles* a code-hook failure
on its own `NoMatchingError` branch — that is normal input-handling, and Connect does not
count it as a contact-flow error. Attempts to make the Lex block's failure "unhandled"
are rejected by Connect at flow-create time (`Action is missing required error`), so the
Lex block can never be the `ContactFlowErrors` source here.

**Fix:** add a realistic call-logger Lambda (`ConnectChaos-CallLogger`,
`lambda/call_logger.py`) that the flow invokes **directly** via an `InvokeLambdaFunction`
("Invoke AWS Lambda function") block placed *before* the Lex block:

```
entry (welcome) → log-call (InvokeLambdaFunction) → lex-input (Lex) → success/error
                        │
                        └─ Error branch → error-msg   ← THIS increments ContactFlowErrors
```

This is a genuine contact-center pattern, not a synthetic probe: the first block of the
flow persists the inbound contact (ContactId, caller number, dialed number, channel,
timestamp) to a DynamoDB Global Table (`ConnectChaosCallLog`) — the audit / interaction-
history write a real contact center performs before servicing the caller. The Lambda runs
in the **same VPC subnets FIS Exp 2 disrupts** and does a `put_item` with a short 2 s DDB
timeout. Under normal conditions the write succeeds in a few ms and the call proceeds to
Lex unchanged. During Exp 2 the `put_item` raises within ~2 s, Connect routes the contact
down the `InvokeLambdaFunction` block's **Error branch**, and `ContactFlowErrors` fires —
exactly the metric the sample documents. The "Invoke AWS Lambda function" block is
explicitly named by AWS as a `ContactFlowErrors` source, so this is the supported,
reliable path.

**Supporting resources added (in `cfn/main-template.yaml`):**
- `CallLogTable` (`AWS::DynamoDB::GlobalTable`, `ConnectChaosCallLog`) — inbound-call log,
  replicated to the paired region, 90-day TTL on `expires_at`. Primary region only (the
  Global Table auto-creates the paired-region replica).
- `CallLoggerHandler` (`AWS::Lambda::Function`) — VPC-attached, invoked directly by the flow.
- `CallLoggerRole` (`AWS::IAM::Role`) — least privilege: VPC networking + `dynamodb:PutItem`
  on the call-log table only (it cannot read the customer/config tables).
- `CallLoggerPermission` (`AWS::Lambda::Permission`) — allows `connect.amazonaws.com`.
- `CallLoggerAssociation` (`AWS::Connect::IntegrationAssociation`, `LAMBDA_FUNCTION`) —
  created in **both** regions (there is no Lex-GR equivalent for Lambda) so ACGR can remap
  the ARN in the replicated paired-region flow.

**Verified end-to-end (real call, London primary):**
`CallLogger` invocation → Errors=1 → `ContactFlowErrors`(ConnectChaos-MainIVR)=1 →
`ConnectChaos-ContactFlow-Errors` ALARM → Composite ALARM → traffic shifted
London 0% / Frankfurt 100%. (Initially verified with an equivalent `get_item` health-check
probe; reshaped into the call-logger write path for realism — same error-branch behavior.)

> Note on threshold: the fault working is not the same as the alarm firing. One test call
> produces exactly **one** `ContactFlowErrors` datapoint, so any threshold above 0 cannot be
> exceeded by a single call. `ContactFlowErrorsThreshold` therefore defaults to `0`. This was
> originally `5`, which silently blocked the experiment — see Fix 15.

---

## Fix 7 — Experiment 3 never produced `RuntimeLambdaErrors` on a real call

**Symptom:** running Experiment 3 (`aws:lambda:invocation-add-delay`) against a real inbound
call never fired the `ConnectChaos-Lex-RuntimeLambdaErrors` alarm, so it never failed over.
The sample committed to Exp 3 being observable as `AWS/Lex RuntimeLambdaErrors`.

**Root cause (confirmed over repeated real calls):** two compounding problems.

1. **Wrong operation.** Real Amazon Connect *voice* invokes the bot through the
   bidirectional streaming API `Operation=StartConversation` (`InputMode=Speech`). The
   original alarm summed `RuntimeLambdaErrors` over `RecognizeUtterance` and `RecognizeText`
   — request/response operations only produced by the CLI and the synthetic traffic
   generator. `list-metrics` for this bot confirms the only `RuntimeLambdaErrors` dimension
   set ever emitted is `RecognizeUtterance/Speech` (synthetic), never `StartConversation`.

2. **The injected delay/timeout did not surface as a Lex error metric on the streaming
   path.** Per the
   [Lex V2 CloudWatch docs](https://docs.aws.amazon.com/lexv2/latest/dg/monitoring-cloudwatch.html),
   `RuntimeLambdaErrors` counts code-hook **runtime errors** (exception / Lambda-side
   timeout / failure to execute) — distinct from `RuntimeInvalidLambdaResponses` (bad
   response) and `RuntimeSystemErrors`/`RuntimeUserErrors` (5xx/4xx). In our testing, across
   repeated real `StartConversation` calls, the Exp 3 fault produced **no** Lex-namespace
   error datapoint: when the code hook timed out the failure showed up only as `AWS/Lambda
   Errors`, and when it ran slow-but-successful there was no error at all. The only
   `RuntimeLambdaErrors` datapoints on this bot were under `RecognizeUtterance` (synthetic).
   We did not find a delay/timeout configuration that produced `RuntimeLambdaErrors` on the
   real voice path.

   > Caveat: we did not test whether a *hard code-hook exception* (e.g. FIS
   > `invocation-error`) produces `RuntimeLambdaErrors` on `StartConversation` — that path
   > was never exercised. This finding is specifically about the delay/timeout fault used by
   > Exp 3, not a proof that the metric can never be emitted for streaming.

**Fix:** re-target the Exp 3 alarm to the fulfillment Lambda's **`AWS/Lambda Duration`**
(`Statistic: Maximum`, threshold `LexCodeHookLatencyThresholdMs`, default 7000 ms), renamed
`ConnectChaos-Lex-CodeHookLatency-${region}`. The experiment raises `LexFulfillmentHandler`'s
timeout to 40 s and injects a ~31 s startup delay, so on every real call the code-hook
Duration spikes to ~31 s while the function still returns cleanly (0 Lambda errors). This
is reliable on real telephony and stays cleanly distinct from Exp 1 (`invocation-error` →
the function never runs → Duration ~0, `Errors` > 0). Composite rule and both dashboards
were updated to the new alarm/metric; the former `RuntimeLambdaErrorsThreshold` parameter
is replaced by `LexCodeHookLatencyThresholdMs`.

**Verified end-to-end (real call, London primary):** `LexFulfillmentHandler` Duration
Maximum = 31159 ms → `ConnectChaos-Lex-CodeHookLatency` ALARM → Composite ALARM → traffic
shifted London 0% / Frankfurt 100%.

---

## NOT bugs — do not "fix" these

- **Experiment 3 uses a Lambda `Duration` alarm, not `AWS/Lex RuntimeLambdaErrors`.** This is
  intentional — see Fix 7. In testing, the injected delay/timeout did not surface as
  `RuntimeLambdaErrors` on the real Connect voice (`StartConversation`) path, so the code
  hook's Duration is the reliable real-call signal. The synthetic generator
  (`fault_type=lex`) still emits `RuntimeLambdaErrors` under `RecognizeUtterance` if you want
  to exercise that metric.

---

## Operational findings (real-telephony testing)

These are not template bugs, but behaviors you must account for when demonstrating the
experiments with real inbound calls.

### FIS Lambda-extension experiments have a ~180 s config-freshness window (Exp 1 & 3)

`aws:lambda:invocation-error` (Exp 1) and `aws:lambda:invocation-add-delay` (Exp 3) work
through the **AWS FIS Lambda extension** (the layer added to `LexFulfillmentHandler`). The
extension reads its fault config from S3 (`AWS_FIS_CONFIGURATION_LOCATION`), polls roughly
every 60 s, and **ignores any config older than ~180 s**. Practical consequences:

- A real call must land **within ~3 minutes** of starting the experiment, otherwise the
  extension treats the config as stale and the invocation runs normally (no fault).
- If your first test call misses the window, re-start the experiment and call again
  promptly.

Experiment 2 (`aws:network:disrupt-connectivity`) is **network-level**, not
extension-based, so it has **no 180 s window** — the DynamoDB path is severed for the
entire experiment duration. This is why Exp 2 is the most reliable to demo with a live
call, and why the health-check Lambda in Fix 6 is a clean fit.

### All faults ultimately manifest as `AWS/Lambda Errors` too

Because every fault ultimately flows through a Lambda, the `AWS/Lambda Errors` metric rises
during Exp 1, 2, and 3. The composite alarm ORs all four child alarms, so **failover still
happens**, but if you are demonstrating a *specific* experiment's *distinct* metric, watch
that metric's own alarm rather than the composite. Fix 6 exists precisely so Exp 2's
distinct metric (`ContactFlowErrors`) fires on its own path rather than only riding the
`Lambda-Errors` alarm.

### The template now exceeds 51,200 bytes — deploy needs an S3 staging bucket

After Fix 6 the template is larger than CloudFormation's 51,200-byte limit for an inline
template body. `aws cloudformation deploy` must be given an S3 staging bucket:

```bash
aws cloudformation deploy --template-file cfn/main-template.yaml \
  --s3-bucket <your-bucket> --s3-prefix cfn-staging ...
```

For StackSets, use `--template-url` (S3) instead of `--template-body file://`. The
`LambdaCodeBucket` you already create for the Lambda zips works fine as the staging bucket.

### `aws cloudformation deploy` auto-deletes a failed *new* stack on rollback

When a brand-new stack fails to create, `aws cloudformation deploy` rolls it back and
deletes it, discarding the events you need to debug. To preserve a failed first-create for
inspection, use `aws cloudformation create-stack --on-failure DO_NOTHING` instead, read the
failure from `describe-stack-events`, then delete manually.

---

# Round 2 — correctness review and prerequisite removal

A second pass over the template. Fixes 8–10 are defects that would have broken the sample's
central claim; 11–13 remove prerequisites. Everything here was verified against AWS
documentation or a live API call, and the record below deliberately includes **two ideas that
were investigated and rejected**, so they are not "fixed" again later.

## Summary

| # | Component | Symptom | Fix |
|---|-----------|---------|-----|
| 8 | Contact flows | After failover the paired region invoked the **primary** region's Lex bot, so the "served locally" claim was false | Use the ACGR `$.AwsRegion` runtime token in the flow's Lex alias ARN |
| 9 | Experiment 4 | `MissedCalls` cannot be produced without a staffed agent deliberately not answering — not reproducible by a reader | Route the failure path to a **no-agent** queue and alarm on `LongestQueueWaitTime` |
| 10 | Lambda runtime | `python3.12` | `python3.13` (supported to Jun 2029) |
| 11 | VPC | The reader had to supply a VPC whose subnets could reach DynamoDB **and S3** | `CreateVpc=true` builds it, with free gateway endpoints |
| 12 | FIS layer ARN | Hand-copied per region; both the publishing account and version differ, so a wrong value fails silently | Resolve from the AWS public SSM parameter |
| 13 | Code bucket | Manual create + zip + upload to an exact prefix | `make` creates the bucket and uploads; also stages the oversized template |

---

## Fix 8 — Flows hardcoded the primary region's Lex ARN (breaks the core claim)

**Symptom:** both flows carried `"AliasArn":"${ConnectChaosBotAlias.Arn}"`, which resolves to
a **primary-region** ARN. ACGR replicates flow content verbatim, so the paired region's copy
still pointed at the primary region's Lex bot. Traffic would shift correctly and the metrics
would look right, while the paired region depended on the region we had just declared
unhealthy.

**Why it was not caught earlier:** the failure is invisible unless you deploy *both* regions
and inspect which region's Lambda logs the call. A previous London run only ever verified
that traffic shifted.

**Fix:**

```
arn:aws:lex:$.AwsRegion:${AWS::AccountId}:bot-alias/${ConnectChaosBot.Id}/${ConnectChaosBotAlias.BotAliasId}
```

`$.AwsRegion` is resolved by Connect at flow runtime to the region the flow is executing in.
This works because Lex Global Resiliency preserves the bot ID and alias ID across regions, so
the same ID pair is valid in both. Per the ACGR requirements, `$.AwsRegion` is supported
**only** for Lambda and Lex ARNs.

**Still required when Lex GR is off** (`ap-northeast-1`↔`ap-northeast-3`): the per-region bot
IDs differ, so `$.AwsRegion` alone is insufficient and `scripts/wire-paired-flow.sh` must be
run after deploy.

**Verification:** with traffic at 0%/100%, place a call and confirm the **paired** region's
`LexFulfillmentHandler` logs it and the primary's does not. See the runbook.

---

## Fix 9 — Experiment 4 was not reproducible

**Symptom:** Exp 4 alarmed on `AWS/Connect MissedCalls`, defined as a voice call *not
answered by an agent within 20 seconds*. It therefore needs a real agent, staffed and
logged in, who deliberately does not answer. A reader following the runbook cannot
reproduce that, and the earlier `AgentQueueArn` approach only moved the problem (it required
a staffed queue).

**Fix:** create `ConnectChaos-Overflow`, a queue that **no routing profile references**, so
no agent can ever receive its contacts. The chaos-test flow's failure path now does
`UpdateContactTargetQueue` → `TransferContactToQueue` into it, so a contact waits
indefinitely and `LongestQueueWaitTime` rises deterministically with no human involved.

Verified dimensions: `InstanceId` + `MetricGroup=Queue` + `QueueName`. `Statistic: Maximum`,
because longest-wait is a gauge, not a rate. An `AWS::Connect::Queue` requires an
`HoursOfOperationArn`, so a 24×7 `ConnectChaos-24x7` is created alongside it. Both are
primary-only and replicated by ACGR, which also remaps the flow's queue reference — so no
`$.AwsRegion` handling is needed for Connect-internal ARNs.

`MissedCallsThreshold` is replaced by `QueueWaitSecondsThreshold` (default 60).

> **Not yet validated on real telephony.** The mechanism is sound and the dimensions are
> confirmed, but unlike Exps 1–3 this has not been proven with a live call. Treat the first
> run as its verification.

---

## Fix 11 — VPC prerequisite removed (and why S3 matters as much as DynamoDB)

The reader previously had to bring a VPC whose subnets could reach DynamoDB. `CreateVpc=true`
(default) now builds a VPC, two private subnets in different AZs, a route table, an
egress-only security group, and **gateway endpoints for DynamoDB and S3**.

**No NAT gateway and no internet gateway.** Which functions are actually VPC-attached was
checked rather than assumed:

| Function | `VpcConfig` | Talks to |
|---|:---:|---|
| `LexFulfillmentHandler` | yes | DynamoDB, S3 (FIS extension) |
| `ConnectChaos-CallLogger` | yes | DynamoDB, S3 (FIS extension) |
| `ConnectChaos-TrafficShiftHandler` | no | Connect APIs |
| `ConnectChaos-TrafficGenerator` | no | CloudWatch |

Only DynamoDB and S3 reachability is needed, and gateway endpoints for both are free — *"There
is no additional charge for using gateway endpoints"* (VPC PrivateLink docs). So the VPC adds
**$0**.

**S3 is not optional.** The FIS Lambda extension polls S3 for its fault config via
`AWS_FIS_CONFIGURATION_LOCATION`. Without an S3 route, Experiments 1 and 3 **silently** never
apply their fault — the invocation simply runs normally. This is the single easiest thing to
get wrong when bringing your own VPC.

`CreateVpc=false` preserves the old behaviour. The subnet/SG parameters had to move from
`AWS::EC2::Subnet::Id` / `SecurityGroup::Id` to `String`, because the strict types reject an
empty value. A new Rule, `BringYourOwnVpcNeedsIds`, asserts all three are supplied when
`CreateVpc=false`, so the looser type cannot silently produce a broken stack. FIS Experiment
2's subnet targets follow the effective subnets either way.

---

## Fix 12 — FIS extension layer ARN now resolves itself

Hand-copying this value is unusually error-prone because **both the publishing account and
the version differ per region**:

```
us-east-1 -> arn:aws:lambda:us-east-1:211125607513:layer:aws-fis-extension-x86_64:374
us-west-2 -> arn:aws:lambda:us-west-2:975050054544:layer:aws-fis-extension-x86_64:370
```

A wrong ARN does not fail loudly — the extension simply never applies a fault.

`FISExtensionLayerArn` is now `AWS::SSM::Parameter::Value<String>` defaulting to
`/aws/service/fis/lambda-extension/AWS-FIS-extension-x86_64/1.x.x`, which CloudFormation
resolves per region at deploy time. Override only to pin a version.

Cross-account `lambda:ListLayerVersions` is **denied** on the public layer, so SSM is the only
programmatic route.

---

## Fix 13 — No manual bucket, no manual zipping

`make bucket` creates the code bucket if missing (idempotent); `upload`/`bootstrap`/`deploy`
depend on it. The same bucket stages the template, which is **mandatory rather than optional**:
the template is ~65 KB and CloudFormation's inline `TemplateBody` limit is 51,200 bytes.

`make deploy-pair` deploys both regions in order and hands the Lex GR bot/alias IDs from the
primary stack to the paired stack, leaving **both** standing — which is what makes Fix 8's
verification possible.

Deploy now needs only `STACK`, `REGION`, `CONNECT_INSTANCE_ARN`, `CONNECT_INSTANCE_ID`,
`TDG_ID`.

---

## Investigated and REJECTED — do not redo these

### Adding `Operation=StartConversation` to a `RuntimeLambdaErrors` alarm

Reasoning from documentation suggests Connect voice should report `RuntimeLambdaErrors` with
`Operation=StartConversation`, since Connect drives Lex over the streaming API. It is a
plausible chain and it is **wrong in practice**: Fix 7 established by `list-metrics` over
repeated real calls that the only dimension set this bot ever emits is
`RecognizeUtterance/Speech` (synthetic traffic). Adding `StartConversation` to the alarm
creates a branch that never matches.

Experiment 3 stays on Lambda `Duration`. Do not "restore" the Lex metric.

### Inlining the Lambda code with `Code.ZipFile`

Attractive because it removes the zip-and-upload step. The inline limit is **4 MB**, so it
would fit. Rejected because:

- the template is already ~65 KB, over the 51,200-byte inline limit, so a staging bucket is
  needed **regardless** — inlining buys nothing there;
- it duplicates 27.6 KB of Python inside the YAML, which will drift from `lambda/*.py`;
- CloudFormation names the inline file `index`, forcing every handler to be renamed to
  `index.*`.

Fix 13 automates the bucket instead, achieving the same goal without the drift risk.

### Adding botocore fast-fail timeouts to `LexFulfillmentHandler`

Would have broken Experiment 3. That function's **40 s timeout is load-bearing**: the ~31 s
injected delay must complete and return cleanly so `Duration` spikes while `Errors` stays 0.
Short timeouts would turn it into an error and make Exp 3 indistinguishable from Exp 1.

`call_logger.py` already has an appropriate fast-fail Config (`connect_timeout=2`,
`read_timeout=2`, single attempt) — correct there, because it is invoked directly by the flow
under an 8 s limit and must surface a DynamoDB failure as a handled error.

---

## Open verification items

Not yet proven on real telephony:

1. **Fix 8** — a call answered in the paired region, confirmed via that region's Lambda logs.
2. **Fix 9** — `LongestQueueWaitTime` breaching on a genuinely unstaffed queue.
3. **Fix 11** — that a VPC-attached Lambda writes CloudWatch Logs through only DynamoDB and
   S3 gateway endpoints. If logs are missing after the first deploy, add a CloudWatch Logs
   interface endpoint (~$7/month/AZ). This was deliberately not added speculatively.

---

## Fix 14 — `AWS::Lex::Bot` `Replication` did not leave a persistent GR replica

**Symptom:** immediately after `make deploy-pair`, bot `QJ5VLLR4GH` was visible in the paired
region via `list-bots` with status `Available`, and the paired stack's
`AWS::Connect::IntegrationAssociation` (which references the replicated bot alias ARN)
created successfully — so the replica demonstrably existed. Roughly forty minutes later the
bot was **gone** from the paired region and the authoritative API reported no replica at all:

```
$ aws lexv2-models list-bot-replicas --bot-id QJ5VLLR4GH --region us-east-1
{ "botId": "QJ5VLLR4GH", "sourceRegion": "us-east-1", "botReplicaSummaries": [] }
```

This is the worst class of failure this sample can have: every stack resource reported
`CREATE_COMPLETE`, every alarm reported `OK`, and a failover would have shifted traffic to a
region whose contact flow had **no reachable Lex bot**.

**What was ruled out:**

- `EnableLexGlobalResiliency` was `true` on the deployed stack.
- The deployed template did carry the `Replication` block (confirmed via
  `cloudformation get-template`), so the intent reached CloudFormation.
- CloudTrail showed **zero** `CreateBotReplica`, `DeleteBotReplica` or `DeleteBot` events in
  either region over the relevant window — so nothing recorded creating *or* removing it.
- Lex GR itself is fully functional in this account, proven below.

**Root cause: not established.** The replica lifecycle left no CloudTrail trail, so the
disappearance cannot be attributed with the evidence available. It is recorded here as an
observed behaviour rather than an explained one.

**Remediation that worked.** Creating the replica explicitly succeeded immediately and
persisted:

```bash
aws lexv2-models create-bot-replica --bot-id <botId> --replica-region <paired> --region <primary>
#   botReplicaStatus: Enabling  ->  Enabled   (within ~30 s)
```

Note that the **bot** replica becoming `Enabled` is not sufficient. The bot **alias** replica
is created separately and lags:

```
IYOEXZUVAZ | Creating  | v0000000001     <- ~90 s
IYOEXZUVAZ | Available | v0000000001
```

The contact flow's `$.AwsRegion` Lex ARN resolves to the **alias**, so the paired region
cannot serve a call until the *alias* replica is `Available` — not merely the bot.

Preconditions confirmed present before replication would work: a numbered bot version
(`1`, not just `DRAFT`) and an alias pointing at it.

**Consequence for the sample.** Do not treat `Replication` in the template as sufficient
evidence that the paired region is usable. `make verify` now checks this explicitly, in both
Lex modes, and reports the replica count. It was this check that caught the regression —
before any test call was spent on it.

**Follow-up worth doing:** determine whether the `Replication` property reliably establishes
a *durable* replica, or whether an explicit `create-bot-replica` should be part of
`post-deploy`. Until that is known, always run `make verify` after deploying and re-check it
before a failover demonstration.

---

## Baseline call — verified on real telephony (IAD, `+448085478029`)

First real inbound call against the IAD/PDX deployment, before any experiment. Full chain
passed: Connect → call-logger direct invoke → DynamoDB write → Lex → fulfillment code hook →
DynamoDB lookup → "Welcome back, John Doe".

```
ContactId      2b4a4ac7-34ef-4b3e-b0dc-bfd1a07ec61e   Channel VOICE   INBOUND
CallLogger     Logged contact ... (ANI=+447345750038, region=us-east-1)   511 ms
Lex            ConnectChaosBot QJ5VLLR4GH  alias IYOEXZUVAZ  platform Connect
ASR            "one two three four five" -> interpretedValue "12345"  (confidence 1.0)
Fulfillment    Intent LookupCustomer, Duration 300 ms, 0 errors
```

Two results from that single call are worth recording permanently.

### Confirmed: the VPC design needs no NAT and no Logs endpoint

Both Lambda log groups were created on first invocation, so a **VPC-attached Lambda writes
CloudWatch Logs successfully with only the DynamoDB and S3 gateway endpoints** — no NAT
gateway and no CloudWatch Logs interface endpoint. This closes the open question left by
Fix 11; the interface endpoint that was deliberately not added speculatively is not needed.

More importantly, the FIS extension proved it can reach S3 through the gateway endpoint:

```
AWS FIS EXTENSION - extension enabled 1.0.6
AWS FIS EXTENSION - polling S3 for active faults impacting this Lambda function
AWS FIS EXTENSION - no active faults found (updated polling interval 60s)
```

That is the concrete justification for the S3 gateway endpoint being mandatory rather than
optional: without it this poll fails and Experiments 1 and 3 silently apply no fault at all,
while every stack resource and alarm still reports healthy.

### Correction to Fix 7 — the reason was wrong, the conclusion was right

Fix 7 stated that `AWS/Lex RuntimeLambdaErrors` is not usable for Experiment 3 **because**
Connect voice never reports `Operation=StartConversation`. The first half of that is correct;
the stated cause is not.

`list-metrics` after a real Connect voice call shows `StartConversation` unambiguously:

```
metric=RuntimeConcurrency             Operation=StartConversation  InputMode=Speech  alias=IYOEXZUVAZ
metric=RuntimeRequestCount            Operation=StartConversation  InputMode=None    alias=IYOEXZUVAZ
metric=RuntimeRequestLength           Operation=StartConversation  InputMode=None    alias=IYOEXZUVAZ
metric=RuntimeSucessfulRequestLatency Operation=StartConversation  InputMode=Speech  alias=IYOEXZUVAZ
metric=RuntimeRequestCount            Operation=GetConnectAudioResponseMode          alias=IYOEXZUVAZ
```

So Connect **does** drive Lex through the streaming `StartConversation` operation, exactly as
the Lex V2 documentation describes.

The real reason the metric is unusable is different and simpler: **`RuntimeLambdaErrors` is
not emitted for this bot at all.** The only Lex-namespace metrics produced are
`RuntimeConcurrency`, `RuntimeRequestCount`, `RuntimeRequestLength` and
`RuntimeSucessfulRequestLatency` (note the AWS spelling of "Sucessful"), plus a
`GetConnectAudioResponseMode` operation specific to the Connect integration.

**Experiment 3 stays on `AWS/Lambda Duration`.** The decision is unchanged and correct. This
entry exists so that nobody later reverses it after discovering that the reason recorded in
Fix 7 does not hold — the conclusion is right for a different reason than originally written.

**Do not** add `Operation=StartConversation` to a `RuntimeLambdaErrors` alarm. The dimension
value is real, but the metric itself is never published, so such an alarm would sit in
`INSUFFICIENT_DATA` indefinitely.

---

## Fix 15 — Alarm thresholds made a working fault unobservable (Exps 1 and 2)

**Symptom:** Experiment 2 was started against the IAD deployment and the fault worked exactly
as designed — the caller heard *"We are experiencing difficulties"* and Connect recorded
`ContactFlowErrors = 1.0` on `ConnectChaos-MainIVR`. Yet `ConnectChaos-ContactFlow-Errors`
stayed in `OK`, the composite alarm never fired, no EventBridge rule matched, no traffic
shifted. Every layer looked correct in isolation.

**Root cause: arithmetic, not chaos.** The alarm compared the metric with
`GreaterThanThreshold` against `ContactFlowErrorsThreshold`, default `5`, over a single 60 s
period. One inbound call produces exactly one error, and `1 > 5` is false. The threshold was
a sensible production monitoring value carried into a sample whose entire demonstration is
**one** phone call, so it could never be satisfied.

Experiment 1 had the same defect and was worse: its `Threshold: 5` was **hardcoded** in
`AlarmLambdaErrors` with no parameter at all, so it could not even be overridden at deploy
time.

Experiments 3 and 4 were unaffected — their signals are magnitudes, not counts, so a single
call already clears them (Duration ~31 000 ms vs 7 000; queue wait ~90 s vs 60).

**Fix:**

| Parameter | Was | Now |
|---|---|---|
| `ContactFlowErrorsThreshold` | `5` | `0` |
| `LambdaErrorsThreshold` | *did not exist* (hardcoded `5`) | `0`, referenced by `AlarmLambdaErrors` |

With `GreaterThanThreshold` and a threshold of `0`, a single error trips the alarm. Both are
parameters, so raising them for production monitoring is a deploy-time choice, and `make
deploy` passes them through (`CONTACT_FLOW_ERRORS_THRESHOLD`, `LAMBDA_ERRORS_THRESHOLD`).
No hardcoded numeric `Threshold` remains in the template.

**Verified end-to-end after the fix (real call, IAD primary / PDX paired):**

```
18:43:05  ConnectChaos-ContactFlow-Errors-us-east-1  OK -> ALARM   (1.0 > 0.0)
18:43:05  ConnectChaos-Composite-us-east-1                 -> ALARM
18:43:06  TrafficShiftHandler invoked (EventBridge alarm state change)
18:43:07  Traffic shifted: us-east-1=0%, us-west-2=100%
          FIS experiment -> stopped, "Experiment halted by stop condition"
```

Alarm to failover was **two seconds**. Note the ~60–90 s lag between the call and the alarm:
Connect publishes `ContactFlowErrors` on a delay, so checking `describe-alarms` immediately
after hanging up shows `OK` and reads as a failure. Wait for the datapoint before concluding
anything — `get-metric-data` on the alarm's own expression is the way to tell "no datapoint
yet" apart from "datapoint present but not breaching".

**Side effect: the FIS stop conditions become live.** Each experiment's stop condition is its
*own* detection alarm (`AlarmLambdaErrors` guards Exp 1, `AlarmContactFlowErrors` guards
Exp 2). At threshold `5` those guardrails were **inert** — a single-call demo could never
trigger them. At `0` they work as designed, as the run above confirms: the experiment
self-terminates the moment impact is detected, and the fault is withdrawn. Failover is unaffected, because the alarm state
change reaches EventBridge and the composite alarm independently of the experiment's
lifecycle. Two practical consequences:

- An experiment that ends in `stopped` with a stop-condition reason is a **success**, not a
  failure. It means the alarm fired.
- The alarm must be back in `OK` before re-running, which is why Step R of the runbook waits
  for `describe-alarms` to return empty. `make verify` asserts the same thing.

Applying this to a live stack is a two-alarm, in-place change, but CloudFormation also lists
`FISExperimentDDBDisruption` and `FISExperimentLambdaFailure` in the change set. Those are
`Dynamic`/`ResourceAttribute` ripples from `StopConditions` referencing `<alarm>.Arn`; the
alarm names are unchanged, so the ARNs are unchanged and they are no-ops.

**The generalisable lesson.** When validating a chaos experiment, verify the *fault*, the
*metric* and the *alarm* as three separate steps. This failure sat entirely in the last one
while the first two were provably healthy, which is why it read as "the experiment does not
work" rather than "the threshold is wrong". `describe-alarms` on the child alarm — not the
composite — is the check that localises it in seconds.

---

## Fix 16 — The flow pinned the call-logger Lambda to the primary region

**Symptom:** with traffic at `us-east-1 0% / us-west-2 100%`, a real inbound call was served by
the paired region and the caller heard *"We are experiencing difficulties"*. The contact record
existed in `us-west-2` (contact `4fdf3f91`, 19:21:35Z) and there was **no contact in
`us-east-1`**, so ACGR routing was correct. But **neither region logged a Lambda invocation** —
`us-west-2` had no `ConnectChaos-CallLogger` log group at all, and `us-east-1`'s log group had
no entry for that contact. Nothing ran anywhere.

**Root cause.** The MainIVR flow's `log-call` block was:

```
"LambdaFunctionARN":"${CallLoggerHandler.Arn}"
```

`!GetAtt ...Arn` resolves to a **primary-region** ARN. ACGR replicates flow *content* verbatim
— the two flows were byte-identical, 3847 bytes each — so the `us-west-2` copy invoked the
`us-east-1` function. A Connect instance can only invoke Lambda functions associated with
*itself*, in its own region, so the block failed instantly and the flow took its Error branch
before reaching Lex.

This is precisely the defect Fix 8 corrected for the Lex alias ARN, **in the same flow**, missed
for Lambda. The Lex ARN already used `$.AwsRegion`, which is why Lex was never implicated.

**Fix:**

```
"LambdaFunctionARN":"arn:aws:lambda:$.AwsRegion:${AWS::AccountId}:function:${CallLoggerHandler}"
```

Per the
[ACGR requirements](https://docs.aws.amazon.com/connect/latest/adminguide/connect-global-resiliency-requirements.html),
`$.AwsRegion` is supported for **exactly two things — Lambda ARNs and Lex ARNs** — and requires
the function to have the **same name in every region**. The template pins
`FunctionName: ConnectChaos-CallLogger`, so this holds; the fix script asserts it, because
letting CloudFormation auto-name that function would silently reintroduce the bug.

Note `${CallLoggerHandler}` is a `Ref` (the function *name*), not `GetAtt ...Arn`. The
`CallLoggerAssociation` resource keeps the concrete regional ARN — it is a control-plane API
call, not flow content, and must name a real function in its own region.

**Why it went unnoticed for so long.** Every previous verification of this sample confirmed
that traffic *shifted*. None confirmed that the destination region could *serve a call* — the
one check that distinguishes "failover worked" from "failover moved traffic to a region that
cannot answer". This is the failure mode the sample exists to teach, and the sample itself had
it. `docs` already listed this as an open verification item rather than claiming it was proven,
which is the only reason it was not stated as a false fact.

**Related gap in the same area (fixed operationally, not yet in the template):**
`LexBotAssociation` is `Condition: IsPrimaryRegion`, so a fresh deploy never associates the
replicated bot alias with the *paired* instance. The paired region's `list-bots` is empty and
its flow cannot reach Lex even with a healthy replica. This needs to move into
`make post-deploy`, because it can only run once the Lex GR replica exists.

---

## Fix 16 — VERIFIED on real telephony (the paired region finally served a call)

The open verification item carried since Fix 8 is now closed. With traffic at
`us-east-1 0% / us-west-2 100%`, a real inbound call was answered entirely by the paired
region:

```
us-west-2  contact 19:33:08Z
us-west-2  CallLogger      "Logged contact 60e271fc... (ANI=+447345750038, region=us-west-2)"
us-west-2  LexFulfillment  interpretedValue "12345"  intent LookupCustomer  0 errors
us-east-1  0 contacts, 0 log events in BOTH function log groups
```

The primary region was completely idle. The paired region used **its own** call logger, **its
own** Lex code hook resolved through the `$.AwsRegion` alias, and **its own** DynamoDB global
table replica.

This is the check that distinguishes "failover worked" from "failover moved traffic to a region
that cannot answer". Every earlier verification of this sample only established the former.

> Speech recognition note, since it will happen to anyone demoing this: on the first attempt the
> caller's digits transcribed as *"look up account oh"* → `0`, and earlier as *"one two oh three
> four five"* → `120345`. Say **"one two three four five"** deliberately. A failed lookup on a
> wrong account number is a correct not-found response, not a fault — check the code hook's
> `interpretedValue` in the log before concluding the experiment misbehaved.

---

## Fix 17 — The paired region could never fail over (bare TDG ID + wrong IAM scope)

**Symptom:** at 18:49:05Z the paired region's `TrafficShiftHandler` fired on its own composite
alarm and failed:

```
[WARNING] GetTrafficDistribution failed; proceeding with write. ResourceNotFoundException
[ERROR]   UpdateTrafficDistribution failed: ResourceNotFoundException
```

**Root cause: two independent defects that both had to be fixed.**

1. **Bare ID instead of ARN.** An ACGR traffic distribution group resolves by bare UUID *only*
   in the region it was created in. Measured directly:

   ```
   us-east-1  bare id  -> OK
   us-east-1  full arn -> OK
   us-west-2  bare id  -> ResourceNotFoundException
   us-west-2  full arn -> OK
   ```

   The handler passed `Id=<uuid>` from an environment variable, so it worked in the primary
   region and was dead in the paired region.

2. **IAM scoped to the wrong region.** The policy granted
   `arn:aws:connect:${AWS::Region}:...:traffic-distribution-group/*`. In the paired region that
   is a `us-west-2` ARN, while the TDG's ARN is `us-east-1` — so even with the correct
   identifier the call would have been denied. Fixing only the identifier would have swapped
   `ResourceNotFoundException` for `AccessDeniedException`.

**Fix:** pass the full ARN, built from `PrimaryRegion`, and scope IAM to that same ARN:

```yaml
TRAFFIC_DISTRIBUTION_GROUP_ARN: !Sub
  'arn:aws:connect:${PrimaryRegion}:${AWS::AccountId}:traffic-distribution-group/${TrafficDistributionGroupId}'
```

`traffic_shift_handler.py` now raises at **import time** if the value is not an ARN, so a
regression fails immediately and visibly rather than only during an incident.

**Why this mattered more than it looked.** It is tempting to read the paired region's handler
firing as a harmless duplicate — the primary already shifted traffic, so who cares. But the
scenario this sample exists to demonstrate is a region becoming unhealthy, and in that scenario
**the surviving region is the only one that can move traffic**. That path was broken from the
first commit, and the idempotency guard in `shift_traffic` masked it: the guard is what makes a
double-shift harmless, so nobody had reason to look at the paired region's failure.

---

## Tooling gaps closed alongside Fixes 16 and 17

These are not template defects, but every one of them is a reason today's failures took as long
to find as they did.

**`make verify` proved nothing about the paired region.** It checked that the Lex *bot* replica
existed and stopped there. It now also asserts, in the paired region: the Lex **alias** replica
is `Available`; the alias is associated with the paired Connect instance; both Lambdas exist and
carry a resource policy that permits invocation; the call logger is associated with the instance;
and — in **both** regions — that the deployed flow's Lambda and Lex ARNs use `$.AwsRegion`. That
last check is the one that would have caught Fix 16 without spending a phone call.

**`make reset` did not exist.** The runbook instructs a reset between every experiment and gave
copy-paste commands. It is now a target that stops running experiments in both regions, restores
100/0, disarms the chaos flag, and waits for alarms in **both** regions to clear before
returning — the last point matters because a stop-condition alarm still in `ALARM` compromises
the next run.

**The reference contact-flow JSONs are now generated.** `scripts/extract-flows.py` derives them
from the template's inline content and `make lint` fails if they diverge. They had drifted far
enough to contradict their own README, which described an `InvokeLambdaFunction` block the JSON
did not contain.

**`make post-deploy` now wires Lex in the paired region.** `LexBotAssociation` is
`Condition: IsPrimaryRegion`, so a fresh deploy left the paired instance with no Lex association
at all and no way for its flow to reach the bot. `post-deploy` now ensures the bot replica
exists, waits for the **alias** replica to become `Available`, and associates it with the paired
instance. It cannot live in the template because it depends on a replica that only exists after
both stacks are up.

---

## Environmental hazard — a third-party replicator in the same account

Not a defect in this sample, recorded because it cost hours of misdiagnosis and will mislead
anyone testing in a shared account.

An unrelated stack, `ConnectAcgrReplicatorStack`, ran in this account and swept resources whose
names overlap this sample's:

```
12:20:30  CreateFunction  LexFulfillmentHandler, ConnectChaos-CallLogger   (us-west-2)
12:30:16  DeleteBotReplica  QJ5VLLR4GH                                     (us-east-1)
12:30:17  DeleteFunction    ConnectChaos-CallLogger                        (us-west-2)
12:30:18  DeleteFunction    LexFulfillmentHandler                          (us-west-2)
```

Consequences worth internalising:

- **CloudFormation kept reporting `CREATE_COMPLETE` for resources that no longer existed.** Stack
  status is not evidence that a resource is present. `detect-stack-drift` reported the two
  `Lambda::Permission`s and the `IntegrationAssociation` as `DELETED` and both functions as
  `MODIFIED`; that is the tool that tells the truth.
- **This is very likely the unexplained disappearance recorded in Fix 14.** That entry closed
  with "root cause not established" because no CloudTrail record was found in the window
  examined. A `DeleteBotReplica` by this replicator is now on record, which supplies the
  mechanism even though the original incident itself remains unconfirmed.
- If you test in a shared account, run `make verify` immediately before each call. Resources can
  vanish between a passing preflight and a test.

---

## Fix 18 — Every experiment produced the same prompt and shared metrics

**Symptom:** during live testing, Experiment 1 and Experiment 2 were audibly identical — both
ended on *"We are experiencing difficulties. Please try again later."* — because the flow had a
single `error-msg` block that every error branch routed to. There was no way to tell from the
call which fault had fired. Worse, Exp 1 alarmed on `AWS/Lambda Errors` and Exp 3 on
`AWS/Lambda Duration` for the **same function**, so the two experiments shared a namespace and
a dimension set.

**The constraint that shaped the fix.** `AWS/Connect` publishes exactly one metric meaning "a
flow failed": `ContactFlowErrors`. There is no per-block metric and no code-hook latency
metric. Measured against the live instance, only ten `AWS/Connect` metrics have ever been
emitted for it at all. So four distinct Connect *metric names* are not available.

But `ContactFlowErrors` is dimensioned by `ContactFlowName`. Giving each experiment **its own
flow** converts that single metric into four independent signals — same metric, disjoint
dimensions, no metric math.

**Fix:**

| Exp | DTMF | Attributing metric | Namespace |
|---|:---:|---|---|
| 1 | `1` | `ContactFlowErrors{ContactFlowName=ConnectChaos-Exp1-Lambda}` | AWS/Connect |
| 2 | `2` | `ContactFlowErrors{ContactFlowName=ConnectChaos-Exp2-DynamoDB}` | AWS/Connect |
| 3 | `3` | `Duration` (Maximum) on `LexFulfillmentHandler` | AWS/Lambda |
| 4 | `4` | `LongestQueueWaitTime{QueueName=ConnectChaos-Overflow}` | AWS/Connect |

Three of four are now Connect-native, up from two, and no two experiments share a dimension
set. Alarms were renamed to `ConnectChaos-Exp{1..4}-*-<region>` so the alarm identifies the
experiment.

Supporting changes:

- **`ConnectChaos-Menu`** is the new entry flow and the only one the phone number points at. It
  announces the region, then a `GetParticipantInput` with `StoreInput=False` — whose *result*
  is the digit and which supports `Equals` conditions on a single character — transfers to one
  experiment flow per digit.
- **Exp 1 moved off the Lex code hook onto a new direct-invoke Lambda,
  `ConnectChaos-AccountLookup`**, preceded by a `GetParticipantInput` with `StoreInput=True`
  that collects the account number as DTMF. FIS now targets that function, so the failure lands
  on an `InvokeLambdaFunction` **Error branch** — which is what `ContactFlowErrors` counts.
- **Every flow opens with "Connected in region `$.AwsRegion`".** Which region served a call is
  now audible. This is a direct response to Fix 16: that defect survived because proving the
  serving region required cross-referencing two log groups after every call, so nobody did it.
- **Each failure path has its own prompt**, naming the experiment.
- **Exp 2's metric math is gone.** It summed `ContactFlowErrors` across `ConnectChaos-MainIVR`
  and `ConnectChaos-ChaosTest`, and `list-metrics` showed the second dimension set was **never
  emitted** — half the expression had always been dead.
- `LambdaErrorsThreshold`, added only one fix earlier, is now unused and was removed along with
  the `make deploy` override that passed it. Leaving the override would have failed every
  deploy with "parameter does not exist".

**Deliberate design decisions, so they are not "fixed" later:**

**"Not found" is not an error.** `account_lookup.py` returns `FOUND` / `NOT_FOUND` /
`INVALID_INPUT` and the flow branches with a `Compare` block. Raising on a bad account number
would make a caller's typo indistinguishable from an injected fault and falsify the
experiment's central claim. Only genuine invocation and DynamoDB failures propagate.

**A DTMF timeout does not error either.** "Store customer input" takes the *Success* branch with
the stored value set to the literal string `Timeout`
([docs](https://docs.aws.amazon.com/connect/latest/adminguide/store-customer-input.html)). The
Lambda rejects that sentinel explicitly; otherwise a silent caller would look like a
`NOT_FOUND`.

**The call logger stays in exactly one flow.** If every flow invoked it, an Exp 2 fault would
raise `ContactFlowErrors` on all four `ContactFlowName` dimensions at once and destroy the
attribution this redesign exists to create.

**Exp 3 keeps a Lambda metric on purpose.** It is a *latency* fault: the function returns
cleanly at ~31 s with `Errors=0` (Fix 7), so there may be no flow error to count. Whether Lex's
30 s code-hook timeout trips the block's error branch is **unverified**. A latency threshold is
the honest measurement for a latency fault; `ContactFlowErrors` for that flow is on the
dashboard as observation-only, and could become the alarm if it proves reliable.

**Error types are per-action and not interchangeable.** The generator asserts this because Fix 2
was an `InvalidContactFlowException` from getting it wrong: `Compare` accepts only
`NoMatchingCondition`; `InvokeLambdaFunction` only `NoMatchingError` and supports no conditions
at all; `GetParticipantInput` with `StoreInput=True` must not declare `NoMatchingCondition` and
*must* supply `InputValidation`.

**Cost of the design:** five flows instead of two, all ACGR-replicated, all needing
`$.AwsRegion` verification. `make verify` now checks all five in both regions — ARNs and the
region announcement — which is the check that would have caught Fix 16 without spending a call.

---

## Fix 19 — Two undocumented flow-validation rules, found by a failed stack update

**Symptom:** the Fix 18 deploy failed with

```
Exp1Flow  CREATE_FAILED
  Resource handler returned message: "Service returned error code InvalidContactFlowException
  (Service: Connect, Status Code: 400)"
```

CloudFormation rolled the entire update back — not just the flow — so `AccountLookupHandler`,
the four renamed alarms and the Fix 17 TDG change all reverted with it. The old flows and the
phone-number association survived, so the environment stayed usable.

`InvalidContactFlowException` carries **no field, no reason and no position**. The only way to
localise it is to ask the service. Creating throwaway flows that isolate one construct each
produced this:

```
PASS  StoreInput=True  + InputValidation + errors [NoMatchingError]
FAIL  StoreInput=True  + InputValidation + errors [NoMatchingError, InputTimeLimitExceeded]
FAIL  StoreInput=True  without InputValidation
FAIL  StoreInput="true"                                    (lowercase)
FAIL  StoreInput=False + errors [NoMatchingError]           (no NoMatchingCondition)
PASS  LambdaInvocationAttributes + ResponseValidation STRING_MAP
PASS  Compare on $.External.status
PASS  "Connected in region $.AwsRegion." as MessageParticipant Text
PASS  "Welcome back, $.External.customer_name." as MessageParticipant Text
```

**Two rules that the
[GetParticipantInput reference](https://docs.aws.amazon.com/connect/latest/devguide/participant-actions-getparticipantinput.html)
does not state:**

1. **With `StoreInput: "True"`, `InputTimeLimitExceeded` is rejected.** The reference lists it
   among the action's error types without noting it is mutually exclusive with `StoreInput`. It
   is consistent with the admin guide, which says a timeout on "Store customer input" takes the
   **Success** branch with the stored value set to the literal string `Timeout` — so there is no
   timeout *error* to branch on, and declaring one is invalid.
2. **With `StoreInput: "False"`, `NoMatchingCondition` is required.** `NoMatchingError` alone
   fails, because conditions are supported in that mode and the condition-miss branch is
   mandatory.

Also confirmed: `StoreInput` is **case-sensitive** (`"true"` fails), and `InputValidation` is
genuinely required when `StoreInput` is `"True"` — the reference's "required if and only if" is
accurate.

**Fix:** delete the `InputTimeLimitExceeded` branch from the Exp 1 flow. Nothing is lost,
because `account_lookup.py` already rejects the `Timeout` sentinel and returns `INVALID_INPUT`
for the `Compare` block to route to the "no account number was received" prompt. That handling
was written from the admin guide *before* this failure; only the flow was wrong.

**The durable part of this fix is the validator, not the deletion.** `scripts/extract-flows.py`
now enforces the per-action error lists, both rules above, the `StoreInput` casing, the
`InvokeLambdaFunction`-has-no-Conditions restriction, transition-target resolution,
`$.AwsRegion` on every Lambda and Lex ARN, and the presence of the region announcement — and
`make lint` runs it. A negative test confirms it reproduces this exact finding:

```
$ make lint
ERROR: Exp1Flow would be rejected or is ACGR-unsafe:
  - ask: StoreInput=True must NOT declare InputTimeLimitExceeded ...
```

**Lesson worth keeping.** Flow content is validated **server-side at create time**, so
`cfn-lint` cannot see any of this — the template was lint-clean and still failed. For a
resource type whose payload is an opaque string validated by a remote service, the cheap and
reliable move is to exercise the real API with throwaway resources rather than reason about
documentation. Nine single-construct flows localised the fault in one pass, at zero risk,
after one failed stack update had already cost a full rollback.

---

## Fix 20 — The new lookup Lambda could not read its FIS fault config

**Symptom:** the first baseline call on the redesigned flows succeeded perfectly — DTMF capture,
`LambdaInvocationAttributes`, the lookup, "Welcome back, John Doe" — but its log carried:

```
AWS FIS EXTENSION - failed to retrieve active fault configurations:
  error when calling ListObjectsV2 on S3: AccessDenied
```

**Impact if it had shipped:** Experiment 1 would have reported `running`, then `completed`, and
applied **no fault at all**. The call would simply have succeeded, and the alarm would have
stayed `OK` — indistinguishable from "the experiment does not work". Exactly the silent-failure
mode Fix 11 warned about for the S3 gateway endpoint, arriving here through IAM instead of
routing.

**Root cause:** `AccountLookupRole` was written with the permissions the *function* needs —
`dynamodb:GetItem` plus VPC access — and not the permissions the *extension* needs.
`LexFulfillmentRole` already carried a `FISConfigRead` policy (`s3:ListBucket` on the bucket,
prefix-conditioned to `FisConfigs/*`, and `s3:GetObject` under it); the new role had no S3
access whatsoever.

```
ConnectChaos-LexFulfillment-us-east-1  ['DynamoDB', 'FISConfigRead']
ConnectChaos-AccountLookup-us-east-1   ['DynamoDBRead']              <- missing
```

**Fix:** mirror `FISConfigRead` onto `AccountLookupRole`. The template now also asserts the
invariant structurally — *every* function carrying `FISExtensionLayerArn` must have a role with
`FISConfigRead` — so adding a third FIS-targeted function cannot repeat this.

**Verified by invocation, not by inspection.** An IAM policy being present does not prove the
extension can read the object, so the function was invoked directly in both regions after a
forced cold start:

```
us-east-1  {"status":"FOUND","customer_name":"John Doe","region":"us-east-1"}
us-west-2  {"status":"FOUND","customer_name":"John Doe","region":"us-west-2"}
AWS FIS EXTENSION - polling S3 for active faults impacting this Lambda function
AWS FIS EXTENSION - no active faults found (updated polling interval 60s)
```

`AccessDenied` gone in both, and the lookup resolves against each region's own Global Table
replica.

**Why this was caught at all.** Only because the extension logs its failure and the log was
read *before* a test call was spent on Experiment 1. Nothing else surfaces it: the stack
deploys clean, `cfn-lint` passes, `make verify` passes, the baseline call succeeds, and the
experiment would have reported success. The generalisable rule is the one from Fix 15 — verify
the **fault**, the **metric** and the **alarm** as three separate steps — with an addition:
for extension-based faults, verify the extension can *fetch its configuration* before trusting
any experiment result. The line to look for is `no active faults found`; anything else means
the fault will not be applied.

---

## Fix 21 — CloudFormation shipped stale Lambda code, silently breaking all failover

**Symptom:** a real Experiment 1 call heard *"Welcome back, John Doe"* instead of the failure
prompt. Forcing the child alarm into `ALARM` by hand proved the alarm and EventBridge were
fine — `TriggeredRules: 1`, `Invocations: 1`, `FailedInvocations: none` — yet traffic never
moved and the handler's log group appeared empty to `filter_log_events`. Reading the log
**stream** directly showed the truth:

```
[ERROR] KeyError: 'TRAFFIC_DISTRIBUTION_GROUP_ID'
INIT_REPORT  Init Duration: 399.52 ms  Phase: init  Status: error  Error Type: Runtime.Unknown
```

**Root cause.** Fix 17 renamed that environment variable to `..._ARN`. CloudFormation applied
the environment change and **left the function code at the previous version**, because
`Code.S3Key` was a fixed path — `connect-chaos/traffic_shift_handler.zip`. The zip *bytes* in
S3 were replaced by `make deploy`, but the *property value* did not change, so CloudFormation
compared old to new, saw no difference, and skipped the code update. The result was code and
configuration that disagreed: the deployed code read a variable that no longer existed, so it
raised at **import**, before the handler ran.

**Blast radius: every failover, in both regions, for the entire period after the Fix 17/18
deploy.** And it was invisible to everything:

```
both stacks           UPDATE_COMPLETE
all alarms            OK
make verify           ALL CHECKS PASSED
EventBridge           rule matched, Lambda invoked, no FailedInvocations
baseline phone call    succeeded end to end
```

Only two things exposed it: reading the handler's log stream directly, and the traffic
distribution simply not changing.

**Immediate remediation:** `aws lambda update-function-code` for all functions in both
regions. Only `TrafficShiftHandler` reported `CHANGED`; `AccountLookup` was newly created so
its code was fresh, and the other two were untouched in that release — which is exactly why
this went unnoticed. The bug only bites a function whose **code changed while its S3 key did
not**.

**Durable fix: content-address the S3 keys.**

```
LAMBDA_CODE_VERSION := $(shell cat $(LAMBDA_DIR)/*.py | shasum | cut -c1-12)
S3Key: !Sub 'connect-chaos/${LambdaCodeVersion}/traffic_shift_handler.zip'
```

Any handler edit changes the hash, which changes `Code.S3Key`, which obliges CloudFormation to
update the code. Hashing the **sources** and not the zips is deliberate: zip archives embed
timestamps, so hashing the archives would change the key on every build even when nothing
changed, producing pointless updates and hiding real ones in the noise.

**New check in `make verify`:** invoke `TrafficShiftHandler` with a synthetic **non-ALARM**
event and assert no `FunctionError`. The handler returns early for any state that is not
`ALARM`, so the probe exercises module import and the entrypoint without touching the traffic
distribution. It reports the stale-code diagnosis by name:

```
=== handlers: do they actually load? (import-time failures are invisible elsewhere) ===
  PASS  us-east-1: TrafficShiftHandler loads and runs
  PASS  us-west-2: TrafficShiftHandler loads and runs
```

**Verified after the fix**, by forcing each region's child alarm:

```
us-east-1 forced ALARM -> traffic us-east-1=0 / us-west-2=100   in 4s
us-west-2 forced ALARM -> traffic us-west-2=0 / us-east-1=100   in 4s   <- Fix 17 proven
```

The second line is the first time the paired region has ever driven the TDG.

**Two lessons.**

`set-alarm-state` on a child alarm is the right way to test the failover half. It exercises
composite evaluation, EventBridge, the Lambda and `UpdateTrafficDistribution` in about four
seconds, with no phone call, no experiment and no 180-second window — so the *fault* and the
*failover* can be verified independently instead of racing to observe both in one call.

`filter_log_events` returned nothing for a log group that visibly had recent events in
`describe_log_streams`. When a Lambda looks silent but should not be, read the stream with
`get_log_events` before concluding it was never invoked.

---

## Fix 22 — Failover was too fast to observe; added a configurable dwell

**Motivation, from a real Experiment 1 run:**

```
15:43:20  caller hears "the account lookup service is unavailable"
15:44:51  ConnectChaos-Exp1-Lambda-us-east-1  OK -> ALARM
15:44:53  Traffic shifted: us-east-1=0% / us-west-2=100%
```

Ninety-three seconds from failure to repair, all of it CloudWatch metric latency rather than a
deliberate choice. For a demonstration that is backwards: the point is hearing the *same number*
fail and then succeed from another Region, and an audience needs time to observe the failure
before it is fixed.

**Fix:** `FailoverDelaySeconds` (default **120**, min 0, max 600) makes the dwell explicit.
`TrafficShiftHandler` logs it, waits, then shifts. `make deploy` accepts
`FAILOVER_DELAY_SECONDS=` to override.

Two supporting changes that are not cosmetic:

- **The handler timeout had to rise from 30 s to 660 s.** Otherwise Lambda kills the function
  mid-sleep, EventBridge retries the asynchronous invocation, and you get repeated partial
  waits and no shift. 660 s is chosen to clear the 600 s parameter maximum.
- **The idempotency check is re-run after the sleep.** During a two-minute wait the paired
  Region's handler, or an operator, may already have moved traffic; writing blindly afterwards
  would undo a newer decision.

**Verified:**

```
16:06:22  Alarm state: ALARM, My region: us-east-1
16:06:22  Holding failover for 120s so the impaired region can be experienced
16:08:23  Traffic shifted: us-east-1=0%, us-west-2=100%      <- 121s
16:08:50  TDG already shifted — no-op.                       <- duplicate correctly ignored
```

---

## Fix 23 — A dwelling handler ignored everything that happened while it slept

**Symptom.** Immediately after Fix 22, a dwell measurement showed traffic shifting **10 seconds**
after the alarm instead of 120. Two log streams explained it:

```
16:12:36  stream c0b3c691  "Holding failover for 120s ..."          <- the new invocation
16:12:37  stream 19923a78  "Traffic shifted"  RequestId 8867d222    <- an OLDER invocation
```

An invocation that had begun sleeping *before* a `make reset` woke up afterwards and shifted
traffic anyway, one second into the next test. The reset had restored 100/0; the sleeper undid
it silently.

**Root cause.** Fix 22's post-dwell check asked the wrong question. It asked *"has someone
already shifted away from me?"* — after a reset the answer is no, so it proceeded. The question
that matters is whether the **condition still holds**.

**Fix.** After the dwell, re-read the triggering alarm (its name arrives in the EventBridge
event as `detail.alarmName`) and abandon the failover if it is no longer in `ALARM`:

```
16:22:11  Holding failover for 120s ...
16:24:11  ConnectChaos-Composite-us-east-1 is now OK after the 120s dwell -
          the impairment cleared or was reset. Not failing over.
```

`TrafficShiftRole` gains `cloudwatch:DescribeAlarms` (which does not support resource-level
permissions, so `Resource: '*'`).

**This is a behavioural improvement, not just a bug fix.** It gives the sample proper debounce
semantics: an impairment that clears inside the dwell no longer causes a Region failover. That
is what you would actually want in production — you do not move a contact centre between
Regions because of a two-second blip.

### Consequence: `set-alarm-state` no longer works as a failover test

This matters because Fix 21 recommended exactly that technique, and it is now invalid whenever
a dwell is configured.

`SetAlarmState` is a **temporary override**. CloudWatch re-evaluates and reverts it on the next
period — measured at ~50 s:

```
16:22:10  OK -> ALARM   reason: "clean dwell test"      (forced)
16:23:01  ALARM -> OK   reason: "no datapoints ... treated as [NonBreaching]"
16:24:11  handler declines: alarm is OK after the dwell
```

The forced state expires inside the 120 s wait, so Fix 23 correctly refuses to fail over, and
no traffic moves. **Real faults are unaffected**: on the Experiment 1 run the alarm held `ALARM`
from 15:44:51 to 15:52:51 — about eight minutes, because CloudWatch is slow to re-evaluate a
breached alarm back to `OK` — which comfortably contains a 120 s dwell.

**How to test each half now:**

| Goal | Method |
|---|---|
| Failover mechanism only | redeploy with `FAILOVER_DELAY_SECONDS=0`, then `set-alarm-state` |
| Fault injection only | direct `lambda invoke`, check for `FunctionError` |
| End to end | a real call, with the dwell at its configured value |

**Also: a dwelling handler outlives `make reset`.** If you reset while a handler is sleeping and
the alarm is still genuinely in `ALARM`, the shift will still land after the dwell — correctly,
because the impairment is real. Either wait out the dwell before resetting, or reset twice about
130 seconds apart. Fix 23 only suppresses the shift when the alarm has actually cleared.

### The wider lesson

Adding a delay to a reactive control loop changed its correctness requirements, not just its
timing. Any state read *before* a wait may be stale after it, so every precondition has to be
re-evaluated on the far side — and the precondition that matters is the *triggering condition*,
not the side effect you were about to write. The first version of this fix re-checked the
side effect and was still wrong.
