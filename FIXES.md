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

> Note on threshold: with the shipped default `ContactFlowErrorsThreshold=5` a single test
> call (1 error) will not trip the alarm. For a live demo where the presenter places one
> or two calls, deploy with a lower threshold (e.g. `ContactFlowErrorsThreshold=0`, which
> fires on the first error) — this is how the end-to-end verification above was run.

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
