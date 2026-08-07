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
	@echo "Targets: package, upload, deploy, clean, lint, help"
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
	@if aws s3api head-bucket --bucket $(BUCKET) --region $(REGION) 2>/dev/null; then 	  echo "bucket s3://$(BUCKET) already exists"; 	else 	  echo "creating s3://$(BUCKET) in $(REGION)"; 	  if [ "$(REGION)" = "us-east-1" ]; then 	    aws s3api create-bucket --bucket $(BUCKET) --region $(REGION); 	  else 	    aws s3api create-bucket --bucket $(BUCKET) --region $(REGION) 	      --create-bucket-configuration LocationConstraint=$(REGION); 	  fi; 	  aws s3api put-public-access-block --bucket $(BUCKET) --region $(REGION) 	    --public-access-block-configuration 	      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true; 	fi

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
	@if [ -z "$(STACK)" ] || [ -z "$(REGION)" ] || [ -z "$(CONNECT_INSTANCE_ARN)" ] 	   || [ -z "$(CONNECT_INSTANCE_ID)" ] || [ -z "$(TDG_ID)" ]; then 	  echo "Required: STACK, REGION, CONNECT_INSTANCE_ARN, CONNECT_INSTANCE_ID, TDG_ID"; 	  echo "Optional: PRIMARY_REGION PAIRED_REGION CREATE_VPC ENABLE_AUTO_FAILOVER"; 	  echo "          ENABLE_LEX_GR ENABLE_TRAFFIC_GEN DASHBOARD_TYPE"; 	  echo "          REPLICATED_LEX_BOT_ID REPLICATED_LEX_BOT_ALIAS_ID"; 	  echo "          LAMBDA_SUBNET_A LAMBDA_SUBNET_B LAMBDA_SG  (only if CREATE_VPC=false)"; 	  exit 2; 	fi
	aws cloudformation deploy 	  --template-file $(TEMPLATE) 	  --stack-name $(STACK) 	  --region $(REGION) 	  --s3-bucket $(BUCKET) 	  --s3-prefix cfn-staging 	  --capabilities CAPABILITY_NAMED_IAM 	  --parameter-overrides 	    ConnectInstanceArn=$(CONNECT_INSTANCE_ARN) 	    ConnectInstanceId=$(CONNECT_INSTANCE_ID) 	    PrimaryRegion=$(or $(PRIMARY_REGION),us-east-1) 	    PairedRegion=$(or $(PAIRED_REGION),us-west-2) 	    TrafficDistributionGroupId=$(TDG_ID) 	    LambdaCodeBucket=$(BUCKET) 	    CreateVpc=$(or $(CREATE_VPC),true) 	    LambdaSubnetIdA=$(LAMBDA_SUBNET_A) 	    LambdaSubnetIdB=$(LAMBDA_SUBNET_B) 	    LambdaSecurityGroupId=$(LAMBDA_SG) 	    EnableAutoFailover=$(or $(ENABLE_AUTO_FAILOVER),true) 	    EnableLexGlobalResiliency=$(or $(ENABLE_LEX_GR),true) 	    EnableTrafficGenerator=$(or $(ENABLE_TRAFFIC_GEN),true) 	    DashboardType=$(or $(DASHBOARD_TYPE),regional) 	    ReplicatedLexBotId=$(REPLICATED_LEX_BOT_ID) 	    ReplicatedLexBotAliasId=$(REPLICATED_LEX_BOT_ALIAS_ID)

# Deploy BOTH regions in the correct order, handing the Lex GR bot/alias IDs from the
# primary stack to the paired stack. Leaving both stacks standing is what proves the
# paired region can actually SERVE a call after failover.
deploy-pair:
	@if [ -z "$(STACK)" ] || [ -z "$(PRIMARY_REGION)" ] || [ -z "$(PAIRED_REGION)" ] 	   || [ -z "$(PRIMARY_INSTANCE_ARN)" ] || [ -z "$(PAIRED_INSTANCE_ARN)" ] 	   || [ -z "$(TDG_ID)" ]; then 	  echo "Required: STACK PRIMARY_REGION PAIRED_REGION PRIMARY_INSTANCE_ARN"; 	  echo "          PAIRED_INSTANCE_ARN TDG_ID"; exit 2; 	fi
	@echo "=== 1/2 primary region $(PRIMARY_REGION) ==="
	$(MAKE) deploy STACK=$(STACK) REGION=$(PRIMARY_REGION) 	  CONNECT_INSTANCE_ARN=$(PRIMARY_INSTANCE_ARN) 	  CONNECT_INSTANCE_ID=$(shell echo $(PRIMARY_INSTANCE_ARN) | awk -F/ '{print $$NF}') 	  PRIMARY_REGION=$(PRIMARY_REGION) PAIRED_REGION=$(PAIRED_REGION) TDG_ID=$(TDG_ID)
	@echo "=== reading Lex GR ids from the primary stack ==="
	$(eval LEX_BOT_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK) --region $(PRIMARY_REGION) --query "Stacks[0].Outputs[?OutputKey=='LexBotId'].OutputValue" --output text))
	$(eval LEX_ALIAS_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK) --region $(PRIMARY_REGION) --query "Stacks[0].Outputs[?OutputKey=='LexBotAliasId'].OutputValue" --output text))
	@echo "    bot=$(LEX_BOT_ID) alias=$(LEX_ALIAS_ID)"
	@if [ -z "$(LEX_BOT_ID)" ] || [ "$(LEX_BOT_ID)" = "None" ]; then 	  echo "ERROR: could not read LexBotId from the primary stack"; exit 1; fi
	@echo "=== 2/2 paired region $(PAIRED_REGION) ==="
	$(MAKE) deploy STACK=$(STACK) REGION=$(PAIRED_REGION) 	  CONNECT_INSTANCE_ARN=$(PAIRED_INSTANCE_ARN) 	  CONNECT_INSTANCE_ID=$(shell echo $(PAIRED_INSTANCE_ARN) | awk -F/ '{print $$NF}') 	  PRIMARY_REGION=$(PRIMARY_REGION) PAIRED_REGION=$(PAIRED_REGION) TDG_ID=$(TDG_ID) 	  REPLICATED_LEX_BOT_ID=$(LEX_BOT_ID) REPLICATED_LEX_BOT_ALIAS_ID=$(LEX_ALIAS_ID)
	@echo "=== both regions deployed ==="

lint:
	# W1030 is expected: ReplicatedLexBot* params are intentionally empty in
	# primary-region deploys (only populated in paired-region). Ignore them.
	cfn-lint -i W1030 -- $(TEMPLATE)
	bash -n scripts/wire-paired-flow.sh
	python3 -c "import py_compile; [py_compile.compile(f, doraise=True) for f in ['$(LAMBDA_DIR)/lex_fulfillment_handler.py', '$(LAMBDA_DIR)/traffic_shift_handler.py', '$(LAMBDA_DIR)/traffic_generator.py', '$(LAMBDA_DIR)/call_logger.py']]; print('Python: OK')"
	python3 -c "import json; [json.load(open(f)) for f in ['contact-flows/main-ivr-flow.json', 'contact-flows/chaos-test-flow.json']]; print('JSON: OK')"

clean:
	rm -rf $(BUILD_DIR)
