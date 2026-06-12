# Amazon Connect Chaos Engineering with FIS & ACGR Failover

> **⚠️ Important:** Amazon Connect Global Resiliency (ACGR) requires **AWS Enterprise Support** and must be onboarded through your AWS account team. This sample assumes ACGR is already enabled with a Traffic Distribution Group configured.

## Overview

This sample demonstrates **chaos engineering** for an Amazon Connect contact center using:
- **AWS Fault Injection Service (FIS)** to inject faults into individual components
- **Amazon Connect Global Resiliency (ACGR)** to automatically fail over telephony traffic to a healthy paired region

Each experiment targets a **distinct component** and monitors a **distinct CloudWatch metric** — proving that failures in any layer (Lambda, DynamoDB, Lex, Contact Flow) are independently observable and can trigger regional failover.

---

## Architecture

![Architecture](docs/architecture.png)

```
                              ┌─────────────────────────────┐
                              │  Traffic Distribution Group  │
                              │  (ACGR)                     │
                              │                             │
                              │  IAD: 100% ←→ PDX: 0%      │
                              └──────────┬──────────────────┘
                                         │
                    ┌────────────────────┴────────────────────┐
                    │                                          │
              IAD (Primary)                             PDX (Paired)
              ┌──────────────┐                    ┌──────────────┐
              │ Connect      │                    │ Connect      │
              │ Contact Flow │                    │ Contact Flow │
              │      │       │                    │ (Replicated) │
              │      ▼       │                    └──────────────┘
              │ Lex V2 Bot   │                    ┌──────────────┐
              │      │       │                    │ Lex V2 Bot   │
              │      ▼       │                    │ (Lex GR rep.) │
              │ Lambda       │                    └──────────────┘
              │ (Fulfillment)│                    ┌──────────────┐
              │      │       │                    │ Lambda       │
              │      ▼       │                    │ (Fulfillment)│
              │ DynamoDB     │── Global Table ──► │ DynamoDB     │
              └──────────────┘                    └──────────────┘
                    │                                    │
              FIS Experiments                      FIS Experiments
              (target local                       (target local
               components)                         components)
```

---

## Experiments — One Per Component

| # | Component | FIS Action | Metric (Distinct) | Namespace |
|---|-----------|-----------|-------------------|-----------:|
| **1** | Lambda | `aws:lambda:invocation-error` | `Errors` | AWS/Lambda |
| **2** | DynamoDB | `aws:network:disrupt-connectivity` scope=dynamodb | `ContactFlowErrors` | AWS/Connect |
| **3** | Lex | `aws:lambda:invocation-add-delay` (> timeout) | `RuntimeLambdaErrors` | AWS/Lex |
| **4** | Contact Flow | Custom (DDB chaos flag → Lex returns Failed) | `MissedCalls` | AWS/Connect |

### Experiment Details

#### Experiment 1: Lambda Invocation Failure
- **What:** FIS prevents the `LexFulfillmentHandler` Lambda from executing
- **How:** `aws:lambda:invocation-error` with `preventExecution: true`
- **Effect:** Lambda emits `Errors` metric in AWS/Lambda namespace
- **Alarm:** `ConnectChaos-Lambda-Errors-{region}` (threshold: >5 errors/min)

#### Experiment 2: DynamoDB Network Disruption
- **What:** FIS blocks network connectivity from Lambda's VPC subnet to DynamoDB
- **How:** `aws:network:disrupt-connectivity` with `scope: dynamodb`
- **Effect:** Lambda executes but throws ClientError → Lex returns error → Contact flow takes Error branch → `ContactFlowErrors` metric fires
- **Alarm:** `ConnectChaos-ContactFlow-Errors-{region}` (threshold: >5 errors/min)

#### Experiment 3: Lex Code Hook Timeout
- **What:** FIS injects 15s delay into Lambda startup (timeout is 8s) → Lex code hook times out
- **How:** `aws:lambda:invocation-add-delay` with `startupDelayMilliseconds: 15000`
- **Effect:** Lex detects code hook timeout → emits `RuntimeLambdaErrors` in AWS/Lex namespace
- **Alarm:** `ConnectChaos-Lex-RuntimeLambdaErrors-{region}` (threshold: >3 errors/min)

#### Experiment 4: Contact Flow Logic Failure (Custom)
- **What:** A DynamoDB chaos flag (`chaos_enabled=true`) causes Lambda to return `Failed` state to Lex
- **How:** Set DDB item `{config_key: "chaos_flag", enabled: true}` in `ConnectChaosConfig` table
- **Effect:** Lex returns Failure response → Contact flow routes to overflow queue (no agents) → `MissedCalls` fires
- **Alarm:** `ConnectChaos-MissedCalls-{region}` (threshold: >5 in 5 min)

---

## Failover Mechanism

```
ANY Alarm fires → Composite Alarm = ALARM
    → EventBridge Rule
        → TrafficShiftHandler Lambda
            → UpdateTrafficDistribution API
                → 0% THIS region / 100% OTHER region

New calls route to healthy region automatically.
```

Each region's `TrafficShiftHandler` Lambda shifts traffic **away from itself** — the region detecting failure is the one that initiates failover.

### Recovery
After the FIS experiment ends and metrics return to normal:
- Alarms return to OK state
- Traffic is shifted back manually (or via auto-recovery if enabled)

---

## Resources Deployed

| Resource | Primary | Paired | Deployment Method |
|----------|:---:|:---:|---|
| Contact Flow — Main IVR | ✓ | ✓ | ACGR auto-replicates |
| Contact Flow — Chaos Test | ✓ | ✓ | ACGR auto-replicates |
| Lex V2 Bot + Alias | ✓ | ✓ | StackSet (independent per region) |
| Lambda — `LexFulfillmentHandler` | ✓ | ✓ | StackSet |
| Lambda — `TrafficShiftHandler` | ✓ | ✓ | StackSet (requires `EnableAutoFailover=true`) |
| DynamoDB — `ConnectChaosCustomers` | ✓ | ✓ | Global Table (create in primary, auto-replicates) |
| DynamoDB — `ConnectChaosConfig` | ✓ | ✓ | Global Table (create in primary, auto-replicates) |
| S3 — FIS config bucket | ✓ | ✓ | StackSet (per-region bucket) |
| FIS Experiment Templates ×3 | ✓ | ✓ | StackSet |
| CloudWatch Alarms ×4 + Composite | ✓ | ✓ | StackSet |
| CloudWatch Dashboard | ✓ | ✓ | StackSet (type depends on `DashboardType` param) |
| EventBridge Rule | ✓ | ✓ | StackSet (requires `EnableAutoFailover=true`) |
| SNS Topic — `AlarmNotificationTopic` | ✓ | ✓ | StackSet (alarm actions + OK actions) |
| IAM Roles | ✓ | ✓ | StackSet (region-suffixed names) |

> **Note:** By default, Lex Global Resiliency replicates the bot from the primary region to the paired region (supported for `us-east-1`↔`us-west-2` and `eu-west-2`↔`eu-central-1`). For `ap-northeast-1`↔`ap-northeast-3`, set `EnableLexGlobalResiliency=false` — the bot deploys independently to each region via StackSet.

---

## Prerequisites

1. **AWS Enterprise Support** (or AWS Unified Operations) — required for ACGR onboarding
2. **Amazon Connect instance** with ACGR enabled, paired with a secondary region, and a production SAML 2.0 identity provider configured on the source instance
3. **Traffic Distribution Group** already created with **ported** phone number(s) associated (claimed-only numbers are not eligible for ACGR)
4. **VPC** with at least two subnets in each region (required for Experiment 2 — DDB network disruption targets both subnets)
5. **S3 bucket** with packaged Lambda .zip files (see Deployment Step 1)
6. **FIS Lambda extension layer ARN** for your region and architecture — see [AWS docs](https://docs.aws.amazon.com/fis/latest/userguide/fis-actions-reference.html)

---

## Parameters

| Parameter | Required | Default | Notes |
|-----------|:---:|---|---|
| `ConnectInstanceArn` | ✓ | — | ACGR-enabled Connect instance ARN for **this** region |
| `ConnectInstanceId` | ✓ | — | Connect instance UUID for **this** region |
| `TrafficDistributionGroupId` | ✓ | — | TDG that ACGR failover updates |
| `LambdaSubnetIdA` | ✓ | — | First Lambda VPC subnet (also targeted by Experiment 2) |
| `LambdaSubnetIdB` | ✓ | — | Second Lambda VPC subnet (also targeted by Experiment 2) |
| `LambdaSecurityGroupId` | ✓ | — | Security group for the Lambda VPC config |
| `LambdaCodeBucket` | ✓ | — | Pre-existing S3 bucket holding the Lambda `.zip` packages (under `connect-chaos/`) |
| `FISExtensionLayerArn` | ✓ | — | AWS FIS Lambda extension layer ARN for this region |
| `PrimaryRegion` | | `us-east-1` | Must form an ACGR-supported pair with `PairedRegion` (enforced by the template `Rules` block) |
| `PairedRegion` | | `us-west-2` | — |
| `EnableAutoFailover` | | `false` | Deploy the EventBridge rule + `TrafficShiftHandler` Lambda |
| `EnableLexGlobalResiliency` | | `true` | Replicate the Lex bot via Lex GR (IAD↔PDX, LDN↔FRA). Set `false` for Tokyo↔Osaka |
| `ReplicatedLexBotId` | | `''` | Paired region only — `LexBotId` output from the primary stack |
| `ReplicatedLexBotAliasId` | | `''` | Paired region only — `LexBotAliasId` output from the primary stack |
| `PairedConnectInstanceId` | | `''` | Primary region only, when `DashboardType=unified` |
| `DashboardType` | | `regional` | `regional` (per-region) or `unified` (cross-region in primary) |
| `EnableTrafficGenerator` | | `false` | Deploy the optional synthetic-traffic Lambda |
| `ContactFlowErrorsThreshold` | | `5` | Experiment 2 alarm threshold |
| `RuntimeLambdaErrorsThreshold` | | `3` | Experiment 3 alarm threshold |
| `MissedCallsThreshold` | | `5` | Experiment 4 alarm threshold |
| `FISExperimentDuration` | | `PT5M` | ISO-8601 duration for FIS experiments 1–3 |

---

## Deployment

This template is designed for **CloudFormation StackSets** — a single template deployed to both the primary and paired regions. The `IsPrimaryRegion` condition controls what deploys where.

### Step 1: Package Lambda Code

```bash
cd lambda/
zip lex_fulfillment_handler.zip lex_fulfillment_handler.py
zip traffic_shift_handler.zip traffic_shift_handler.py

# Upload to your pre-created S3 bucket in each region — the CFN template
# expects all Lambda code under the `connect-chaos/` prefix.
aws s3 cp lex_fulfillment_handler.zip s3://YOUR-BUCKET-NAME/connect-chaos/ --region us-east-1
aws s3 cp traffic_shift_handler.zip s3://YOUR-BUCKET-NAME/connect-chaos/ --region us-east-1
```

### Step 2: Collect deployment parameter values

Before running the deploy command, gather these values from your account. Replace `<your-instance-alias>`, `<your-bucket-iad>`, etc. with values from your environment. The shell variables defined here are referenced by the deploy commands in Step 3.

```bash
# Region pair (one of: us-east-1/us-west-2, eu-west-2/eu-central-1, ap-northeast-1/ap-northeast-3)
PRIMARY_REGION=us-east-1
PAIRED_REGION=us-west-2

# Your AWS account ID
ACCT=$(aws sts get-caller-identity --query Account --output text)

# Connect instance ARN and ID — primary region
PRIMARY_INSTANCE_ARN=$(aws connect list-instances --region $PRIMARY_REGION \
  --query "InstanceSummaryList[?InstanceAlias=='<your-instance-alias>'].Arn | [0]" --output text)
PRIMARY_INSTANCE_ID=$(echo $PRIMARY_INSTANCE_ARN | awk -F/ '{print $NF}')

# Connect instance ARN and ID — paired region (auto-created by ACGR replication)
PAIRED_INSTANCE_ARN=$(aws connect list-instances --region $PAIRED_REGION \
  --query "InstanceSummaryList[?InstanceAlias=='<your-instance-alias>'].Arn | [0]" --output text)
PAIRED_INSTANCE_ID=$(echo $PAIRED_INSTANCE_ARN | awk -F/ '{print $NF}')

# Traffic Distribution Group (created during ACGR onboarding)
TDG_ID=$(aws connect list-traffic-distribution-groups \
  --instance-id $PRIMARY_INSTANCE_ID --region $PRIMARY_REGION \
  --query "TrafficDistributionGroupSummaryList[0].Id" --output text)
```

Look up the remaining values manually:

| Variable | Where to find it |
|---|---|
| `LAMBDA_SUBNET_A_IAD`, `LAMBDA_SUBNET_B_IAD` | Two private subnets in your VPC in the primary region (Experiment 2 disrupts both for deterministic blast radius) |
| `LAMBDA_SUBNET_A_PDX`, `LAMBDA_SUBNET_B_PDX` | Same, in the paired region |
| `LAMBDA_SG_IAD`, `LAMBDA_SG_PDX` | Security group ID per region for the Lambda VPC config |
| `LAMBDA_BUCKET_IAD`, `LAMBDA_BUCKET_PDX` | The bucket in each region where you uploaded the zips in Step 1 |
| `FIS_LAYER_IAD`, `FIS_LAYER_PDX` | FIS Lambda extension layer ARN per region — see the [per-region catalog](https://docs.aws.amazon.com/fis/latest/userguide/actions-lambda-extension-arns.html) |

```bash
LAMBDA_SUBNET_A_IAD=<subnet-id>
LAMBDA_SUBNET_B_IAD=<subnet-id>
LAMBDA_SG_IAD=<sg-id>
LAMBDA_BUCKET_IAD=<your-bucket-iad>
FIS_LAYER_IAD=<fis-extension-layer-arn-iad>

LAMBDA_SUBNET_A_PDX=<subnet-id>
LAMBDA_SUBNET_B_PDX=<subnet-id>
LAMBDA_SG_PDX=<sg-id>
LAMBDA_BUCKET_PDX=<your-bucket-pdx>
FIS_LAYER_PDX=<fis-extension-layer-arn-pdx>
```

### Step 3: Deploy via StackSet (Recommended)

The top-level `--parameters` carry the **primary region's** values. The paired region's values are supplied via `--parameter-overrides` on `create-stack-instances`.

```bash
aws cloudformation create-stack-set \
  --stack-set-name connect-chaos-sample \
  --template-body file://cfn/main-template.yaml \
  --parameters \
    ParameterKey=ConnectInstanceArn,ParameterValue=$PRIMARY_INSTANCE_ARN \
    ParameterKey=ConnectInstanceId,ParameterValue=$PRIMARY_INSTANCE_ID \
    ParameterKey=PrimaryRegion,ParameterValue=$PRIMARY_REGION \
    ParameterKey=PairedRegion,ParameterValue=$PAIRED_REGION \
    ParameterKey=TrafficDistributionGroupId,ParameterValue=$TDG_ID \
    ParameterKey=EnableAutoFailover,ParameterValue=true \
    ParameterKey=DashboardType,ParameterValue=regional \
    ParameterKey=LambdaSubnetIdA,ParameterValue=$LAMBDA_SUBNET_A_IAD \
    ParameterKey=LambdaSubnetIdB,ParameterValue=$LAMBDA_SUBNET_B_IAD \
    ParameterKey=LambdaSecurityGroupId,ParameterValue=$LAMBDA_SG_IAD \
    ParameterKey=LambdaCodeBucket,ParameterValue=$LAMBDA_BUCKET_IAD \
    ParameterKey=FISExtensionLayerArn,ParameterValue=$FIS_LAYER_IAD \
    ParameterKey=EnableLexGlobalResiliency,ParameterValue=true \
  --capabilities CAPABILITY_NAMED_IAM \
  --permission-model SELF_MANAGED

# Wait for the PRIMARY stack to reach CREATE_COMPLETE, then read the Lex IDs
# that Lex Global Resiliency preserves in the paired region:
LEX_BOT_ID=$(aws cloudformation describe-stacks \
  --stack-name connect-chaos-sample --region $PRIMARY_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text)
LEX_BOT_ALIAS_ID=$(aws cloudformation describe-stacks \
  --stack-name connect-chaos-sample --region $PRIMARY_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='LexBotAliasId'].OutputValue" --output text)

# Paired-region values are supplied as ParameterOverrides:
aws cloudformation create-stack-instances \
  --stack-set-name connect-chaos-sample \
  --accounts $ACCT \
  --regions $PRIMARY_REGION $PAIRED_REGION \
  --parameter-overrides \
    "[
      {\"ParameterKey\":\"ConnectInstanceArn\",\"ParameterValue\":\"$PAIRED_INSTANCE_ARN\"},
      {\"ParameterKey\":\"ConnectInstanceId\",\"ParameterValue\":\"$PAIRED_INSTANCE_ID\"},
      {\"ParameterKey\":\"LambdaSubnetIdA\",\"ParameterValue\":\"$LAMBDA_SUBNET_A_PDX\"},
      {\"ParameterKey\":\"LambdaSubnetIdB\",\"ParameterValue\":\"$LAMBDA_SUBNET_B_PDX\"},
      {\"ParameterKey\":\"LambdaSecurityGroupId\",\"ParameterValue\":\"$LAMBDA_SG_PDX\"},
      {\"ParameterKey\":\"LambdaCodeBucket\",\"ParameterValue\":\"$LAMBDA_BUCKET_PDX\"},
      {\"ParameterKey\":\"FISExtensionLayerArn\",\"ParameterValue\":\"$FIS_LAYER_PDX\"},
      {\"ParameterKey\":\"ReplicatedLexBotId\",\"ParameterValue\":\"$LEX_BOT_ID\"},
      {\"ParameterKey\":\"ReplicatedLexBotAliasId\",\"ParameterValue\":\"$LEX_BOT_ALIAS_ID\"}
    ]" \
  --operation-preferences MaxConcurrentPercentage=100
```

### Alternative: Deploy Individually Per Region

If you prefer not to use a StackSet, deploy the same template twice with `aws cloudformation deploy`. The variable names are identical to the section above.

```bash
# Primary region (creates the Lex bot; Global Resiliency replicates it to paired)
aws cloudformation deploy \
  --template-file cfn/main-template.yaml \
  --stack-name connect-chaos-sample \
  --parameter-overrides \
    ConnectInstanceArn=$PRIMARY_INSTANCE_ARN \
    ConnectInstanceId=$PRIMARY_INSTANCE_ID \
    PrimaryRegion=$PRIMARY_REGION \
    PairedRegion=$PAIRED_REGION \
    TrafficDistributionGroupId=$TDG_ID \
    EnableAutoFailover=true \
    LambdaSubnetIdA=$LAMBDA_SUBNET_A_IAD \
    LambdaSubnetIdB=$LAMBDA_SUBNET_B_IAD \
    LambdaSecurityGroupId=$LAMBDA_SG_IAD \
    LambdaCodeBucket=$LAMBDA_BUCKET_IAD \
    FISExtensionLayerArn=$FIS_LAYER_IAD \
    EnableLexGlobalResiliency=true \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $PRIMARY_REGION

# Read Lex bot IDs from primary stack outputs (Lex GR preserves these in the replica)
LEX_BOT_ID=$(aws cloudformation describe-stacks \
  --stack-name connect-chaos-sample --region $PRIMARY_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text)
LEX_BOT_ALIAS_ID=$(aws cloudformation describe-stacks \
  --stack-name connect-chaos-sample --region $PRIMARY_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='LexBotAliasId'].OutputValue" --output text)

# Paired region (imports the replicated Lex bot — does NOT create a new bot)
aws cloudformation deploy \
  --template-file cfn/main-template.yaml \
  --stack-name connect-chaos-sample \
  --parameter-overrides \
    ConnectInstanceArn=$PAIRED_INSTANCE_ARN \
    ConnectInstanceId=$PAIRED_INSTANCE_ID \
    PrimaryRegion=$PRIMARY_REGION \
    PairedRegion=$PAIRED_REGION \
    TrafficDistributionGroupId=$TDG_ID \
    EnableAutoFailover=true \
    LambdaSubnetIdA=$LAMBDA_SUBNET_A_PDX \
    LambdaSubnetIdB=$LAMBDA_SUBNET_B_PDX \
    LambdaSecurityGroupId=$LAMBDA_SG_PDX \
    LambdaCodeBucket=$LAMBDA_BUCKET_PDX \
    FISExtensionLayerArn=$FIS_LAYER_PDX \
    EnableLexGlobalResiliency=true \
    ReplicatedLexBotId=$LEX_BOT_ID \
    ReplicatedLexBotAliasId=$LEX_BOT_ALIAS_ID \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $PAIRED_REGION
```

> **Note (Tokyo/Osaka pair):** Lex Global Resiliency is not available for `ap-northeast-1`↔`ap-northeast-3`. For that pair, set `EnableLexGlobalResiliency=false` and deploy the Lex bot independently in each region (omit the `ReplicatedLexBot*` parameters), then run `scripts/wire-paired-flow.sh` to point the paired-region contact flow at its independent Lex alias.

### Step 4: Seed DynamoDB with Test Data

```bash
aws dynamodb put-item \
  --table-name ConnectChaosCustomers \
  --item '{"account_id": {"S": "12345"}, "customer_name": {"S": "John Doe"}}' \
  --region us-east-1

aws dynamodb put-item \
  --table-name ConnectChaosConfig \
  --item '{"config_key": {"S": "chaos_flag"}, "enabled": {"BOOL": false}}' \
  --region us-east-1
```

---

## Running Experiments

### Experiment 1: Lambda Failure
```bash
aws fis start-experiment \
  --experiment-template-id $(aws cloudformation describe-stacks \
    --stack-name connect-chaos-sample \
    --query 'Stacks[0].Outputs[?OutputKey==`FISExperiment1Id`].OutputValue' \
    --output text --region us-east-1) \
  --region us-east-1
```

### Experiment 2: DDB Network Disruption
```bash
aws fis start-experiment \
  --experiment-template-id $(aws cloudformation describe-stacks \
    --stack-name connect-chaos-sample \
    --query 'Stacks[0].Outputs[?OutputKey==`FISExperiment2Id`].OutputValue' \
    --output text --region us-east-1) \
  --region us-east-1
```

### Experiment 3: Lex Timeout
```bash
aws fis start-experiment \
  --experiment-template-id $(aws cloudformation describe-stacks \
    --stack-name connect-chaos-sample \
    --query 'Stacks[0].Outputs[?OutputKey==`FISExperiment3Id`].OutputValue' \
    --output text --region us-east-1) \
  --region us-east-1
```

### Experiment 4: Custom Chaos Flag
```bash
# Enable chaos
aws dynamodb put-item \
  --table-name ConnectChaosConfig \
  --item '{"config_key": {"S": "chaos_flag"}, "enabled": {"BOOL": true}}' \
  --region us-east-1

# Disable chaos (recovery)
aws dynamodb put-item \
  --table-name ConnectChaosConfig \
  --item '{"config_key": {"S": "chaos_flag"}, "enabled": {"BOOL": false}}' \
  --region us-east-1
```

---

## Synthetic Traffic Generator (Optional)

The sample includes an **optional** synthetic traffic generator that emits CloudWatch metric data points simulating real Connect call traffic. This lets you:

- Test alarm thresholds without placing actual phone calls
- Validate the failover chain (Composite Alarm → EventBridge → TrafficShift)
- Demo the experiment workflow in environments where telephony isn't configured

### Enabling

Set `EnableTrafficGenerator=true` when deploying:

```bash
--parameter-overrides EnableTrafficGenerator=true
```

This deploys:
- `ConnectChaos-TrafficGenerator-{region}` Lambda
- EventBridge rule (deployed **DISABLED** — enable manually when ready)

### Usage

#### Generate baseline (healthy) traffic
```bash
# One-shot: 10 data points of healthy metrics
aws lambda invoke --function-name ConnectChaos-TrafficGenerator-us-east-1 \
  --payload '{"mode": "healthy", "count": 10}' /dev/stdout

# Continuous: enable the EventBridge schedule (emits every minute)
aws events enable-rule --name ConnectChaos-TrafficGen-Schedule-us-east-1 --region us-east-1
```

#### Simulate a fault (trigger alarms)
```bash
# Simulate Experiment 1: Lambda errors
aws lambda invoke --function-name ConnectChaos-TrafficGenerator-us-east-1 \
  --payload '{"mode": "faulty", "fault_type": "lambda", "count": 10}' /dev/stdout

# Simulate Experiment 2: ContactFlowErrors
aws lambda invoke --function-name ConnectChaos-TrafficGenerator-us-east-1 \
  --payload '{"mode": "faulty", "fault_type": "dynamodb", "count": 10}' /dev/stdout

# Simulate Experiment 3: Lex RuntimeLambdaErrors
aws lambda invoke --function-name ConnectChaos-TrafficGenerator-us-east-1 \
  --payload '{"mode": "faulty", "fault_type": "lex", "count": 10}' /dev/stdout

# Simulate Experiment 4: MissedCalls
aws lambda invoke --function-name ConnectChaos-TrafficGenerator-us-east-1 \
  --payload '{"mode": "faulty", "fault_type": "flow", "count": 10}' /dev/stdout

# Simulate ALL faults at once
aws lambda invoke --function-name ConnectChaos-TrafficGenerator-us-east-1 \
  --payload '{"mode": "faulty", "fault_type": "all", "count": 10}' /dev/stdout
```

### How It Works

The traffic generator uses the CloudWatch `PutMetricData` API to emit metrics in the same namespaces and with the same dimensions as real Connect/Lambda/Lex traffic. CloudWatch alarms cannot distinguish these from real metrics — so the full alarm → failover chain triggers exactly as it would with real calls.

> **⚠️ Note:** Synthetic metrics are indistinguishable from real ones in your CloudWatch dashboard. Disable the schedule and stop invoking the generator when you're done testing to avoid contaminating production metrics.

### Packaging

```bash
cd lambda/
zip traffic_generator.zip traffic_generator.py
aws s3 cp traffic_generator.zip s3://YOUR-BUCKET-NAME/connect-chaos/ --region us-east-1
```

---

## Monitoring

Open the CloudWatch Dashboard: `ConnectChaos-Monitoring-{region}`

The dashboard shows four panels — one per experiment:
1. **Lambda Errors** (AWS/Lambda)
2. **ContactFlowErrors** (AWS/Connect)
3. **RuntimeLambdaErrors** (AWS/Lex)
4. **MissedCalls** (AWS/Connect)

Plus a composite alarm status widget showing overall health.

---

## Cost

This sample uses the following services which incur charges:

| Service | Cost Driver |
|---------|-------------|
| Amazon Connect | Per-minute telephony + daily active use charges (for testing) |
| AWS FIS | Per experiment-minute (~$0.10/action-minute) |
| Lambda | Invocations + duration (negligible for testing) |
| DynamoDB | On-demand R/W units (negligible for testing) |
| CloudWatch | Alarms ($0.10/alarm/month × 5) + Dashboard ($3/month) |
| Lex V2 | Per voice/text request during testing |
| S3 | FIS config storage (< $0.01/month) |

**Estimated cost for running all 4 experiments once:** < $5 (excluding telephony charges for test calls).

**Ongoing retention cost** (if stacks remain deployed between experiments): ~$80–120/month across both regions (primarily CloudWatch alarms, dashboards, Lambda provisioned concurrency if enabled, and DynamoDB on-demand capacity).

Run `cleanup` after testing to avoid ongoing charges.

---

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

### Important Considerations

- **This is a sample for testing/demonstration only.** Do NOT run FIS experiments against production contact centers without thorough planning and blast-radius controls.
- **FIS stop conditions** are configured on all experiments — if the composite alarm fires, experiments auto-stop.
- **IAM roles** are scoped to the minimum required permissions. Review them before deploying.
- **VPC Lambda** is used for network-level experiments (Experiment 2). Ensure your security group allows outbound access to DynamoDB and CloudWatch endpoints.
- **FIS extension layer** has access to S3 configuration — the S3 bucket is restricted to the FIS execution role and Lambda execution role only.

---

## Cleanup

> **Important:** S3 buckets created by this stack (the FIS config bucket, named `connect-chaos-fis-${ACCOUNT}-${REGION}-${STACK}`) must be **emptied first** — CloudFormation cannot delete a non-empty bucket and the stack will fail with `DELETE_FAILED`.

```bash
# 1. Empty the FIS config buckets in BOTH regions
PRIMARY_REGION=us-east-1
PAIRED_REGION=us-west-2
ACCT=$(aws sts get-caller-identity --query Account --output text)
STACK=connect-chaos-sample

aws s3 rm "s3://connect-chaos-fis-${ACCT}-${PRIMARY_REGION}-${STACK}/" --recursive --region $PRIMARY_REGION
aws s3 rm "s3://connect-chaos-fis-${ACCT}-${PAIRED_REGION}-${STACK}/" --recursive --region $PAIRED_REGION

# 2. Optional: clear the Lambda code bucket if it was a one-off for this sample
# aws s3 rm s3://YOUR-BUCKET-NAME/connect-chaos/ --recursive --region $PRIMARY_REGION

# 3. Delete the stacks/StackSet

# If deployed via StackSet:
aws cloudformation delete-stack-instances \
  --stack-set-name connect-chaos-sample \
  --accounts $ACCT \
  --regions $PRIMARY_REGION $PAIRED_REGION \
  --no-retain-stacks

aws cloudformation delete-stack-set \
  --stack-set-name connect-chaos-sample

# If deployed individually (delete paired BEFORE primary):
aws cloudformation delete-stack --stack-name connect-chaos-sample --region $PAIRED_REGION
aws cloudformation wait stack-delete-complete --stack-name connect-chaos-sample --region $PAIRED_REGION
aws cloudformation delete-stack --stack-name connect-chaos-sample --region $PRIMARY_REGION
```

> **Note:** Delete the paired region stack first, then primary. DynamoDB Global Tables must be deleted from the region where they were created (primary). If you set `EnableLexGlobalResiliency=true`, the Lex GR replica is deleted automatically when the primary bot is deleted.

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| One metric per experiment | Each component's failure is independently observable — no duplicate/cascading alarm noise |
| FIS native actions only (Exp 1–3) | No custom chaos libraries or Lambda extensions needed beyond the AWS FIS layer |
| Custom logic for Exp 4 only | Contact flow failures cannot be injected by FIS directly — DDB flag is simplest workaround |
| Composite Alarm → EventBridge → Lambda | Clean, event-driven failover — no polling |
| TrafficShift Lambda in BOTH regions | Each region can independently detect failure and shift traffic away from itself |
| ACGR auto-replicates flows | No need to deploy contact flows separately to paired region |
| DDB Global Table for chaos config | Chaos flag propagates to paired region automatically |
| Lex Global Resiliency as default | Lex GR replicates the bot from primary to paired region (IAD↔PDX, LDN↔FRA). For Tokyo↔Osaka (not supported by Lex GR), the bot deploys independently per region. |
| StackSet deployment model | Single template, parallel deployment to both regions — no custom cross-region orchestration |

---

## `contact-flows/` Directory

The `contact-flows/` directory contains **reference copies** of the Contact Flow JSON for readability. The actual flows are deployed inline in the CloudFormation template (`AWS::Connect::ContactFlow` resources). These reference files are not used during deployment.

---

## `scripts/` Directory

| Script | When to run |
|---|---|
| `scripts/wire-paired-flow.sh` | Only when `EnableLexGlobalResiliency=false` (currently `ap-northeast-1` ↔ `ap-northeast-3`). Rewrites the paired-region copies of the contact flows to reference the paired-region Lex alias. Run after both stacks reach `CREATE_COMPLETE`. |

```bash
./scripts/wire-paired-flow.sh \
  --stack-name connect-chaos-sample \
  --primary-region ap-northeast-1 \
  --paired-region ap-northeast-3
```

---

## Tooling

### `make` targets

A `Makefile` is provided to simplify the package + upload + deploy cycle:

```bash
make package                                    # zip all Lambdas
make upload BUCKET=my-bucket REGION=us-east-1   # upload to S3 (correct prefix)
make deploy STACK=connect-chaos-sample REGION=us-east-1 \
  CONNECT_INSTANCE_ARN=... CONNECT_INSTANCE_ID=... \
  LAMBDA_SUBNET_A=subnet-aaa LAMBDA_SUBNET_B=subnet-bbb \
  LAMBDA_SG=sg-ccc TDG_ID=tdg-xyz \
  FIS_LAYER=arn:aws:lambda:us-east-1:...:layer:aws-fis-extension:1 \
  CODE_BUCKET=my-bucket
make lint                                       # run cfn-lint, bash -n, py_compile
make clean
```

### CI

A GitHub Actions workflow at `.github/workflows/lint.yml` runs `cfn-lint`, bash syntax checks, Python compile checks, and JSON parse checks on every push/PR.

### Integration testing

A `.taskcat.yml` is provided for integration-testing across both regions. It expects prerequisite resource IDs (Connect instance ARN, VPC subnets, FIS layer ARN, etc.) to be stored as SSM parameters under `/taskcat/...`. taskcat will not provision these prerequisites — they must exist in the target sandbox account first. See [taskcat docs](https://github.com/aws-ia/taskcat) for details.

---

## License

This sample is provided under the MIT-0 license. See [LICENSE](LICENSE) file.
