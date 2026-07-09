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
