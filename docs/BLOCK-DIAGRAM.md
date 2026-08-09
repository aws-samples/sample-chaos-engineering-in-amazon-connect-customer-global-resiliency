# Block Diagram — as actually deployed

Every identifier below was read back from the live deployment in account `101506645078`
(stack `connect-chaos-sample`, IAD ↔ PDX). This is a record of a real, verified deployment,
not an idealised design.

---

## 1. Steady state — all calls served by the primary region

```
                          ┌──────────────────────────┐
                          │   PSTN caller            │
                          │   +44 808 547 8029       │
                          └────────────┬─────────────┘
                                       │
                          ┌────────────▼──────────────────────────────┐
                          │  Traffic Distribution Group  (ACGR)       │
                          │  tdg2  fb104a2a-3e14-41b1-b4ab-a9afec8e0685│
                          │                                           │
                          │     us-east-1 100%   ◄── steady state      │
                          │     us-west-2   0%                        │
                          └────────────┬──────────────────────────────┘
                                       │ 100%
     ══════════════════════════════════▼═══════════════════════════════════════
      PRIMARY — us-east-1 (IAD)                    acgr-saml-demo-iad
      Connect instance f4d29ac8-fcfc-4cc1-be06-545ac29aefe9
     ═══════════════════════════════════════════════════════════════════════════

        ConnectChaos-Menu  ->  ConnectChaos-Exp{1,2,3,4}-*  (contact flows)
        ┌──────────────────────────────────────────────────────────────┐
        │ 1  entry              play greeting                          │
        │            │                                                 │
        │ 2  log-call ──────────► ConnectChaos-CallLogger  (Lambda)    │
        │            │            writes audit record ──► DynamoDB      │
        │            │            ERROR branch ─────────┐              │
        │            ▼                                  │              │
        │ 3  lex-input ─────────► Lex V2 bot QJ5VLLR4GH │              │
        │            │            alias IYOEXZUVAZ      │              │
        │            │                 │                │              │
        │            │                 ▼ FulfillmentCodeHook           │
        │            │            LexFulfillmentHandler  (Lambda)      │
        │            │                 │        │                      │
        │            │                 ▼        ▼                      │
        │            │            Customers   Config (chaos flag)      │
        │            │                                  │              │
        │            ▼                                  ▼              │
        │ 4  success-msg                        error-msg ──► ContactFlowErrors
        └──────────────────────────────────────────────────────────────┘

        Lex alias ARN in the flow is region-agnostic:
          arn:aws:lex:$.AwsRegion:101506645078:bot-alias/QJ5VLLR4GH/IYOEXZUVAZ
          └─ resolved by Connect at RUNTIME to whichever region is executing
```

### Networking — VPC per region, no NAT, no internet gateway

```
   VPC  vpc-0f6018164a8383055  (IAD)          VPC vpc-0abb4de0b0af63282 (PDX)
   ┌──────────────────────────────────────┐
   │ subnet-0b4c915ebec02484a   (AZ a)    │   Only these two Lambdas are in the VPC:
   │ subnet-066ab137866d092a2   (AZ b)    │     • LexFulfillmentHandler
   │                                      │     • ConnectChaos-CallLogger
   │        │                             │
   │        ├──► gateway endpoint ────────┼──► DynamoDB      ($0)
   │        └──► gateway endpoint ────────┼──► S3            ($0)
   │                                      │
   │  NAT gateways: 0    IGW: 0           │   S3 is NOT optional — the FIS Lambda
   └──────────────────────────────────────┘   extension reads its fault config from
                                              S3. No S3 route ⇒ Exps 1 and 3 silently
                                              apply no fault at all.
```

### Cross-region replication

```
   IAD                                              PDX
   ─────────────────────────────────────────────────────────────────────────────
   Contact flows          ──── ACGR replicates ───►  same flows
   Lex bot QJ5VLLR4GH     ──── Lex Global Res. ───►  QJ5VLLR4GH  (SAME id)
   connect-chaos-sample-Customers ─ global table ─►  replica
   connect-chaos-sample-Config    ─ global table ─►  replica
   connect-chaos-sample-CallLog   ─ global table ─►  replica
   ConnectChaos-Overflow queue    ──── ACGR ──────►  same queue
   LexFulfillmentHandler          per-region deploy, IDENTICAL NAME (ACGR requirement)
   ConnectChaos-CallLogger        per-region deploy, identical name
```

---

## 1b. Deploy is not enough — three manual steps

CloudFormation builds every box above, but the contact centre will **not answer a call**
until these are done. `make post-deploy` performs all three and is safe to re-run.

```
  make deploy-pair            creates ALL infrastructure in both regions
        │
        ▼
  make post-deploy            ┌─ 1. seed DynamoDB (customer 12345, chaos_flag=false)
                              ├─ 2. associate the phone number with ConnectChaos-Menu
                              └─ 3. reset traffic to 100% primary / 0% paired
        │
        ▼
  make verify                 PASS/FAIL per check, including whether the PAIRED
                              region can actually serve a call
        │
        ▼
  baseline call               the only real proof of the number -> flow link,
                              because no AWS API exposes it
```

**Step 2 cannot be a CloudFormation resource.** The phone number belongs to the Traffic
Distribution Group, not to the stack, and no resource type models the number → flow link.
Skipping it is a **silent** failure: every resource reports `CREATE_COMPLETE`, every alarm
reports `OK`, and calls never enter the flow, with nothing indicating why.

### ⚠️ Lex GR: verify the replica, and verify the ALIAS

The `Replication` property on `AWS::Lex::Bot` is **not** sufficient evidence that the paired
region is usable. On this deployment the replica it created was present right after deploy
and had **vanished ~40 minutes later**, with no CloudTrail record of its creation or removal
(FIXES.md Fix 14). It had to be established explicitly:

```
aws lexv2-models create-bot-replica --bot-id <id> --replica-region <paired> --region <primary>

  bot   replica   Enabling  -> Enabled     ~30 s
  ALIAS replica   Creating  -> Available   ~90 s   ← the flow resolves to the ALIAS
```

The bot replica reaching `Enabled` is **not** enough. The flow's
`arn:aws:lex:$.AwsRegion:…:bot-alias/<botId>/<aliasId>` resolves to the **alias**, so the
paired region cannot serve a call until the *alias* replica is `Available`.

Always confirm with `make verify` before demonstrating a failover.

---

## 2. Inducing the chaos — four injection points

```
 EXP 1 ── FIS: aws:lambda:invocation-error ── template EXTr1GJfcSvf1BW
 │   FIS ──► writes fault config ──► s3://ccfis-101506645078-us-east-1-connect-chaos-sample
 │                                        │
 │                                        ▼ extension layer polls S3 (~60 s)
 │                              LexFulfillmentHandler
 │                              invocation marked FAILED, code never runs
 │                                        │
 │                                        ▼
 │                              AWS/Lambda  Errors  ▲          Duration ≈ 0
 │   ⚠ ~180 s window: call must land within ~3 min of starting
 │
 EXP 2 ── FIS: aws:network:disrupt-connectivity (scope=dynamodb) ── EXT52xQ3YYqgvC2kx
 │   FIS clones the NACL on BOTH subnets and denies the DynamoDB endpoint
 │                                        │
 │                                        ▼
 │                              ConnectChaos-CallLogger cannot reach DynamoDB
 │                              (fails fast: connect_timeout 2 s, 1 attempt)
 │                                        │
 │                                        ▼ flow takes its ERROR branch
 │                              AWS/Connect  ContactFlowErrors  ▲
 │   ✓ NO timing window — path severed for the whole experiment  ← most reliable
 │
 EXP 3 ── FIS: aws:lambda:invocation-add-delay ── template EXT2JeAjdNb4wBM2g
 │   ~31 s startup delay injected; function timeout is 40 s
 │                                        │
 │                                        ▼ runs slow but RETURNS CLEANLY
 │                              AWS/Lambda  Duration ≈ 31 000 ms ▲   Errors = 0
 │   ⚠ ~180 s window applies
 │   (deliberately NOT AWS/Lex RuntimeLambdaErrors — never emitted on Connect's
 │    real StartConversation voice path. See FIXES.md Fix 7.)
 │
 EXP 4 ── no FIS: a data flag
     put-item connect-chaos-sample-Config  chaos_flag = true
                                          │
                                          ▼
                              LexFulfillmentHandler returns Failed to Lex
                                          │
                                          ▼ ChaosTest flow failure path
                              set queue ConnectChaos-Overflow (7b4d65cb-…)
                              transfer to queue  ── NO routing profile ⇒ NO agent
                                          │
                                          ▼ contact waits indefinitely
                              AWS/Connect  LongestQueueWaitTime ▲
```

---

## 3. Detection and failover — the chain that was verified live

```
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ STEP 1   component alarms  (us-east-1)                                   │
  │                                                                          │
  │   ConnectChaos-Exp1-Lambda-us-east-1          ◄── Exp 1                │
  │   ConnectChaos-Exp2-DynamoDB-us-east-1     ◄── Exp 2                │
  │   ConnectChaos-Exp3-Latency-us-east-1    ◄── Exp 3  (> 7000 ms)   │
  │   ConnectChaos-Exp4-Queue-us-east-1              ◄── Exp 4  (> 60 s)      │
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  │  any ONE of them
  ┌───────────────────────────────▼──────────────────────────────────────────┐
  │ STEP 2   ConnectChaos-Composite-us-east-1                                │
  │          AlarmRule = ALARM(a) OR ALARM(b) OR ALARM(c) OR ALARM(d)        │
  │          → ALARM                                                        │
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                           ▼
  ┌──────────────────────────────┐   ┌────────────────────────────────────┐
  │ STEP 3  EventBridge rule     │   │ SNS AlarmNotificationTopic         │
  │ ConnectChaos-Failover-       │   │ (subscribe an email manually)      │
  │   us-east-1        [ENABLED] │   └────────────────────────────────────┘
  └──────────────┬───────────────┘
                 ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ STEP 4  ConnectChaos-TrafficShiftHandler   (NOT in the VPC)              │
  │         MY_REGION=us-east-1  PAIRED_REGION=us-west-2                     │
  │         TRAFFIC_DISTRIBUTION_GROUP_ID=fb104a2a-…                         │
  │                                                                          │
  │   a) GetTrafficDistribution   ── idempotency guard: no-op if already 0%   │
  │   b) UpdateTrafficDistribution                                           │
  │        us-east-1 → 0%     us-west-2 → 100%                               │
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  ▼
                    NEW inbound calls now route to PDX
                    (calls already in progress are NOT moved)
```

**Symmetric by design.** PDX runs an identical handler with `MY_REGION=us-west-2`, so each
region shifts traffic *away from itself*. The region that detects the fault initiates the
failover — there is no central controller to become a single point of failure. The
idempotency guard means both regions alarming at once cannot fight each other.

---

## 4. After failover — the claim that matters

```
   TDG:  us-east-1 0%   │   us-west-2 100%
                        ▼
     PAIRED — us-west-2 (PDX)        acgr-saml-demo-iad-dr
     Connect instance f4d29ac8-fcfc-4cc1-be06-545ac29aefe9   (SAME id — ACGR replica)

       ConnectChaos-Menu + 4  (ACGR-replicated, byte-identical content)
              │
              │  Lex ARN resolves via $.AwsRegion  →  arn:aws:lex:us-west-2:…
              ▼
       Lex bot QJ5VLLR4GH  (Lex GR replica, SAME id)  ── status Available
              │
              ▼
       PDX LexFulfillmentHandler + ConnectChaos-CallLogger   (PDX's own)
              │
              ▼
       PDX DynamoDB replicas  (same data)

   ✔ PASS  = the PDX Lambda logs the invocation and the IAD one does not
   ✘ FAIL  = the IAD Lambda logs it → the flow is still calling the primary's Lex,
             so the "healthy" region still depends on the failed one
```

This is the single most important verification in the whole sample, and it is exactly what a
hardcoded Lex ARN would break silently — traffic would move, metrics would look correct, and
the paired region would still be reaching back into the failed region.

---

## 5. Recovery — deliberately manual

```
   experiment ends / fault removed
              │
              ▼
   alarms return to OK          ── TrafficShiftHandler IGNORES OK events by design
              │
              ▼
   operator runs, when satisfied the fault is genuinely resolved:
     aws connect update-traffic-distribution --id fb104a2a-… \
       --telephony-config '{"Distributions":[
           {"Region":"us-east-1","Percentage":100},
           {"Region":"us-west-2","Percentage":0}]}'
```

Skipping this between experiments is the single easiest way to invalidate a test run: every
later experiment would start from an already-failed-over state and prove nothing.

---

## Deployed inventory (verified by API read-back)

| Component | us-east-1 (IAD) | us-west-2 (PDX) |
|---|---|---|
| Stack | `CREATE_COMPLETE` | `CREATE_COMPLETE` |
| Connect instance | `f4d29ac8-…` | `f4d29ac8-…` *(same — ACGR)* |
| Lex bot / alias | `QJ5VLLR4GH` / `IYOEXZUVAZ` | `QJ5VLLR4GH` *(Lex GR, Available)* |
| VPC | `vpc-0f6018164a8383055` | `vpc-0abb4de0b0af63282` |
| Gateway endpoints | DynamoDB + S3 | DynamoDB + S3 |
| NAT gateways | **0** | **0** |
| Lambdas (all `python3.13`) | 4 | 4 |
| Tables | `connect-chaos-sample-{Customers,Config,CallLog}` | replicas |
| Overflow queue | `ConnectChaos-Overflow` `7b4d65cb-…` | ACGR-replicated |
| Component alarms | 4, all `OK` | 4 |
| Composite alarm | `OK` | present |
| EventBridge failover rule | `ENABLED` | `ENABLED` |
| FIS templates | `EXTr1GJfcSvf1BW`, `EXT52xQ3YYqgvC2kx`, `EXT2JeAjdNb4wBM2g` | 3 |

> The `ccfis-101506645078-eu-west-2-…` bucket also exists — that belongs to the separate
> London deployment, which is still live and untouched by this stack.
