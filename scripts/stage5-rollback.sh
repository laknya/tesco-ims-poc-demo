#!/bin/bash
# Stage 5 -- Full rollback: remove all NEW stacks, restore all EXISTING stacks.
# Auto-discovers modules -- no module names hardcoded.
#
# ORDER MATTERS:
#   NEW stacks are deleted FIRST so that retained resources (e.g. S3 bucket)
#   become unmanaged before we re-import them into the restored EXISTING stack.
#   Modules with import-config.json use CFN Resource Import for the restore step,
#   mirroring exactly what stage 2 does in the forward direction.
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

# -- Step 1: Remove NEW stacks (reverse dependency order: s3 -> kms -> vpc) ---
# This must happen first. For import modules, DeletionPolicy: Retain on the NEW
# template keeps the resource (e.g. S3 bucket) alive after stack deletion, ready
# for re-import into the restored EXISTING stack in step 2.
echo ""
echo "Removing NEW stacks (reverse order)..."
while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"
  STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")
  if [ "${STACK_STATUS}" = "DOES_NOT_EXIST" ]; then
    echo ">> ${STACK} -- not found, skipping"
    continue
  fi
  echo ">> Deleting ${STACK}..."
  aws cloudformation delete-stack \
    --stack-name "${STACK}" --region "${REGION}"
  aws cloudformation wait stack-delete-complete \
    --stack-name "${STACK}" --region "${REGION}"
  echo "   [OK] Deleted"
done < <(discover_new_modules "${ACCOUNT}" | tac)

# -- Step 2: Restore EXISTING stacks (forward dependency order: vpc -> kms -> s3) --
# For modules with import-config.json (e.g. s3-bucket), the retained resource is
# re-imported into the restored EXISTING stack via --change-set-type IMPORT, exactly
# mirroring what stage 2 did in the forward direction.
echo ""
echo "Restoring EXISTING stacks..."
while IFS= read -r domain_module; do
  DOMAIN="${domain_module%/*}"; MODULE="${domain_module#*/}"

  TEMPLATE="existing-structure/${ACCOUNT}/${DOMAIN}__${MODULE}-template.yaml"
  PARAMS="existing-structure/${ACCOUNT}/${DOMAIN}__${MODULE}-params.json"
  STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  IMPORT_CONFIG="new-structure/modules/${domain_module}/import-config.json"

  EXTRA_CAPS=""
  if grep -q "Type: AWS::IAM::" "${TEMPLATE}" 2>/dev/null; then
    EXTRA_CAPS="--capabilities CAPABILITY_NAMED_IAM"
  fi

  # Check whether the EXISTING stack already exists (may have been left from stage 1).
  OLD_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ -f "${IMPORT_CONFIG}" ] && [ "${OLD_STATUS}" = "DOES_NOT_EXIST" ]; then
    # Import module: resource was retained when NEW stack was deleted above.
    # Re-import it into the restored EXISTING stack.
    echo ">> Restoring ${STACK} via CFN Resource Import..."
    echo "   (Resource was retained from NEW stack deletion -- re-importing into EXISTING)"

    RESOURCES_TO_IMPORT=$(python3 -c "
import json, sys
cfg    = json.load(open('${IMPORT_CONFIG}'))
params = {p['ParameterKey']: p['ParameterValue']
          for p in json.load(open('${PARAMS}'))}
result = []
for r in cfg['resources_to_import']:
    result.append({
        'ResourceType':       r['ResourceType'],
        'LogicalResourceId':  r['LogicalResourceId'],
        'ResourceIdentifier': {r['IdentifierKey']: params[r['IdentifierParam']]}
    })
print(json.dumps(result))
")

    CHANGESET_NAME="rollback-import-$(date +%s)"
    # shellcheck disable=SC2086
    aws cloudformation create-change-set \
      --stack-name         "${STACK}" \
      --change-set-name    "${CHANGESET_NAME}" \
      --change-set-type    IMPORT \
      --resources-to-import "${RESOURCES_TO_IMPORT}" \
      --template-body      "file://${TEMPLATE}" \
      --parameters         "file://${PARAMS}" \
      --tags "Key=POCStage,Value=rollback" "Key=Account,Value=${ACCOUNT}" \
             "Key=Domain,Value=${DOMAIN}" "Key=Module,Value=${MODULE}" \
      --region "${REGION}" \
      ${EXTRA_CAPS}

    aws cloudformation wait change-set-create-complete \
      --stack-name      "${STACK}" \
      --change-set-name "${CHANGESET_NAME}" \
      --region          "${REGION}"

    aws cloudformation execute-change-set \
      --stack-name      "${STACK}" \
      --change-set-name "${CHANGESET_NAME}" \
      --region          "${REGION}"

    aws cloudformation wait stack-create-complete \
      --stack-name "${STACK}" \
      --region     "${REGION}"

    echo "   [OK] Restored: ${STACK} (via import)"

  else
    # Standard module: deploy (create or update) from existing-structure template.
    echo ">> Restoring ${STACK}..."
    # shellcheck disable=SC2086
    aws cloudformation deploy \
      --stack-name        "${STACK}" \
      --template-file     "${TEMPLATE}" \
      --parameter-overrides "file://${PARAMS}" \
      --tags POCStage=rollback Account="${ACCOUNT}" \
             Domain="${DOMAIN}" Module="${MODULE}" \
      --region "${REGION}" \
      --no-fail-on-empty-changeset \
      ${EXTRA_CAPS}
    echo "   [OK] Restored: ${STACK}"
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
