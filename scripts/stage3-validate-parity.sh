#!/bin/bash
# Stage 3 -- Parity validation: EXISTING == NEW for every module.
# Auto-discovers modules for the account -- same list as stage 2.
# Each module pair (EXISTING vs NEW) runs the 5-check parity validator.
# All modules must pass before cutover is permitted.
set -e

ACCOUNT=${1:-dev}
REGION="eu-west-1"

# shellcheck source=scripts/lib/stack-names.sh
source "$(dirname "$0")/lib/stack-names.sh"

echo ""
echo "+======================================================+"
echo "|  STAGE 3 -- Parity Validation                         "
echo "|  Account  : ${ACCOUNT}                               "
echo "+======================================================+"
echo ""
echo "  Proving: every EXISTING stack == its NEW counterpart."
echo "  Stack names derived by cfn_stack_name() -- same formula as stage 1 + 2."
echo ""

pip install boto3 pyyaml -q 2>/dev/null || true

FAILED_MODULES=()

while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  NEW_STACK=$(cfn_stack_name "NEW"      "${DOMAIN}" "${MODULE}" "${ACCOUNT}")

  echo ">> Checking parity: ${domain_module}"
  echo "    EXISTING : ${OLD_STACK}"
  echo "    NEW      : ${NEW_STACK}"

  # Modules with import-config.json are migrated via CFN Resource Import in stage 2.
  # The EXISTING stack is deleted during stage 2 (with --retain-resources), so
  # there is no side-by-side old stack to compare against.  These modules are
  # skipped here and counted as passing -- ownership has already been transferred.
  IMPORT_CONFIG="new-structure/modules/${domain_module}/import-config.json"
  OLD_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${OLD_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ -f "${IMPORT_CONFIG}" ] && [ "${OLD_STATUS}" = "DOES_NOT_EXIST" ]; then
    echo "  [OK]  ${domain_module} -- migrated via CFN Resource Import in stage 2"
    echo "        EXISTING stack '${OLD_STACK}' was released (resources retained)."
    echo "        '${NEW_STACK}' now owns the resource. No side-by-side parity needed."
    echo ""
    continue
  fi

  if python3 new-structure/pipeline/validate_parity.py \
       --old-stack "${OLD_STACK}" \
       --new-stack "${NEW_STACK}" \
       --region    "${REGION}"; then
    echo "  [OK]  ${domain_module} parity confirmed"
  else
    echo "  [FAIL]  ${domain_module} parity FAILED"
    FAILED_MODULES+=("${domain_module}")
  fi
  echo ""

done < <(discover_new_modules "${ACCOUNT}")

# -- Summary -----------------------------------------------------------
if [ ${#FAILED_MODULES[@]} -ne 0 ]; then
  echo "+======================================================+"
  echo "|  [FAIL]  PARITY FAILED (${ACCOUNT})                      "
  for m in "${FAILED_MODULES[@]}"; do
    printf "|     %-48s [FAIL]\n" "${m}"
  done
  echo "|  Fix mismatches before proceeding to cutover.        "
  echo "+======================================================+"
  exit 1
fi

echo "+======================================================+"
echo "|  [OK]  ALL PARITY CHECKS PASSED (${ACCOUNT})            "
echo "+======================================================+"
echo ""
while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  NEW_STACK=$(cfn_stack_name "NEW"      "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  printf "  %s\n    %s == %s\n" "${domain_module}" "${OLD_STACK}" "${NEW_STACK}"
done < <(discover_new_modules "${ACCOUNT}")
echo ""
echo "  Proceed to: scripts/stage4-cutover.sh ${ACCOUNT}"
