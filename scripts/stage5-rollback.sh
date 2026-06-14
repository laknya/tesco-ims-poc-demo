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

  # Check if EXISTING stack already exists -- skip resolve if already restored
  OLD_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${OLD_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "${OLD_STATUS}" != "DOES_NOT_EXIST" ]; then
    echo "  ${domain_module}: EXISTING stack already restored (${OLD_STATUS}) -- skipping resolve"
    continue
  fi

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

  # Check whether the EXISTING stack already exists.
  OLD_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${OLD_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "${OLD_STATUS}" != "DOES_NOT_EXIST" ]; then
    echo ">> ${OLD_STACK} already exists (${OLD_STATUS}) -- skipping"
    continue
  fi

  if [ -f "${IMPORT_CONFIG}" ] && [ -f "${ROLLBACK_IMPORT_FILE}" ]; then
    # Import path: resource was retained when NEW stack was deleted above.
    echo ">> Restoring ${OLD_STACK} via CFN Resource Import..."
    echo "   (Resource retained from NEW stack deletion -- importing into EXISTING)"

    RESOURCES_TO_IMPORT=$(cat "${ROLLBACK_IMPORT_FILE}")

    CHANGESET_NAME="rollback-import-$(date +%s)"
    # shellcheck disable=SC2086
    aws cloudformation create-change-set \
      --stack-name         "${OLD_STACK}" \
      --change-set-name    "${CHANGESET_NAME}" \
      --change-set-type    IMPORT \
      --resources-to-import "${RESOURCES_TO_IMPORT}" \
      --template-body      "file://${TEMPLATE}" \
      --parameters         "file://${PARAMS}" \
      --tags "Key=POCStage,Value=rollback" "Key=Account,Value=${ACCOUNT}" \
             "Key=Domain,Value=${DOMAIN}" "Key=Module,Value=${MODULE}" \
      --region "${REGION}" \
      ${EXTRA_CAPS}

    echo "   Waiting for changeset to be ready..."
    WAITED=0
    while true; do
      CS_STATUS=$(aws cloudformation describe-change-set \
        --stack-name      "${OLD_STACK}" \
        --change-set-name "${CHANGESET_NAME}" \
        --region          "${REGION}" \
        --query 'Status' --output text 2>/dev/null || echo "UNKNOWN")
      case "${CS_STATUS}" in
        CREATE_COMPLETE)
          echo "   Changeset ready"
          break ;;
        FAILED)
          CS_REASON=$(aws cloudformation describe-change-set \
            --stack-name      "${OLD_STACK}" \
            --change-set-name "${CHANGESET_NAME}" \
            --region          "${REGION}" \
            --query 'StatusReason' --output text 2>/dev/null || echo "unknown")
          echo ""
          echo "   [FAIL] IMPORT changeset FAILED for '${OLD_STACK}'"
          echo "     Reason: ${CS_REASON}"
          echo ""
          exit 1 ;;
        CREATE_IN_PROGRESS)
          sleep 10; WAITED=$((WAITED + 10)) ;;
        *)
          sleep 10; WAITED=$((WAITED + 10)) ;;
      esac
      if [ "${WAITED}" -ge 300 ]; then
        echo "   [FAIL] Timed out waiting for rollback changeset"
        exit 1
      fi
    done

    aws cloudformation execute-change-set \
      --stack-name      "${OLD_STACK}" \
      --change-set-name "${CHANGESET_NAME}" \
      --region          "${REGION}"

    echo "   Waiting for IMPORT_COMPLETE..."
    WAITED=0
    while true; do
      STACK_STATUS=$(aws cloudformation describe-stacks \
        --stack-name "${OLD_STACK}" --region "${REGION}" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")
      case "${STACK_STATUS}" in
        IMPORT_COMPLETE)
          echo "   [OK] Restored: ${OLD_STACK} (via import)"
          break ;;
        IMPORT_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_FAILED|ROLLBACK_COMPLETE|CREATE_FAILED)
          echo "   [FAIL] Rollback import failed: ${STACK_STATUS}"
          exit 1 ;;
        IMPORT_IN_PROGRESS|CREATE_IN_PROGRESS)
          sleep 15; WAITED=$((WAITED + 15)) ;;
        *)
          sleep 15; WAITED=$((WAITED + 15)) ;;
      esac
      if [ "${WAITED}" -ge 600 ]; then
        echo "   [FAIL] Timed out waiting for rollback import"
        exit 1
      fi
    done

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
