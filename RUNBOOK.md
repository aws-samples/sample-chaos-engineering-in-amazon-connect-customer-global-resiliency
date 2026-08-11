# Test Runbook

**The procedure for running the four chaos experiments.** Every command, what to press on the
keypad, what you should hear, and what to check afterwards.

**Install first.** This runbook assumes both Region stacks are deployed and `make verify` passes.
If not, do [README → Installation](README.md#installation) first. For *what* each experiment does
and *why* it is built that way, see [README → The four experiments](README.md#the-four-experiments);
this file does not repeat it.

> ### Two things invalidate an entire test run
>
> **1. Failover is one-way by design.** When an experiment trips the composite alarm,
> `TrafficShiftHandler` sets that Region to 0% and nothing shifts it back. Run **[Step R](#step-r--reset-between-every-experiment)**
> after every experiment, or every later test starts from an already-failed-over state and proves
> nothing.
>
> **2. Experiments 1 and 3 need ~55 s to arm. Do not call immediately.** Start the experiment,
> wait about a minute, *then* dial. Calling straight away is the commonest way to think an
> experiment is broken — the call simply succeeds. ([Why](README.md#why-you-must-wait-before-calling-experiments-1-and-3).)
> Experiments 2 and 4 need no wait.

---

## Contents

- [Step 0 — shell variables](#step-0--shell-variables)
- [Step 1 — pre-flight](#step-1--pre-flight)
- [Step 2 — confirm the environment](#step-2--confirm-the-environment)
- [Step 3 — baseline call](#step-3--baseline-call-do-this-before-any-experiment)
- [Timing to expect](#timing-to-expect)
- [Step R — reset](#step-r--reset-between-every-experiment)
- [Experiment 1 — Lambda failure](#experiment-1--account-lookup-lambda-fails)
- [Experiment 2 — DynamoDB unreachable](#experiment-2--dynamodb-unreachable--start-here)
- [Experiment 3 — Lex code-hook latency](#experiment-3--lex-code-hook-latency)
- [Experiment 4 — no-agent queue](#experiment-4--flow-failure--no-agent-queue)
- [The proof that matters](#the-proof-that-matters--a-call-answered-in-the-paired-region)
- [Run order](#run-order)
- [Troubleshooting](#troubleshooting)

---

## Step 0 — shell variables

Paste this once per terminal session. Every command below depends on it.

```bash
export STACK=connect-chaos-sample
export PRIMARY_REGION=us-east-1
export PAIRED_REGION=us-west-2
export ACCT=$(aws sts get-caller-identity --query Account --output text)

# An ACGR replica shares the SAME instance id, so both ARNs differ only by Region.
export INSTANCE_ID=<your-connect-instance-id>
export PRIMARY_INSTANCE_ARN=arn:aws:connect:$PRIMARY_REGION:$ACCT:instance/$INSTANCE_ID
export PAIRED_INSTANCE_ARN=arn:aws:connect:$PAIRED_REGION:$ACCT:instance/$INSTANCE_ID

# The Traffic Distribution Group holding your ported number, and the number itself.
export TDG_ID=<your-traffic-distribution-group-id>
export PHONE=<the-ported-number-on-that-tdg>
```

Then read the FIS experiment template IDs straight out of the stack, rather than copying them:

```bash
get_out () { aws cloudformation describe-stacks --stack-name $STACK --region "$1" \
  --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }

export EXP1=$(get_out $PRIMARY_REGION FISExperiment1)   # Lambda invocation error
export EXP2=$(get_out $PRIMARY_REGION FISExperiment2)   # DynamoDB network disruption
export EXP3=$(get_out $PRIMARY_REGION FISExperiment3)   # Lex code-hook latency
export GEN=ConnectChaos-TrafficGenerator-$PRIMARY_REGION

echo "exp1=$EXP1  exp2=$EXP2  exp3=$EXP3"
```

All three must print a value starting `EXT`. An empty result means `EnableAutoFailover` or the
stack outputs are not what you expect — stop and check the stack before going further.

---

## Step 1 — pre-flight

Four things must be true before a single test call is worth placing. Run these against a fresh
deployment, or any time results stop making sense.

```bash
# 1. ACGR pair — the SAME instance id must appear in BOTH Regions
for R in $PRIMARY_REGION $PAIRED_REGION; do
  printf '%-12s ' "$R"
  aws connect list-instances --region "$R" \
    --query "InstanceSummaryList[?Id=='$INSTANCE_ID'].InstanceAlias" --output text
done

# 2. The TDG must be ACTIVE
aws connect describe-traffic-distribution-group --traffic-distribution-group-id $TDG_ID \
  --region $PRIMARY_REGION --query "TrafficDistributionGroup.Status" --output text

# 3. A phone number must be attached to THIS TDG, or no call can reach the flow
aws connect list-phone-numbers-v2 --region $PRIMARY_REGION --max-results 60 \
  --query "ListPhoneNumbersSummaryList[?contains(TargetArn,'$TDG_ID')].{Number:PhoneNumber,Type:PhoneNumberType}" \
  --output table

# 4. Current traffic split — must be 100% primary / 0% paired before you start
aws connect get-traffic-distribution --id $TDG_ID --region $PRIMARY_REGION \
  --query "TelephonyConfig.Distributions" --output table
```

Expected: an alias printed for **both** Regions, status `ACTIVE`, at least one number listed, and
primary at 100%. If the split is not 100/0, run [Step R](#step-r--reset-between-every-experiment).

---

## Step 2 — confirm the environment

```bash
make verify STACK=$STACK PRIMARY_REGION=$PRIMARY_REGION \
  PAIRED_REGION=$PAIRED_REGION TDG_ID=$TDG_ID
```

29 checks across both Regions. **It must exit `0`.** It covers both stacks, whether the paired
Region can actually serve a call, Lex bot *and alias* replication, the `$.AwsRegion` tokens in all
five flows, seed data, the traffic split, the alarms, and a smoke invoke of the traffic-shift
handler.

`verify` cannot check the number → flow link — **no AWS API exposes it** — which is why Step 3
exists.

Then confirm every alarm is clear, in **both** Regions. FIS refuses to start an experiment whose
stop-condition alarm is not already `OK`:

```bash
for R in $PRIMARY_REGION $PAIRED_REGION; do
  echo "── $R"
  aws cloudwatch describe-alarms --region "$R" --alarm-name-prefix ConnectChaos- \
    --query "sort_by(MetricAlarms,&AlarmName)[].{Alarm:AlarmName,State:StateValue}" --output table
  aws cloudwatch describe-alarms --region "$R" --alarm-types CompositeAlarm \
    --alarm-name-prefix ConnectChaos- \
    --query "CompositeAlarms[].{Alarm:AlarmName,State:StateValue}" --output table
done
```

Every row must read `OK` or `INSUFFICIENT_DATA`. Open the dashboard now so you can watch:
**CloudWatch → Dashboards → `ConnectChaos-<primary-region>`**.

---

## Step 3 — baseline call (do this before any experiment)

**If the baseline call does not work, no experiment result below means anything.**

1. Dial `$PHONE`.
2. Listen for **"Connected in region us-east-1"** (or whichever Region is primary). That
   announcement alone tells you where the call landed — no log inspection needed.
3. Press **1** on the keypad.
4. Key **1 2 3 4 5** on the keypad. Use the keypad, not your voice: account numbers are collected
   as DTMF because ASR mis-transcribed "one two three four five" as `120345`, and once as `0`,
   which looks exactly like a broken lookup.
5. Expect **"Welcome back, John Doe."**
6. Hang up.

Then confirm the **primary** Region served it:

```bash
aws logs tail /aws/lambda/ConnectChaos-AccountLookup --region $PRIMARY_REGION --since 5m
aws logs tail /aws/lambda/ConnectChaos-CallLogger    --region $PRIMARY_REGION --since 5m
```

**Pass:** you heard the region announcement and the customer name, and the primary Region's logs
show the invocation.

If you heard nothing at all, the phone number is not associated with `ConnectChaos-Menu` — re-run
`make post-deploy` (see [README → Installation step 3](README.md#step-3--the-three-things-cloudformation-cannot-do)).

---

## Timing to expect

Measured on this sample, not estimated. **Do not conclude anything is broken before about four
minutes have passed.**

| Stage | Delay |
|---|---|
| `start-experiment` → fault actually effective (Exps 1 and 3) | **~55 s** |
| Exp 2 fault | immediate, and stays applied for the whole experiment |
| Exp 4 flag | applies to the next call |
| Call → `ContactFlowErrors` published | ~60–90 s |
| Alarm → traffic shifted | **`FailoverDelaySeconds`** (default 120 s) + ~2 s |
| **Full cycle, start to traffic shifted** | **~4 minutes** |

So a complete Experiment 1 run is: start, wait ~60 s, call, wait ~90 s for the alarm, then a
further ~120 s dwell before traffic moves.

Two consequences of the dwell ([why it exists](README.md#why-failover-is-deliberately-delayed)):

- **`aws cloudwatch set-alarm-state` cannot test failover while a dwell is configured.** A forced
  state is a temporary override CloudWatch reverts within ~50 s, so it expires inside the dwell
  and the handler correctly declines to act. To test the mechanism alone, redeploy with
  `FAILOVER_DELAY_SECONDS=0`.
- **A dwelling handler outlives a reset.** If you reset while a handler is sleeping and the alarm
  is genuinely still in `ALARM`, the shift still lands after the dwell. Wait the dwell out before
  resetting, or reset twice ~130 s apart.

---

## Step R — reset between every experiment

```bash
make reset STACK=$STACK PRIMARY_REGION=$PRIMARY_REGION \
           PAIRED_REGION=$PAIRED_REGION TDG_ID=$TDG_ID
```

It stops running experiments in **both** Regions, restores 100% primary / 0% paired, disarms the
Experiment 4 chaos flag in **both** Regions, then waits for every alarm in both Regions to leave
`ALARM` — and exits non-zero if they do not.

**Do not start the next experiment until it exits `0`.** The alarm wait is not cosmetic: each
experiment's stop condition is its **own** detection alarm, so an alarm still in `ALARM` makes FIS
fail the next experiment within ten seconds:

```
Error while handling stop condition for experiment: EXP...
The following alarms were not in state OK: [...ConnectChaos-Exp3-Latency-us-east-1]
```

<details>
<summary>Equivalent manual commands</summary>

```bash
# stop anything running
aws fis list-experiments --region $PRIMARY_REGION \
  --query "experiments[?state.status=='running'].id" --output text

# restore traffic
aws connect update-traffic-distribution --id $TDG_ID --region $PRIMARY_REGION \
  --telephony-config "{\"Distributions\":[{\"Region\":\"$PRIMARY_REGION\",\"Percentage\":100},{\"Region\":\"$PAIRED_REGION\",\"Percentage\":0}]}"

# disarm the Exp 4 flag in BOTH Regions
for R in $PRIMARY_REGION $PAIRED_REGION; do
  aws dynamodb put-item --table-name $STACK-Config --region $PRIMARY_REGION \
    --item '{"config_key":{"S":"chaos_flag#'"$R"'"},"enabled":{"BOOL":false}}'
done

# must return EMPTY, in BOTH Regions
for R in $PRIMARY_REGION $PAIRED_REGION; do
  aws cloudwatch describe-alarms --region "$R" --alarm-name-prefix ConnectChaos- \
    --query "MetricAlarms[?StateValue=='ALARM'].AlarmName" --output text
done
```

</details>

---

## Experiment 1 — account-lookup Lambda fails

**Alarm:** `ConnectChaos-Exp1-Lambda-$PRIMARY_REGION` · **Metric:** `ContactFlowErrors` on
`ConnectChaos-Exp1-Lambda`

**1. Start the fault.**

```bash
aws fis start-experiment --experiment-template-id $EXP1 --region $PRIMARY_REGION \
  --query "experiment.{id:id,state:state.status}"
```

**2. Wait ~60 seconds.** ⚠️ Calling sooner means no fault is applied and the call just succeeds.

**3. Call and drive the IVR.**

| Do | Expect |
|---|---|
| Dial `$PHONE` | *"Connected in region us-east-1"* |
| Press **1** | prompt for your account number |
| Key **any 5 digits** | ***"The account lookup service is unavailable. This is experiment one."*** |

> A `NOT_FOUND` or `INVALID_INPUT` result is **not** the fault — those return normally and the
> flow branches on them with a `Compare` block. Only a genuine invocation failure reaches the
> Error branch, which is what makes the metric attributable.

**4. Verify, in this order.**

```bash
# a) the component alarm
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp1-Lambda-$PRIMARY_REGION \
  --region $PRIMARY_REGION --query "MetricAlarms[0].StateValue" --output text

# b) the composite alarm
aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
  --alarm-names ConnectChaos-Composite-$PRIMARY_REGION --region $PRIMARY_REGION \
  --query "CompositeAlarms[0].StateValue" --output text

# c) the traffic shift — allow the 120 s dwell first
aws connect get-traffic-distribution --id $TDG_ID --region $PRIMARY_REGION \
  --query "TelephonyConfig.Distributions" --output table

# d) the handler's own account of what it did
aws logs tail /aws/lambda/ConnectChaos-TrafficShiftHandler --region $PRIMARY_REGION --since 10m
```

**Pass:** component `ALARM` → composite `ALARM` → primary `0` / paired `100` → a log line
`Traffic shifted: <primary>=0%, <paired>=100%`.

**5. Recovery call — press `1` again.** Dial once more and press **1**, the same digit. You should
hear *"Connected in region us-west-2"* then *"Welcome back, John Doe"*. This is what proves the
flow that just failed in the primary Region now succeeds in the paired one.

**6.** ➡️ **[Step R](#step-r--reset-between-every-experiment).**

---

## Experiment 2 — DynamoDB unreachable  *(start here)*

**The most reliable experiment and the best first proof of the failover chain** — no arming delay,
and the fault stays applied for the whole run.

**Alarm:** `ConnectChaos-Exp2-DynamoDB-$PRIMARY_REGION` · **Metric:** `ContactFlowErrors` on
`ConnectChaos-Exp2-DynamoDB`

**1. Start the fault.**

```bash
aws fis start-experiment --experiment-template-id $EXP2 --region $PRIMARY_REGION \
  --query "experiment.{id:id,state:state.status}"
```

**2. Call immediately — no wait needed.**

| Do | Expect |
|---|---|
| Dial `$PHONE` | *"Connected in region us-east-1"* |
| Press **2** | ***"We could not record your call. This is experiment two."*** |

**3. Verify.**

```bash
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp2-DynamoDB-$PRIMARY_REGION \
  --region $PRIMARY_REGION --query "MetricAlarms[0].StateValue" --output text

# the call logger should show DynamoDB failures
aws logs tail /aws/lambda/ConnectChaos-CallLogger --region $PRIMARY_REGION --since 10m
```

**Pass:**

| Check | Expected |
|---|---|
| `ConnectChaos-Exp2-DynamoDB-<primary>` | `ALARM` |
| `ConnectChaos-Composite-<primary>` | `ALARM` |
| Traffic distribution | primary `0` / paired `100` |
| `ConnectChaos-TrafficShiftHandler` log | `Traffic shifted: <primary>=0%, <paired>=100%` |
| `ConnectChaos-CallLogger` log | a DynamoDB timeout or connection error |

`ContactFlowErrors` only increments for **real contacts**, so a live call is the true test here.
Lambda `Errors` will also rise — expected, see the cascade note in the README.

> **Partial pass to watch for.** If Lambda `Errors` rises but `ContactFlowErrors` stays flat, the
> fault reached the Lambda and the flow did *not* take its Error branch — the exact failure Fix 6
> addressed. Check that a **real contact** went through, and that the flow really invokes
> `ConnectChaos-CallLogger`. Synthetic metrics cannot exercise a flow branch.

**4. Recovery call — press `2` again.** Expect *"Connected in region us-west-2"* then
*"Your call has been recorded for quality purposes."*

**5.** ➡️ **[Step R](#step-r--reset-between-every-experiment).**

---

## Experiment 3 — Lex code-hook latency

**Alarm:** `ConnectChaos-Exp3-Latency-$PRIMARY_REGION` · **Metric:** `AWS/Lambda` `Duration`
Maximum on `LexFulfillmentHandler`

**1. Start the fault.**

```bash
aws fis start-experiment --experiment-template-id $EXP3 --region $PRIMARY_REGION \
  --query "experiment.{id:id,state:state.status}"
```

**2. Wait ~60 seconds.** ⚠️ Same as Experiment 1.

**3. Call and drive the IVR.**

| Do | Expect |
|---|---|
| Dial `$PHONE` | *"Connected in region us-east-1"* |
| Press **3** | the Lex prompt |
| Answer, then key **1 2 3 4 5** | a long silence (~31 s), then ***"The lookup service is taking too long. This is experiment three."*** |

**4. Verify.**

```bash
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp3-Latency-$PRIMARY_REGION \
  --region $PRIMARY_REGION --query "MetricAlarms[0].StateValue" --output text

aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Duration \
  --dimensions Name=FunctionName,Value=LexFulfillmentHandler \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 60 --statistics Maximum \
  --region $PRIMARY_REGION \
  --query "sort_by(Datapoints,&Timestamp)[].{t:Timestamp,MaxMs:Maximum}" --output table
```

**Pass:** a `Duration` Maximum around **31,000 ms**, the alarm in `ALARM`, and `Errors` still
**0** — the function returns successfully, which is what separates Experiment 3 from Experiment 1.
The validated run measured 31,232 ms with `Errors` 0.0.

> **Two things you should *not* expect.** No `AWS/Lex RuntimeLambdaErrors` — never emitted on
> Connect's voice path. And **no `ContactFlowErrors` datapoint** for the Exp 3 flow: Connect
> handles the timed-out code hook internally. Both were measured, and both are why this experiment
> alarms on Lambda `Duration`.

**5. Recovery call — press `3` again.** Expect *"Connected in region us-west-2"* then
*"I found your information."*

**6.** ➡️ **[Step R](#step-r--reset-between-every-experiment).**

---

## Experiment 4 — flow failure → no-agent queue

Not a FIS experiment: you set a DynamoDB flag. **It does not expire — you must turn it off.**

**Alarm:** `ConnectChaos-Exp4-Queue-$PRIMARY_REGION` · **Metric:** `LongestQueueWaitTime` on
`ConnectChaos-Overflow`

**1. Arm the flag — in the PRIMARY Region only.**

```bash
aws dynamodb put-item --table-name $STACK-Config --region $PRIMARY_REGION \
  --item '{"config_key":{"S":"chaos_flag#'$PRIMARY_REGION'"},"enabled":{"BOOL":true}}'
```

The key is Region-scoped on purpose. Arming both Regions replicates the fault to the standby and
failover can then never recover — [README explains why](README.md#experiment-4--a-bad-config-value-parks-the-caller-on-an-unstaffed-queue).

**2. Call, and stay on the line. This is the one experiment where hanging up too early is the
usual failure.**

| Do | Expect |
|---|---|
| Dial `$PHONE` | *"Connected in region us-east-1"* |
| Press **4** | the Lex prompt |
| Answer, then key **1 2 3 4 5** | ***"All agents are currently busy. Please hold. This is experiment four."*** |
| **Start counting from that hold prompt** and stay on the line a further **90 seconds** | silence — the contact is parked on an unstaffed queue |

**The 60 s clock starts at the hold prompt, not when you dial.** The IVR consumes about a minute
first (region announcement, Lex prompt, your reply, the account number, the code hook), so the
total call is roughly two and a half minutes.

**3. Turn the flag off. It does not expire.**

```bash
aws dynamodb put-item --table-name $STACK-Config --region $PRIMARY_REGION \
  --item '{"config_key":{"S":"chaos_flag#'$PRIMARY_REGION'"},"enabled":{"BOOL":false}}'
```

**4. Verify.**

```bash
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp4-Queue-$PRIMARY_REGION \
  --region $PRIMARY_REGION --query "MetricAlarms[0].StateValue" --output text

aws cloudwatch get-metric-statistics --namespace AWS/Connect \
  --metric-name LongestQueueWaitTime \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID Name=MetricGroup,Value=Queue \
               Name=QueueName,Value=ConnectChaos-Overflow \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 60 --statistics Maximum \
  --region $PRIMARY_REGION \
  --query "sort_by(Datapoints,&Timestamp)[].{t:Timestamp,MaxSec:Maximum}" --output table
```

**Pass:**

| Check | Expected |
|---|---|
| `LongestQueueWaitTime` (Maximum) | a datapoint **> 60** for `QueueName=ConnectChaos-Overflow` |
| `ConnectChaos-Exp4-Queue-<primary>` | `ALARM` |
| `ConnectChaos-Composite-<primary>` | `ALARM` |
| Traffic distribution | primary `0` / paired `100` |
| `LexFulfillmentHandler` log | the chaos flag being read as enabled |

**Two things that produce a false negative:**

1. **Hanging up too early.** A measured failed attempt:

   ```
   19:27:09  call starts
   19:28:08  transferred to the queue   <- the 60 s clock starts HERE
   19:28:15  caller hung up             <- only 8 s of queue wait; threshold is 60
   ```

   That call lasted 66 s, which sounds like plenty, and produced `LongestQueueWaitTime = 8`.

2. **Pressing the wrong digit.** The chaos-flag path exists only in `ConnectChaos-Exp4-Queue`,
   reached by pressing **4**. Any other digit runs a different experiment's flow, where you will
   see the Lex failure but no queue transfer — so no queue wait accumulates.

> **Validated on real telephony.** A call held on the line produced `LongestQueueWaitTime = 96` at
> 19:35 UTC against the 60 s threshold; the alarm went `OK → ALARM` at 19:36:28 UTC and back to
> `OK` at 19:39:28 UTC after Step R. If the metric never appears at all, list the real dimensions
> and compare them with the alarm:
> `aws cloudwatch list-metrics --namespace AWS/Connect --metric-name LongestQueueWaitTime --region $PRIMARY_REGION`

**5. Recovery call — press `4` again**, with the flag now off. Expect *"Connected in region
us-west-2"* then *"I found your information."*

**6.** ➡️ **[Step R](#step-r--reset-between-every-experiment)**, and confirm the flag is off.

---

## The proof that matters — a call answered in the PAIRED Region

Failover that moves traffic to a Region which cannot answer is not resilience. Verify it
explicitly, independently of any experiment.

**1. Shift traffic by hand.**

```bash
aws connect update-traffic-distribution --id $TDG_ID --region $PRIMARY_REGION \
  --telephony-config "{\"Distributions\":[{\"Region\":\"$PRIMARY_REGION\",\"Percentage\":0},{\"Region\":\"$PAIRED_REGION\",\"Percentage\":100}]}"
```

**2. Call, press `1`, key `12345`, and complete the IVR.** You should hear *"Connected in region
us-west-2"* and then *"Welcome back, John Doe."*

**3. Prove which Region's compute actually ran.**

```bash
# the PAIRED Region's Lambdas MUST show the invocation
aws logs tail /aws/lambda/ConnectChaos-AccountLookup --region $PAIRED_REGION --since 5m
aws logs tail /aws/lambda/LexFulfillmentHandler      --region $PAIRED_REGION --since 5m

# and the PRIMARY Region's must NOT
aws logs tail /aws/lambda/ConnectChaos-AccountLookup --region $PRIMARY_REGION --since 5m
```

**Pass:** the paired Region logs the invocation and the primary does not.

**Fail:** if the **primary** logs it instead, the paired flow is still pointing at the primary's
Lambda or Lex bot — the `$.AwsRegion` token or Lex GR replication is not working. Re-run
`make verify`, which checks all five flows in both Regions.

**4.** ➡️ **[Step R](#step-r--reset-between-every-experiment).**

---

## Run order

| # | Experiment | Trigger | Wait before calling | Digit | Stay on the line |
|:-:|---|---|:-:|:-:|:-:|
| 1 | DynamoDB unreachable | `start-experiment $EXP2` | none | `2` | no |
| 2 | Flow failure → no-agent queue | set `chaos_flag#<region>=true` | none | `4` | **90 s after the hold prompt** |
| 3 | Lambda failure | `start-experiment $EXP1` | **~55 s** | `1` | no |
| 4 | Lex code-hook latency | `start-experiment $EXP3` | **~55 s** | `3` | no |
| 5 | Paired-Region proof | manual traffic shift | none | `1` | no |

Experiment 2 first because it has no arming delay, so it is the most forgiving verification of the
whole failover chain. **Step R after every one.**

> **Always use the SAME digit for the recovery call.** After failover, dial again and press the
> digit for the experiment you just ran — not a different one. The claim being proven is that
> *this* flow, which just failed in the primary Region, now succeeds in the paired Region.
> Pressing a different digit exercises a different flow and proves something weaker. There is no
> technical difference; the distinction is what the test demonstrates.
>
> | Experiment | Digit | Expected on the recovery call |
> |:-:|:-:|---|
> | 1 | `1` | *"Welcome back, John Doe"* |
> | 2 | `2` | *"Your call has been recorded for quality purposes"* |
> | 3 | `3` | *"I found your information"* |
> | 4 | `4` | *"I found your information"* (flag off) |
>
> Every recovery call opens with *"Connected in region &lt;paired&gt;"*. That announcement is the
> proof of which Region served it, and it needs no log inspection.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No audio at all when you dial | The number is not associated with `ConnectChaos-Menu` | `make post-deploy`. No API exposes this link, so only a call reveals it |
| Exp 1 or 3 had no effect; the call just succeeded | You called before the fault armed | Wait ~60 s after `start-experiment`, then call |
| `start-experiment` fails in ~10 s | Its stop-condition alarm is not `OK` | Let `make reset` finish and exit `0` first |
| Exp 2 alarm flat but Lambda `Errors` rising | The flow did not take its Error branch | A **real** call is required; synthetic metrics cannot exercise a flow branch |
| Exp 4 metric shows a small number | Hung up before 60 s of *queue wait* accrued | Count from the hold prompt, stay on 90 s |
| Alarm stuck `INSUFFICIENT_DATA` | No datapoints match its dimension tuple | `aws cloudwatch list-metrics --namespace <ns> --metric-name <name>` and compare with the alarm |
| Traffic never shifts although the alarm fired | Still inside the `FailoverDelaySeconds` dwell | Wait the dwell out (default 120 s), then re-check |
| `set-alarm-state` does not trigger failover | The forced state expires inside the dwell | Redeploy with `FAILOVER_DELAY_SECONDS=0` to test the mechanism alone |
| Traffic shifts again right after a reset | A handler was mid-dwell when you reset | Wait the dwell out, or reset twice ~130 s apart |
| Paired Region answers nothing | Paired stack missing, or its Lex **alias** replica is not `Available` | `make verify` |
| The primary logs a call after failover | The flow still points at the primary's Lambda or Lex | `$.AwsRegion` / Lex GR — `make verify` |
| The second experiment proves nothing | Traffic still at 0% primary | Step R |
| `DELETE_FAILED` on cleanup | FIS config bucket not empty | Empty `ccfis-…` first — see [README → Cleanup](README.md#cleanup) |

Defects already found and fixed, plus the things that are deliberately **not** bugs, are in
[FIXES.md](FIXES.md). Read it before changing an experiment's metric.
