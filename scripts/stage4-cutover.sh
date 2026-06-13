#!/bin/bash
# Stage 4 -- Cutover: retire ALL existing stacks for the account.
# Pre-flight: re-runs parity for every module. Any failure aborts cutover.
# Auto-discovers modules -- no module names hardcoded.
set -e

ACCOUNT=${1:-dev}
REGION="eu-west-1"

# shellcheck source=scripts/lib/stack-names.sh
source "$(dirname "$0")/lib/stack-names.sh"

echo ""
echo "+======================================================+"
echo "|  STAGE 4 -- Cutover (${ACCOUNT})                      "
echo "+======================================================+"
echo ""

pip install boto3 pyyaml -q 2>/dev/null || true

# -- Pre-flight: parity check for every module -------------------------
echo "Pre-flight: final parity check before we delete anything..."
echo ""

while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  NEW_STACK=$(cfn_stack_name "NEW"      "${DOMAIN}" "${MODULE}" "${ACCOUNT}")

  echo "  Checking ${domain_module}..."
  python3 new-structure/pipeline/validate_parity.py \
    --old-stack "${OLD_STACK}" \
    --new-stack "${NEW_STACK}" \
    --region    "${REGION}" \
    || { echo "[FAIL] Parity failed for ${domain_module} -- cutover aborted."; exit 1; }
  echo "  [OK] ${domain_module}"

done < <(discover_new_modules "${ACCOUNT}")

echo ""
echo "  All parity checks passed."
echo ""
echo "  Cutover will DELETE (retiring per-account copies):"
while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"
  printf "    %s\n" "$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")"
done < <(discover_new_modules "${ACCOUNT}")
echo ""
echo "  Canonical going forward (centralized modules):"
while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"
  printf "    %-50s  (%s)\n" \
    "$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")" \
    "new-structure/modules/${domain_module}/"
done < <(discover_new_modules "${ACCOUNT}")
echo ""

# -- Confirmation ------------------------------------------------------
# In CI the environment gate approval + typed workflow_dispatch input
# substitutes for the interactive prompt.
if [ "${CI}" = "true" ]; then
  echo "  Running in CI -- environment gate approval + workflow_dispatch input"
  echo "  'CUTOVER' substitutes for interactive confirmation."
else
  read -r -p "Type YES to confirm cutover: " CONFIRM
  [ "${CONFIRM}" = "YES" ] || { echo "Cutover cancelled."; exit 0; }
fi

# -- Delete EXISTING stacks (in reverse discovery order for safe dependency) --
echo ""
while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"
  STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  echo ">> Deleting ${STACK}..."
  aws cloudformation delete-stack \
    --stack-name "${STACK}" --region "${REGION}"
  aws cloudformation wait stack-delete-complete \
    --stack-name "${STACK}" --region "${REGION}"
  echo "  Done."
done < <(discover_new_modules "${ACCOUNT}" | tac)

echo ""
echo "+======================================================+"
echo "|  [OK]  CUTOVER COMPLETE (${ACCOUNT})                    "
echo "|                                                      "
echo "|  Retired: existing-structure/${ACCOUNT}/             "
echo "|  Active : new-structure/modules/ + config/accounts/  "
echo "+======================================================+"
