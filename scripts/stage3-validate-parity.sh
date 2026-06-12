#!/bin/bash
# Stage 3 — Parity validation: EXISTING == NEW for every module.
# Auto-discovers modules for the account — same list as stage 2.
# Each module pair (EXISTING vs NEW) runs the 5-check parity validator.
# All modules must pass before cutover is permitted.
set -e

ACCOUNT=${1:-dev}
REGION="eu-west-1"

# shellcheck source=scripts/lib/stack-names.sh
source "$(dirname "$0")/lib/stack-names.sh"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  STAGE 3 — Parity Validation                         "
echo "║  Account  : ${ACCOUNT}                               "
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Proving: every EXISTING stack == its NEW counterpart."
echo "  Stack names derived by cfn_stack_name() — same formula as stage 1 + 2."
echo ""

pip install boto3 pyyaml -q 2>/dev/null || true

FAILED_MODULES=()

while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  NEW_STACK=$(cfn_stack_name "NEW"      "${DOMAIN}" "${MODULE}" "${ACCOUNT}")

  echo "► Checking parity: ${domain_module}"
  echo "    EXISTING : ${OLD_STACK}"
  echo "    NEW      : ${NEW_STACK}"

  if python3 new-structure/pipeline/validate_parity.py \
       --old-stack "${OLD_STACK}" \
       --new-stack "${NEW_STACK}" \
       --region    "${REGION}"; then
    echo "  ✅  ${domain_module} parity confirmed"
  else
    echo "  ❌  ${domain_module} parity FAILED"
    FAILED_MODULES+=("${domain_module}")
  fi
  echo ""

done < <(discover_new_modules "${ACCOUNT}")

# ── Summary ───────────────────────────────────────────────────────────
if [ ${#FAILED_MODULES[@]} -ne 0 ]; then
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  ❌  PARITY FAILED (${ACCOUNT})                      "
  for m in "${FAILED_MODULES[@]}"; do
    printf "║     %-48s ❌\n" "${m}"
  done
  echo "║  Fix mismatches before proceeding to cutover.        "
  echo "╚══════════════════════════════════════════════════════╝"
  exit 1
fi

echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  ALL PARITY CHECKS PASSED (${ACCOUNT})            "
echo "╚══════════════════════════════════════════════════════╝"
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
