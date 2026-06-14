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

  # If this module uses CFN Resource Import (e.g. s3-bucket) and the EXISTING
  # stack is in DELETE_FAILED (left over from a previous stage2 run that tried
  # to release it), a plain deploy would create a changeset that EarlyValidation
  # rejects because the bucket name already exists in AWS (it was retained).
  # Fix: force-clear the stuck stack with --retain-resources so the resource
  # stays in AWS, then skip the re-deploy -- stage2 will import it.
  IMPORT_CONFIG="new-structure/modules/${DOMAIN}/${MODULE}/import-config.json"
  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ -f "${IMPORT_CONFIG}" ] && [ "${STACK_STATUS}" = "DELETE_FAILED" ]; then
    echo "  [WARN] '${STACK}' is in DELETE_FAILED (left by a previous stage2 run)."
    echo "  Force-clearing stuck stack -- resource is retained in AWS."
    cfn_delete_stack_robust "${STACK}" "${REGION}" "  "
    echo "  [OK] ${STACK} -- cleared. Stage2 import path will own this resource."
    DEPLOYED+=("${STACK} (cleared -- import path)")
    echo ""
    continue
  fi

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
