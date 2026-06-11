#!/usr/bin/env bash
#
# wire-paired-flow.sh
#
# Post-deploy helper for the EnableLexGlobalResiliency=false path
# (currently the ap-northeast-1 ↔ ap-northeast-3 region pair, which Lex
# Global Resiliency does not yet support).
#
# WHAT THIS SCRIPT DOES
# ─────────────────────
# When Lex GR is enabled (default), the bot ID and alias ID are preserved
# across regions, so the contact flow content that ACGR replicates from
# the primary region will resolve to a valid Lex alias in the paired
# region without modification.
#
# When Lex GR is disabled, each region has its OWN Lex bot with a
# DIFFERENT bot/alias ID. ACGR-replicated contact flows in the paired
# region still reference the PRIMARY region's Lex alias ARN, which the
# paired-region runtime cannot resolve. This script rewrites the paired-
# region copies of the two contact flows (`ConnectChaos-MainIVR` and
# `ConnectChaos-ChaosTest`) so they reference the paired-region Lex alias.
#
# WHEN TO RUN
# ───────────
# Only when EnableLexGlobalResiliency=false. Otherwise this script is
# unnecessary and harmless to skip.
#
# REQUIREMENTS
# ────────────
#   - aws CLI v2, jq
#   - Credentials with connect:UpdateContactFlowContent in BOTH regions
#   - The CFN stacks in primary AND paired regions must be CREATE_COMPLETE
#
# USAGE
# ─────
#   ./scripts/wire-paired-flow.sh \
#     --stack-name connect-chaos-sample \
#     --primary-region us-east-1 \
#     --paired-region us-west-2

set -euo pipefail

STACK_NAME=""
PRIMARY_REGION=""
PAIRED_REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)      STACK_NAME="$2";      shift 2 ;;
    --primary-region)  PRIMARY_REGION="$2";  shift 2 ;;
    --paired-region)   PAIRED_REGION="$2";   shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$STACK_NAME" || -z "$PRIMARY_REGION" || -z "$PAIRED_REGION" ]]; then
  echo "Usage: $0 --stack-name <name> --primary-region <region> --paired-region <region>" >&2
  exit 2
fi

echo "Reading paired-region Lex bot alias ARN from stack outputs in $PAIRED_REGION..."
PAIRED_LEX_ALIAS_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$PAIRED_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LexBotAliasArn'].OutputValue" \
  --output text)

if [[ -z "$PAIRED_LEX_ALIAS_ARN" || "$PAIRED_LEX_ALIAS_ARN" == "None" ]]; then
  echo "ERROR: Could not read LexBotAliasArn output from $STACK_NAME in $PAIRED_REGION." >&2
  echo "       Make sure EnableLexGlobalResiliency=false (otherwise this script is not needed)." >&2
  exit 1
fi
echo "  Paired-region Lex alias ARN: $PAIRED_LEX_ALIAS_ARN"

PAIRED_INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$PAIRED_REGION" \
  --query "Stacks[0].Parameters[?ParameterKey=='ConnectInstanceId'].ParameterValue" \
  --output text)
echo "  Paired-region Connect instance: $PAIRED_INSTANCE_ID"

for FLOW_NAME in "ConnectChaos-MainIVR" "ConnectChaos-ChaosTest"; do
  echo
  echo "Rewriting flow '$FLOW_NAME' in $PAIRED_REGION..."

  FLOW_ID=$(aws connect list-contact-flows \
    --instance-id "$PAIRED_INSTANCE_ID" \
    --region "$PAIRED_REGION" \
    --query "ContactFlowSummaryList[?Name=='${FLOW_NAME}'].Id | [0]" \
    --output text)

  if [[ -z "$FLOW_ID" || "$FLOW_ID" == "None" ]]; then
    echo "  WARNING: Flow '$FLOW_NAME' not found in $PAIRED_REGION — skipping." >&2
    continue
  fi

  CURRENT_CONTENT=$(aws connect describe-contact-flow \
    --instance-id "$PAIRED_INSTANCE_ID" \
    --contact-flow-id "$FLOW_ID" \
    --region "$PAIRED_REGION" \
    --query "ContactFlow.Content" --output text)

  NEW_CONTENT=$(echo "$CURRENT_CONTENT" | jq --arg arn "$PAIRED_LEX_ALIAS_ARN" '
    .Actions |= map(
      if .Type == "ConnectParticipantWithLexBot"
      then .Parameters.LexV2Bot.AliasArn = $arn
      else . end
    )
  ')

  aws connect update-contact-flow-content \
    --instance-id "$PAIRED_INSTANCE_ID" \
    --contact-flow-id "$FLOW_ID" \
    --content "$NEW_CONTENT" \
    --region "$PAIRED_REGION"

  echo "  Updated $FLOW_NAME (id=$FLOW_ID)"
done

echo
echo "Done. The paired region's contact flows now reference the paired-region Lex alias."
echo "Verify by placing a test call routed to $PAIRED_REGION via the Traffic Distribution Group."
