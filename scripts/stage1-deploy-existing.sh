#!/bin/bash
# Stage 1 -- Deploy EXISTING per-account structure (simulates live state).
# Auto-discovers every *-template.yaml in existing-structure/{account}/ and deploys
# it.  No module names are hardcoded here -- add a new template file and it deploys
# automatically on the next run.
set -e

ACCOUNT=${1:-dev}
REGION="eu-west-1"

# shellcheck source=scripts/lib/stack-names.sh
source "$(dirname "$0")/lib/stack-names.sh"

echo ""
echo "+======================================================+"
echo "|  STAGE 1 -- Deploy EXISTING structure (per-account)  "
echo "|  Account  : ${ACCOUNT}                               "
echo "+======================================================+"
echo ""
echo "  Deploying the EXISTING approach: each account has its own"
echo "  copy of every template with hardcoded values."
echo ""
echo "  Stack naming: poc-EXISTING-{domain}-{module}-{account}"
echo "  Derived from: domain/module path (not manually typed abbreviations)"
echo ""

if [ ! -d "existing-structure/${ACCOUNT}" ]; then
  echo "[FAIL] No existing-structure found for account: ${ACCOUNT}"
  exit 1
fi

DEPLOYED=()

# -- Auto-discover and deploy every module in existing-structure/{account}/ --
# Template files follow the naming convention: {domain}__{module}-template.yaml
# Adding a new module requires only two files -- no script changes needed.
while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"    # networking
  MODULE="${domain_module#*/}"    # vpc-baseline

  TEMPLATE="existing-structure/${ACCOUNT}/${DOMAIN}__${MODULE}-template.yaml"
  PARAMS="existing-structure/${ACCOUNT}/${DOMAIN}__${MODULE}-params.json"
  STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")

  echo ">> Deploying ${domain_module}: ${STACK}"
  echo "    template : ${TEMPLATE}"
  echo "    params   : ${PARAMS}"

  # Detect whether this template creates IAM resources (requires capabilities).
  # Generic check: any AWS::IAM:: resource type triggers CAPABILITY_NAMED_IAM.
  EXTRA_CAPS=""
  if grep -q "Type: AWS::IAM::" "${TEMPLATE}" 2>/dev/null; then
    EXTRA_CAPS="--capabilities CAPABILITY_NAMED_IAM"
  fi

  # shellcheck disable=SC2086
  aws cloudformation deploy \
    --stack-name  "${STACK}" \
    --template-file "${TEMPLATE}" \
    --parameter-overrides "file://${PARAMS}" \
    --tags POCStage=existing Account="${ACCOUNT}" \
           Domain="${DOMAIN}" Module="${MODULE}" \
           Repo=tesco-ims-poc-demo \
    --region "${REGION}" \
    --no-fail-on-empty-changeset \
    ${EXTRA_CAPS}
  echo "  [OK] ${STACK}"
  DEPLOYED+=("${STACK}")
  echo ""

done < <(discover_existing_modules "${ACCOUNT}")

echo "+======================================================+"
echo "|  [OK]  EXISTING stacks LIVE (${ACCOUNT})               "
echo "+======================================================+"
echo ""
for S in "${DEPLOYED[@]}"; do
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${S}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
  printf "  %-54s -> %s\n" "${S}" "${STATUS}"
done
echo ""
echo "  These stacks represent your live production deployment."
echo "  All use EXISTING per-account templates (duplicated across 68+ accounts)."
echo "  Run scripts/stage2-deploy-new.sh ${ACCOUNT} next."
