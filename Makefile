# Makefile for the Amazon Connect chaos engineering sample.
#
# Packages the Lambda code, stages it in S3, deploys the CloudFormation template to both
# Regions of an ACGR pair, then seeds, verifies and resets. README.md covers installation and
# RUNBOOK.md covers testing; `make help` lists every target.
#
# Usage:
#   make deploy-pair STACK=connect-chaos-sample SOURCE_REGION=us-east-1 REPLICA_REGION=us-west-2 \
#     SOURCE_INSTANCE_ARN=... REPLICA_INSTANCE_ARN=... TDG_ID=...
#   make post-deploy STACK=... SOURCE_REGION=... REPLICA_REGION=... INSTANCE_ID=... TDG_ID=...
#   make verify      STACK=... SOURCE_REGION=... REPLICA_REGION=... TDG_ID=...
#   make reset       STACK=... SOURCE_REGION=... REPLICA_REGION=... TDG_ID=...
#   make deploy      STACK=... REGION=... CONNECT_INSTANCE_ARN=... CONNECT_INSTANCE_ID=... TDG_ID=...
#
#   make package                           # zip all Lambda functions
#   make lint                              # cfn-lint, py_compile, JSON, flow drift, secrets scan
#   make clean                             # remove built zip artifacts

LAMBDA_DIR := lambda
BUILD_DIR  := build
TEMPLATE   := cfn/main-template.yaml

LAMBDAS := lex_fulfillment_handler traffic_shift_handler traffic_generator call_logger account_lookup

# Content hash of the handler SOURCES. Goes into the S3 key of every function so that a code
# change necessarily changes Code.S3Key and CloudFormation updates the function. Hashing the
# sources, not the zips: zip archives embed timestamps, so hashing them would change the key
# on every build even with identical code.
LAMBDA_CODE_VERSION := $(shell cat $(LAMBDA_DIR)/*.py | shasum | cut -c1-12)
ZIPS    := $(addprefix $(BUILD_DIR)/,$(addsuffix .zip,$(LAMBDAS)))

.PHONY: all package upload deploy clean lint flows help history-scan

all: package

help:
	@echo "Targets: package, bucket, bootstrap, deploy, deploy-pair, post-deploy, verify, reset, lint, flows, clean, help"
	@grep -E '^# {2,}make' Makefile | sed 's/^# //'

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Build a single zip per Lambda. We zip from inside the lambda/ dir so the
# handler files land at the root of the zip (matching the CFN handler config).
$(BUILD_DIR)/%.zip: $(LAMBDA_DIR)/%.py | $(BUILD_DIR)
	cd $(LAMBDA_DIR) && zip -j ../$@ $*.py

package: $(ZIPS)
	@echo "Built: $(ZIPS)"

# Bucket used both for the Lambda zips and for staging the template.
# Derived so a fresh clone needs no manual setup. Override with BUCKET=...
# The account id is only needed to name the bucket, so it is looked up only for the targets
# that use one. `make lint`, `make help` and `make package` then need no AWS credentials.
ifneq ($(filter bucket upload bootstrap deploy,$(MAKECMDGOALS)),)
ACCOUNT   := $(shell aws sts get-caller-identity --query Account --output text)
endif
BUCKET    ?= connect-chaos-code-$(ACCOUNT)-$(REGION)

.PHONY: bucket bootstrap deploy-pair

# Create the bucket if it does not already exist. Safe to re-run.
bucket:
	@if [ -z "$(REGION)" ]; then echo "Usage: make bucket REGION=<aws-region>"; exit 2; fi
	@if aws s3api head-bucket --bucket $(BUCKET) --region $(REGION) 2>/dev/null; then \
	  echo "bucket s3://$(BUCKET) already exists"; \
	else \
	  echo "creating s3://$(BUCKET) in $(REGION)"; \
	  if [ "$(REGION)" = "us-east-1" ]; then \
	    aws s3api create-bucket --bucket $(BUCKET) --region $(REGION); \
	  else \
	    aws s3api create-bucket --bucket $(BUCKET) --region $(REGION) \
	      --create-bucket-configuration LocationConstraint=$(REGION); \
	  fi; \
	  aws s3api put-public-access-block --bucket $(BUCKET) --region $(REGION) \
	    --public-access-block-configuration \
	      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true; \
	fi

upload: package bucket
	aws s3 cp $(BUILD_DIR)/lex_fulfillment_handler.zip s3://$(BUCKET)/connect-chaos/$(LAMBDA_CODE_VERSION)/ --region $(REGION)
	aws s3 cp $(BUILD_DIR)/traffic_shift_handler.zip   s3://$(BUCKET)/connect-chaos/$(LAMBDA_CODE_VERSION)/ --region $(REGION)
	aws s3 cp $(BUILD_DIR)/traffic_generator.zip       s3://$(BUCKET)/connect-chaos/$(LAMBDA_CODE_VERSION)/ --region $(REGION)
	aws s3 cp $(BUILD_DIR)/call_logger.zip             s3://$(BUCKET)/connect-chaos/$(LAMBDA_CODE_VERSION)/ --region $(REGION)
	aws s3 cp $(BUILD_DIR)/account_lookup.zip           s3://$(BUCKET)/connect-chaos/$(LAMBDA_CODE_VERSION)/ --region $(REGION)

# One-shot preparation for a region: bucket + zips uploaded.
bootstrap: upload
	@echo "bootstrap complete for $(REGION); code bucket = s3://$(BUCKET)"

# Deploy one region. Only 4 values are genuinely required now.
#   CreateVpc=true (default) builds the VPC, subnets and free DDB/S3 gateway endpoints.
#   FISExtensionLayerArn auto-resolves from the AWS public SSM parameter.
# --s3-bucket is REQUIRED: the template is ~100 KB and CloudFormation's inline
# TemplateBody limit is 51,200 bytes.
deploy: bootstrap
	@if [ -z "$(STACK)" ] || [ -z "$(REGION)" ] || [ -z "$(CONNECT_INSTANCE_ARN)" ] \
	   || [ -z "$(CONNECT_INSTANCE_ID)" ] || [ -z "$(TDG_ID)" ]; then \
	  echo "Required: STACK, REGION, CONNECT_INSTANCE_ARN, CONNECT_INSTANCE_ID, TDG_ID"; \
	  echo "Optional: SOURCE_REGION REPLICA_REGION CREATE_VPC ENABLE_AUTO_REGION_SWITCH"; \
	  echo "          ENABLE_LEX_GR ENABLE_TRAFFIC_GEN DASHBOARD_TYPE"; \
	  echo "          CONTACT_FLOW_ERRORS_THRESHOLD REGION_SWITCH_DELAY_SECONDS"; \
	  echo "          REPLICATED_LEX_BOT_ID REPLICATED_LEX_BOT_ALIAS_ID"; \
	  echo "          LAMBDA_SUBNET_A LAMBDA_SUBNET_B LAMBDA_SG  (only if CREATE_VPC=false)"; \
	  exit 2; \
	fi
	aws cloudformation deploy \
	  --template-file $(TEMPLATE) \
	  --stack-name $(STACK) \
	  --region $(REGION) \
	  --s3-bucket $(BUCKET) \
	  --s3-prefix cfn-staging \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --parameter-overrides \
	    ConnectInstanceArn=$(CONNECT_INSTANCE_ARN) \
	    ConnectInstanceId=$(CONNECT_INSTANCE_ID) \
	    SourceRegion=$(or $(SOURCE_REGION),us-east-1) \
	    ReplicaRegion=$(or $(REPLICA_REGION),us-west-2) \
	    TrafficDistributionGroupId=$(TDG_ID) \
	    LambdaCodeBucket=$(BUCKET) \
	    CreateVpc=$(or $(CREATE_VPC),true) \
	    LambdaSubnetIdA=$(LAMBDA_SUBNET_A) \
	    LambdaSubnetIdB=$(LAMBDA_SUBNET_B) \
	    LambdaSecurityGroupId=$(LAMBDA_SG) \
	    EnableAutoRegionSwitch=$(or $(ENABLE_AUTO_REGION_SWITCH),true) \
	    EnableLexGlobalResiliency=$(or $(ENABLE_LEX_GR),true) \
	    EnableTrafficGenerator=$(or $(ENABLE_TRAFFIC_GEN),true) \
	    DashboardType=$(or $(DASHBOARD_TYPE),regional) \
	    ContactFlowErrorsThreshold=$(or $(CONTACT_FLOW_ERRORS_THRESHOLD),0) \
	    LambdaCodeVersion=$(LAMBDA_CODE_VERSION) \
	    RegionSwitchDelaySeconds=$(or $(REGION_SWITCH_DELAY_SECONDS),120) \
	    ReplicatedLexBotId=$(REPLICATED_LEX_BOT_ID) \
	    ReplicatedLexBotAliasId=$(REPLICATED_LEX_BOT_ALIAS_ID)

# Deploy BOTH regions in the correct order, handing the Lex GR bot/alias IDs from the
# source stack to the replica stack. Leaving both stacks standing is what proves the
# replica Region can actually SERVE a call after traffic transition.
#
# This runs as a SINGLE shell script on purpose. Make expands $$(shell ...) and $$(eval ...)
# at parse time, which would read the Lex ids before the source stack exists and pass empty
# values to the replica Region - producing alarms with empty dimensions. Using shell variables
# keeps the lookup at execution time.
deploy-pair:
	@set -e; \
	if [ -z "$(STACK)" ] || [ -z "$(SOURCE_REGION)" ] || [ -z "$(REPLICA_REGION)" ] \
	   || [ -z "$(SOURCE_INSTANCE_ARN)" ] || [ -z "$(REPLICA_INSTANCE_ARN)" ] \
	   || [ -z "$(TDG_ID)" ]; then \
	  echo "Required: STACK SOURCE_REGION REPLICA_REGION SOURCE_INSTANCE_ARN"; \
	  echo "          REPLICA_INSTANCE_ARN TDG_ID"; exit 2; \
	fi; \
	SOURCE_ID=$$(echo "$(SOURCE_INSTANCE_ARN)" | awk -F/ '{print $$NF}'); \
	REPLICA_ID=$$(echo "$(REPLICA_INSTANCE_ARN)"  | awk -F/ '{print $$NF}'); \
	echo "=== 1/2 source Region $(SOURCE_REGION) (instance $$SOURCE_ID) ==="; \
	$(MAKE) deploy STACK=$(STACK) REGION=$(SOURCE_REGION) \
	  CONNECT_INSTANCE_ARN=$(SOURCE_INSTANCE_ARN) CONNECT_INSTANCE_ID=$$SOURCE_ID \
	  SOURCE_REGION=$(SOURCE_REGION) REPLICA_REGION=$(REPLICA_REGION) TDG_ID=$(TDG_ID); \
	echo "=== reading Lex GR ids from the source stack ==="; \
	BOT=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(SOURCE_REGION) \
	        --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text); \
	ALIAS=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(SOURCE_REGION) \
	        --query "Stacks[0].Outputs[?OutputKey=='LexBotAliasId'].OutputValue" --output text); \
	echo "    bot=$$BOT alias=$$ALIAS"; \
	if [ -z "$$BOT" ] || [ "$$BOT" = "None" ] || [ -z "$$ALIAS" ] || [ "$$ALIAS" = "None" ]; then \
	  echo "ERROR: could not read LexBotId/LexBotAliasId from the source stack."; \
	  echo "       The replica Region needs them when EnableLexGlobalResiliency=true."; \
	  exit 1; \
	fi; \
	echo "=== 2/2 replica Region $(REPLICA_REGION) (instance $$REPLICA_ID) ==="; \
	$(MAKE) deploy STACK=$(STACK) REGION=$(REPLICA_REGION) \
	  CONNECT_INSTANCE_ARN=$(REPLICA_INSTANCE_ARN) CONNECT_INSTANCE_ID=$$REPLICA_ID \
	  SOURCE_REGION=$(SOURCE_REGION) REPLICA_REGION=$(REPLICA_REGION) TDG_ID=$(TDG_ID) \
	  REPLICATED_LEX_BOT_ID=$$BOT REPLICATED_LEX_BOT_ALIAS_ID=$$ALIAS; \
	echo "=== both regions deployed ==="; \
	for R in $(SOURCE_REGION) $(REPLICA_REGION); do \
	  printf "%-12s " $$R; \
	  aws cloudformation describe-stacks --stack-name $(STACK) --region $$R \
	    --query "Stacks[0].StackStatus" --output text; \
	done

# ─────────────────────────────────────────────────────────────────────────────
# post-deploy: the three steps CloudFormation cannot do for you.
#
# The template cannot own the phone-number -> contact-flow association: the number
# belongs to the Traffic Distribution Group, not to the stack, and there is no
# CloudFormation resource for that link. Skipping it is a SILENT failure - every
# stack resource reports CREATE_COMPLETE, every alarm reports OK, and calls never
# reach the flow.
#
# Idempotent: safe to re-run.
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: post-deploy verify reset

post-deploy:
	@set -e; \
	if [ -z "$(STACK)" ] || [ -z "$(SOURCE_REGION)" ] || [ -z "$(REPLICA_REGION)" ] \
	   || [ -z "$(INSTANCE_ID)" ] || [ -z "$(TDG_ID)" ]; then \
	  echo "Required: STACK SOURCE_REGION REPLICA_REGION INSTANCE_ID TDG_ID"; \
	  echo "Optional: PHONE_NUMBER_ID (otherwise resolved from the TDG)"; \
	  exit 2; \
	fi; \
	echo "=== 1/4 seeding DynamoDB ==="; \
	aws dynamodb put-item --table-name $(STACK)-Customers --region $(SOURCE_REGION) \
	  --item '{"account_id":{"S":"12345"},"customer_name":{"S":"John Doe"}}'; \
	aws dynamodb put-item --table-name $(STACK)-Config --region $(SOURCE_REGION) \
	  --item '{"config_key":{"S":"chaos_flag#$(SOURCE_REGION)"},"enabled":{"BOOL":false}}'; \
	aws dynamodb put-item --table-name $(STACK)-Config --region $(SOURCE_REGION) \
	  --item '{"config_key":{"S":"chaos_flag#$(REPLICA_REGION)"},"enabled":{"BOOL":false}}'; \
	echo "    seeded $(STACK)-Customers (account 12345) and disarmed chaos_flag#<region> for BOTH regions"; \
	echo "=== 2/4 associating the phone number with ConnectChaos-Menu ==="; \
	FLOW=$$(aws connect list-contact-flows --instance-id $(INSTANCE_ID) \
	         --region $(SOURCE_REGION) \
	         --query "ContactFlowSummaryList[?Name=='ConnectChaos-Menu'].Id | [0]" \
	         --output text); \
	if [ -z "$$FLOW" ] || [ "$$FLOW" = "None" ]; then \
	  echo "ERROR: contact flow ConnectChaos-Menu not found in $(SOURCE_REGION)."; \
	  echo "       Did the source stack finish deploying?"; exit 1; \
	fi; \
	echo "    flow ConnectChaos-Menu = $$FLOW"; \
	PN="$(PHONE_NUMBER_ID)"; \
	if [ -z "$$PN" ]; then \
	  echo "    resolving the number attached to TDG $(TDG_ID)..."; \
	  PN=$$(aws connect list-phone-numbers-v2 --region $(SOURCE_REGION) --max-results 100 \
	        --query "ListPhoneNumbersSummaryList[?contains(TargetArn,'$(TDG_ID)')].PhoneNumberId" \
	        --output text); \
	  COUNT=$$(echo $$PN | wc -w | tr -d ' '); \
	  if [ "$$COUNT" = "0" ]; then \
	    echo "ERROR: no phone number is attached to TDG $(TDG_ID)."; \
	    echo "       Claim or port a number to the TDG first (a ported number is needed for real telephony failover)."; exit 1; \
	  fi; \
	  if [ "$$COUNT" != "1" ]; then \
	    echo "ERROR: $$COUNT numbers are attached to that TDG: $$PN"; \
	    echo "       Re-run with PHONE_NUMBER_ID=<one of them>"; exit 1; \
	  fi; \
	fi; \
	echo "    phone-number-id = $$PN"; \
	aws connect associate-phone-number-contact-flow --phone-number-id $$PN \
	  --instance-id $(INSTANCE_ID) --contact-flow-id $$FLOW --region $(SOURCE_REGION); \
	echo "    associated"; \
	echo "=== 3/4 wiring Lex in the REPLICA region ==="; \
	GR=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(SOURCE_REGION) \
	        --query "Stacks[0].Parameters[?ParameterKey=='EnableLexGlobalResiliency'].ParameterValue|[0]" --output text); \
	BOT=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(SOURCE_REGION) \
	        --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue|[0]" --output text); \
	ALIAS=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(SOURCE_REGION) \
	        --query "Stacks[0].Outputs[?OutputKey=='LexBotAliasId'].OutputValue|[0]" --output text); \
	if [ "$$GR" = "false" ]; then \
	  echo "    the stack was deployed with EnableLexGlobalResiliency=false: there is no Lex replica to wire; skipping"; \
	elif [ -z "$$BOT" ] || [ "$$BOT" = "None" ]; then \
	  echo "ERROR: LexBotId output not found on stack $(STACK) in $(SOURCE_REGION); cannot wire Lex."; exit 1; \
	else \
	  echo "    bot=$$BOT alias=$$ALIAS"; \
	  R=$$(aws lexv2-models list-bot-replicas --bot-id $$BOT --region $(SOURCE_REGION) \
	        --query "botReplicaSummaries[?replicaRegion=='$(REPLICA_REGION)'].botReplicaStatus|[0]" \
	        --output text 2>/dev/null); \
	  if [ "$$R" != "Enabled" ]; then \
	    echo "    bot replica in $(REPLICA_REGION) is '$$R' - creating it"; \
	    aws lexv2-models create-bot-replica --bot-id $$BOT --replica-region $(REPLICA_REGION) \
	      --region $(SOURCE_REGION) >/dev/null || true; \
	  fi; \
	  echo "    waiting for the ALIAS replica to become Available (the flow's \$$.AwsRegion ARN resolves to the ALIAS, not the bot)"; \
	  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
	    A=$$(aws lexv2-models list-bot-alias-replicas --bot-id $$BOT --replica-region $(REPLICA_REGION) \
	          --region $(SOURCE_REGION) \
	          --query "botAliasReplicaSummaries[?botAliasId=='$$ALIAS'].botAliasReplicationStatus|[0]" \
	          --output text 2>/dev/null); \
	    echo "      attempt $$i: alias replica = $$A"; \
	    [ "$$A" = "Available" ] && break; sleep 15; \
	  done; \
	  if [ "$$A" != "Available" ]; then \
	    echo "ERROR: alias replica never became Available; the replica Region cannot serve a call."; exit 1; \
	  fi; \
	  echo "    associating the replicated alias with the REPLICA Connect instance"; \
	  ARN="arn:aws:lex:$(REPLICA_REGION):$$(aws sts get-caller-identity --query Account --output text):bot-alias/$$BOT/$$ALIAS"; \
	  OUT=$$(aws connect associate-bot --instance-id $(INSTANCE_ID) --region $(REPLICA_REGION) \
	    --lex-v2-bot AliasArn=$$ARN 2>&1) \
	    && echo "    associated $$ARN" \
	    || case "$$OUT" in \
	         *ResourceConflictException*) echo "    already associated - continuing";; \
	         *) echo "ERROR: associate-bot failed in $(REPLICA_REGION):"; echo "$$OUT"; exit 1;; \
	       esac; \
	fi; \
	echo "=== 4/4 resetting traffic to 100% source / 0% replica ==="; \
	aws connect update-traffic-distribution --id $(TDG_ID) --region $(SOURCE_REGION) \
	  --telephony-config '{"Distributions":[{"Region":"$(SOURCE_REGION)","Percentage":100},{"Region":"$(REPLICA_REGION)","Percentage":0}]}'; \
	aws connect get-traffic-distribution --id $(TDG_ID) --region $(SOURCE_REGION) \
	  --query "TelephonyConfig.Distributions[].[Region,Percentage]" --output text; \
	echo "=== post-deploy complete - run 'make verify' next ==="

# ─────────────────────────────────────────────────────────────────────────────
# reset: return to a clean pre-experiment state. RUNBOOK Step R, as a target -
# it is required between every experiment.
#   make reset SOURCE_REGION=.. REPLICA_REGION=.. TDG_ID=.. STACK=..
# ─────────────────────────────────────────────────────────────────────────────
reset:
	@set -e; \
	if [ -z "$(STACK)" ] || [ -z "$(SOURCE_REGION)" ] || [ -z "$(REPLICA_REGION)" ] \
	   || [ -z "$(TDG_ID)" ]; then \
	  echo "Required: STACK SOURCE_REGION REPLICA_REGION TDG_ID"; exit 2; \
	fi; \
	echo "=== 1/4 stopping any running experiments ==="; \
	for R in $(SOURCE_REGION) $(REPLICA_REGION); do \
	  for E in $$(aws fis list-experiments --region $$R \
	              --query "experiments[?state.status=='running'].id" --output text); do \
	    echo "    stopping $$E in $$R"; \
	    aws fis stop-experiment --id $$E --region $$R >/dev/null; \
	  done; \
	done; \
	echo "=== 2/4 restoring 100% source / 0% replica ==="; \
	aws connect update-traffic-distribution --id $(TDG_ID) --region $(SOURCE_REGION) \
	  --telephony-config '{"Distributions":[{"Region":"$(SOURCE_REGION)","Percentage":100},{"Region":"$(REPLICA_REGION)","Percentage":0}]}'; \
	aws connect get-traffic-distribution --id $(TDG_ID) --region $(SOURCE_REGION) \
	  --query "TelephonyConfig.Distributions[].[Region,Percentage]" --output text; \
	echo "=== 3/4 disarming the Exp 4 chaos flag ==="; \
	aws dynamodb put-item --table-name $(STACK)-Config --region $(SOURCE_REGION) \
	  --item '{"config_key":{"S":"chaos_flag#$(SOURCE_REGION)"},"enabled":{"BOOL":false}}'; \
	aws dynamodb put-item --table-name $(STACK)-Config --region $(SOURCE_REGION) \
	  --item '{"config_key":{"S":"chaos_flag#$(REPLICA_REGION)"},"enabled":{"BOOL":false}}'; \
	echo "    chaos_flag#$(SOURCE_REGION) and chaos_flag#$(REPLICA_REGION) = false"; \
	echo "=== 4/4 waiting for alarms to clear ==="; \
	for i in $$(seq 1 30); do \
	  BAD=""; \
	  for R in $(SOURCE_REGION) $(REPLICA_REGION); do \
	    MA=$$(aws cloudwatch describe-alarms --region $$R --alarm-name-prefix ConnectChaos- \
	          --query "MetricAlarms[?StateValue=='ALARM'].AlarmName" --output text); \
	    CA=$$(aws cloudwatch describe-alarms --region $$R --alarm-name-prefix ConnectChaos- \
	          --alarm-types CompositeAlarm \
	          --query "CompositeAlarms[?StateValue=='ALARM'].AlarmName" --output text); \
	    BAD="$$BAD $$MA $$CA"; \
	  done; \
	  BAD=$$(echo $$BAD | sed 's/None//g' | xargs); \
	  if [ -z "$$BAD" ]; then echo "    all alarms clear"; break; fi; \
	  echo "      attempt $$i still in ALARM: $$BAD"; sleep 20; \
	done; \
	if [ -n "$$BAD" ]; then \
	  echo "WARNING: alarms still in ALARM. Do NOT start the next experiment yet -"; \
	  echo "         a stop-condition alarm already in ALARM prevents a clean run."; exit 1; \
	fi; \
	echo "=== reset complete ==="

# ─────────────────────────────────────────────────────────────────────────────
# verify: preflight before testing. Reports PASS/FAIL per check.
# The phone number -> flow link is checked with `connect list-flow-associations`
# (VOICE_PHONE_NUMBER). It proves the association exists; only the baseline call
# proves the call is actually answered.
# ─────────────────────────────────────────────────────────────────────────────
verify:
	@set -e; \
	if [ -z "$(STACK)" ] || [ -z "$(SOURCE_REGION)" ] || [ -z "$(REPLICA_REGION)" ] \
	   || [ -z "$(TDG_ID)" ]; then \
	  echo "Required: STACK SOURCE_REGION REPLICA_REGION TDG_ID"; exit 2; \
	fi; \
	FAIL=0; \
	echo "=== stacks ==="; \
	for R in $(SOURCE_REGION) $(REPLICA_REGION); do \
	  S=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $$R \
	       --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo MISSING); \
	  case "$$S" in CREATE_COMPLETE|UPDATE_COMPLETE) echo "  PASS  $$R $$S";; \
	    *) echo "  FAIL  $$R $$S"; FAIL=1;; esac; \
	done; \
	echo "=== Lex: can the replica Region serve a call? ==="; \
	PBOT=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(SOURCE_REGION) \
	       --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text 2>/dev/null); \
	SBOT=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(REPLICA_REGION) \
	       --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text 2>/dev/null); \
	if [ -n "$$SBOT" ] && [ "$$SBOT" != "None" ]; then \
	  echo "    mode: PER-REGION bots (Lex GR off)"; \
	  ST=$$(aws lexv2-models list-bots --region $(REPLICA_REGION) \
	        --query "botSummaries[?botId=='$$SBOT'].botStatus | [0]" --output text 2>/dev/null); \
	  if [ "$$ST" = "Available" ]; then echo "  PASS  replica Region owns bot $$SBOT ($$ST)"; \
	    echo "  NOTE  bot ids differ by design, so the flow's \$$.AwsRegion token is NOT"; \
	    echo "        sufficient - the flows must select the Lex alias per Region. This"; \
	    echo "        sample does not do that (README: Tokyo/Osaka is not supported)."; \
	  else echo "  FAIL  replica bot $$SBOT not Available (got '$$ST')"; FAIL=1; fi; \
	else \
	  echo "    mode: LEX GLOBAL RESILIENCY (same bot id expected in both regions)"; \
	  REPL=$$(aws lexv2-models list-bot-replicas --bot-id $$PBOT --region $(SOURCE_REGION) \
	          --query "length(botReplicaSummaries)" --output text 2>/dev/null || echo 0); \
	  ST=$$(aws lexv2-models list-bots --region $(REPLICA_REGION) \
	        --query "botSummaries[?botId=='$$PBOT'].botStatus | [0]" --output text 2>/dev/null); \
	  if [ "$$ST" = "Available" ]; then echo "  PASS  bot $$PBOT Available in $(REPLICA_REGION) (replicas reported: $$REPL)"; \
	  else \
	    echo "  FAIL  bot $$PBOT is NOT in $(REPLICA_REGION) (status '$$ST', replicas $$REPL)"; \
	    echo "        The replica Region CANNOT serve a call - a traffic transition would move traffic"; \
	    echo "        to a region whose contact flow has no reachable Lex bot."; \
	    echo "        Fix: run 'make post-deploy' (it creates the replica and waits for the"; \
	    echo "             alias replica). Lex GR exists only for us-east-1/us-west-2 and"; \
	    echo "             eu-west-2/eu-central-1."; FAIL=1; \
	  fi; \
	fi; \
	echo "=== replica Region: can it actually INVOKE anything? ==="; \
	ACCT=$$(aws sts get-caller-identity --query Account --output text); \
	IID=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(REPLICA_REGION) \
	       --query "Stacks[0].Parameters[?ParameterKey=='ConnectInstanceId'].ParameterValue|[0]" --output text); \
	if [ -n "$$PBOT" ] && [ "$$PBOT" != "None" ]; then \
	  AR=$$(aws lexv2-models list-bot-alias-replicas --bot-id $$PBOT --replica-region $(REPLICA_REGION) \
	        --region $(SOURCE_REGION) \
	        --query "botAliasReplicaSummaries[?botAliasReplicationStatus=='Available'].botAliasId" \
	        --output text 2>/dev/null); \
	  if [ -n "$$AR" ]; then echo "  PASS  Lex ALIAS replica(s) Available in $(REPLICA_REGION): $$AR"; \
	  else echo "  FAIL  no Lex ALIAS replica Available - the bot replica alone is NOT enough,"; \
	       echo "        the flow's \$$.AwsRegion ARN resolves to the ALIAS"; FAIL=1; fi; \
	fi; \
	B=$$(aws connect list-bots --instance-id $$IID --lex-version V2 --region $(REPLICA_REGION) \
	     --query "LexBots[].LexV2Bot.AliasArn" --output text 2>/dev/null); \
	if [ -n "$$B" ]; then echo "  PASS  replica instance has a Lex alias associated"; \
	else echo "  FAIL  replica instance has NO Lex bot association - its flow cannot reach Lex."; \
	     echo "        LexBotAssociation is source-only by design; run 'make post-deploy'"; FAIL=1; fi; \
	for FN in ConnectChaos-CallLogger ConnectChaos-AccountLookup LexFulfillmentHandler; do \
	  ST=$$(aws lambda get-function --function-name $$FN --region $(REPLICA_REGION) \
	        --query "Configuration.State" --output text 2>/dev/null || echo MISSING); \
	  if [ "$$ST" != "Active" ]; then echo "  FAIL  $$FN in $(REPLICA_REGION): $$ST"; FAIL=1; \
	  else \
	    POL=$$(aws lambda get-policy --function-name $$FN --region $(REPLICA_REGION) \
	           --query Policy --output text 2>/dev/null || echo NONE); \
	    case "$$POL" in *amazonaws.com*) echo "  PASS  $$FN Active with an invoke policy";; \
	      *) echo "  FAIL  $$FN has NO resource policy - nothing may invoke it"; FAIL=1;; esac; \
	  fi; \
	done; \
	for FN in ConnectChaos-CallLogger ConnectChaos-AccountLookup; do \
	  L=$$(aws connect list-lambda-functions --instance-id $$IID --region $(REPLICA_REGION) \
	       --query "LambdaFunctions[?contains(@,'$$FN')]" --output text 2>/dev/null); \
	  if [ -n "$$L" ]; then echo "  PASS  $$FN associated with the replica instance"; \
	  else echo "  FAIL  $$FN NOT associated with the replica instance"; FAIL=1; fi; \
	done; \
	echo "=== flows: region-agnostic ARNs + region announcement, ALL flows, BOTH regions ==="; \
	for R in $(SOURCE_REGION) $(REPLICA_REGION); do \
	  RID=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $$R \
	         --query "Stacks[0].Parameters[?ParameterKey=='ConnectInstanceId'].ParameterValue|[0]" --output text); \
	  for FN in ConnectChaos-Menu ConnectChaos-Exp1-Lambda ConnectChaos-Exp2-DynamoDB \
	            ConnectChaos-Exp3-Latency ConnectChaos-Exp4-Queue; do \
	    FID=$$(aws connect list-contact-flows --instance-id $$RID --region $$R \
	           --query "ContactFlowSummaryList[?Name=='$$FN'].Id|[0]" --output text 2>/dev/null); \
	    if [ -z "$$FID" ] || [ "$$FID" = "None" ]; then \
	      echo "  FAIL  $$R: flow $$FN not found"; FAIL=1; continue; fi; \
	    CT=$$(aws connect describe-contact-flow --instance-id $$RID --contact-flow-id $$FID \
	          --region $$R --query "ContactFlow.Content" --output text 2>/dev/null); \
	    BAD=""; \
	    case "$$CT" in *'arn:aws:lambda:'*) \
	      case "$$CT" in *'arn:aws:lambda:$$.AwsRegion:'*) :;; \
	        *) BAD="$$BAD Lambda-ARN-pinned";; esac;; esac; \
	    case "$$CT" in *'arn:aws:lex:'*) \
	      case "$$CT" in *'arn:aws:lex:$$.AwsRegion:'*) :;; \
	        *) BAD="$$BAD Lex-ARN-pinned";; esac;; esac; \
	    case "$$CT" in *'Connected in region $$.AwsRegion'*) :;; \
	      *) BAD="$$BAD no-region-announcement";; esac; \
	    if [ -z "$$BAD" ]; then echo "  PASS  $$R/$$FN"; \
	    else echo "  FAIL  $$R/$$FN:$$BAD"; FAIL=1; fi; \
	  done; \
	done; \
	echo "=== handlers: do they actually load? (import-time failures are invisible elsewhere) ==="; \
	for R in $(SOURCE_REGION) $(REPLICA_REGION); do \
	  OUT=$$(aws lambda invoke --function-name ConnectChaos-TrafficShiftHandler --region $$R \
	         --cli-binary-format raw-in-base64-out \
	         --payload '{"detail-type":"CloudWatch Alarm State Change","detail":{"state":{"value":"OK"}}}' \
	         /dev/null --query FunctionError --output text 2>/dev/null); \
	  if [ "$$OUT" = "None" ] || [ -z "$$OUT" ]; then \
	    echo "  PASS  $$R: TrafficShiftHandler loads and runs"; \
	  else \
	    echo "  FAIL  $$R: TrafficShiftHandler returned $$OUT - it cannot even import."; \
	    echo "        Almost certainly STALE CODE: CloudFormation does not update a"; \
	    echo "        function whose Code.S3Key is unchanged."; \
	    FAIL=1; \
	  fi; \
	done; \
	echo "=== seed data ==="; \
	C=$$(aws dynamodb get-item --table-name $(STACK)-Customers --region $(SOURCE_REGION) \
	     --key '{"account_id":{"S":"12345"}}' --query "Item.customer_name.S" --output text 2>/dev/null); \
	if [ "$$C" = "None" ] || [ -z "$$C" ]; then echo "  FAIL  customer 12345 missing - run 'make post-deploy'"; FAIL=1; \
	else echo "  PASS  customer 12345 = $$C"; fi; \
	F=$$(aws dynamodb get-item --table-name $(STACK)-Config --region $(SOURCE_REGION) \
	     --key '{"config_key":{"S":"chaos_flag#$(SOURCE_REGION)"}}' --query "Item.enabled.BOOL" --output text 2>/dev/null); \
	if [ "$$F" = "False" ]; then echo "  PASS  chaos_flag = false (healthy)"; \
	elif [ "$$F" = "True" ]; then echo "  FAIL  chaos_flag is TRUE - Exp 4 is still armed"; FAIL=1; \
	else echo "  FAIL  chaos_flag#$(SOURCE_REGION) missing - run 'make post-deploy'"; FAIL=1; fi; \
	FP=$$(aws dynamodb get-item --table-name $(STACK)-Config --region $(REPLICA_REGION) \
	      --key '{"config_key":{"S":"chaos_flag#$(REPLICA_REGION)"}}' --query "Item.enabled.BOOL" --output text 2>/dev/null); \
	if [ "$$FP" = "True" ]; then \
	  echo "  FAIL  chaos_flag#$(REPLICA_REGION) is TRUE - the replica Region is armed too,"; \
	  echo "        so a traffic transition could not recover. Run 'make reset'."; FAIL=1; \
	else echo "  PASS  replica Region flag disarmed (traffic transition can recover)"; fi; \
	echo "=== traffic distribution ==="; \
	P=$$(aws connect get-traffic-distribution --id $(TDG_ID) --region $(SOURCE_REGION) \
	     --query "TelephonyConfig.Distributions[?Region=='$(SOURCE_REGION)'].Percentage | [0]" --output text); \
	if [ "$$P" = "100" ]; then echo "  PASS  $(SOURCE_REGION) at 100%"; \
	else echo "  FAIL  $(SOURCE_REGION) at $$P% - not a clean baseline, run 'make post-deploy'"; FAIL=1; fi; \
	echo "=== alarms (both regions - a stop-condition alarm already in ALARM blocks a clean run) ==="; \
	for R in $(SOURCE_REGION) $(REPLICA_REGION); do \
	  MA=$$(aws cloudwatch describe-alarms --region $$R --alarm-name-prefix ConnectChaos- \
	        --query "MetricAlarms[?StateValue=='ALARM'].AlarmName" --output text); \
	  CA=$$(aws cloudwatch describe-alarms --region $$R --alarm-name-prefix ConnectChaos- \
	        --alarm-types CompositeAlarm \
	        --query "CompositeAlarms[?StateValue=='ALARM'].AlarmName" --output text); \
	  BOTH=$$(echo $$MA $$CA | sed 's/None//g' | xargs); \
	  if [ -z "$$BOTH" ]; then echo "  PASS  $$R: nothing in ALARM"; \
	  else echo "  FAIL  $$R still in ALARM: $$BOTH  (run 'make reset')"; FAIL=1; fi; \
	done; \
	echo "=== phone number ==="; \
	SID=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(SOURCE_REGION) \
	       --query "Stacks[0].Parameters[?ParameterKey=='ConnectInstanceId'].ParameterValue|[0]" --output text); \
	MENU=$$(aws connect list-contact-flows --instance-id $$SID --region $(SOURCE_REGION) \
	        --query "ContactFlowSummaryList[?Name=='ConnectChaos-Menu'].Id|[0]" --output text); \
	PNS=$$(aws connect list-phone-numbers-v2 --region $(SOURCE_REGION) --max-results 100 \
	      --query "ListPhoneNumbersSummaryList[?contains(TargetArn,'$(TDG_ID)')].PhoneNumberId" --output text); \
	if [ -z "$$PNS" ]; then echo "  FAIL  no number attached to TDG $(TDG_ID)"; FAIL=1; \
	elif [ -z "$$MENU" ] || [ "$$MENU" = "None" ]; then \
	  echo "  FAIL  flow ConnectChaos-Menu not found in $(SOURCE_REGION)"; FAIL=1; \
	else \
	  ASSOC=$$(aws connect list-flow-associations --instance-id $$SID --region $(SOURCE_REGION) \
	           --resource-type VOICE_PHONE_NUMBER --output json); \
	  for PN in $$PNS; do \
	    NUM=$$(aws connect list-phone-numbers-v2 --region $(SOURCE_REGION) --max-results 100 \
	           --query "ListPhoneNumbersSummaryList[?PhoneNumberId=='$$PN'].PhoneNumber|[0]" --output text); \
	    FLOWARN=$$(echo "$$ASSOC" | python3 -c "import sys,json; pn=sys.argv[1]; \
print(next((a['FlowId'] for a in json.load(sys.stdin)['FlowAssociationSummaryList'] if a['ResourceId'].endswith('/'+pn)), ''))" $$PN); \
	    case "$$FLOWARN" in \
	      "") echo "  FAIL  $$NUM is not associated with any flow (run 'make post-deploy')"; FAIL=1;; \
	      */contact-flow/$$MENU) echo "  PASS  $$NUM -> ConnectChaos-Menu";; \
	      *) echo "  FAIL  $$NUM is associated with a different flow: $${FLOWARN##*/} (expected ConnectChaos-Menu $$MENU)"; FAIL=1;; \
	    esac; \
	  done; \
	fi; \
	echo; \
	if [ "$$FAIL" = "0" ]; then echo "ALL CHECKS PASSED - ready to test (RUNBOOK Step 3, baseline call)"; \
	else echo "SOME CHECKS FAILED - fix the above before testing"; exit 1; fi


lint:
	# W1030 is expected: ReplicatedLexBot* params are intentionally empty in
	# source-region deploys (only populated in replica-region). Ignore them.
	cfn-lint -i W1030 -- $(TEMPLATE)
	python3 -c "import py_compile; [py_compile.compile(f, doraise=True) for f in ['$(LAMBDA_DIR)/lex_fulfillment_handler.py', '$(LAMBDA_DIR)/traffic_shift_handler.py', '$(LAMBDA_DIR)/traffic_generator.py', '$(LAMBDA_DIR)/call_logger.py', '$(LAMBDA_DIR)/account_lookup.py']]; print('Python: OK')"
	python3 -c "import json,glob; [json.load(open(f)) for f in sorted(glob.glob('contact-flows/*.json'))]; print('JSON: OK')"
	# The reference flows are GENERATED from the template. Fail if they have drifted,
	# rather than shipping reference files that contradict what is deployed.
	python3 scripts/extract-flows.py --check
	# README, RUNBOOK, template and code must agree: parameter table, anchors, resource names,
	# make targets, paths, shell blocks, and which alarm each generator fault type trips.
	python3 scripts/check-docs.py
	# This sample is published: fail if any deployment-specific identifier or
	# credential has crept in. Pattern-based, so it needs no denylist of real values.
	python3 scripts/scan-secrets.py

# Scan every commit on every ref for deployment-specific identifiers. Deleting a file from
# the tree does not remove it from history, so `make lint` alone is not enough before publishing.
history-scan:
	python3 scripts/scan-secrets.py --history

# Regenerate the reference contact-flow JSONs from cfn/main-template.yaml.
flows:
	python3 scripts/extract-flows.py

clean:
	rm -rf $(BUILD_DIR)
