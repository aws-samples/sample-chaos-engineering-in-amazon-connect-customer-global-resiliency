# Makefile for connect-fis-acgr-sample
#
# Convenience targets for packaging Lambda code, uploading to S3, and deploying
# the CloudFormation template. Avoids the manual zip + aws s3 cp dance described
# in README.md.
#
# Usage:
#   make package                           # zip all Lambda functions
#   make upload BUCKET=my-bucket REGION=us-east-1
#   make deploy STACK=connect-chaos-sample REGION=us-east-1 \
#     CONNECT_INSTANCE_ARN=... CONNECT_INSTANCE_ID=... \
#     LAMBDA_SUBNET_A=subnet-aaa LAMBDA_SUBNET_B=subnet-bbb \
#     LAMBDA_SG=sg-ccc TDG_ID=tdg-xyz \
#     FIS_LAYER=arn:aws:lambda:us-east-1:...:layer:aws-fis-extension:1 \
#     CODE_BUCKET=my-bucket
#
#   make clean                             # remove built zip artifacts
#   make lint                              # run cfn-lint and bash -n on scripts

LAMBDA_DIR := lambda
BUILD_DIR  := build
TEMPLATE   := cfn/main-template.yaml

LAMBDAS := lex_fulfillment_handler traffic_shift_handler traffic_generator call_logger
ZIPS    := $(addprefix $(BUILD_DIR)/,$(addsuffix .zip,$(LAMBDAS)))

.PHONY: all package upload deploy clean lint help

all: package

help:
	@echo "Targets: package, bucket, bootstrap, deploy, deploy-pair, post-deploy, verify, lint, clean, help"
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
ACCOUNT   := $(shell aws sts get-caller-identity --query Account --output text)
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
	aws s3 cp $(BUILD_DIR)/lex_fulfillment_handler.zip s3://$(BUCKET)/connect-chaos/ --region $(REGION)
	aws s3 cp $(BUILD_DIR)/traffic_shift_handler.zip   s3://$(BUCKET)/connect-chaos/ --region $(REGION)
	aws s3 cp $(BUILD_DIR)/traffic_generator.zip       s3://$(BUCKET)/connect-chaos/ --region $(REGION)
	aws s3 cp $(BUILD_DIR)/call_logger.zip             s3://$(BUCKET)/connect-chaos/ --region $(REGION)

# One-shot preparation for a region: bucket + zips uploaded.
bootstrap: upload
	@echo "bootstrap complete for $(REGION); code bucket = s3://$(BUCKET)"

# Deploy one region. Only 4 values are genuinely required now.
#   CreateVpc=true (default) builds the VPC, subnets and free DDB/S3 gateway endpoints.
#   FISExtensionLayerArn auto-resolves from the AWS public SSM parameter.
# --s3-bucket is REQUIRED: the template is ~65KB and CloudFormation's inline
# TemplateBody limit is 51,200 bytes.
deploy: bootstrap
	@if [ -z "$(STACK)" ] || [ -z "$(REGION)" ] || [ -z "$(CONNECT_INSTANCE_ARN)" ] \
	   || [ -z "$(CONNECT_INSTANCE_ID)" ] || [ -z "$(TDG_ID)" ]; then \
	  echo "Required: STACK, REGION, CONNECT_INSTANCE_ARN, CONNECT_INSTANCE_ID, TDG_ID"; \
	  echo "Optional: PRIMARY_REGION PAIRED_REGION CREATE_VPC ENABLE_AUTO_FAILOVER"; \
	  echo "          ENABLE_LEX_GR ENABLE_TRAFFIC_GEN DASHBOARD_TYPE"; \
	  echo "          CONTACT_FLOW_ERRORS_THRESHOLD LAMBDA_ERRORS_THRESHOLD"; \
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
	    PrimaryRegion=$(or $(PRIMARY_REGION),us-east-1) \
	    PairedRegion=$(or $(PAIRED_REGION),us-west-2) \
	    TrafficDistributionGroupId=$(TDG_ID) \
	    LambdaCodeBucket=$(BUCKET) \
	    CreateVpc=$(or $(CREATE_VPC),true) \
	    LambdaSubnetIdA=$(LAMBDA_SUBNET_A) \
	    LambdaSubnetIdB=$(LAMBDA_SUBNET_B) \
	    LambdaSecurityGroupId=$(LAMBDA_SG) \
	    EnableAutoFailover=$(or $(ENABLE_AUTO_FAILOVER),true) \
	    EnableLexGlobalResiliency=$(or $(ENABLE_LEX_GR),true) \
	    EnableTrafficGenerator=$(or $(ENABLE_TRAFFIC_GEN),true) \
	    DashboardType=$(or $(DASHBOARD_TYPE),regional) \
	    ContactFlowErrorsThreshold=$(or $(CONTACT_FLOW_ERRORS_THRESHOLD),0) \
	    LambdaErrorsThreshold=$(or $(LAMBDA_ERRORS_THRESHOLD),0) \
	    ReplicatedLexBotId=$(REPLICATED_LEX_BOT_ID) \
	    ReplicatedLexBotAliasId=$(REPLICATED_LEX_BOT_ALIAS_ID)

# Deploy BOTH regions in the correct order, handing the Lex GR bot/alias IDs from the
# primary stack to the paired stack. Leaving both stacks standing is what proves the
# paired region can actually SERVE a call after failover.
#
# This runs as a SINGLE shell script on purpose. Make expands $$(shell ...) and $$(eval ...)
# at parse time, which would read the Lex ids before the primary stack exists and pass empty
# values to the paired region - producing alarms with empty dimensions. Using shell variables
# keeps the lookup at execution time.
deploy-pair:
	@set -e; \
	if [ -z "$(STACK)" ] || [ -z "$(PRIMARY_REGION)" ] || [ -z "$(PAIRED_REGION)" ] \
	   || [ -z "$(PRIMARY_INSTANCE_ARN)" ] || [ -z "$(PAIRED_INSTANCE_ARN)" ] \
	   || [ -z "$(TDG_ID)" ]; then \
	  echo "Required: STACK PRIMARY_REGION PAIRED_REGION PRIMARY_INSTANCE_ARN"; \
	  echo "          PAIRED_INSTANCE_ARN TDG_ID"; exit 2; \
	fi; \
	PRIMARY_ID=$$(echo "$(PRIMARY_INSTANCE_ARN)" | awk -F/ '{print $$NF}'); \
	PAIRED_ID=$$(echo "$(PAIRED_INSTANCE_ARN)"  | awk -F/ '{print $$NF}'); \
	echo "=== 1/2 primary region $(PRIMARY_REGION) (instance $$PRIMARY_ID) ==="; \
	$(MAKE) deploy STACK=$(STACK) REGION=$(PRIMARY_REGION) \
	  CONNECT_INSTANCE_ARN=$(PRIMARY_INSTANCE_ARN) CONNECT_INSTANCE_ID=$$PRIMARY_ID \
	  PRIMARY_REGION=$(PRIMARY_REGION) PAIRED_REGION=$(PAIRED_REGION) TDG_ID=$(TDG_ID); \
	echo "=== reading Lex GR ids from the primary stack ==="; \
	BOT=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(PRIMARY_REGION) \
	        --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text); \
	ALIAS=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(PRIMARY_REGION) \
	        --query "Stacks[0].Outputs[?OutputKey=='LexBotAliasId'].OutputValue" --output text); \
	echo "    bot=$$BOT alias=$$ALIAS"; \
	if [ -z "$$BOT" ] || [ "$$BOT" = "None" ] || [ -z "$$ALIAS" ] || [ "$$ALIAS" = "None" ]; then \
	  echo "ERROR: could not read LexBotId/LexBotAliasId from the primary stack."; \
	  echo "       The paired region needs them when EnableLexGlobalResiliency=true."; \
	  exit 1; \
	fi; \
	echo "=== 2/2 paired region $(PAIRED_REGION) (instance $$PAIRED_ID) ==="; \
	$(MAKE) deploy STACK=$(STACK) REGION=$(PAIRED_REGION) \
	  CONNECT_INSTANCE_ARN=$(PAIRED_INSTANCE_ARN) CONNECT_INSTANCE_ID=$$PAIRED_ID \
	  PRIMARY_REGION=$(PRIMARY_REGION) PAIRED_REGION=$(PAIRED_REGION) TDG_ID=$(TDG_ID) \
	  REPLICATED_LEX_BOT_ID=$$BOT REPLICATED_LEX_BOT_ALIAS_ID=$$ALIAS; \
	echo "=== both regions deployed ==="; \
	for R in $(PRIMARY_REGION) $(PAIRED_REGION); do \
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
.PHONY: post-deploy verify

post-deploy:
	@set -e; \
	if [ -z "$(STACK)" ] || [ -z "$(PRIMARY_REGION)" ] || [ -z "$(PAIRED_REGION)" ] \
	   || [ -z "$(INSTANCE_ID)" ] || [ -z "$(TDG_ID)" ]; then \
	  echo "Required: STACK PRIMARY_REGION PAIRED_REGION INSTANCE_ID TDG_ID"; \
	  echo "Optional: PHONE_NUMBER_ID (otherwise resolved from the TDG)"; \
	  exit 2; \
	fi; \
	echo "=== 1/3 seeding DynamoDB ==="; \
	aws dynamodb put-item --table-name $(STACK)-Customers --region $(PRIMARY_REGION) \
	  --item '{"account_id":{"S":"12345"},"customer_name":{"S":"John Doe"}}'; \
	aws dynamodb put-item --table-name $(STACK)-Config --region $(PRIMARY_REGION) \
	  --item '{"config_key":{"S":"chaos_flag"},"enabled":{"BOOL":false}}'; \
	echo "    seeded $(STACK)-Customers (account 12345) and $(STACK)-Config (chaos_flag=false)"; \
	echo "=== 2/3 associating the phone number with ConnectChaos-MainIVR ==="; \
	FLOW=$$(aws connect list-contact-flows --instance-id $(INSTANCE_ID) \
	         --region $(PRIMARY_REGION) \
	         --query "ContactFlowSummaryList[?Name=='ConnectChaos-MainIVR'].Id | [0]" \
	         --output text); \
	if [ -z "$$FLOW" ] || [ "$$FLOW" = "None" ]; then \
	  echo "ERROR: contact flow ConnectChaos-MainIVR not found in $(PRIMARY_REGION)."; \
	  echo "       Did the primary stack finish deploying?"; exit 1; \
	fi; \
	echo "    flow ConnectChaos-MainIVR = $$FLOW"; \
	PN="$(PHONE_NUMBER_ID)"; \
	if [ -z "$$PN" ]; then \
	  echo "    resolving the number attached to TDG $(TDG_ID)..."; \
	  PN=$$(aws connect list-phone-numbers-v2 --region $(PRIMARY_REGION) --max-results 100 \
	        --query "ListPhoneNumbersSummaryList[?contains(TargetArn,'$(TDG_ID)')].PhoneNumberId" \
	        --output text); \
	  COUNT=$$(echo $$PN | wc -w | tr -d ' '); \
	  if [ "$$COUNT" = "0" ]; then \
	    echo "ERROR: no phone number is attached to TDG $(TDG_ID)."; \
	    echo "       ACGR needs a PORTED number claimed to the TDG."; exit 1; \
	  fi; \
	  if [ "$$COUNT" != "1" ]; then \
	    echo "ERROR: $$COUNT numbers are attached to that TDG: $$PN"; \
	    echo "       Re-run with PHONE_NUMBER_ID=<one of them>"; exit 1; \
	  fi; \
	fi; \
	echo "    phone-number-id = $$PN"; \
	aws connect associate-phone-number-contact-flow --phone-number-id $$PN \
	  --instance-id $(INSTANCE_ID) --contact-flow-id $$FLOW --region $(PRIMARY_REGION); \
	echo "    associated"; \
	echo "=== 3/3 resetting traffic to 100% primary / 0% paired ==="; \
	aws connect update-traffic-distribution --id $(TDG_ID) --region $(PRIMARY_REGION) \
	  --telephony-config '{"Distributions":[{"Region":"$(PRIMARY_REGION)","Percentage":100},{"Region":"$(PAIRED_REGION)","Percentage":0}]}'; \
	aws connect get-traffic-distribution --id $(TDG_ID) --region $(PRIMARY_REGION) \
	  --query "TelephonyConfig.Distributions[].[Region,Percentage]" --output text; \
	echo "=== post-deploy complete - run 'make verify' next ==="

# ─────────────────────────────────────────────────────────────────────────────
# verify: preflight before testing. Reports PASS/FAIL per check.
# Honest limitation: there is no AWS API that returns the contact flow a phone
# number is associated with, so that link cannot be asserted here. `post-deploy`
# sets it; a baseline call is the only real proof.
# ─────────────────────────────────────────────────────────────────────────────
verify:
	@set -e; \
	if [ -z "$(STACK)" ] || [ -z "$(PRIMARY_REGION)" ] || [ -z "$(PAIRED_REGION)" ] \
	   || [ -z "$(TDG_ID)" ]; then \
	  echo "Required: STACK PRIMARY_REGION PAIRED_REGION TDG_ID"; exit 2; \
	fi; \
	FAIL=0; \
	echo "=== stacks ==="; \
	for R in $(PRIMARY_REGION) $(PAIRED_REGION); do \
	  S=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $$R \
	       --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo MISSING); \
	  case "$$S" in CREATE_COMPLETE|UPDATE_COMPLETE) echo "  PASS  $$R $$S";; \
	    *) echo "  FAIL  $$R $$S"; FAIL=1;; esac; \
	done; \
	echo "=== Lex: can the paired region serve a call? ==="; \
	PBOT=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(PRIMARY_REGION) \
	       --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text 2>/dev/null); \
	SBOT=$$(aws cloudformation describe-stacks --stack-name $(STACK) --region $(PAIRED_REGION) \
	       --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text 2>/dev/null); \
	if [ -n "$$SBOT" ] && [ "$$SBOT" != "None" ]; then \
	  echo "    mode: PER-REGION bots (Lex GR off)"; \
	  ST=$$(aws lexv2-models list-bots --region $(PAIRED_REGION) \
	        --query "botSummaries[?botId=='$$SBOT'].botStatus | [0]" --output text 2>/dev/null); \
	  if [ "$$ST" = "Available" ]; then echo "  PASS  paired region owns bot $$SBOT ($$ST)"; \
	    echo "  NOTE  bot ids differ by design, so the flow's \$$.AwsRegion token is NOT"; \
	    echo "        sufficient - scripts/wire-paired-flow.sh must have been run"; \
	  else echo "  FAIL  paired bot $$SBOT not Available (got '$$ST')"; FAIL=1; fi; \
	else \
	  echo "    mode: LEX GLOBAL RESILIENCY (same bot id expected in both regions)"; \
	  REPL=$$(aws lexv2-models list-bot-replicas --bot-id $$PBOT --region $(PRIMARY_REGION) \
	          --query "length(botReplicaSummaries)" --output text 2>/dev/null || echo 0); \
	  ST=$$(aws lexv2-models list-bots --region $(PAIRED_REGION) \
	        --query "botSummaries[?botId=='$$PBOT'].botStatus | [0]" --output text 2>/dev/null); \
	  if [ "$$ST" = "Available" ]; then echo "  PASS  bot $$PBOT Available in $(PAIRED_REGION) (replicas reported: $$REPL)"; \
	  else \
	    echo "  FAIL  bot $$PBOT is NOT in $(PAIRED_REGION) (status '$$ST', replicas $$REPL)"; \
	    echo "        The paired region CANNOT serve a call - a failover would move traffic"; \
	    echo "        to a region whose contact flow has no reachable Lex bot."; \
	    echo "        Fix: redeploy both regions with ENABLE_LEX_GR=false and then run"; \
	    echo "             scripts/wire-paired-flow.sh"; FAIL=1; \
	  fi; \
	fi; \
	echo "=== seed data ==="; \
	C=$$(aws dynamodb get-item --table-name $(STACK)-Customers --region $(PRIMARY_REGION) \
	     --key '{"account_id":{"S":"12345"}}' --query "Item.customer_name.S" --output text 2>/dev/null); \
	if [ "$$C" = "None" ] || [ -z "$$C" ]; then echo "  FAIL  customer 12345 missing - run 'make post-deploy'"; FAIL=1; \
	else echo "  PASS  customer 12345 = $$C"; fi; \
	F=$$(aws dynamodb get-item --table-name $(STACK)-Config --region $(PRIMARY_REGION) \
	     --key '{"config_key":{"S":"chaos_flag"}}' --query "Item.enabled.BOOL" --output text 2>/dev/null); \
	if [ "$$F" = "False" ]; then echo "  PASS  chaos_flag = false (healthy)"; \
	elif [ "$$F" = "True" ]; then echo "  FAIL  chaos_flag is TRUE - Exp 4 is still armed"; FAIL=1; \
	else echo "  FAIL  chaos_flag missing - run 'make post-deploy'"; FAIL=1; fi; \
	echo "=== traffic distribution ==="; \
	P=$$(aws connect get-traffic-distribution --id $(TDG_ID) --region $(PRIMARY_REGION) \
	     --query "TelephonyConfig.Distributions[?Region=='$(PRIMARY_REGION)'].Percentage | [0]" --output text); \
	if [ "$$P" = "100" ]; then echo "  PASS  $(PRIMARY_REGION) at 100%"; \
	else echo "  FAIL  $(PRIMARY_REGION) at $$P% - not a clean baseline, run 'make post-deploy'"; FAIL=1; fi; \
	echo "=== alarms ==="; \
	A=$$(aws cloudwatch describe-alarms --region $(PRIMARY_REGION) --alarm-name-prefix ConnectChaos- \
	     --query "MetricAlarms[?StateValue=='ALARM'].AlarmName" --output text); \
	if [ -z "$$A" ]; then echo "  PASS  no component alarm in ALARM"; \
	else echo "  FAIL  still in ALARM: $$A"; FAIL=1; fi; \
	echo "=== phone number ==="; \
	N=$$(aws connect list-phone-numbers-v2 --region $(PRIMARY_REGION) --max-results 100 \
	     --query "ListPhoneNumbersSummaryList[?contains(TargetArn,'$(TDG_ID)')].PhoneNumber" --output text); \
	if [ -z "$$N" ]; then echo "  FAIL  no number attached to TDG $(TDG_ID)"; FAIL=1; \
	else echo "  PASS  number(s) on the TDG: $$N"; \
	     echo "  NOTE  AWS exposes no API for the number -> contact flow link, so that"; \
	     echo "        cannot be asserted here. 'make post-deploy' sets it; the baseline"; \
	     echo "        call is the only real proof."; fi; \
	echo; \
	if [ "$$FAIL" = "0" ]; then echo "ALL CHECKS PASSED - ready to test (RUNBOOK step 3a)"; \
	else echo "SOME CHECKS FAILED - fix the above before testing"; exit 1; fi


lint:
	# W1030 is expected: ReplicatedLexBot* params are intentionally empty in
	# primary-region deploys (only populated in paired-region). Ignore them.
	cfn-lint -i W1030 -- $(TEMPLATE)
	bash -n scripts/wire-paired-flow.sh
	python3 -c "import py_compile; [py_compile.compile(f, doraise=True) for f in ['$(LAMBDA_DIR)/lex_fulfillment_handler.py', '$(LAMBDA_DIR)/traffic_shift_handler.py', '$(LAMBDA_DIR)/traffic_generator.py', '$(LAMBDA_DIR)/call_logger.py']]; print('Python: OK')"
	python3 -c "import json; [json.load(open(f)) for f in ['contact-flows/main-ivr-flow.json', 'contact-flows/chaos-test-flow.json']]; print('JSON: OK')"

clean:
	rm -rf $(BUILD_DIR)
