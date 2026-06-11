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

LAMBDAS := lex_fulfillment_handler traffic_shift_handler traffic_generator
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

upload: package
	@if [ -z "$(BUCKET)" ] || [ -z "$(REGION)" ]; then \
	  echo "Usage: make upload BUCKET=<s3-bucket> REGION=<aws-region>"; exit 2; \
	fi
	aws s3 cp $(BUILD_DIR)/lex_fulfillment_handler.zip s3://$(BUCKET)/connect-chaos/ --region $(REGION)
	aws s3 cp $(BUILD_DIR)/traffic_shift_handler.zip   s3://$(BUCKET)/connect-chaos/ --region $(REGION)
	aws s3 cp $(BUILD_DIR)/traffic_generator.zip       s3://$(BUCKET)/connect-chaos/ --region $(REGION)

deploy:
	@if [ -z "$(STACK)" ] || [ -z "$(REGION)" ] || [ -z "$(CONNECT_INSTANCE_ARN)" ]; then \
	  echo "Required: STACK, REGION, CONNECT_INSTANCE_ARN, CONNECT_INSTANCE_ID,"; \
	  echo "          LAMBDA_SUBNET_A, LAMBDA_SUBNET_B, LAMBDA_SG, TDG_ID,"; \
	  echo "          FIS_LAYER, CODE_BUCKET"; exit 2; \
	fi
	aws cloudformation deploy \
	  --template-file $(TEMPLATE) \
	  --stack-name $(STACK) \
	  --region $(REGION) \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --parameter-overrides \
	    ConnectInstanceArn=$(CONNECT_INSTANCE_ARN) \
	    ConnectInstanceId=$(CONNECT_INSTANCE_ID) \
	    PrimaryRegion=$(or $(PRIMARY_REGION),us-east-1) \
	    PairedRegion=$(or $(PAIRED_REGION),us-west-2) \
	    TrafficDistributionGroupId=$(TDG_ID) \
	    LambdaSubnetIdA=$(LAMBDA_SUBNET_A) \
	    LambdaSubnetIdB=$(LAMBDA_SUBNET_B) \
	    LambdaSecurityGroupId=$(LAMBDA_SG) \
	    LambdaCodeBucket=$(CODE_BUCKET) \
	    FISExtensionLayerArn=$(FIS_LAYER) \
	    EnableAutoFailover=$(or $(ENABLE_AUTO_FAILOVER),true) \
	    EnableLexGlobalResiliency=$(or $(ENABLE_LEX_GR),true) \
	    DashboardType=$(or $(DASHBOARD_TYPE),regional)

lint:
	# W1030 is expected: ReplicatedLexBot* params are intentionally empty in
	# primary-region deploys (only populated in paired-region). Ignore them.
	cfn-lint -i W1030 -- $(TEMPLATE)
	bash -n scripts/wire-paired-flow.sh
	python3 -c "import py_compile; [py_compile.compile(f, doraise=True) for f in ['$(LAMBDA_DIR)/lex_fulfillment_handler.py', '$(LAMBDA_DIR)/traffic_shift_handler.py', '$(LAMBDA_DIR)/traffic_generator.py']]; print('Python: OK')"
	python3 -c "import json; [json.load(open(f)) for f in ['contact-flows/main-ivr-flow.json', 'contact-flows/chaos-test-flow.json']]; print('JSON: OK')"

clean:
	rm -rf $(BUILD_DIR)
