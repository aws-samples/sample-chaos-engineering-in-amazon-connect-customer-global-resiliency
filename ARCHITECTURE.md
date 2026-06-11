# Amazon Connect FIS Chaos Engineering — ACGR Failover

## What This Sample Does

This sample enables **chaos engineering** for an Amazon Connect contact center running in an **ACGR (Amazon Connect Global Resiliency)** paired-region configuration.

It deploys infrastructure that allows users to:

1. **Inject controlled faults** into individual components (Lambda, DynamoDB, Lex, Contact Flow) using AWS Fault Injection Service (FIS)
2. **Observe failures** through distinct CloudWatch metrics per component
3. **Automatically fail over** telephony traffic to the healthy paired region via ACGR's `UpdateTrafficDistribution` API

---

## Architecture

```
                         ┌──────────────────────────────────┐
                         │   Traffic Distribution Group      │
                         │          (ACGR)                  │
                         │                                  │
                         │   Normal:  IAD 100% | PDX 0%    │
                         │   Failover: IAD 0%  | PDX 100%  │
                         └────────────┬─────────────────────┘
                                      │
              ┌───────────────────────┴───────────────────────┐
              │                                               │
    ┌─────────▼──────────┐                      ┌────────────▼─────────┐
    │  PRIMARY (us-east-1)│                      │  PAIRED (us-west-2)  │
    │                     │                      │                      │
    │  Connect Instance   │                      │  Connect Instance    │
    │  (ACGR Source)      │                      │  (ACGR Replica)      │
    │       │             │                      │       │              │
    │       ▼             │                      │       ▼              │
    │  Contact Flows ─────┼── ACGR Replicates ──►│  Contact Flows       │
    │  (Main IVR +        │                      │  (auto-replicated)   │
    │   Chaos Test)       │                      │                      │
    │       │             │                      │       │              │
    │       ▼             │                      │       ▼              │
    │  Lex V2 Bot ────────┼── Lex GR ──────────►│  Lex V2 Bot          │
    │  (FulfillmentHook)  │  (replicates bot)    │  (GR replica)        │
    │       │             │                      │       │              │
    │       ▼             │                      │       ▼              │
    │  Lambda ────────────┼── Deploy via ───────►│  Lambda              │
    │  (LexFulfillment    │    StackSet          │  (same name)         │
    │   Handler)          │                      │                      │
    │       │             │                      │       │              │
    │       ▼             │                      │       ▼              │
    │  DynamoDB ──────────┼── Global Table ─────►│  DynamoDB            │
    │  (auto-replicates)  │                      │  (auto-replicated)   │
    │                     │                      │                      │
    │  FIS Experiments    │                      │  FIS Experiments     │
    │  CW Alarms          │                      │  CW Alarms           │
    │  EventBridge        │                      │  EventBridge         │
    │  TrafficShift Lambda│                      │  TrafficShift Lambda │
    └─────────────────────┘                      └──────────────────────┘
```

---

## Experiment Details

### How Each Fault Is Injected and What It Produces

| # | Component | FIS Action | What Breaks | Distinct Metric | Namespace |
|---|-----------|-----------|-------------|-----------------|-----------|
| **1** | **Lambda** | `aws:lambda:invocation-error` | Lambda marked as failed — no code executes | `Errors` | AWS/Lambda |
| **2** | **DynamoDB** | `aws:network:disrupt-connectivity` scope=`dynamodb` | Lambda's VPC subnet blocked from reaching DDB endpoint | `ContactFlowErrors` | AWS/Connect |
| **3** | **Lex** | `aws:lambda:invocation-add-delay` (15s delay, 8s timeout) | Lex code hook Lambda times out | `RuntimeLambdaErrors` | AWS/Lex |
| **4** | **Contact Flow** | Custom: DDB chaos flag set to `true` | Lambda returns `Failed` state → Lex failure response → flow error path → no agent pickup | `MissedCalls` | AWS/Connect |

### Experiment Execution

| Experiment | Native FIS OOTB? | How User Invokes |
|:---:|:---:|---|
| 1 | ✅ Yes | `aws fis start-experiment --experiment-template-id <exp1-id>` |
| 2 | ✅ Yes | `aws fis start-experiment --experiment-template-id <exp2-id>` |
| 3 | ✅ Yes | `aws fis start-experiment --experiment-template-id <exp3-id>` |
| 4 | Custom | `aws dynamodb put-item --table ConnectChaosConfig --item '{"config_key":{"S":"chaos_flag"},"enabled":{"BOOL":true}}'` |

### Failure Cascade Per Experiment

**Experiment 1 — Lambda Failure:**
```
FIS injects error → Lambda fails
  → Lex code hook fails → Lex returns Failure response
    → Contact flow "Get customer input" Error branch fires
      → CW: AWS/Lambda Errors ↑ (ALARM METRIC)
```

**Experiment 2 — DynamoDB Unreachable:**
```
FIS blocks DDB traffic from subnet → Lambda runs but can't reach DDB → throws exception
  → Lex code hook fails → Lex returns Failure response
    → Contact flow Error branch fires
      → CW: AWS/Connect ContactFlowErrors ↑ (ALARM METRIC)
```

**Experiment 3 — Lex Code Hook Timeout:**
```
FIS adds 15s delay → Lambda exceeds 8s timeout
  → Lex detects code hook timeout → emits RuntimeLambdaErrors
    → Contact flow receives timeout → Error branch fires
      → CW: AWS/Lex RuntimeLambdaErrors ↑ (ALARM METRIC)
```

**Experiment 4 — Contact Flow Logic Failure:**
```
User sets DDB chaos_flag=true → Lambda reads flag → returns Failed state to Lex
  → Lex routes to Failure response
    → Contact flow routes to overflow queue (no agents)
      → Call rings, no agent answers within 20s
        → CW: AWS/Connect MissedCalls ↑ (ALARM METRIC)
```

---

## Outcome — ACGR Failover

```
ANY alarm fires
    │
    ▼
Composite Alarm enters ALARM state
    │
    ▼
EventBridge Rule triggers TrafficShift Lambda
    │
    ▼
Lambda calls UpdateTrafficDistribution API:
  TelephonyConfig:
    - MyRegion: 0%
    - PairedRegion: 100%
    │
    ▼
New inbound calls route to paired region (healthy)
  → Same contact flows (ACGR-replicated)
  → Same Lex bot (independently deployed)
  → Same DDB data (Global Table replicated)
  → Normal customer experience

Recovery (manual or auto):
  → Alarms return to OK
  → User (or EventBridge) shifts traffic back: 100% primary / 0% paired
```

---

## Deployed Resources

### StackSet Deployment Model

**Deployed via CloudFormation StackSet** to both primary and paired regions.
Template uses `IsPrimaryRegion` condition to control what deploys where.

### Primary Region ONLY (Condition: IsPrimaryRegion)

| Resource | Type | Purpose |
|----------|------|---------|
| DynamoDB Global Table — `ConnectChaosCustomers` | `AWS::DynamoDB::GlobalTable` | Customer data (auto-replicates to paired) |
| DynamoDB Global Table — `ConnectChaosConfig` | `AWS::DynamoDB::GlobalTable` | Chaos flag storage (auto-replicates to paired) |
| Contact Flow — Main IVR | `AWS::Connect::ContactFlow` | Production IVR with Lex integration (ACGR auto-replicates) |
| Contact Flow — Chaos Test | `AWS::Connect::ContactFlow` | Chaos test flow with overflow queue (ACGR auto-replicates) |
| CW Dashboard — Unified *(if user selects unified)* | `AWS::CloudWatch::Dashboard` | Cross-region metrics in one pane |

### BOTH Regions (No Condition — deployed via StackSet)

| Resource | Type | Purpose |
|----------|------|---------|
| Lex V2 Bot + Version + Alias | `AWS::Lex::Bot` / `BotVersion` / `BotAlias` | IVR bot with FulfillmentCodeHook. Lex GR replicates from primary (IAD↔PDX, LDN↔FRA). For Tokyo↔Osaka, deploys independently. |
| Lambda — `LexFulfillmentHandler` | `AWS::Lambda::Function` | Lex code hook: DDB lookup + chaos flag logic. Has FIS extension layer. |
| Lambda — `TrafficShiftHandler` | `AWS::Lambda::Function` | Calls `UpdateTrafficDistribution` on alarm (optional) |
| S3 — FIS Config Bucket | `AWS::S3::Bucket` | FIS extension config distribution (per-region required) |
| SNS Topic — `AlarmNotificationTopic` | `AWS::SNS::Topic` | Alarm actions and OK actions target for notifications |
| FIS Experiment Template 1 | `AWS::FIS::ExperimentTemplate` | Lambda invocation failure |
| FIS Experiment Template 2 | `AWS::FIS::ExperimentTemplate` | DDB network disruption |
| FIS Experiment Template 3 | `AWS::FIS::ExperimentTemplate` | Lambda timeout (Lex code hook) |
| CloudWatch Alarm — Lambda Errors | `AWS::CloudWatch::Alarm` | Monitors `Errors` in AWS/Lambda |
| CloudWatch Alarm — ContactFlowErrors | `AWS::CloudWatch::Alarm` | Monitors `ContactFlowErrors` in AWS/Connect |
| CloudWatch Alarm — RuntimeLambdaErrors | `AWS::CloudWatch::Alarm` | Monitors `RuntimeLambdaErrors` in AWS/Lex |
| CloudWatch Alarm — MissedCalls | `AWS::CloudWatch::Alarm` | Monitors `MissedCalls` in AWS/Connect |
| CloudWatch Composite Alarm | `AWS::CloudWatch::CompositeAlarm` | ANY sub-alarm → triggers failover |
| EventBridge Rule | `AWS::Events::Rule` | Composite alarm ALARM → invokes TrafficShift Lambda |
| CW Dashboard — Regional *(if user selects regional)* | `AWS::CloudWatch::Dashboard` | Per-region metrics view |
| IAM Roles (FIS, Lambda, Lex, TrafficShift) | `AWS::IAM::Role` | Least-privilege execution roles |

### User-Selectable Parameters

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `ConnectInstanceArn` | ACGR-enabled Connect instance ARN | *(required)* |
| `PrimaryRegion` | Which region is primary | `us-east-1` |
| `PairedRegion` | Which region is paired | `us-west-2` |
| `EnableAutoFailover` | Deploy EventBridge + TrafficShift Lambda | `false` |
| `DashboardType` | `regional` (per-region) or `unified` (cross-region in primary) | `regional` |
| `LambdaSubnetIdA` | First VPC subnet for Lambda (also targeted by FIS Exp 2) | *(required)* |
| `LambdaSubnetIdB` | Second VPC subnet for Lambda (also targeted by FIS Exp 2) | *(required)* |
| `EnableLexGlobalResiliency` | Use Lex GR to replicate bot from primary (IAD↔PDX, LDN↔FRA only) | `true` |
| `ReplicatedLexBotId` | Lex Bot ID from primary stack output (paired region only, when Lex GR enabled) | *(empty)* |
| `ReplicatedLexBotAliasId` | Lex Bot Alias ID from primary stack output (paired region only, when Lex GR enabled) | *(empty)* |
| `FISExtensionLayerArn` | AWS FIS Lambda extension layer ARN for region | *(required)* |
| `LambdaCodeBucket` | Pre-existing S3 bucket with Lambda .zip packages | *(required)* |

---

## Prerequisites

1. **AWS Enterprise Support** (or AWS Unified Operations) — required for ACGR onboarding
2. **ACGR-enabled Connect instance** — paired with a secondary region, Traffic Distribution Group created with **ported** phone numbers
3. **Production SAML 2.0 identity provider** configured on the source Connect instance
4. **VPC** with two subnets where Lambda will run (required for DDB network disruption experiment — FIS targets both subnets)
5. **S3 bucket** with packaged Lambda code uploaded (zip files)
6. **FIS Lambda extension layer ARN** for your region ([reference](https://docs.aws.amazon.com/fis/latest/userguide/actions-lambda-extension-arns.html))

---

## Deployment

```bash
# 1. Package Lambda code
zip lex_fulfillment_handler.zip lex_fulfillment_handler.py
zip traffic_shift_handler.zip traffic_shift_handler.py
aws s3 cp *.zip s3://YOUR-CODE-BUCKET/connect-chaos/

# 2. Deploy StackSet to both regions
aws cloudformation create-stack-set \
  --stack-set-name connect-chaos \
  --template-body file://cfn/main-template.yaml \
  --parameters \
    ParameterKey=ConnectInstanceArn,ParameterValue=arn:aws:connect:us-east-1:123456789012:instance/abc \
    ParameterKey=ConnectInstanceId,ParameterValue=abc \
    ParameterKey=PrimaryRegion,ParameterValue=us-east-1 \
    ParameterKey=PairedRegion,ParameterValue=us-west-2 \
    ParameterKey=LambdaCodeBucket,ParameterValue=YOUR-CODE-BUCKET \
    ParameterKey=LambdaSubnetIdA,ParameterValue=subnet-aaa \
    ParameterKey=LambdaSubnetIdB,ParameterValue=subnet-bbb \
    ParameterKey=LambdaSecurityGroupId,ParameterValue=sg-ccc \
    ParameterKey=FISExtensionLayerArn,ParameterValue=arn:aws:lambda:us-east-1:123456789012:layer:... \
    ParameterKey=EnableAutoFailover,ParameterValue=true \
    ParameterKey=EnableLexGlobalResiliency,ParameterValue=true \
    ParameterKey=DashboardType,ParameterValue=unified \
  --capabilities CAPABILITY_NAMED_IAM \
  --permission-model SELF_MANAGED

# 3. Create stack instances in both regions
aws cloudformation create-stack-instances \
  --stack-set-name connect-chaos \
  --accounts 123456789012 \
  --regions us-east-1 us-west-2
```
