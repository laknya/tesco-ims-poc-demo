#!/bin/bash
# Stage 5 -- Full rollback: remove all NEW stacks, restore all EXISTING stacks.
# Auto-discovers modules -- no module names hardcoded.
#
# THREE-PASS ROLLBACK FLOW:
#   Pass A: Resolve  -- resolve import IDs FROM NEW stacks (while they exist)
#   Pass B: Release  -- delete NEW stacks in reverse order
#   Pass C: Restore  -- import (or deploy) EXISTING stacks in forward order
#
# ORDER MATTERS:
#   NEW stacks deleted in reverse dependency order (s3 -> kms -> vpc).
#   EXISTING stacks restored in forward dependency order (vpc -> kms -> s3).
set -e

ACCOUNT=${1:-dev}
REGION="eu-west-1"

# shellcheck source=scripts/lib/stack-names.sh
source "$(dirname "$0")/lib/stack-names.sh"

echo ""
echo "+======================================================+"
echo "|  STAGE 5 -- ROLLBACK (${ACCOUNT})                     "
echo "+======================================================+"
echo ""

# In CI the environment gate + typed workflow_dispatch input substitutes.
if [ "${CI}" = "true" ]; then
  echo "  Running in CI -- environment gate approval + workflow_dispatch input"
  echo "  'ROLLBACK' substitutes for interactive confirmation."
else
  read -r -p "Type ROLLBACK to confirm full restore: " CONFIRM
  [ "${CONFIRM}" = "ROLLBACK" ] || { echo "Rollback cancelled."; exit 0; }
fi

START=$(date +%s)

# ==========================================================================
# PASS A: Resolve -- resolve import identifiers FROM NEW stacks while they
# still exist. Uses EXISTING params files for param-source identifiers.
# Save to /tmp for use in Pass C.
# ==========================================================================
echo ""
echo ">> PASS A: Resolve -- capturing physical resource IDs from NEW stacks..."
echo ""

while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"

  IMPORT_CONFIG="new-structure/modules/${domain_module}/import-config.json"
  NEW_STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  EXISTING_PARAMS="existing-structure/${ACCOUNT}/${DOMAIN}__${MODULE}-params.json"
  ROLLBACK_IMPORT_FILE="/tmp/tesco-ims-rollback-${ACCOUNT}-${DOMAIN}-${MODULE}.json"

  if [ ! -f "${IMPORT_CONFIG}" ]; then
    echo "  ${domain_module}: no import-config.json -- will redeploy fresh in Pass C"
    continue
  fi

  # Skip resolve only for healthy EXISTING stacks (already restored).
  # Stuck states (UPDATE_ROLLBACK_COMPLETE etc.) must be re-resolved: the Phase 1
  # template has no Outputs, so exports are absent until Phase 2 succeeds.
  OLD_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${OLD_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  case "${OLD_STATUS}" in
    ROLLBACK_COMPLETE|ROLLBACK_FAILED|CREATE_FAILED|UPDATE_ROLLBACK_FAILED|\
    UPDATE_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_FAILED|\
    DELETE_FAILED)
      echo "  ${domain_module}: EXISTING stack stuck in ${OLD_STATUS} -- resolving from NEW stack for re-import..."
      ;;
    DOES_NOT_EXIST)
      ;;
    *)
      echo "  ${domain_module}: EXISTING stack already restored (${OLD_STATUS}) -- skipping resolve"
      continue
      ;;
  esac

  NEW_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${NEW_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "${NEW_STATUS}" = "DOES_NOT_EXIST" ]; then
    echo "  ${domain_module}: NEW stack '${NEW_STACK}' not found -- using fallback-by-tag"
  else
    echo "  ${domain_module}: resolving import identifiers from NEW stack '${NEW_STACK}'..."
  fi

  # Use EXISTING params file for param-source identifiers (e.g. BucketName)
  if [ ! -f "${EXISTING_PARAMS}" ]; then
    echo "  [WARN] No existing params file found at '${EXISTING_PARAMS}' -- skipping ${domain_module}"
    continue
  fi

  python3 new-structure/pipeline/resolve_import.py \
    --stack-name "${NEW_STACK}" \
    --config     "${IMPORT_CONFIG}" \
    --params     "${EXISTING_PARAMS}" \
    --region     "${REGION}" \
    --output     "${ROLLBACK_IMPORT_FILE}" \
    --fallback-by-tag

  echo "  [OK] ${domain_module}: rollback import identifiers saved to ${ROLLBACK_IMPORT_FILE}"
  echo ""

done < <(discover_new_modules "${ACCOUNT}")

echo ">> PASS A complete."
echo ""

# ==========================================================================
# PASS B: Release NEW stacks -- delete in REVERSE dependency order.
# DeletionPolicy: Retain on NEW templates keeps resources alive.
# ==========================================================================
echo ">> PASS B: Release -- deleting NEW stacks (reverse order)..."
echo ""

while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"
  NEW_STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${NEW_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")
  if [ "${STACK_STATUS}" = "DOES_NOT_EXIST" ]; then
    echo ">> ${NEW_STACK} -- not found, skipping"
    continue
  fi
  echo ">> Deleting ${NEW_STACK}..."
  cfn_delete_stack_robust "${NEW_STACK}" "${REGION}" ">>"
  echo "   [OK] ${NEW_STACK} released"
done < <(discover_new_modules "${ACCOUNT}" | tac)

echo ">> PASS B complete."
echo ""

# ==========================================================================
# PASS C: Restore EXISTING stacks -- in FORWARD dependency order.
# For modules with import-config.json: use --change-set-type IMPORT
# with the pre-resolved identifiers from Pass A.
# For modules without import-config.json: use aws cloudformation deploy.
# ==========================================================================
echo ">> PASS C: Restore -- creating EXISTING stacks..."
echo ""

while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"

  TEMPLATE="existing-structure/${ACCOUNT}/${DOMAIN}__${MODULE}-template.yaml"
  PARAMS="existing-structure/${ACCOUNT}/${DOMAIN}__${MODULE}-params.json"
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  IMPORT_CONFIG="new-structure/modules/${domain_module}/import-config.json"
  ROLLBACK_IMPORT_FILE="/tmp/tesco-ims-rollback-${ACCOUNT}-${DOMAIN}-${MODULE}.json"

  EXTRA_CAPS=""
  if grep -q "Type: AWS::IAM::" "${TEMPLATE}" 2>/dev/null; then
    EXTRA_CAPS="--capabilities CAPABILITY_NAMED_IAM"
  fi

  # Skip restore only for healthy EXISTING stacks.
  # Stuck states are cleared first (DeletionPolicy: Retain keeps AWS resources)
  # so re-import can adopt them. Without this, a stuck VPC stack would block
  # all downstream stacks that import its exports (e.g. S3 BucketPolicy).
  OLD_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${OLD_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  case "${OLD_STATUS}" in
    ROLLBACK_COMPLETE|ROLLBACK_FAILED|CREATE_FAILED|UPDATE_ROLLBACK_FAILED|\
    UPDATE_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_FAILED|\
    DELETE_FAILED)
      echo ">> [WARN] ${OLD_STACK} stuck in ${OLD_STATUS} -- clearing for re-restore..."
      cfn_delete_stack_robust "${OLD_STACK}" "${REGION}" ">>"
      echo ">> [OK] Stuck EXISTING stack cleared -- will re-import below"
      ;;
    DOES_NOT_EXIST)
      ;;
    *)
      echo ">> ${OLD_STACK} already exists (${OLD_STATUS}) -- skipping"
      continue
      ;;
  esac

  if [ -f "${IMPORT_CONFIG}" ] && [ -f "${ROLLBACK_IMPORT_FILE}" ]; then
    # Import path: resources retained when NEW stack was deleted above.
    # Two-phase (Phase 1 filtered IMPORT + Phase 2 full UPDATE) restores the
    # EXISTING stack. Non-importable resources (Route, BucketPolicy) recreated in Phase 2.
    echo ">> Restoring ${OLD_STACK} via CFN Resource Import (two-phase)..."

    if ! cfn_import_then_update \
          "${OLD_STACK}" "${REGION}" "${TEMPLATE}" "${IMPORT_CONFIG}" \
          "${PARAMS}" "${ROLLBACK_IMPORT_FILE}" "rollback" \
          "${ACCOUNT}" "${DOMAIN}" "${MODULE}" "${EXTRA_CAPS}"; then
      echo "   [FAIL] Rollback import failed for '${OLD_STACK}'."
      exit 1
    fi
    echo "   [OK] Restored: ${OLD_STACK} (via import)"

  else
    # Standard module: deploy (create or update) from existing-structure template.
    echo ">> Restoring ${OLD_STACK}..."
    # shellcheck disable=SC2086
    aws cloudformation deploy \
      --stack-name        "${OLD_STACK}" \
      --template-file     "${TEMPLATE}" \
      --parameter-overrides "file://${PARAMS}" \
      --tags POCStage=rollback Account="${ACCOUNT}" \
             Domain="${DOMAIN}" Module="${MODULE}" \
      --region "${REGION}" \
      --no-fail-on-empty-changeset \
      ${EXTRA_CAPS}
    echo "   [OK] Restored: ${OLD_STACK}"
  fi

done < <(discover_existing_modules "${ACCOUNT}")

END=$(date +%s)
echo ""
echo "+======================================================+"
echo "|  [OK]  ROLLBACK COMPLETE in $(( END - START ))s         "
echo "|                                                      "
echo "|  All NEW stacks removed.                             "
echo "|  All EXISTING stacks restored.                       "
echo "|  Deployment back to: existing-structure/${ACCOUNT}/  "
echo "+======================================================+"
