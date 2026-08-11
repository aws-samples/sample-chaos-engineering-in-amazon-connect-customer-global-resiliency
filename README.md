# Amazon Connect Chaos Engineering with FIS and ACGR Failover

Inject controlled faults into a live Amazon Connect contact centre with **AWS Fault Injection
Service (FIS)**, watch CloudWatch attribute the failure to the component that broke, and verify
that **Amazon Connect Global Resiliency (ACGR)** shifts telephony traffic to the paired Region —
where the call is still answered.

> **Requires AWS Enterprise Support.** ACGR is onboarded through your AWS account team. This
> sample assumes you already have an ACGR-paired Connect instance and a Traffic Distribution
> Group with a **ported** phone number attached.

> ### ⚠️ Non-production sample — deploy into a dedicated AWS account
>
> The FIS execution role can create, modify, delete and re-associate network ACLs on **any VPC in
> the account you deploy into**, not just the one this stack creates. FIS builds the cloned ACL at
> run time, so no ARN can be scoped in advance. A mis-targeted experiment can sever connectivity
> for unrelated workloads in the same account — the blast radius is the account, so the account is
> the isolation boundary.
>
> Every FIS experiment here carries a bounded duration and a stop condition on its own alarm, so
> disruption is time-limited and self-reverting. That limits duration, not scope.
>
> **This sample is not cleared for production.** Several security findings are accepted
> specifically because this is a demonstration in a throwaway account — no real customer data, an
> operator present for every experiment, and faults that expire on their own. None of those
> assumptions hold in production.
>
> Before any production use, work through
> [Security posture and production hardening](#security-posture-and-production-hardening) below.

**This file explains what the sample is, how it works, and how to install it.**
**[RUNBOOK.md](RUNBOOK.md) is the procedure for running the experiments** — every test command,
what to press on the keypad, what you should hear, and what to check afterwards. Install from
here, test from there.

---

## Contents

- [Why chaos-test a contact centre](#why-chaos-test-a-contact-centre)
- [What FIS contributes](#what-fis-contributes)
- [Architecture](#architecture)
- [The four experiments](#the-four-experiments)
- [Why you must wait before calling](#why-you-must-wait-before-calling-experiments-1-and-3)
- [Detection and failover](#detection-and-failover)
- [Why failover is deliberately delayed](#why-failover-is-deliberately-delayed)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Parameters](#parameters)
- [Resources deployed](#resources-deployed)
- [Monitoring](#monitoring)
- [Synthetic traffic generator](#synthetic-traffic-generator-optional)
- [Cost](#cost)
- [Security posture and production hardening](#security-posture-and-production-hardening)
- [Cleanup](#cleanup)
- [Key design decisions](#key-design-decisions)
- [Repository layout and tooling](#repository-layout-and-tooling)

---

## Why chaos-test a contact centre

A contact centre fails differently from a web service. There is no retry button, no page
refresh, and no error page to read. A caller gets silence, a wrong prompt, or a hold that never
ends — and every second of it is a person waiting on a phone line. Worse, the failures that hurt
most are rarely Amazon Connect itself. They are the things Connect calls out to: a Lambda that
throws, a database it cannot reach, a code hook that answers too slowly to matter, a queue with
nobody in it.

Those dependencies are exactly what a runbook review cannot test. You can read the architecture
diagram and still not know:

- whether a broken account-lookup Lambda produces a **metric that names the Lambda**, or just a
  generic "flow error" indistinguishable from four other causes;
- whether your alarm thresholds can actually fire on the volume a single test call produces;
- whether failing over to the paired Region **helps**, or whether the paired Region is quietly
  reaching back into the Region you just declared unhealthy;
- whether the paired Region can answer a call at all.

Every one of those questions was answered "no" at some point while building this sample, on
infrastructure that reported entirely healthy. [FIXES.md](FIXES.md) records all of them. The
short version: of the defects that mattered most, **not one was caught by `cfn-lint`, by
CloudFormation succeeding, or by alarms reporting `OK`.** Each needed a real fault and a real
phone call.

That is the argument for chaos engineering here. You are not testing whether AWS works. You are
testing whether **your detection and your failover work**, and the only way to know is to break
something on purpose while someone is on the line.

---

## What FIS contributes

FIS is what makes the fault **controlled, repeatable, and safe to run against a live instance**.
Without it you would be reduced to breaking things by hand — revoking an IAM permission,
commenting out code, dropping a table — which is slow, hard to undo, and impossible to run the
same way twice.

FIS gives four things this sample depends on:

| What FIS provides | Why it matters here |
|---|---|
| **Managed fault actions** | `aws:lambda:invocation-error` and `aws:lambda:invocation-add-delay` break a Lambda *from outside*, with no code change. The function you test is byte-identical to the one in production. |
| **A defined blast radius** | Targets are explicit ARNs. Experiment 1 errors one named function; it cannot spread to the other three. |
| **Automatic expiry** | Each experiment carries a duration (`PT5M`). If you walk away, the fault removes itself. |
| **Stop conditions** | Every experiment is bound to **its own** detection alarm. The moment the alarm fires, FIS halts the experiment — the fault stops as soon as it has proven the point. |

Two consequences of the stop-condition design are worth knowing up front:

- **Failover still happens** when FIS stops the experiment. The alarm, EventBridge and the
  traffic shift are independent of FIS; halting the fault does not undo the detection.
- **FIS refuses to start an experiment whose stop-condition alarm is not already `OK`.** It fails
  within about ten seconds with an explicit message. This is why the runbook's reset step waits
  for alarms to clear before you start the next experiment.

Experiments 1, 2 and 3 are FIS experiments. **Experiment 4 is not** — it is a data flag, because
the fault being modelled is a bad configuration value rather than an infrastructure failure.

---

## Architecture

![Architecture](docs/architecture.png)

> Diagram source is `docs/architecture.dac.yaml`. Regenerate with
> `awsdac docs/architecture.dac.yaml --output docs/architecture.png` (delete the PNG first —
> `awsdac` prompts before overwriting).

```
                        ┌──────────────────────────────────┐
                        │  Traffic Distribution Group      │
                        │           (ACGR)                 │
                        │  normal:   IAD 100% | PDX 0%     │
                        │  failover: IAD 0%   | PDX 100%   │
                        └───────────────┬──────────────────┘
                                        │
             ┌──────────────────────────┴──────────────────────────┐
       PRIMARY (us-east-1)                              PAIRED (us-west-2)
       ┌──────────────────────┐                    ┌──────────────────────┐
       │ Connect instance     │                    │ Connect instance     │
       │  (same instance id) ─┼── ACGR replicates ►│  (same instance id)  │
       │ 5 contact flows ─────┼───────────────────►│ 5 contact flows      │
       │        │             │                    │        │             │
       │        ▼             │                    │        ▼             │
       │ Lex V2 bot ──────────┼──── Lex GR ───────►│ Lex V2 bot (same id) │
       │        │             │                    │        │             │
       │        ▼             │                    │        ▼             │
       │ AccountLookup        │                    │ AccountLookup        │
       │ CallLogger           │  same names, per   │ CallLogger           │
       │ LexFulfillmentHandler│  Region deploys    │ LexFulfillmentHandler│
       │        │             │                    │        │             │
       │        ▼             │                    │        ▼             │
       │ DynamoDB ────────────┼── global tables ──►│ DynamoDB (replica)   │
       │ Overflow queue ──────┼──── ACGR ─────────►│ Overflow queue       │
       └──────────────────────┘                    └──────────────────────┘
                    │                                        │
              4 alarms → composite → EventBridge → TrafficShiftHandler
                                        │
                                        ▼
                         UpdateTrafficDistribution (ACGR)
```

**One entry point.** The phone number stays associated with **`ConnectChaos-Menu`** for all four
experiments; you never re-point it. Every call announces the serving Region, then offers a DTMF
menu. The digit you press selects which experiment's flow runs.

Two details in that diagram carry more weight than they look like they do:

- **The Lambda and Lex ARNs inside the flows use the ACGR runtime token `$.AwsRegion`.** ACGR
  replicates flow content *verbatim*, so a hardcoded Region makes the paired Region invoke the
  **primary's** Lambda and Lex bot. Traffic moves, metrics look correct, and the "healthy" Region
  is still entirely dependent on the failed one. This is a silent defect, and it was real — see
  [FIXES.md](FIXES.md) Fixes 8 and 16.
- **Both Regions run their own `TrafficShiftHandler`, and each shifts traffic away from itself.**
  There is no central controller to become a single point of failure. The handler reads the
  current distribution first and no-ops if traffic has already moved, so both Regions alarming at
  once cannot fight each other.

---

## The four experiments

| # | DTMF | Component broken | How it is broken | Attributing metric | Outcome you should observe |
|:-:|:----:|---|---|---|---|
| **1** | `1` | `ConnectChaos-AccountLookup` Lambda | FIS `aws:lambda:invocation-error` (`preventExecution=true`) | `ContactFlowErrors` on `ConnectChaos-Exp1-Lambda` (AWS/Connect) | Flow takes its `InvokeLambdaFunction` Error branch; alarm fires; traffic shifts |
| **2** | `2` | DynamoDB reachability | FIS `aws:network:disrupt-connectivity` (`scope=dynamodb`) on both Lambda subnets | `ContactFlowErrors` on `ConnectChaos-Exp2-DynamoDB` (AWS/Connect) | The audit write fails; flow takes its Error branch; alarm fires; traffic shifts |
| **3** | `3` | `LexFulfillmentHandler` code hook | FIS `aws:lambda:invocation-add-delay` (~31 s startup delay) | `Duration` Maximum (AWS/Lambda) | Code hook runs slow but returns cleanly; `Duration` ≈ 31,000 ms with `Errors` = 0 |
| **4** | `4` | Contact flow configuration | A DynamoDB chaos flag, **not** FIS | `LongestQueueWaitTime` on `ConnectChaos-Overflow` (AWS/Connect) | Contact is parked on a queue no agent can receive; queue wait climbs past 60 s |

### How each experiment stays distinguishable

Amazon Connect publishes exactly **one** metric meaning "a flow failed" — `ContactFlowErrors` —
dimensioned by `ContactFlowName`. Each experiment therefore gets **its own contact flow**, which
turns that single metric into independent per-experiment signals with no metric math and no
overlap. Three of the four alarms are Connect-native as a result.

Three supporting decisions make the attribution hold:

- **The call logger appears in exactly one flow.** If every flow invoked it, an Experiment 2
  fault would raise `ContactFlowErrors` on all four `ContactFlowName` dimensions at once and
  destroy the attribution this design exists to create.
- **Every flow announces `"Connected in region $.AwsRegion"`** before anything else, so which
  Region served the call is *audible* rather than something you reconstruct from two log groups
  afterwards. That missing signal is exactly how Fix 16 stayed hidden.
- **Every failure path has its own prompt**, naming the experiment, so the caller experience
  identifies the fault. All four previously ended on one shared "We are experiencing
  difficulties", which made a wrong-experiment test impossible to spot.

**Input is DTMF, not speech, deliberately.** During testing ASR turned "one two three four five"
into `120345` and once into `0` — indistinguishable from a broken lookup.

> **On cascades — read this before you judge a result.** Every fault here ultimately flows
> through a Lambda, so `AWS/Lambda Errors` also rises during Experiments 1, 2 and 3. That is
> inherent to a synchronous IVR call path, not a defect. The composite alarm ORs all four
> component alarms, so failover happens regardless. When demonstrating a *specific* experiment,
> watch **that experiment's own alarm**, never the composite.

### Experiment 1 — the account-lookup Lambda fails

`ConnectChaos-Exp1-Lambda` collects a 5-digit account number as DTMF, then invokes
`ConnectChaos-AccountLookup` **directly**. FIS marks that invocation failed without running the
code, so the flow takes the block's Error branch.

- **Caller hears:** *"The account lookup service is unavailable. This is experiment one."*
- **Alarm:** `ConnectChaos-Exp1-Lambda-{region}`, threshold `ContactFlowErrorsThreshold`
  (default `0`, so a single flow error trips it)
- A wrong or missing account number does **not** error. The Lambda returns `NOT_FOUND` or
  `INVALID_INPUT` and the flow branches on it with a `Compare` block, so a mistyped number can
  never masquerade as an injected fault.
- **Needs ~55 s to arm** — see [below](#why-you-must-wait-before-calling-experiments-1-and-3).

### Experiment 2 — DynamoDB is unreachable

FIS blocks both Lambda subnets from the DynamoDB endpoint at the network ACL.
`ConnectChaos-Exp2-DynamoDB` invokes `ConnectChaos-CallLogger` directly — a genuine audit write —
so the DynamoDB failure takes the flow's Error branch.

- **Caller hears:** *"We could not record your call. This is experiment two."*
- **Alarm:** `ConnectChaos-Exp2-DynamoDB-{region}`, threshold `ContactFlowErrorsThreshold`
- **No arming delay and no expiry within the experiment.** It is network-level, so the DynamoDB
  path is severed for the whole duration. **This is the most reliable experiment to demonstrate
  with a live call, and the best one to run first.**

### Experiment 3 — the Lex code hook becomes too slow to be useful

FIS injects a ~31 s startup delay while the function's own timeout is 40 s, so the code hook runs
slow but still returns cleanly. It is observed as latency, not as an error.

- **Caller hears:** *"The lookup service is taking too long. This is experiment three."*
- **Alarm:** `ConnectChaos-Exp3-Latency-{region}`, threshold `LexCodeHookLatencyThresholdMs`
  (default 7000 ms)
- **The only experiment not alarmed on a Connect metric, deliberately.** It is a *latency* fault:
  the function succeeds, so there may be no flow error to count. This was measured, not assumed —
  the validated run produced `Duration` 31,232 ms, `Errors` 0.0, and **no `ContactFlowErrors`
  datapoint at all.** Had this experiment alarmed on `ContactFlowErrors` it would never have
  fired. A latency threshold is not merely the more honest measurement for a latency fault, it is
  the only one that works.
- **Why not `AWS/Lex RuntimeLambdaErrors`?** It is never emitted for this bot on Connect's real
  voice path — established by `list-metrics` over repeated real calls (FIXES.md Fix 7). Do not
  "restore" it.
- **Needs ~55 s to arm**, as with Experiment 1.

### Experiment 4 — a bad config value parks the caller on an unstaffed queue

A DynamoDB chaos flag makes the fulfillment Lambda return `Failed` to Lex.
`ConnectChaos-Exp4-Queue` routes the failure path to **`ConnectChaos-Overflow`** — a queue
referenced by **no routing profile**, so no agent can ever receive its contacts — and transfers
the contact there. It waits indefinitely and `LongestQueueWaitTime` climbs.

- **Caller hears:** *"All agents are currently busy. Please hold. This is experiment four."*
- **Alarm:** `ConnectChaos-Exp4-Queue-{region}`, threshold `QueueWaitSecondsThreshold`
  (default 60 s)
- **Not a FIS experiment.** You toggle a DynamoDB item. It does **not** expire on its own — you
  must turn it off.
- **Why not `MissedCalls`?** That metric requires a call to be *offered to an agent* and go
  unanswered for 20 s, which is not reproducible without a staffed agent deliberately not
  answering. An unstaffed queue removes the human from the test entirely.
- **The signal is accumulated queue wait, not a count**, so the caller has to stay on the line.
  The 60 s clock starts at the hold prompt, not when you dial. Exact timing is in the runbook.

**The flag is Region-scoped (`chaos_flag#<region>`) on purpose, and this is the most important
lesson in the sample.** The config table is a DynamoDB Global Table. A single shared key would
replicate the fault to the paired Region, and failover could never recover: the caller would land
in a Region reading the same broken row and queueing into the same unstaffed queue. Every
dashboard green, every alarm correct, traffic moved, customer still broken.

> **A dependency failure that lives in replicated data is not a regional failure, and no amount
> of traffic shifting will fix it.**

Multi-Region architectures routinely fail this way — a poisoned config row, a bad feature flag, a
corrupt cache entry, a schema migration. All replicate faithfully to the standby, which is the
one thing you did not want replicated. Do not "simplify" the flag back to a single shared key.
See [FIXES.md](FIXES.md) Fix 25.

---

## Why you must wait before calling (Experiments 1 and 3)

**Start the experiment, wait about a minute, then call.** Calling immediately is the single most
common way to conclude an experiment is broken — the invocation runs normally, you hear *"Welcome
back, John Doe"*, and nothing is wrong except the timing. It happened four times in a row during
this sample's own validation.

Experiments 1 and 3 apply their fault through the **AWS FIS Lambda extension**, a layer attached
to the target function. The extension does not receive a push notification. It polls S3 for the
fault configuration on its own schedule, and until that poll completes the function behaves
completely normally.

That polling has to happen *inside* a Lambda invocation, and this is where it gets
counter-intuitive: these handlers run in 57–290 ms. Before this was tuned, the polling thread
never got enough wall-clock time to finish a fetch, so **the fault only ever applied on a cold
start** — a warm invocation completed in 0.7 s with no fault, while a cold one took 32.9 s. Two
environment variables fix it by letting the extension block briefly and poll more often:

```yaml
AWS_FIS_POLL_MAX_WAIT_MILLISECONDS: '3000'
AWS_FIS_SLOW_POLL_INTERVAL_SECONDS: '20'   # 20 is the minimum the extension accepts;
                                           # 10 silently falls back to 60
```

Measured result on this sample:

```
start-experiment  ->  fault actually effective : ~55 s
experiment duration                            : PT5M  (FISExperimentDuration)
```

So the usable window **opens** at ~55 s and closes when the experiment ends, leaving roughly four
minutes to place your call. Full detail, including two other undocumented FIS behaviours found
alongside this, is in [FIXES.md](FIXES.md) Fix 24.

**Experiment 2 needs no wait** — it is network-level, applies immediately, and stays applied for
the whole experiment. **Experiment 4 needs no wait** — the flag is read on the next call.

---

## Detection and failover

```
any component alarm → composite alarm ALARM
  → EventBridge rule
    → TrafficShiftHandler
      → hold for FailoverDelaySeconds        (default 120 s)
        → re-check the triggering alarm is STILL in ALARM
          → UpdateTrafficDistribution:  this Region 0%  /  other Region 100%
```

New inbound calls then route to the paired Region. **Calls already in progress are not moved** —
ACGR shifts telephony traffic, it does not migrate live contacts.

**Recovery is deliberately manual.** Alarms returning to `OK` shift nothing back; the handler
ignores `OK` events by design, so an operator confirms the fault is genuinely resolved before
customers are routed back. The runbook's reset step does this.

## Why failover is deliberately delayed

`FailoverDelaySeconds` (default **120**, maximum 600) holds the traffic shift after the alarm
fires. Setting it to `0` shifts immediately.

The delay exists because **failover that is too fast is impossible to demonstrate.** Without it,
the sequence from alarm to traffic shift completed in about two seconds. By the time you had
finished reading the alarm state in the console, traffic had already moved — so nobody ever
experienced the impaired Region, and the thing the sample exists to show happened invisibly. The
dwell gives you a window to place a call *into the broken Region*, hear the failure prompt for
yourself, and only then watch traffic move.

It also reflects something real. Shifting an entire contact centre's telephony is not free: calls
in progress stay where they are, agents in the paired Region pick up the load, and a transient
blip is not worth that disruption. A short dwell is a crude but genuine form of flap damping.

One behaviour the dwell introduced, and how it is handled: a sleeping handler was **silently
undoing a reset.** You would reset traffic to 100/0, and a handler that had started its dwell
before the reset would wake up and shift traffic away again. The handler now **re-reads the
triggering alarm after the dwell and abandons the failover if it is no longer in `ALARM`.** Two
consequences:

- **`aws cloudwatch set-alarm-state` can no longer test failover while a dwell is configured.** A
  forced alarm state is a temporary override that CloudWatch reverts within ~50 s, so it expires
  inside the 120 s dwell and the handler correctly declines to act. To test the mechanism alone,
  redeploy with `FAILOVER_DELAY_SECONDS=0`.
- **If you reset while a handler is dwelling and the alarm is genuinely still in `ALARM`, the
  shift still lands** after the dwell. Wait out the dwell before resetting, or reset twice about
  130 s apart.

See [FIXES.md](FIXES.md) Fixes 22 and 23.

---

## Prerequisites

1. **AWS Enterprise Support** (or AWS Unified Operations) — required to onboard ACGR.
2. **ACGR-paired Connect instance**, SAML 2.0 enabled. The replica has the **same instance ID**
   in both Regions; that is how you recognise an ACGR pair.
3. **Traffic Distribution Group** with a **ported** phone number attached. Claimed-only numbers
   are not eligible for ACGR.
4. **A supported Region pair:** `us-east-1`↔`us-west-2`, `eu-west-2`↔`eu-central-1`, or
   `ap-northeast-1`→`ap-northeast-3`. Enforced by the template's `Rules` block.
5. **Tooling:** AWS CLI v2 with credentials that can create the resources below, `python3`, and
   `cfn-lint` if you intend to run `make lint`.

**You do NOT need to pre-create** a VPC, subnets, a security group, an S3 bucket, or the FIS
extension layer ARN. All are created or auto-resolved. Lambda functions needing identical names
across Regions and flows avoiding hardcoded Regions are both handled by the template.

The runbook's pre-flight step gives you the exact commands to confirm items 2, 3 and 4 before you
deploy anything.

---

## Installation

The **only deployable artifact is `cfn/main-template.yaml`.** It deploys **twice** — once per
Region — and the `IsPrimaryRegion` condition controls what goes where. The global tables, all
five contact flows, the overflow queue and its hours of operation are created only in the primary
Region and replicated by ACGR and DynamoDB.

### Step 1 — set your environment

You supply **two** values; the rest are derived. Both are UUIDs:

| Variable | What it is | Example (not a real value) | How to find yours |
|---|---|---|---|
| `INSTANCE_ID` | Connect instance ID. An ACGR replica shares the **same** ID in both Regions, which is how you recognise a pair | `EXAMPLE1-2222-3333-4444-555555555555` | `aws connect list-instances --region us-east-1` |
| `TDG_ID` | The Traffic Distribution Group that failover updates | `EXAMPLE2-6666-7777-8888-999999999999` | `aws connect list-traffic-distribution-groups --region us-east-1` |

```bash
export STACK=connect-chaos-sample
export PRIMARY_REGION=us-east-1
export PAIRED_REGION=us-west-2
export ACCT=$(aws sts get-caller-identity --query Account --output text)

# REPLACE both — the values below only show the expected shape.
export INSTANCE_ID=EXAMPLE1-2222-3333-4444-555555555555
export TDG_ID=EXAMPLE2-6666-7777-8888-999999999999

# An ACGR replica shares the SAME instance id, so the two ARNs differ only by Region.
export PRIMARY_INSTANCE_ARN=arn:aws:connect:$PRIMARY_REGION:$ACCT:instance/$INSTANCE_ID
export PAIRED_INSTANCE_ARN=arn:aws:connect:$PAIRED_REGION:$ACCT:instance/$INSTANCE_ID
```

`EXAMPLE…` is not valid hexadecimal, so a UUID still containing it has not been replaced —
[RUNBOOK Step 0](RUNBOOK.md#step-0--shell-variables) has a guard that fails on exactly that.

### Step 2 — deploy both Regions

```bash
# Creates the code bucket, zips and uploads the Lambdas, deploys the primary Region,
# reads the Lex GR bot/alias ids from its outputs, then deploys the paired Region.
make deploy-pair STACK=$STACK \
  PRIMARY_REGION=$PRIMARY_REGION PAIRED_REGION=$PAIRED_REGION \
  PRIMARY_INSTANCE_ARN=$PRIMARY_INSTANCE_ARN \
  PAIRED_INSTANCE_ARN=$PAIRED_INSTANCE_ARN \
  TDG_ID=$TDG_ID
```

`deploy-pair` creates the code bucket, zips and uploads the Lambdas, deploys the primary Region,
reads the Lex GR bot and alias IDs from its outputs, then deploys the paired Region with those
IDs.

**Both stacks must be left standing.** The paired Region cannot answer a call without its own
Lambdas, and that is the single most important thing this sample proves.

<details>
<summary>Deploying one Region at a time</summary>

```bash
# Deploy ONE Region. Run it again for the paired Region, adding the replicated Lex ids.
make deploy STACK=$STACK REGION=$PRIMARY_REGION \
  CONNECT_INSTANCE_ARN=$PRIMARY_INSTANCE_ARN \
  CONNECT_INSTANCE_ID=$INSTANCE_ID TDG_ID=$TDG_ID
```

Then read `LexBotId` and `LexBotAliasId` from the primary stack outputs and pass them to the
paired Region as `REPLICATED_LEX_BOT_ID` and `REPLICATED_LEX_BOT_ALIAS_ID`.

**Tokyo/Osaka:** Lex GR does not support `ap-northeast-1`↔`ap-northeast-3`. Deploy both with
`ENABLE_LEX_GR=false`, omit the replicated IDs, then run `./scripts/wire-paired-flow.sh` to point
the paired flow at its own bot.
</details>

### Step 3 — the three things CloudFormation cannot do

```bash
# The three steps CloudFormation cannot do: seed the tables, associate the phone number
# with ConnectChaos-Menu, and reset traffic to 100% primary. Idempotent, safe to re-run.
make post-deploy STACK=$STACK \
  PRIMARY_REGION=$PRIMARY_REGION PAIRED_REGION=$PAIRED_REGION \
  INSTANCE_ID=$INSTANCE_ID TDG_ID=$TDG_ID
```

`post-deploy` is idempotent and safe to re-run. It performs all three:

| Step | Why CloudFormation cannot do it |
|---|---|
| Seed the DynamoDB tables (customer `12345`, chaos flag off in **both** Regions) | Data, not infrastructure |
| **Associate the phone number with `ConnectChaos-Menu`** | The number belongs to the TDG, not the stack, and no CloudFormation resource models the number → flow link |
| Reset traffic to 100% primary / 0% paired | Live routing state |

> **⚠️ Skipping the association is a silent failure.** Every resource reports `CREATE_COMPLETE`,
> every alarm reports `OK`, and calls simply never enter the flow with nothing indicating why.
> **No AWS API exposes the number → flow link**, so `make verify` cannot check it either — the
> baseline call in the runbook is the only real proof.

### Step 4 — verify before spending any phone calls

```bash
# 29 checks across both Regions. Must exit 0 before you place a single test call.
make verify STACK=$STACK PRIMARY_REGION=$PRIMARY_REGION \
  PAIRED_REGION=$PAIRED_REGION TDG_ID=$TDG_ID
```

29 checks across both Regions: stack status, whether the paired Region can actually serve a call,
Lex replication, the `$.AwsRegion` tokens in all five flows, seed data, the traffic split, the
alarms, and a smoke invoke of the traffic-shift handler. It must exit `0` before you test.

> **⚠️ Lex GR needs the ALIAS replica, not just the bot replica.** The flow resolves
> `arn:aws:lex:$.AwsRegion:…:bot-alias/<botId>/<aliasId>` to the **alias**, so the paired Region
> cannot serve a call until the *alias* replica reports `Available` (~90 s, versus ~30 s for the
> bot). The `Replication` property on `AWS::Lex::Bot` is also not sufficient evidence on its own:
> on one deployment the replica it created was present after deploy and had vanished 40 minutes
> later with no CloudTrail record either way (FIXES.md Fix 14). `make verify` checks this.

**Now go to [RUNBOOK.md](RUNBOOK.md)** for the baseline call and the four experiments.

---

## Parameters

| Parameter | Required | Default | Notes |
|-----------|:---:|---|---|
| `ConnectInstanceArn` | ✓ | — | ACGR instance ARN for **this** Region |
| `ConnectInstanceId` | ✓ | — | Instance UUID for **this** Region |
| `TrafficDistributionGroupId` | ✓ | — | The TDG that failover updates |
| `LambdaCodeBucket` | ✓ | — | Bucket holding the Lambda zips; `make` creates and fills it |
| `CreateVpc` | | `true` | Create VPC, subnets and free DynamoDB/S3 gateway endpoints |
| `VpcCidr` / `SubnetACidr` / `SubnetBCidr` | | `10.20.0.0/16`, `.1.0/24`, `.2.0/24` | Only when `CreateVpc=true` |
| `LambdaSubnetIdA` / `IdB` / `LambdaSecurityGroupId` | | `''` | **Only when `CreateVpc=false`.** A Rule enforces all three |
| `FISExtensionLayerArn` | | *SSM path* | Auto-resolves per Region. Override only to pin a version |
| `PrimaryRegion` / `PairedRegion` | | `us-east-1` / `us-west-2` | Must be an ACGR pair |
| `EnableAutoFailover` | | `false` | Deploy EventBridge and `TrafficShiftHandler` |
| `EnableLexGlobalResiliency` | | `true` | Replicate the bot via Lex GR (IAD↔PDX, LHR↔FRA) |
| `ReplicatedLexBotId` / `…AliasId` | | `''` | Paired Region only; from the primary stack outputs |
| `EnableTrafficGenerator` | | `false` | Synthetic metrics — drive alarms without phone calls |
| `DashboardType` | | `regional` | `regional` or `unified` |
| `PairedConnectInstanceId` | | `''` | Primary only, when `DashboardType=unified` |
| `ContactFlowErrorsThreshold` | | `0` | Exps 1 and 2. `0` means one flow error trips the alarm. Raise for production monitoring |
| `LexCodeHookLatencyThresholdMs` | | `7000` | Exp 3 |
| `QueueWaitSecondsThreshold` | | `60` | Exp 4 |
| `FailoverDelaySeconds` | | `120` | Hold the failover this long after the alarm. Max 600. `0` shifts immediately |
| `FISExperimentDuration` | | `PT5M` | ISO-8601 |

---

## Resources deployed

| Resource | Primary | Paired | How |
|----------|:---:|:---:|---|
| VPC, 2 private subnets, route table, SG | ✓ | ✓ | Created when `CreateVpc=true` (default) |
| Gateway endpoints — DynamoDB + S3 | ✓ | ✓ | Free. **S3 is required by the FIS extension** |
| Contact flows ×5 — `Menu` + one per experiment | ✓ | ✓ | Created in primary, ACGR replicates |
| Queue `ConnectChaos-Overflow` + 24×7 hours | ✓ | ✓ | Created in primary, ACGR replicates |
| Lex V2 bot + version + alias | ✓ | ✓ | Primary creates; Lex GR replicates (same IDs) |
| Connect ↔ Lex `IntegrationAssociation` | ✓ | ✓ | Per Region, against its local bot |
| `LexFulfillmentHandler` (40 s timeout, VPC, FIS layer) | ✓ | ✓ | Same name in both Regions — an ACGR requirement |
| `ConnectChaos-CallLogger` (VPC) | ✓ | ✓ | Invoked directly by the Exp 2 flow |
| `ConnectChaos-AccountLookup` (VPC, FIS layer) | ✓ | ✓ | Invoked directly by the Exp 1 flow |
| `ConnectChaos-TrafficShiftHandler` (no VPC) | ✓ | ✓ | Requires `EnableAutoFailover=true` |
| DynamoDB global tables ×3 | ✓ | ✓ | Created in primary, auto-replicated |
| S3 — FIS config bucket (`ccfis-…`) | ✓ | ✓ | Per Region |
| FIS experiment templates ×3 | ✓ | ✓ | Per Region. Exp 4 is not a FIS experiment |
| CloudWatch alarms ×4 + composite | ✓ | ✓ | Per Region |
| Dashboard | ✓ | ✓ | `regional` or `unified` |

**No NAT gateway and no internet gateway are created.** Only DynamoDB and S3 reachability is
needed and gateway endpoints for both are free, so the VPC adds **$0**. S3 is not optional: the
FIS extension reads its fault config from S3, and without an S3 route Experiments 1 and 3
**silently** apply no fault at all. This is the easiest thing to get wrong when bringing your own
VPC with `CreateVpc=false`.

---

## Monitoring

Dashboard **`ConnectChaos-{region}`**, one panel per experiment:

| Panel | Metric | Statistic |
|---|---|---|
| Exp 1 | `ContactFlowErrors` on `ConnectChaos-Exp1-Lambda` | Sum |
| Exp 2 | `ContactFlowErrors` on `ConnectChaos-Exp2-DynamoDB` | Sum |
| Exp 3 | `LexFulfillmentHandler` `Duration` | Maximum (ms) |
| Exp 4 | `LongestQueueWaitTime` on `ConnectChaos-Overflow` | Maximum (sec) |

`ContactFlowErrors` for the Exp 3 flow is also on the dashboard as an **observation-only** panel.
It should not become the alarm — see [Experiment 3](#experiment-3--the-lex-code-hook-becomes-too-slow-to-be-useful).

**There is no SNS topic.** One used to be wired to the composite alarm, but nothing was ever
subscribed to it, so it published into the void on every experiment while adding two security
findings to justify. Failover never depended on it — that path is composite alarm → EventBridge →
`TrafficShiftHandler`.

To get notified, create a topic, subscribe to it, then add `AlarmActions` and `OKActions` to
`CompositeAlarm`. If you do, encrypt it with a **customer-managed** KMS key whose policy grants
`cloudwatch.amazonaws.com` `kms:Decrypt` and `kms:GenerateDataKey*`. The default `alias/aws/sns`
key silently blocks CloudWatch from publishing and its policy cannot be edited.

---

## Synthetic traffic generator (optional)

Set `EnableTrafficGenerator=true` to drive every alarm **without placing phone calls**. Deploys
`ConnectChaos-TrafficGenerator-{region}` plus a **disabled** EventBridge schedule.

```bash
GEN=ConnectChaos-TrafficGenerator-$PRIMARY_REGION

aws lambda invoke --function-name $GEN --region $PRIMARY_REGION \
  --payload '{"mode":"healthy","count":10}' /dev/stdout

# faults: lambda | dynamodb | lex | flow | all
aws lambda invoke --function-name $GEN --region $PRIMARY_REGION \
  --payload '{"mode":"faulty","fault_type":"dynamodb","count":10}' /dev/stdout
```

The generator emits metrics with the **same namespaces and dimensions** as real traffic, so
CloudWatch cannot distinguish them and the full alarm → failover chain fires.

> **⚠️ Two limits.** Synthetic points are indistinguishable from real ones on your dashboard —
> disable the schedule when finished. And `fault_type=lex` emits `RuntimeLambdaErrors` under
> `RecognizeUtterance`, which is *not* what a real Connect voice call produces; it exercises the
> metric, but Experiment 3's real-call signal is Lambda `Duration`.
>
> **The generator cannot substitute for a real call on Experiments 1, 2 and 4.**
> `ContactFlowErrors` and `LongestQueueWaitTime` only increment for real contacts, and no
> synthetic metric can exercise a contact flow branch.

---

## Cost

| Service | Driver |
|---------|--------|
| Amazon Connect | Per-minute telephony + daily active use |
| AWS FIS | ~$0.10 per action-minute |
| Lambda | Invocations + duration (negligible) |
| DynamoDB | On-demand read/write (negligible) |
| CloudWatch | 5 alarms ≈ $0.50/mo + dashboard $3/mo |
| Lex V2 | Per request during testing |
| S3 | FIS config + template staging (< $0.01/mo) |
| **VPC** | **$0** — gateway endpoints are free, no NAT gateway is created |

**All four experiments once:** under $5, excluding telephony. **Left standing:** roughly
$10–15/month per Region, mostly dashboards and alarms.

---

## Security posture and production hardening

### Controls in place

- Every FIS experiment has a **stop condition** bound to its own alarm and a bounded duration
  (`FISExperimentDuration`, default `PT5M`), so any fault is time-limited and self-reverting.
- The created VPC has **no internet gateway and no NAT** — only free gateway endpoints to
  DynamoDB and S3, so Lambda egress has no route off the VPC.
- The FIS config bucket is encrypted at rest and blocks all four categories of public access;
  only the FIS and Lambda execution roles can reach it.
- No credentials, keys or deployment-specific identifiers are committed. `make lint` runs
  `scripts/scan-secrets.py`, which fails the build on account IDs, phone numbers, instance and
  TDG UUIDs, VPC and subnet IDs, access keys and private keys.
- Experiment 4's chaos flag does **not** expire. `make reset` disarms it in both Regions and
  `make verify` fails if the paired Region is still armed.

### Accepted for this sample — and what each one assumes

Static analysis findings are suppressed in the template with a written reason on each resource
(`Metadata.cfn_nag.rules_to_suppress` and `Metadata.checkov.skip`). Each was justified against the
threat model of **a sample in a dedicated non-production account**: regenerable demo data, no real
customers, an operator present for every run, and bounded self-reverting faults. Those assumptions
are what make the reasoning valid, and **none of them hold in production**.

| Accepted | The assumption it rests on |
|---|---|
| FIS role holds `ec2:*NetworkAcl*` on `Resource: '*'` | The account contains nothing a mis-targeted experiment must not reach |
| Security group has no explicit egress rule | There is no NAT and no internet gateway, so egress has no route. Add either and the control disappears |
| No Dead Letter Queue on the failover path | An operator is watching each run, so a dropped event shows up immediately as "traffic did not shift" |
| No DynamoDB point-in-time recovery | The data is demo fixtures, recreated by `make post-deploy` in seconds |
| No reserved concurrency | Untested against real call volume; a cap would throttle and drop live calls |
| No VPC flow logs, S3 access logging or versioning | Forensics and auditability are not required for a demo |

### Hardening required before production

| # | Change | Priority | Re-test |
|:-:|---|---|---|
| 1 | Scope the FIS network policy to this stack's VPC, and gate the destructive NACL verbs on the `managedbyFIS=true` tag FIS applies to the ACL it clones | **Highest** | Experiment 2, live call |
| 2 | Add explicit `SecurityGroupEgress` limited to the DynamoDB and S3 gateway-endpoint prefix lists | High | Experiments 1–3, live call each |
| 3 | Add an SQS DLQ on the EventBridge rule target, plus an alarm on its depth | High | `make verify` |
| 4 | Enable DynamoDB PITR on all three tables | Medium | `make verify` |
| 5 | Enable VPC flow logs | Medium | `make verify` |
| 6 | Add S3 access logging and versioning — **and update cleanup to delete object versions**, or stack deletion will fail | Medium | Cleanup dry run |
| 7 | Re-evaluate reserved concurrency against real call volume | Low | Load test |

Items 3 and 4 are the cheap wins: additive, no existing code path touched, verifiable without a
phone call. Items 1 and 2 change the network path the faults depend on, so getting either wrong
makes the experiments silently stop working while still looking healthy — each needs a real call to
confirm.

Beyond this list, production use needs a security review against your own organisation's controls,
and chaos testing against a production contact centre additionally needs blast-radius planning, a
rollback plan, and agreement from whoever owns the customer-facing service.

---

## Cleanup

> **Empty the FIS config buckets first.** CloudFormation cannot delete a non-empty bucket and the
> stack will hit `DELETE_FAILED`.

```bash
for R in $PAIRED_REGION $PRIMARY_REGION; do
  aws s3 rm "s3://ccfis-${ACCT}-${R}-${STACK}/" --recursive --region $R
done

# delete PAIRED first, then PRIMARY
aws cloudformation delete-stack --stack-name $STACK --region $PAIRED_REGION
aws cloudformation wait stack-delete-complete --stack-name $STACK --region $PAIRED_REGION
aws cloudformation delete-stack --stack-name $STACK --region $PRIMARY_REGION

# optional: the code/staging bucket
# aws s3 rb s3://connect-chaos-code-${ACCT}-${PRIMARY_REGION} --force --region $PRIMARY_REGION
```

Paired before primary, because the DynamoDB global tables are owned by the primary stack. With
Lex GR enabled, the replica bot is removed when the primary bot is deleted.

---

## Key design decisions

| Decision | Rationale |
|----------|-----------|
| One contact flow per experiment | `ContactFlowErrors` is the only "flow failed" metric Connect publishes; its `ContactFlowName` dimension is the only way to get per-experiment attribution without metric math |
| An attributing metric per experiment, not fault isolation | All faults also raise `Lambda Errors`; only each experiment's own metric names the cause |
| Exp 1 targets the account-lookup Lambda, not the Lex code hook | Erroring the code hook would only raise `AWS/Lambda Errors`, which Exp 3 also touches, destroying attribution |
| Exp 2 invokes a call logger directly from the flow | Otherwise `ContactFlowErrors` never fired and Exp 2 only rode the Lambda-Errors alarm (Fix 6) |
| Exp 3 uses Lambda `Duration`, not `ContactFlowErrors` or `RuntimeLambdaErrors` | Measured: the latency fault produces no flow-error datapoint, and that Lex metric is never emitted on Connect's voice path (Fixes 7, 18) |
| Exp 4 uses a no-agent queue + `LongestQueueWaitTime` | `MissedCalls` needs a staffed agent to deliberately not answer — not reproducible by a reader |
| Exp 4's chaos flag is Region-scoped | A Global Table would replicate the fault to the standby, making failover incapable of recovering (Fix 25) |
| DTMF input, not speech | ASR mis-transcribed test account numbers in a way indistinguishable from a broken lookup |
| Region announced at the start of every flow | Makes the serving Region audible instead of requiring two log groups to be cross-referenced (Fix 16) |
| `$.AwsRegion` in the flows' Lambda and Lex ARNs | ACGR replicates flow content verbatim; a hardcoded Region makes the paired Region call the **primary's** dependencies, defeating failover (Fixes 8, 16) |
| Explicit `IntegrationAssociation` per Region | A Lex bot must be associated with the instance before a flow can invoke it (Fix 5) |
| `CreateVpc=true` with free gateway endpoints | Removes the VPC prerequisite at no cost. S3 reachability is mandatory — the FIS extension reads its config from S3 |
| FIS layer ARN resolved from public SSM | Both the publishing account **and** the version differ per Region, so a hand-copied ARN fails silently (Fix 12) |
| Lambda S3 key includes a code content hash | A fixed key made CloudFormation skip code updates and ship stale Lambdas while reporting success (Fix 21) |
| Composite alarm has an explicit `DependsOn` | The rule names children in a `!Sub` literal, so CloudFormation cannot infer the dependency and creation races (Fix 1) |
| A configurable dwell before the traffic shift | A 2-second failover is impossible to observe, and shifting a contact centre on a transient blip is not desirable (Fix 22) |
| The handler re-checks the alarm after the dwell | A sleeping handler was silently undoing an operator's reset (Fix 23) |
| Manual recovery | An operator should confirm the fault is resolved before customers are routed back |

---

## Repository layout and tooling

| Path | Purpose |
|---|---|
| **`cfn/main-template.yaml`** | **The only deployable artifact.** Deployed once per Region |
| `lambda/*.py` | Function source; zipped and uploaded by `make`. Source of truth for the code |
| `contact-flows/*.json` | **Generated** reference copies — not deployed. Live flows are inline in the template |
| `scripts/extract-flows.py` | Regenerates the reference JSON and validates flow structure |
| `scripts/scan-secrets.py` | Fails the build on any committed credential or deployment-specific identifier |
| `scripts/wire-paired-flow.sh` | Post-deploy, **only** when `EnableLexGlobalResiliency=false` |
| `docs/` | Architecture diagram and its `awsdac` source |
| `RUNBOOK.md` | The test procedure |
| `FIXES.md` | Every defect found against a real ACGR instance, and what is deliberately not a bug |

```bash
make help                          # list every target
make bucket   REGION=...           # create the code/staging bucket (idempotent)
make package                       # zip the Lambdas
make bootstrap REGION=...          # bucket + package + upload
make deploy      STACK=... REGION=... CONNECT_INSTANCE_ARN=... CONNECT_INSTANCE_ID=... TDG_ID=...
make deploy-pair STACK=... PRIMARY_REGION=... PAIRED_REGION=... \
                 PRIMARY_INSTANCE_ARN=... PAIRED_INSTANCE_ARN=... TDG_ID=...
make post-deploy STACK=... PRIMARY_REGION=... PAIRED_REGION=... INSTANCE_ID=... TDG_ID=...
make verify      STACK=... PRIMARY_REGION=... PAIRED_REGION=... TDG_ID=...
make reset       STACK=... PRIMARY_REGION=... PAIRED_REGION=... TDG_ID=...   # see RUNBOOK Step R
make flows                         # regenerate contact-flows/*.json from the template
make lint                          # cfn-lint, bash -n, py_compile, JSON, flow drift, secrets
make clean
```

### No deployment-specific values in the repository

`make lint` runs `scripts/scan-secrets.py`, which fails on AWS access keys, private keys,
credential assignments, and any identifier tied to one deployment: account IDs, phone numbers,
Connect instance / TDG / flow / queue / contact UUIDs, VPC and subnet IDs, FIS experiment
template IDs, and Lex bot or alias IDs.

Every check is a **pattern**, never a denylist of known values — a denylist would have to contain
the very values it exists to keep out. Two AWS-owned public FIS layer accounts are allowlisted
with a justification in `ALLOWED_LITERALS`; add to it only for values that are genuinely public,
or append `scan-secrets: allow` to a single line.

The runbook is written so you never need to paste these values: IDs come from `describe-stacks`
outputs and shell variables at run time. Scan staged changes before committing with:

```bash
# Scan only what is about to be committed, rather than the whole tree.
python3 scripts/scan-secrets.py --staged
```

Run `make lint` before committing. There is no CI in this repo; validation is local. `-i W1030`
is expected — the `ReplicatedLexBot*` parameters are intentionally empty in primary-Region
deploys.

**The template exceeds CloudFormation's 51,200-byte inline limit** (~84 KB), so deploys must
stage it through S3. `make deploy` does this automatically. For StackSets use `--template-url`.

> **A failed first-create is auto-deleted.** `aws cloudformation deploy` rolls back and deletes a
> brand-new stack that fails, discarding the events you need. To keep it for inspection use
> `aws cloudformation create-stack --on-failure DO_NOTHING`, read `describe-stack-events`, then
> delete manually.

---

## Known findings

**[FIXES.md](FIXES.md)** records every defect found by deploying this against a real ACGR-paired
instance, the fix applied, and the things that are deliberately **not** bugs. Read it before
changing an experiment's metric — several obvious-looking "fixes" have already been proven wrong
by real calls.

## License

MIT-0. See [LICENSE](LICENSE).
