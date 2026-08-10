# Deploy & Test Runbook

Sequential guide: deploy both regions once, then run each experiment one after the other,
verifying before moving on.

**Deploy `cfn/main-template.yaml`** — the only deployable artifact.

> **Read first — two things invalidate a whole test run:**
>
> 1. **Failover is one-way by design.** When an experiment trips the composite alarm,
>    `TrafficShiftHandler` sets that region to 0% and nothing shifts it back. Run **Step R**
>    after every experiment or all later tests start from an already-failed-over state.
> 2. **Experiments 1 and 3 have a ~180 second window.** They work through the FIS Lambda
>    extension, which ignores fault config older than ~180 s. A real call must land within
>    ~3 minutes of starting the experiment. Experiment 2 has no such limit.

---

## Live deployment — copy/paste for the current environment

> **This section describes the stack that is deployed right now** in account
> `101506645078`, IAD ↔ PDX. Every value was read back from the deployment. If you are
> deploying fresh somewhere else, skip this and use the generic sections below.
>
> **Steps 1 and 2 (pre-flight and deploy) are already DONE.** Both stacks are
> `CREATE_COMPLETE` and traffic is reset to IAD 100% / PDX 0%. Start at **step 3**.

```bash
export PRIMARY_REGION=us-east-1
export PAIRED_REGION=us-west-2
export STACK=connect-chaos-sample
export ACCT=101506645078

# ACGR replica: the SAME instance id exists in both regions
export INSTANCE_ID=f4d29ac8-fcfc-4cc1-be06-545ac29aefe9
export PRIMARY_INSTANCE_ARN=arn:aws:connect:$PRIMARY_REGION:$ACCT:instance/$INSTANCE_ID
export PAIRED_INSTANCE_ARN=arn:aws:connect:$PAIRED_REGION:$ACCT:instance/$INSTANCE_ID

# tdg2 — the TDG that has the ported number attached
export TDG_ID=fb104a2a-3e14-41b1-b4ab-a9afec8e0685
export PHONE="+44 808 547 8029"

# FIS experiment templates (from the primary stack outputs)
export EXP1=EXTr1GJfcSvf1BW        # Lambda invocation error
export EXP2=EXT52xQ3YYqgvC2kx      # DynamoDB network disruption
export EXP3=EXT2JeAjdNb4wBM2g      # Lex code-hook latency
export GEN=ConnectChaos-TrafficGenerator-$PRIMARY_REGION
```

### What is deployed

| Component | us-east-1 (IAD) | us-west-2 (PDX) |
|---|---|---|
| Stack | `CREATE_COMPLETE` | `CREATE_COMPLETE` |
| Lex bot / alias | `QJ5VLLR4GH` / `IYOEXZUVAZ` | `QJ5VLLR4GH` *(Lex GR, Available)* |
| VPC | `vpc-0f6018164a8383055` | `vpc-0abb4de0b0af63282` |
| Gateway endpoints | DynamoDB + S3 | DynamoDB + S3 |
| NAT gateways | 0 | 0 |
| Tables | `connect-chaos-sample-{Customers,Config,CallLog}` | replicas |
| Overflow queue | `ConnectChaos-Overflow` `7b4d65cb-7d5b-423f-b279-bc668f7bcee4` | ACGR-replicated |
| Alarms | 4 component + composite, all `OK` | 4 + composite |
| Failover rule | `ConnectChaos-Failover-us-east-1` `ENABLED` | `ENABLED` |

A visual walkthrough of the injection points and the failover chain, with these same IDs,
is in **[docs/BLOCK-DIAGRAM.md](docs/BLOCK-DIAGRAM.md)**.

### Recommended test order for this deployment

1. **Seed the tables** (step 3) — they are new and empty.
2. **Baseline call** (step 3a) — proves the healthy path AND settles whether a VPC Lambda
   writes CloudWatch Logs with only DynamoDB and S3 gateway endpoints.
3. **Experiment 2 first** — it is the only fault with **no ~180 s window**, so it is the
   most forgiving to verify and the best first proof of the failover chain.
4. Then Experiment 4, then 1 and 3 (both need a call within ~3 minutes).
5. Finally the **paired-region proof** — a call answered in PDX.

> **Use the SAME digit for the recovery call.** After failover, dial again and press the digit
> for the experiment you just ran — not a different one. The claim being proven is that *this
> flow*, which just failed in the primary Region, now succeeds in the paired Region. Pressing a
> different digit exercises a different flow and proves something weaker. There is no technical
> difference; the distinction is what the test demonstrates.
>
> | Experiment | Failure call | Recovery call | Expected on recovery |
> |---|:---:|:---:|---|
> | 1 | `1` | `1` | *"Welcome back, John Doe"* |
> | 2 | `2` | `2` | *"Your call has been recorded for quality purposes"* |
> | 3 | `3` | `3` | *"I found your information"* |
> | 4 | `4` | `4` | *"I found your information"* (flag off) |
>
> Every recovery call should open with *"Connected in region us-west-2"* — that announcement is
> the proof of which Region served it, and needs no log inspection.


---

## 0. Shell variables

```bash
export PRIMARY_REGION=us-east-1
export PAIRED_REGION=us-west-2
export STACK=connect-chaos-sample
export ACCT=$(aws sts get-caller-identity --query Account --output text)

# An ACGR replica shares the SAME instance id, so the ARNs differ only by region.
export INSTANCE_ID=<instance-id>
export PRIMARY_INSTANCE_ARN=arn:aws:connect:$PRIMARY_REGION:$ACCT:instance/$INSTANCE_ID
export PAIRED_INSTANCE_ARN=arn:aws:connect:$PAIRED_REGION:$ACCT:instance/$INSTANCE_ID

# The TDG that has your ported phone number attached.
export TDG_ID=<traffic-distribution-group-id>
```

You do **not** need a VPC, subnets, a security group, an S3 bucket, or the FIS layer ARN.

---

## 1. Pre-flight  *(already done for the live deployment)*

```bash
# ACGR pair: the SAME instance id must appear in both regions
aws connect list-instances --region $PRIMARY_REGION \
  --query "InstanceSummaryList[?Id=='$INSTANCE_ID'].{Alias:InstanceAlias,Id:Id}" --output table
aws connect list-instances --region $PAIRED_REGION \
  --query "InstanceSummaryList[?Id=='$INSTANCE_ID'].{Alias:InstanceAlias,Id:Id}" --output table

# TDG must be ACTIVE
aws connect describe-traffic-distribution-group --traffic-distribution-group-id $TDG_ID \
  --region $PRIMARY_REGION --query "TrafficDistributionGroup.Status"

# Note the current split — you will restore it later
aws connect get-traffic-distribution --id $TDG_ID --region $PRIMARY_REGION \
  --query "TelephonyConfig.Distributions"

# A phone number must be attached to THIS TDG, or no real call can reach the flow
aws connect list-phone-numbers-v2 --region $PRIMARY_REGION --max-results 60 \
  --query "ListPhoneNumbersSummaryList[?contains(TargetArn,'$TDG_ID')].{Number:PhoneNumber,Type:PhoneNumberType}" \
  --output table
```

Also confirm `$STACK-Customers` does **not** already exist in the primary region — an
existing table would be adopted or conflict:

```bash
aws dynamodb list-tables --region $PRIMARY_REGION \
  --query "TableNames[?contains(@,'$STACK')]"
```

---

## 2. Deploy both regions  *(already done for the live deployment)*

```bash
make deploy-pair STACK=$STACK \
  PRIMARY_REGION=$PRIMARY_REGION PAIRED_REGION=$PAIRED_REGION \
  PRIMARY_INSTANCE_ARN=$PRIMARY_INSTANCE_ARN \
  PAIRED_INSTANCE_ARN=$PAIRED_INSTANCE_ARN \
  TDG_ID=$TDG_ID
```

This creates the code bucket, uploads the Lambdas, deploys primary, reads the Lex GR
bot/alias IDs from its outputs, then deploys paired with those IDs.

**Both stacks must remain deployed.** The paired region cannot answer a call without its own
Lambdas, and that is the single most important thing this sample proves.

Confirm:

```bash
for R in $PRIMARY_REGION $PAIRED_REGION; do
  printf "%-12s " $R
  aws cloudformation describe-stacks --stack-name $STACK --region $R \
    --query "Stacks[0].StackStatus" --output text
done
```

Both must read `CREATE_COMPLETE` or `UPDATE_COMPLETE`.

### 2a. Verify Lex GR replicated the bot — do not skip

If the paired region has no bot, failover will shift traffic to a region that cannot serve
calls. This is the exact gap that a previous London deployment never closed.

```bash
export LEX_BOT_ID=$(aws cloudformation describe-stacks --stack-name $STACK \
  --region $PRIMARY_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text)
echo "primary bot id = $LEX_BOT_ID"

# The SAME bot id must exist in the paired region
aws lexv2-models list-bots --region $PAIRED_REGION \
  --query "botSummaries[?botId=='$LEX_BOT_ID'].{Name:botName,Id:botId,Status:botStatus}" \
  --output table
```

**Expected:** one row, `Available`. If empty, Lex GR did not replicate — redeploy both
regions with `ENABLE_LEX_GR=false` and run
`./scripts/wire-paired-flow.sh --stack-name $STACK --primary-region $PRIMARY_REGION --paired-region $PAIRED_REGION`.

Also confirm the paired region has its own Lambdas:

```bash
aws lambda list-functions --region $PAIRED_REGION \
  --query "Functions[?contains(FunctionName,'LexFulfillment')||contains(FunctionName,'CallLogger')].FunctionName" \
  --output table
```

---

## 2b. Point the phone number at the contact flow  ⚠️ REQUIRED

**This is a silent failure if skipped.** Every stack resource reports `CREATE_COMPLETE`,
every alarm reports `OK`, and calls simply never enter the flow — nothing indicates why.

CloudFormation cannot do it: the number belongs to the Traffic Distribution Group, not to
the stack, and there is no CloudFormation resource for the number → flow link.

```bash
make post-deploy STACK=$STACK \
  PRIMARY_REGION=$PRIMARY_REGION PAIRED_REGION=$PAIRED_REGION \
  INSTANCE_ID=$INSTANCE_ID TDG_ID=$TDG_ID
```

`post-deploy` does all three manual steps and is safe to re-run: seeds the tables,
associates the number with **`ConnectChaos-Menu`**, wires Lex in the paired region, and resets traffic to
100% primary / 0% paired.

Then confirm the environment before spending any calls:

```bash
make verify STACK=$STACK PRIMARY_REGION=$PRIMARY_REGION \
  PAIRED_REGION=$PAIRED_REGION TDG_ID=$TDG_ID
```

`verify` checks both stacks, whether the paired region can actually serve a call, the seed
data, the traffic split and the alarms. It cannot check the number → flow link itself —
**no AWS API exposes it** — so the baseline call below is the only real proof of that.

> **One entry point for everything.** The number stays associated with `ConnectChaos-Menu`
> for all four experiments — you never re-point it. Every call announces the serving region,
> then offers a DTMF menu: press **1** for Experiment 1, **2** for 2, **3** for 3, **4** for 4.
> The digit selects which flow runs, and therefore which `ContactFlowName` dimension the
> metric lands on.

---

## 3. Seed data and baseline

```bash
aws dynamodb put-item --table-name $STACK-Customers --region $PRIMARY_REGION \
  --item '{"account_id":{"S":"12345"},"customer_name":{"S":"John Doe"}}'
aws dynamodb put-item --table-name $STACK-Config --region $PRIMARY_REGION \
  --item '{"config_key":{"S":"chaos_flag"},"enabled":{"BOOL":false}}'

# prove global-table replication works
aws dynamodb get-item --table-name $STACK-Customers --region $PAIRED_REGION \
  --key '{"account_id":{"S":"12345"}}'
```

Capture experiment IDs:

```bash
get_out () { aws cloudformation describe-stacks --stack-name $STACK --region $1 \
  --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }
export EXP1=$(get_out $PRIMARY_REGION FISExperiment1)
export EXP2=$(get_out $PRIMARY_REGION FISExperiment2)
export EXP3=$(get_out $PRIMARY_REGION FISExperiment3)
export GEN=ConnectChaos-TrafficGenerator-$PRIMARY_REGION
echo "exp1=$EXP1  exp2=$EXP2  exp3=$EXP3"
```

All alarms must be `OK` or `INSUFFICIENT_DATA` before you break anything:

```bash
aws cloudwatch describe-alarms --region $PRIMARY_REGION --alarm-name-prefix ConnectChaos- \
  --query "sort_by(MetricAlarms,&AlarmName)[].{Alarm:AlarmName,State:StateValue}" --output table
aws cloudwatch describe-alarms --region $PRIMARY_REGION --alarm-types CompositeAlarm \
  --alarm-name-prefix ConnectChaos- \
  --query "CompositeAlarms[].{Alarm:AlarmName,State:StateValue}" --output table
```

### 3a. Baseline call — prove the healthy path first

Call the number attached to your TDG. You should hear **"Connected in region us-east-1"**
(or whichever region is primary) — that announcement alone tells you where the call landed.
Press **1**, then key **12345** on the keypad. Expect *"Welcome back, John Doe."*

Use the keypad, not speech. Account numbers are collected as DTMF precisely because ASR
mis-transcribed "one two three four five" as `120345` and once as `0` during testing, which
looks exactly like a broken lookup.

Then confirm the **primary** region served it:

```bash
aws logs tail /aws/lambda/LexFulfillmentHandler --region $PRIMARY_REGION --since 5m
aws logs tail /aws/lambda/ConnectChaos-CallLogger --region $PRIMARY_REGION --since 5m
```

If the baseline call does not work, no experiment result below will mean anything.

Open the dashboard: **CloudWatch → Dashboards → `ConnectChaos-<primary-region>`**

---

## Timing you must expect

Measured on this sample, not estimated:

| Step | Delay |
|---|---|
| `start-experiment` -> fault actually effective (Exps 1 and 3) | **~55 s** |
| Fault persistence | continuous once applied (see Fix 24) |
| Exp 2 fault | immediate, never expires |
| Call -> `ContactFlowErrors` published | ~60-90 s |
| Alarm -> traffic shifted | **`FailoverDelaySeconds`** (default 120 s) + ~2 s |

So a full Experiment 1 cycle is roughly: start, wait ~60 s, call, wait ~90 s for the alarm,
then a further ~120 s dwell before traffic moves. Do not conclude anything is broken before
about four minutes have passed.

**Never start an experiment while its stop-condition alarm is in `ALARM`.** FIS fails the
experiment within ten seconds:

```
Error while handling stop condition for experiment: EXP...
The following alarms were not in state OK: [...ConnectChaos-Exp3-Latency-us-east-1]
```

This is exactly what Step R's alarm wait prevents, so always let `make reset` finish. Note the
Exp 3 alarm watches Lambda `Duration` on the code hook, so a diagnostic probe of that function
trips it for real — unlike an Exp 1 probe, which cannot (FIXES.md Fix 24).

Two consequences worth knowing:

- **`set-alarm-state` cannot test failover while a dwell is configured.** A forced alarm state
  is a temporary override that CloudWatch reverts within ~50 s, so it expires inside the dwell
  and the handler correctly declines to fail over. To test the mechanism alone, redeploy with
  `FAILOVER_DELAY_SECONDS=0`. See FIXES.md Fix 23.
- **A dwelling handler outlives a reset.** If you reset while a handler is sleeping and the
  alarm is genuinely still in `ALARM`, the shift still lands after the dwell. Wait out the
  dwell before resetting, or reset twice ~130 s apart.

---

## Step R — Reset between every experiment

```bash
make reset STACK=$STACK PRIMARY_REGION=$PRIMARY_REGION \
           PAIRED_REGION=$PAIRED_REGION TDG_ID=$TDG_ID
```

It stops running experiments in **both** regions, restores 100% primary / 0% paired, disarms
the Exp 4 chaos flag, then waits for every alarm in both regions to leave `ALARM` — and exits
non-zero if they do not. Do not start the next experiment until it exits 0.

The alarm wait is not cosmetic. Each experiment's stop condition is its **own** detection
alarm, so an alarm still in `ALARM` compromises the next run.

<details>
<summary>Equivalent manual commands</summary>

```bash
aws fis list-experiments --region $PRIMARY_REGION \
  --query "experiments[?state.status=='running'].id" --output text

aws connect update-traffic-distribution --id $TDG_ID --region $PRIMARY_REGION \
  --telephony-config "{\"Distributions\":[{\"Region\":\"$PRIMARY_REGION\",\"Percentage\":100},{\"Region\":\"$PAIRED_REGION\",\"Percentage\":0}]}"

aws dynamodb put-item --table-name $STACK-Config --region $PRIMARY_REGION \
  --item '{"config_key":{"S":"chaos_flag"},"enabled":{"BOOL":false}}'

# must return EMPTY, in BOTH regions
aws cloudwatch describe-alarms --region $PRIMARY_REGION --alarm-name-prefix ConnectChaos- \
  --query "MetricAlarms[?StateValue=='ALARM'].AlarmName" --output text
```

</details>

---

## Experiment 1 — Account-lookup Lambda fails

**Fault:** every `ConnectChaos-AccountLookup` invocation is marked failed without running.
**Expect:** the flow takes its `InvokeLambdaFunction` Error branch → `AWS/Connect
ContactFlowErrors` for `ConnectChaos-Exp1-Lambda` → `ConnectChaos-Exp1-Lambda-{region}` ALARM.

**Press 1**, then key any 5 digits. Expect *"The account lookup service is unavailable. This
is experiment one."*

> A `NOT_FOUND` or `INVALID_INPUT` result is **not** a fault: those return normally and the
> flow branches on them with a `Compare` block. Only a genuine invocation failure reaches the
> Error branch, which is what makes the metric attributable.

```bash
aws fis start-experiment --experiment-template-id $EXP1 --region $PRIMARY_REGION \
  --query "experiment.{id:id,state:state.status}"
```

**⚠️ Call within 180 seconds.** Or use the generator:

```bash
aws lambda invoke --function-name $GEN --region $PRIMARY_REGION \
  --payload '{"mode":"faulty","fault_type":"lambda","count":10}' /dev/stdout
```

Verify in order:

```bash
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp1-Lambda-$PRIMARY_REGION \
  --region $PRIMARY_REGION --query "MetricAlarms[0].StateValue"

aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
  --alarm-names ConnectChaos-Composite-$PRIMARY_REGION --region $PRIMARY_REGION \
  --query "CompositeAlarms[0].StateValue"

aws connect get-traffic-distribution --id $TDG_ID --region $PRIMARY_REGION \
  --query "TelephonyConfig.Distributions"

aws logs tail /aws/lambda/ConnectChaos-TrafficShiftHandler --region $PRIMARY_REGION --since 10m
```

**Pass:** component ALARM → composite ALARM → primary `0` / paired `100` → log line
`Traffic shifted: <primary>=0%, <paired>=100%`.

➡️ **Step R.**

---

## Experiment 2 — DynamoDB unreachable  *(most reliable for a live demo)*

**Fault:** both Lambda subnets blocked from the DynamoDB endpoint at the NACL. No 180 s
window — the path stays severed for the whole experiment.
**Expect:** the flow's direct call-logger invoke fails → flow Error branch →
`ContactFlowErrors` → `ConnectChaos-Exp2-DynamoDB-{region}` ALARM.

```bash
aws fis start-experiment --experiment-template-id $EXP2 --region $PRIMARY_REGION \
  --query "experiment.{id:id,state:state.status}"
```

Place a real call (any time during the experiment), or:

```bash
aws lambda invoke --function-name $GEN --region $PRIMARY_REGION \
  --payload '{"mode":"faulty","fault_type":"dynamodb","count":10}' /dev/stdout
```

```bash
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp2-DynamoDB-$PRIMARY_REGION \
  --region $PRIMARY_REGION --query "MetricAlarms[0].StateValue"

# the call logger should show DynamoDB failures
aws logs tail /aws/lambda/ConnectChaos-CallLogger --region $PRIMARY_REGION --since 10m
```

`ContactFlowErrors` only increments for **real contacts**, so a live call is the true test
here. Note that Lambda `Errors` will also rise — expected, see the cascade note.

**Pass:**

| Check | Expected |
|---|---|
| `ConnectChaos-Exp2-DynamoDB-us-east-1` | `ALARM` |
| `ConnectChaos-Composite-us-east-1` | `ALARM` |
| Traffic distribution | primary `0` / paired `100` |
| `ConnectChaos-TrafficShiftHandler` log | `Traffic shifted: us-east-1=0%, us-west-2=100%` |
| `ConnectChaos-CallLogger` log | a DynamoDB timeout/connection error |

**Partial pass to watch for:** if only `ConnectChaos-Exp1-Lambda` fires and
`ContactFlowErrors` stays flat, the fault reached the Lambda but the flow did not take its
Error branch — that is the exact failure Fix 6 addressed. Check that the flow really invokes
`ConnectChaos-CallLogger` before the Lex block, and that a **real contact** went through
(synthetic metrics cannot exercise a flow branch).

➡️ **Step R.**

---

## Experiment 3 — Lex code-hook latency

**Fault:** ~31 s startup delay injected while the function timeout is 40 s, so the code hook
is slow but still returns cleanly.
**Expect:** `LexFulfillmentHandler` `Duration` Maximum spikes to ~31 000 ms →
`ConnectChaos-Exp3-Latency-{region}` ALARM.

```bash
aws fis start-experiment --experiment-template-id $EXP3 --region $PRIMARY_REGION \
  --query "experiment.{id:id,state:state.status}"
```

**⚠️ Call within 180 seconds.**

```bash
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp3-Latency-$PRIMARY_REGION \
  --region $PRIMARY_REGION --query "MetricAlarms[0].StateValue"

aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Duration \
  --dimensions Name=FunctionName,Value=LexFulfillmentHandler \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 60 --statistics Maximum \
  --region $PRIMARY_REGION \
  --query "sort_by(Datapoints,&Timestamp)[].{t:Timestamp,MaxMs:Maximum}" --output table
```

**Pass:** a Duration Maximum around 31 000 ms, alarm ALARM, `Errors` still 0 (the function
returns successfully — this is what separates Exp 3 from Exp 1).

> Do **not** expect `AWS/Lex RuntimeLambdaErrors`. It is never emitted on Connect's real
> `StartConversation` voice path — see FIXES.md Fix 7.

➡️ **Step R.**

---

## Experiment 4 — Contact flow failure → no-agent queue

**Fault:** a DynamoDB chaos flag makes the fulfillment Lambda return `Failed` to Lex. The
`ConnectChaos-Exp4-Queue` flow's failure path sets `ConnectChaos-Overflow` (no routing
profile, so no agent can ever receive its contacts) and transfers the contact there.

**Press 4** from the menu.
**Expect:** `LongestQueueWaitTime` climbs past the threshold (default 60 s) →
`ConnectChaos-Exp4-Queue-{region}` ALARM.

```bash
aws dynamodb put-item --table-name $STACK-Config --region $PRIMARY_REGION \
  --item '{"config_key":{"S":"chaos_flag"},"enabled":{"BOOL":true}}'
```

Call, press **4**, and **stay on the line past the threshold**, or:

```bash
aws lambda invoke --function-name $GEN --region $PRIMARY_REGION \
  --payload '{"mode":"faulty","fault_type":"flow","count":10}' /dev/stdout
```

```bash
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp4-Queue-$PRIMARY_REGION \
  --region $PRIMARY_REGION --query "MetricAlarms[0].StateValue"

aws cloudwatch get-metric-statistics --namespace AWS/Connect \
  --metric-name LongestQueueWaitTime \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID Name=MetricGroup,Value=Queue \
               Name=QueueName,Value=ConnectChaos-Overflow \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 60 --statistics Maximum \
  --region $PRIMARY_REGION \
  --query "sort_by(Datapoints,&Timestamp)[].{t:Timestamp,MaxSec:Maximum}" --output table
```

**Turn the flag off — it does not expire:**

```bash
aws dynamodb put-item --table-name $STACK-Config --region $PRIMARY_REGION \
  --item '{"config_key":{"S":"chaos_flag"},"enabled":{"BOOL":false}}'
```

**Pass:**

| Check | Expected |
|---|---|
| `LongestQueueWaitTime` (Maximum) | a datapoint **> 60 s** for `QueueName=ConnectChaos-Overflow` |
| `ConnectChaos-Exp4-Queue-us-east-1` | `ALARM` |
| `ConnectChaos-Composite-us-east-1` | `ALARM` |
| Traffic distribution | primary `0` / paired `100` |
| `LexFulfillmentHandler` log | `CHAOS FLAG ENABLED` (or equivalent) — proves the flag was read |

**Two things that produce a false negative here:**

1. **Hanging up too early.** The threshold is 60 s of *queue wait*, so the contact has to sit
   in the queue past that. Stay on the line for at least 90 s after the transfer.
2. **Choosing the wrong menu option.** The chaos flag path is in **`ConnectChaos-Exp4-Queue`**, not the
   Main IVR. If your phone number points at the Main IVR you will see the Lex failure but no
   queue transfer, so no queue wait accumulates.

> This experiment has not yet been validated on real telephony — this run is its first test.
> If the metric never appears, list the real dimensions and compare them against the alarm:
> `aws cloudwatch list-metrics --namespace AWS/Connect --metric-name LongestQueueWaitTime --region us-east-1`

➡️ **Step R** (and confirm the flag is off).

---

## The proof that matters — a call answered in the PAIRED region

Failover that moves traffic to a region which cannot answer is not resilience. Verify this
explicitly.

```bash
# shift to paired
aws connect update-traffic-distribution --id $TDG_ID --region $PRIMARY_REGION \
  --telephony-config "{\"Distributions\":[{\"Region\":\"$PRIMARY_REGION\",\"Percentage\":0},{\"Region\":\"$PAIRED_REGION\",\"Percentage\":100}]}"
```

Place a real call and complete the IVR. Then:

```bash
# the PAIRED region's Lambdas must show the invocation
aws logs tail /aws/lambda/LexFulfillmentHandler --region $PAIRED_REGION --since 5m
aws logs tail /aws/lambda/ConnectChaos-CallLogger --region $PAIRED_REGION --since 5m

# and the PRIMARY region's must NOT
aws logs tail /aws/lambda/LexFulfillmentHandler --region $PRIMARY_REGION --since 5m
```

**Pass:** the paired region logs the invocation and the primary does not.

If the **primary** logs it instead, the paired flow is still pointing at the primary's Lex
bot — the `$.AwsRegion` token or Lex GR replication is not working. Re-check step 2a.

Then restore with **Step R**.

---

## Run order

| # | Experiment | Trigger | Alarm | 180 s window |
|:-:|---|---|---|:-:|
| 1 | Lambda failure | `start-experiment $EXP1` | `ConnectChaos-Exp1-Lambda-*` | **yes** |
| 2 | DynamoDB unreachable | `start-experiment $EXP2` | `ConnectChaos-Exp2-DynamoDB-*` | no |
| 3 | Lex code-hook latency | `start-experiment $EXP3` | `ConnectChaos-Exp3-Latency-*` | **yes** |
| 4 | Flow failure → no-agent queue | set `chaos_flag=true` | `ConnectChaos-Exp4-Queue-*` | no |

Step R after every one.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Alarm stuck `INSUFFICIENT_DATA` | No datapoints match its dimension tuple | `aws cloudwatch list-metrics --namespace <ns> --metric-name <name>` and compare with the alarm |
| Exp 1 or 3 had no effect | Call landed outside the ~180 s window | Restart the experiment, call promptly |
| Exp 2 alarm flat | `ContactFlowErrors` needs **real** contacts | Place a live call, or use `fault_type=dynamodb` |
| Paired region answers nothing | Paired stack missing, or no Lex bot there | Step 2a |
| Primary logs a call after failover | Flow still points at the primary's Lex | `$.AwsRegion` / Lex GR — step 2a |
| Second experiment proves nothing | Traffic still at 0% | Step R |
| Stack `CREATE_FAILED` on composite alarm | Child alarms not yet created | Should not occur — explicit `DependsOn` is present (FIXES.md Fix 1) |
| `InvalidContactFlowException` | Lex block missing its prompt | Should not occur — Fix 2 |
| Lex alias unusable | Intents missing `SlotPriorities` | Should not occur — Fix 3 |
| Template too large to deploy | > 51,200 byte inline limit | `make deploy` stages via S3 automatically |
| Failed first create vanished | `deploy` auto-deletes new failed stacks | Use `create-stack --on-failure DO_NOTHING` |
| `DELETE_FAILED` on cleanup | FIS config bucket not empty | Empty `ccfis-…` first — see README Cleanup |

---

## Cleanup

See **Cleanup** in [README.md](README.md). Empty the FIS config buckets, delete the
**paired** stack first, then the primary.
