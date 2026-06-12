#!/bin/bash
# Stage 5 — Full rollback: restore all EXISTING stacks, remove all NEW stacks.
# Auto-discovers modules — no module names hardcoded.
set -e

ACCOUNT=${1:-dev}
REGION="eu-west-1"

# shellcheck source=scripts/lib/stack-names.sh
source "$(dirname "$0")/lib/stack-names.sh"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  STAGE 5 — ROLLBACK (${ACCOUNT})                     "
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# In CI the environment gate + typed workflow_dispatch input substitutes.
if [ "${CI}" = "true" ]; then
  echo "  Running in CI — environment gate approval + workflow_dispatch input"
  echo "  'ROLLBACK' substitutes for interactive confirmation."
else
  read -r -p "Type ROLLBACK to confirm full restore: " CONFIRM
  [ "${CONFIRM}" = "ROLLBACK" ] || { echo "Rollback cancelled."; exit 0; }
fi

START=$(date +%s)

# ── Restore EXISTING stacks from per-account templates ────────────────
echo ""
echo "Restoring EXISTING stacks from per-account templates..."
while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"

  ABBREV=$(_abbrev_for_module "${domain_module}")

  TEMPLATE="existing-structure/${ACCOUNT}/${ABBREV}-template.yaml"
  PARAMS="existing-structure/${ACCOUNT}/${ABBREV}-params.json"
  STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")

  EXTRA_CAPS=""
  [[ "${ABBREV}" == "kms" ]] && EXTRA_CAPS="--capabilities CAPABILITY_NAMED_IAM"

  echo "► Restoring ${STACK}..."
  # shellcheck disable=SC2086
  aws cloudformation deploy \
    --stack-name  "${STACK}" \
    --template-file "${TEMPLATE}" \
    --parameter-overrides "file://${PARAMS}" \
    --tags POCStage=rollback Account="${ACCOUNT}" \
           Domain="${DOMAIN}" Module="${MODULE}" \
    --region "${REGION}" \
    --no-fail-on-empty-changeset \
    ${EXTRA_CAPS}
  echo "  ✅ Restored: ${STACK}"

done < <(discover_existing_modules "${ACCOUNT}")

# ── Remove NEW stacks (in reverse order for safe dependency) ──────────
echo ""
echo "Removing NEW stacks..."
while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"
  STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  echo "► Deleting ${STACK}..."
  aws cloudformation delete-stack \
    --stack-name "${STACK}" --region "${REGION}"
  aws cloudformation wait stack-delete-complete \
    --stack-name "${STACK}" --region "${REGION}"
  echo "  Done."
done < <(discover_new_modules "${ACCOUNT}" | tac)

END=$(date +%s)
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  ROLLBACK COMPLETE in $(( END - START ))s         "
echo "║                                                      "
echo "║  All EXISTING stacks restored.                       "
echo "║  All NEW stacks removed.                             "
echo "║  Deployment back to: existing-structure/${ACCOUNT}/  "
echo "╚══════════════════════════════════════════════════════╝"
