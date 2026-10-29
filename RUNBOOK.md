# Test Runbook

> ⚠️ **This sample is for non-production use only.** Deploy and run it in a dedicated AWS account
> with no production workloads. The FIS execution role can modify network ACLs on any VPC in the
> account. See the [security section in the README](README.md#security-posture-and-production-hardening)
> for the full posture, accepted findings, and what to change before any production use.

**The procedure for running the four chaos experiments.** Every command, what to press on the
keypad, what you should hear, and what to check afterwards.

**Install first.** This runbook assumes both Region stacks are deployed and `make verify` passes.
If not, do [README → Installation](README.md#installation) first. For *what* each experiment does
and *why* it is built that way, see [README → The four experiments](README.md#the-four-experiments);
this file does not repeat it.

> ### Two things invalidate an entire test run
>
> **1. Traffic transition is one-way by design.** When an experiment trips the composite alarm,
> `TrafficShiftHandler` sets that Region to 0% and nothing shifts it back. Run **[Step R](#step-r--reset-between-every-experiment)**
> after every experiment, or every later test starts from an already-failed-over state and proves
> nothing.
>
> **2. Experiments 1 and 3 need about a minute to arm. Do not call immediately.** Start the experiment,
> wait about a minute, *then* dial. Calling straight away is an easy way to think an
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
- [The proof that matters](#the-proof-that-matters--a-call-answered-in-the-replica-region)
- [Run order](#run-order)
- [Troubleshooting](#troubleshooting)

---

## Step 0 — shell variables

Paste this once per terminal session. Every command below depends on it.

**You supply three values. Everything else is derived or read from the stack.**

| Variable | What it is | Shape, with an example | How to find yours |
|---|---|---|---|
| `INSTANCE_ID` | Connect instance ID. An ACGR replica shares the **same** ID in both Regions | UUID — `EXAMPLE1-2222-3333-4444-555555555555` | `aws connect list-instances --region $SOURCE_REGION` |
| `TDG_ID` | The Traffic Distribution Group the traffic shift updates | UUID — `EXAMPLE2-6666-7777-8888-999999999999` | `aws connect list-traffic-distribution-groups --region $SOURCE_REGION` |
| `PHONE` | The number attached to that TDG | The number as you would dial it — `+1-555-0100` | Step 1, check 3 below |

> The examples above are **not real values** — they exist to show the shape. `EXAMPLE…` is not
> valid hexadecimal, so a UUID that still contains it has not been replaced. The guard at the end
> of this step catches that.

```bash
# ── fixed for this sample ───────────────────────────────────────────────────────
export STACK=connect-chaos-sample
export SOURCE_REGION=us-east-1
export REPLICA_REGION=us-west-2

# ── derived, never pasted ───────────────────────────────────────────────────────
export ACCT=$(aws sts get-caller-identity --query Account --output text)

# ── REPLACE these three with your own values ────────────────────────────────────
export INSTANCE_ID=EXAMPLE1-2222-3333-4444-555555555555
export TDG_ID=EXAMPLE2-6666-7777-8888-999999999999
export PHONE=+1-555-0100

# ── built from the above; an ACGR pair differs only by Region ───────────────────
export SOURCE_INSTANCE_ARN=arn:aws:connect:$SOURCE_REGION:$ACCT:instance/$INSTANCE_ID
export REPLICA_INSTANCE_ARN=arn:aws:connect:$REPLICA_REGION:$ACCT:instance/$INSTANCE_ID
```

Now read the FIS experiment template IDs out of the stack rather than copying them. They change
on every redeploy, so pasting them is how a test run ends up pointing at a template that no longer
exists:

```bash
# Helper: read a named output from the stack. Args: <region> <OutputKey>
get_out () { aws cloudformation describe-stacks --stack-name $STACK --region "$1" \
  --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }

export EXP1=$(get_out $SOURCE_REGION FISExperiment1)   # Lambda invocation error
export EXP2=$(get_out $SOURCE_REGION FISExperiment2)   # DynamoDB network disruption
export EXP3=$(get_out $SOURCE_REGION FISExperiment3)   # Lex code-hook latency
```

**Guard — run this before anything else.** It fails loudly if an example value survived or a
lookup came back empty, which is cheaper than discovering it three commands into an experiment:

```bash
# Refuse to continue if an example value survived, a variable is empty, or the FIS
# template lookup came back with something that is not a template id.
ok=1
case "$INSTANCE_ID$TDG_ID$PHONE" in
  *EXAMPLE*|*555-0100*) echo "FAIL  replace the three example values in Step 0"; ok=0 ;;
esac
for v in ACCT INSTANCE_ID TDG_ID PHONE EXP1 EXP2 EXP3; do
  eval "val=\$$v"
  [ -n "$val" ] || { echo "FAIL  \$$v is empty"; ok=0; }
done
case "$EXP1" in EXT*) ;; *) echo "FAIL  EXP1 is not a FIS template id: '$EXP1'"; ok=0 ;; esac
[ "$ok" = 1 ] && echo "OK  environment ready: acct=$ACCT instance=$INSTANCE_ID exp1=$EXP1"
```

`EXP1`–`EXP3` must each be a FIS template ID, which begins `EXT`.
An empty result means the stack name or Region is not what you think, or the stack has not finished
deploying — stop and check the stack before going further.

---

## Step 1 — pre-flight

Four things must be true before a single test call is worth placing. Run these against a fresh
deployment, or any time results stop making sense.

```bash
# 1. ACGR pair — the SAME instance id must appear in BOTH Regions
for R in $SOURCE_REGION $REPLICA_REGION; do
  printf '%-12s ' "$R"
  aws connect list-instances --region "$R" \
    --query "InstanceSummaryList[?Id=='$INSTANCE_ID'].InstanceAlias" --output text
done

# 2. The TDG must be ACTIVE
aws connect describe-traffic-distribution-group --traffic-distribution-group-id $TDG_ID \
  --region $SOURCE_REGION --query "TrafficDistributionGroup.Status" --output text

# 3. A phone number must be attached to THIS TDG, or no call can reach the flow
aws connect list-phone-numbers-v2 --region $SOURCE_REGION --max-results 60 \
  --query "ListPhoneNumbersSummaryList[?contains(TargetArn,'$TDG_ID')].{Number:PhoneNumber,Type:PhoneNumberType}" \
  --output table

# 4. Current traffic split — must be 100% source / 0% replica before you start
aws connect get-traffic-distribution --id $TDG_ID --region $SOURCE_REGION \
  --query "TelephonyConfig.Distributions" --output table
```

Expected: an alias printed for **both** Regions, status `ACTIVE`, at least one number listed, and
source at 100%. If the split is not 100/0, run [Step R](#step-r--reset-between-every-experiment).

---

## Step 2 — confirm the environment

```bash
# Confirms both stacks, Lex bot AND alias replication, the $.AwsRegion tokens in all five
# flows, seed data, the traffic split, the alarms, and smoke-invokes the shift handler.
make verify STACK=$STACK SOURCE_REGION=$SOURCE_REGION \
  REPLICA_REGION=$REPLICA_REGION TDG_ID=$TDG_ID
```

It runs a series of checks across both Regions. **It must exit `0`.** It covers both stacks, whether the replica
Region can actually serve a call, Lex bot *and alias* replication, the `$.AwsRegion` tokens in all
five flows, seed data, the traffic split, the alarms, and a smoke invoke of the traffic-shift
handler.

`verify` checks that the phone number is associated with `ConnectChaos-Menu`
(`aws connect list-flow-associations`). It cannot prove the call is answered — that is what the
baseline call in Step 3 is for.

Then confirm every `ConnectChaos-` alarm is clear, in **both** Regions. An experiment's stop condition is a
CloudWatch alarm, so an alarm that is already in `ALARM` would stop the experiment as it starts:

```bash
# Component alarms, then the composite, for BOTH Regions. An alarm already in ALARM would trip
# an experiment's stop condition as it starts, so all of these must be clear.
for R in $SOURCE_REGION $REPLICA_REGION; do
  echo "── $R"
  aws cloudwatch describe-alarms --region "$R" --alarm-name-prefix ConnectChaos- \
    --query "sort_by(MetricAlarms,&AlarmName)[].{Alarm:AlarmName,State:StateValue}" --output table
  aws cloudwatch describe-alarms --region "$R" --alarm-types CompositeAlarm \
    --alarm-name-prefix ConnectChaos- \
    --query "CompositeAlarms[].{Alarm:AlarmName,State:StateValue}" --output table
done
```

Every row must read `OK` or `INSUFFICIENT_DATA`. Open the dashboard now so you can watch:
**CloudWatch → Dashboards → `ConnectChaos-$SOURCE_REGION`**.

---

## Step 3 — baseline call (do this before any experiment)

**If the baseline call does not work, no experiment result below means anything.**

1. Dial `$PHONE`.
2. Listen for **"Connected in region us-east-1"** (or whichever Region is source). That
   announcement alone tells you where the call landed — no log inspection needed.
3. Press **1** on the keypad.
4. Key **1 2 3 4 5** on the keypad, then press **#**. The prompt asks for the pound key. Use the
   keypad, not your voice: account numbers are collected as DTMF so that speech recognition is not
   a variable in the test.
5. Expect **"Welcome back, John Doe. Your account is in good standing."**
6. Hang up.

Then confirm the **source** Region served it:

```bash
# Should show the invocation. The customer name you heard came from DynamoDB, so this also proves
# the VPC-attached Lambda reaches DynamoDB through the gateway endpoint alone (no NAT).
aws logs tail /aws/lambda/ConnectChaos-AccountLookup --region $SOURCE_REGION --since 5m
```

`ConnectChaos-CallLogger` is only invoked by the Experiment 2 flow (menu option 2), so it has
nothing to show after this call.

**Pass:** you heard the region announcement and the customer name, and the source Region's log
shows the `ConnectChaos-AccountLookup` invocation.

If you heard nothing at all, the phone number is not associated with `ConnectChaos-Menu` — re-run
`make post-deploy` (see [README → Installation step 3](README.md#step-3--the-things-cloudformation-cannot-do)).

---

## Timing to expect

Metric publication and alarm evaluation take time, so **do not conclude anything is broken straight away.**

| Stage | Delay |
|---|---|
| `start-experiment` → fault actually effective (Exps 1 and 3) | up to about a minute (AWS documents a ramp-up of up to 60 s for the FIS Lambda extension) |
| Exp 2 fault | no extension ramp-up; stays applied for the whole experiment |
| Exp 4 flag | applies to the next call |
| Alarm fires → traffic shifted | **`RegionSwitchDelaySeconds`** (default 120 s) |

So a complete Experiment 1 run is: start, wait about a minute, call, wait for the alarm, then the
dwell (default 120 s) before traffic moves.

Two consequences of the dwell ([why it exists](README.md#why-traffic-transition-is-deliberately-delayed)):

- **`aws cloudwatch set-alarm-state` cannot test traffic transition while a dwell is configured.** A forced
  state is a temporary override that CloudWatch reverts at the alarm's next evaluation, so it can expire
  inside the dwell and the handler then correctly declines to act. To test the mechanism alone, redeploy with
  `REGION_SWITCH_DELAY_SECONDS=0`.
- **A dwelling handler outlives a reset.** If you reset while a handler is sleeping and the alarm
  is genuinely still in `ALARM`, the shift still lands after the dwell. Wait the dwell out before
  resetting, or reset again after the dwell has elapsed.

---

## Step R — reset between every experiment

```bash
# Stops running experiments in both Regions, restores 100% source / 0% replica, disarms the
# Exp 4 flag in both Regions, then waits for every alarm to leave ALARM. Must exit 0.
make reset STACK=$STACK SOURCE_REGION=$SOURCE_REGION \
           REPLICA_REGION=$REPLICA_REGION TDG_ID=$TDG_ID
```

It exits non-zero if the alarms do not leave `ALARM`. Allow several minutes: CloudWatch returns an alarm to `OK` only after it has evaluated periods without breaching data, and `make reset` waits up to ten minutes before giving up.

**Do not start the next experiment until it exits `0`.** The alarm wait is not cosmetic: each
experiment's stop condition is its **own** detection alarm, so an alarm still in `ALARM` would trip the
stop condition as soon as the next experiment starts.

<details>
<summary>Equivalent manual commands</summary>

```bash
# stop anything running, in BOTH Regions
for R in $SOURCE_REGION $REPLICA_REGION; do
  for E in $(aws fis list-experiments --region $R \
              --query "experiments[?state.status=='running'].id" --output text); do
    aws fis stop-experiment --id $E --region $R
  done
done

# restore traffic
aws connect update-traffic-distribution --id $TDG_ID --region $SOURCE_REGION \
  --telephony-config "{\"Distributions\":[{\"Region\":\"$SOURCE_REGION\",\"Percentage\":100},{\"Region\":\"$REPLICA_REGION\",\"Percentage\":0}]}"

# disarm the Exp 4 flag in BOTH Regions
for R in $SOURCE_REGION $REPLICA_REGION; do
  aws dynamodb put-item --table-name $STACK-Config --region $SOURCE_REGION \
    --item '{"config_key":{"S":"chaos_flag#'"$R"'"},"enabled":{"BOOL":false}}'
done

# must return EMPTY, in BOTH Regions (component alarms and the composite)
for R in $SOURCE_REGION $REPLICA_REGION; do
  aws cloudwatch describe-alarms --region "$R" --alarm-name-prefix ConnectChaos- \
    --alarm-types MetricAlarm CompositeAlarm \
    --query "[MetricAlarms[?StateValue=='ALARM'].AlarmName, CompositeAlarms[?StateValue=='ALARM'].AlarmName][]" --output text
done
```

</details>

---

## Experiment 1 — account-lookup Lambda fails

**Alarm:** `ConnectChaos-Exp1-Lambda-$SOURCE_REGION` · **Metric:** `ContactFlowErrors` on
`ConnectChaos-Exp1-Lambda`

**1. Start the fault.**

```bash
# Errors every ConnectChaos-AccountLookup invocation without running the code.
# Stop condition is this experiment's OWN alarm, so FIS halts it as soon as it is detected.
aws fis start-experiment --experiment-template-id $EXP1 --region $SOURCE_REGION \
  --query "experiment.{id:id,state:state.status}"
```

**2. Wait ~60 seconds.** ⚠️ Calling sooner means no fault is applied and the call just succeeds.

**3. Call and drive the IVR.**

| Do | Expect |
|---|---|
| Dial `$PHONE` | *"Connected in region us-east-1"* |
| Press **1** | *"Experiment one, account lookup."* then a prompt for your account number |
| Key **any 5 digits**, then press **#** | ***"The account lookup service is unavailable. This is experiment one."*** |

> A `NOT_FOUND` or `INVALID_INPUT` result is **not** the fault — those return normally and the
> flow branches on them with a `Compare` block. Only a genuine invocation failure reaches the
> Error branch, which is what makes the metric attributable.

**4. Verify, in this order.**

```bash
# a) the component alarm
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp1-Lambda-$SOURCE_REGION \
  --region $SOURCE_REGION --query "MetricAlarms[0].StateValue" --output text

# b) the composite alarm
aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
  --alarm-names ConnectChaos-Composite-$SOURCE_REGION --region $SOURCE_REGION \
  --query "CompositeAlarms[0].StateValue" --output text

# c) the traffic shift — allow the 120 s dwell first
aws connect get-traffic-distribution --id $TDG_ID --region $SOURCE_REGION \
  --query "TelephonyConfig.Distributions" --output table

# d) the handler's own account of what it did
aws logs tail /aws/lambda/ConnectChaos-TrafficShiftHandler --region $SOURCE_REGION --since 10m
```

**Pass:** component `ALARM` → composite `ALARM` → source `0` / replica `100` → a log line
`Traffic shifted: $SOURCE_REGION=0%, $REPLICA_REGION=100%`.

**5. Recovery call — press `1` again.** Dial once more and press **1**, the same digit. You should
hear *"Connected in region us-west-2"* then *"Welcome back, John Doe. Your account is in good standing."* This is what proves the
flow that just failed in the source Region now succeeds in the replica one.

**6.** ➡️ **[Step R](#step-r--reset-between-every-experiment).**

---

## Experiment 2 — DynamoDB unreachable  *(start here)*

**A good first experiment** — no arming delay, and the fault stays applied for the whole run.

**Alarm:** `ConnectChaos-Exp2-DynamoDB-$SOURCE_REGION` · **Metric:** `ContactFlowErrors` on
`ConnectChaos-Exp2-DynamoDB`

**1. Start the fault.**

```bash
# Blocks both Lambda subnets from the DynamoDB endpoint at the NACL. Network-level, so it
# needs no extension ramp-up and stays applied for the whole experiment.
aws fis start-experiment --experiment-template-id $EXP2 --region $SOURCE_REGION \
  --query "experiment.{id:id,state:state.status}"
```

**2. Call — no wait needed.** There is no extension ramp-up. Check that the experiment shows
`running`, then dial.

| Do | Expect |
|---|---|
| Dial `$PHONE` | *"Connected in region us-east-1"* |
| Press **2** | *"Experiment two, call audit logging."* then a short silence, then ***"We could not record your call. This is experiment two."*** |

**3. Verify.**

```bash
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp2-DynamoDB-$SOURCE_REGION \
  --region $SOURCE_REGION --query "MetricAlarms[0].StateValue" --output text

# the call logger should show DynamoDB failures (possibly several attempts for one call: Connect
# retries a failed Lambda invocation up to three times before taking the Error branch)
aws logs tail /aws/lambda/ConnectChaos-CallLogger --region $SOURCE_REGION --since 10m
```

**Pass:**

| Check | Expected |
|---|---|
| `ConnectChaos-Exp2-DynamoDB-$SOURCE_REGION` | `ALARM` |
| `ConnectChaos-Composite-$SOURCE_REGION` | `ALARM` |
| Traffic distribution | source `0` / replica `100` |
| `ConnectChaos-TrafficShiftHandler` log | `Traffic shifted: $SOURCE_REGION=0%, $REPLICA_REGION=100%` |
| `ConnectChaos-CallLogger` log | a DynamoDB timeout or connection error |

The short silence is Connect retrying the call logger, up to three times, before it takes the Error branch.

`ContactFlowErrors` only increments for **real contacts**, so a live call is the true test here.
Lambda `Errors` will also rise — expected, see the cascade note in the README.

> **Partial pass to watch for.** If Lambda `Errors` rises but `ContactFlowErrors` stays flat, the
> fault reached the Lambda and the flow did *not* take its Error branch — the failure a direct-invoke call
> logger exists to expose. Check that a **real contact** went through, and that the flow really invokes
> `ConnectChaos-CallLogger`. Synthetic metrics cannot exercise a flow branch.

**4. Recovery call — press `2` again.** Expect *"Connected in region us-west-2"* then
*"Your call has been recorded for quality purposes."*

**5.** ➡️ **[Step R](#step-r--reset-between-every-experiment).**

---

## Experiment 3 — Lex code-hook latency

**Alarm:** `ConnectChaos-Exp3-Latency-$SOURCE_REGION` · **Metric:** `AWS/Lambda` `Duration`
Maximum on `LexFulfillmentHandler`

**1. Start the fault.**

```bash
# Injects a ~31 s startup delay into LexFulfillmentHandler, whose own timeout is 40 s -- so
# the code hook runs slow but still returns cleanly, which is why Errors stays 0.
aws fis start-experiment --experiment-template-id $EXP3 --region $SOURCE_REGION \
  --query "experiment.{id:id,state:state.status}"
```

**2. Wait ~60 seconds.** ⚠️ Same as Experiment 1.

**3. Call and drive the IVR.**

| Do | Expect |
|---|---|
| Dial `$PHONE` | *"Connected in region us-east-1"* |
| Press **3** | *"Experiment three, speech latency."* then the Lex prompt, *"How can I help you today?"* |
| Say **"I want to look up my account"** | *"What is your account number?"* |
| Within 4 seconds, key **1 2 3 4 5** and press **#** (or say the number) | a long silence (the injected delay is ~31 s, and Lex waits 30 s for a code hook by default), then ***"The lookup service is taking too long. This is experiment three."*** |

The flow plays that same line for any problem in the Lex block. If Lex does not recognise your
phrase, or hears no answer in time, you hear it straight away with no fault involved — call again.

**4. Verify.**

```bash
# a) the latency alarm
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp3-Latency-$SOURCE_REGION \
  --region $SOURCE_REGION --query "MetricAlarms[0].StateValue" --output text

aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Duration \
  --dimensions Name=FunctionName,Value=LexFulfillmentHandler \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 60 --statistics Maximum \
  --region $SOURCE_REGION \
  --query "sort_by(Datapoints,&Timestamp)[].{t:Timestamp,MaxMs:Maximum}" --output table
```

**Pass:** a `Duration` Maximum around **31,000 ms**, the alarm in `ALARM`, and `Errors` still
**0** — the function returns successfully, which is what separates Experiment 3 from Experiment 1.

> This experiment alarms on Lambda `Duration`, not on `ContactFlowErrors`: the function returns
> successfully, and the flow's error branch just plays a message, so error metrics may stay flat.

**5. Recovery call — press `3` again.** Say the same phrase and key the digits. Expect *"Connected
in region us-west-2"*, then Lex's answer (*"Welcome back, John Doe…"*) and the flow's closing
line, *"I found your information. Thank you for calling."* The call then ends: the sample has no
agents.

**6.** ➡️ **[Step R](#step-r--reset-between-every-experiment).**

---

## Experiment 4 — flow failure → no-agent queue

Not a FIS experiment: you set a DynamoDB flag. **It does not expire — you must turn it off.**

**Alarm:** `ConnectChaos-Exp4-Queue-$SOURCE_REGION` · **Metric:** `LongestQueueWaitTime` on
`ConnectChaos-Overflow`

**1. Arm the flag — in the SOURCE Region only.**

```bash
# Arm the flag in the SOURCE Region only. The key is Region-scoped because the table is a
# Global Table -- arming both Regions replicates the fault and traffic transition could never recover.
aws dynamodb put-item --table-name $STACK-Config --region $SOURCE_REGION \
  --item '{"config_key":{"S":"chaos_flag#'$SOURCE_REGION'"},"enabled":{"BOOL":true}}'
```

The key is Region-scoped on purpose. Arming both Regions replicates the fault to the standby and
traffic transition can then never recover — [README explains why](README.md#experiment-4--a-bad-config-value-parks-the-caller-on-an-unstaffed-queue).

**2. Call, and stay on the line. This is the one experiment where hanging up too early is the
usual failure.**

| Do | Expect |
|---|---|
| Dial `$PHONE` | *"Connected in region us-east-1"* |
| Press **4** | *"Experiment four, queue overflow."* then the Lex prompt, *"How can I help you today?"* |
| Say **"I want to look up my account"** | *"What is your account number?"* |
| Within 4 seconds, key **1 2 3 4 5** and press **#** (or say the number) | ***"All agents are currently busy. Please hold. This is experiment four."*** |
| **Start counting from that hold prompt** and stay on the line comfortably past the 60 s threshold | silence — the contact is parked on an unstaffed queue |

**The 60 s clock starts at the hold prompt, not when you dial.** The IVR takes some time first
(region announcement, Lex prompt, your reply, the account number, the code hook).

The flow sends any problem in the Lex block to the same queue, so a phrase Lex does not recognise
also parks the caller there with the flag off. The pass table in Step 4 lists the
`LexFulfillmentHandler` log showing the flag read as enabled, which is how to confirm the flag
was the cause.

**3. Turn the flag off. It does not expire.**

```bash
# Disarm. Unlike a FIS experiment this has no duration and will NOT expire on its own.
aws dynamodb put-item --table-name $STACK-Config --region $SOURCE_REGION \
  --item '{"config_key":{"S":"chaos_flag#'$SOURCE_REGION'"},"enabled":{"BOOL":false}}'
```

**4. Verify.**

```bash
# a) the queue-wait alarm
aws cloudwatch describe-alarms --alarm-names ConnectChaos-Exp4-Queue-$SOURCE_REGION \
  --region $SOURCE_REGION --query "MetricAlarms[0].StateValue" --output text

aws cloudwatch get-metric-statistics --namespace AWS/Connect \
  --metric-name LongestQueueWaitTime \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID Name=MetricGroup,Value=Queue \
               Name=QueueName,Value=ConnectChaos-Overflow \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 60 --statistics Maximum \
  --region $SOURCE_REGION \
  --query "sort_by(Datapoints,&Timestamp)[].{t:Timestamp,MaxSec:Maximum}" --output table

# b) the composite alarm
aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
  --alarm-names ConnectChaos-Composite-$SOURCE_REGION --region $SOURCE_REGION \
  --query "CompositeAlarms[0].StateValue" --output text

# c) the traffic shift — allow the 120 s dwell first
aws connect get-traffic-distribution --id $TDG_ID --region $SOURCE_REGION \
  --query "TelephonyConfig.Distributions" --output table

# d) the handler's own account of what it did
aws logs tail /aws/lambda/ConnectChaos-TrafficShiftHandler --region $SOURCE_REGION --since 10m

# e) the cause, from the function's side: the chaos flag being read as enabled
aws logs tail /aws/lambda/LexFulfillmentHandler --region $SOURCE_REGION --since 15m
```

**Pass:**

| Check | Expected |
|---|---|
| `LongestQueueWaitTime` (Maximum) | a datapoint **> 60** for `QueueName=ConnectChaos-Overflow` |
| `ConnectChaos-Exp4-Queue-$SOURCE_REGION` | `ALARM` |
| `ConnectChaos-Composite-$SOURCE_REGION` | `ALARM` |
| Traffic distribution | source `0` / replica `100` |
| `LexFulfillmentHandler` log | the chaos flag being read as enabled |

**Two things that produce a false negative:**

1. **Hanging up too early.** The alarm threshold is 60 s of *queue wait*, which starts when the
   contact is transferred to the queue, not when the call starts. A caller who hangs up soon after
   the transfer leaves a small `LongestQueueWaitTime` and the alarm does not fire.

2. **Pressing the wrong digit.** The chaos-flag path exists only in `ConnectChaos-Exp4-Queue`,
   reached by pressing **4**. Any other digit runs a different experiment's flow, where you will
   see the Lex failure but no queue transfer — so no queue wait accumulates.

> If the metric never appears at all, list the real dimensions and compare them with the alarm:
> `aws cloudwatch list-metrics --namespace AWS/Connect --metric-name LongestQueueWaitTime --region $SOURCE_REGION`

**5. Recovery call — press `4` again**, with the flag now off. Say the same phrase and key the
digits. Expect *"Connected in region us-west-2"*, then Lex's answer (*"Welcome back, John Doe…"*)
and the flow's closing line, *"I found your information. Thank you for calling."* The call then
ends. This is the self-service path: the lookup worked, so nothing needs a queue or an agent.

**6.** ➡️ **[Step R](#step-r--reset-between-every-experiment)**, and confirm the flag is off.

---

## The proof that matters — a call answered in the REPLICA Region

Traffic transition that moves traffic to a Region which cannot answer is not resilience. Verify it
explicitly, independently of any experiment.

**1. Shift traffic by hand.**

```bash
# Shift by hand, so this proof does not depend on an experiment having fired.
aws connect update-traffic-distribution --id $TDG_ID --region $SOURCE_REGION \
  --telephony-config "{\"Distributions\":[{\"Region\":\"$SOURCE_REGION\",\"Percentage\":0},{\"Region\":\"$REPLICA_REGION\",\"Percentage\":100}]}"
```

**2. Call, press `1`, key `12345` and press `#`, and complete the IVR.** You should hear
*"Connected in region us-west-2"* and then *"Welcome back, John Doe. Your account is in good
standing."*

**3. Prove which Region's compute actually ran.**

```bash
# the REPLICA Region's function MUST show the invocation (menu option 1 uses AccountLookup only;
# LexFulfillmentHandler runs only for options 3 and 4)
aws logs tail /aws/lambda/ConnectChaos-AccountLookup --region $REPLICA_REGION --since 5m

# and the SOURCE Region's must NOT
aws logs tail /aws/lambda/ConnectChaos-AccountLookup --region $SOURCE_REGION --since 5m
```

**Pass:** the replica Region logs the invocation and the source does not.

**Fail:** if the **source** logs it instead, the replica flow is still pointing at the source's
Lambda or Lex bot — the `$.AwsRegion` token or Lex GR replication is not working. Re-run
`make verify`, which checks all five flows in both Regions.

**4.** ➡️ **[Step R](#step-r--reset-between-every-experiment).**

---

## Run order

| Order | Experiment | Trigger | Wait before calling | Digit | Stay on the line |
|:-:|---|---|:-:|:-:|:-:|
| 1 | DynamoDB unreachable | `start-experiment $EXP2` | none | `2` | no |
| 2 | Flow failure → no-agent queue | set `chaos_flag#<region>=true` | none | `4` | **comfortably past the 60 s threshold** |
| 3 | Lambda failure | `start-experiment $EXP1` | **about a minute** | `1` | no |
| 4 | Lex code-hook latency | `start-experiment $EXP3` | **about a minute** | `3` | no |
| 5 | Replica-Region proof | manual traffic shift | none | `1` | no |

Experiment 2 first because it has no arming delay, which makes it the simplest way to verify the
whole traffic transition chain. **Step R after every one.**

> **Always use the SAME digit for the recovery call.** After traffic transition, dial again and press the
> digit for the experiment you just ran — not a different one. The claim being proven is that
> *this* flow, which just failed in the source Region, now succeeds in the replica Region.
> Pressing a different digit exercises a different flow and proves something weaker. There is no
> technical difference; the distinction is what the test demonstrates.
>
> | Experiment | Digit | Expected on the recovery call |
> |:-:|:-:|---|
> | 1 | `1` | *"Welcome back, John Doe. Your account is in good standing."* |
> | 2 | `2` | *"Your call has been recorded for quality purposes"* |
> | 3 | `3` | Lex's *"Welcome back, John Doe…"*, then *"I found your information. Thank you for calling."* |
> | 4 | `4` | Lex's *"Welcome back, John Doe…"*, then *"I found your information. Thank you for calling."* (flag off) |
>
> Experiments 3 and 4 end the call after that closing line. The sample has no agents, so ending
> there is intentional.
>
> Every recovery call opens with *"Connected in region &lt;replica&gt;"*. That announcement is the
> proof of which Region served it, and it needs no log inspection.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No audio at all when you dial | The number is not associated with `ConnectChaos-Menu` | `make post-deploy`; `make verify` reports the association (`list-flow-associations`) |
| Exp 1 or 3 had no effect; the call just succeeded | You called before the fault armed | Wait ~60 s after `start-experiment`, then call |
| The experiment stops straight after `start-experiment` | Its stop-condition alarm is in `ALARM` | Let `make reset` finish and exit `0` first |
| Exp 2 alarm flat but Lambda `Errors` rising | The flow did not take its Error branch | A **real** call is required; synthetic metrics cannot exercise a flow branch |
| Exp 3 plays the "taking too long" line straight away | Lex did not recognise your phrase, or got no answer in time. The flow plays that line for any problem in the Lex block | Call again: say "I want to look up my account" clearly and key the digits within 4 seconds |
| Exp 4 plays the hold prompt but the flag log shows no flag read | The same Lex problem sends the caller to the queue even with the flag off | Check the `LexFulfillmentHandler` log; call again with a clear phrase |
| Exp 4 metric shows a small number | Hung up before 60 s of *queue wait* accrued | Count from the hold prompt and stay on past the 60 s threshold |
| Alarm stuck `INSUFFICIENT_DATA` | No datapoints match its dimension tuple | `aws cloudwatch list-metrics --namespace <ns> --metric-name <name>` and compare with the alarm |
| Traffic never shifts although the alarm fired | Still inside the `RegionSwitchDelaySeconds` dwell | Wait the dwell out (default 120 s), then re-check |
| `set-alarm-state` does not trigger traffic transition | The forced state expires inside the dwell | Redeploy with `REGION_SWITCH_DELAY_SECONDS=0` to test the mechanism alone |
| Traffic shifts again right after a reset | A handler was mid-dwell when you reset | Wait the dwell out, then reset again |
| Replica Region answers nothing | Replica stack missing, or its Lex **alias** replica is not `Available` | `make verify` |
| The source logs a call after traffic transition | The flow still points at the source's Lambda or Lex | `$.AwsRegion` / Lex GR — `make verify` |
| The second experiment proves nothing | Traffic still at 0% source | Step R |
| A first deploy ends in `ROLLBACK_COMPLETE` | The first create failed and rolled back | Read the cause with `aws cloudformation describe-stack-events --stack-name $STACK --region <REGION>`, then delete the stack before deploying again |
| The stack ends in `ROLLBACK_FAILED` | Rollback could not delete a DynamoDB global table: DynamoDB refuses to remove a replica that was added within the last 24 hours | `aws dynamodb update-table --table-name <TABLE> --region <SOURCE_REGION> --replica-updates 'Delete={RegionName=<REPLICA_REGION>}'`, wait for it to finish, then delete the stack again |
| `DELETE_FAILED` on cleanup | FIS config bucket not empty | Empty `ccfis-…` first — see [README → Cleanup](README.md#cleanup) |

Before changing an experiment's metric, re-read the reasoning in
[README.md](README.md#the-four-experiments). Several obvious-looking "improvements" — alarming
Exp 3 on `ContactFlowErrors`, sharing one chaos flag across Regions — change what the experiment
measures; read the reasoning there first.
