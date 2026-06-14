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
  IMPORT_CONFIG="new-structure/modules/${DOMAIN}/${MODULE}/import-config.json"
  NEW_STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")

  echo ">> Deploying ${domain_module}: ${STACK}"
  echo "    template : ${TEMPLATE}"
  echo "    params   : ${PARAMS}"

  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  echo "    status   : ${STACK_STATUS}"

  # Terminal stuck states that block further create/update:
  #   CREATE_FAILED / ROLLBACK_COMPLETE / ROLLBACK_FAILED  -- initial create failed
  #   DELETE_FAILED                                         -- delete stuck (retained)
  #   UPDATE_ROLLBACK_FAILED                                -- update rollback stuck
  #   IMPORT_ROLLBACK_COMPLETE / IMPORT_ROLLBACK_FAILED     -- import rolled back
  #   REVIEW_IN_PROGRESS                                    -- changeset created, never executed
  # Resources survive via DeletionPolicy: Retain or --retain-resources.
  # Delete the stuck stack so the import path below can re-adopt the resources.
  case "${STACK_STATUS}" in
    DELETE_FAILED|CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|\
UPDATE_ROLLBACK_FAILED|IMPORT_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_FAILED|\
REVIEW_IN_PROGRESS)
      echo "  [WARN] '${STACK}' is in ${STACK_STATUS} -- clearing stuck stack."
      echo "  AWS resources retained (DeletionPolicy: Retain). Will re-import below."
      cfn_delete_stack_robust "${STACK}" "${REGION}" "  "
      STACK_STATUS="DOES_NOT_EXIST"
      echo "  [OK] Stuck stack cleared."
      ;;
  esac

  # For modules with import-config.json that appear healthy (CREATE_COMPLETE etc.),
  # verify the stack actually owns its key resource. If the first resource in
  # import-config is NOT owned by the stack (e.g. was retained by a prior run and
  # never re-imported), delete and re-import rather than letting the deploy fail
  # with EarlyValidation.
  if [ -f "${IMPORT_CONFIG}" ] && [ "${STACK_STATUS}" != "DOES_NOT_EXIST" ]; then
    FIRST_LOGICAL_ID=$(python3 -c "
import json, sys
try:
    cfg = json.load(open('${IMPORT_CONFIG}'))
    rs = cfg.get('resources_to_import', [])
    print(rs[0]['LogicalResourceId'] if rs else '')
except Exception:
    pass
" 2>/dev/null)
    if [ -n "${FIRST_LOGICAL_ID}" ]; then
      OWN_STDERR=$(mktemp)
      RES_STATUS=$(aws cloudformation describe-stack-resource \
        --stack-name "${STACK}" --region "${REGION}" \
        --logical-resource-id "${FIRST_LOGICAL_ID}" \
        --query 'StackResourceDetail.ResourceStatus' --output text 2>"${OWN_STDERR}" \
        || echo "LOOKUP_FAILED")
      OWN_ERR=$(cat "${OWN_STDERR}"); rm -f "${OWN_STDERR}"

      if echo "${OWN_ERR}" | grep -qi "AccessDenied\|not authorized"; then
        # Cannot verify ownership due to missing cloudformation:DescribeStackResource.
        # Do NOT delete the stack -- assume it owns its resources and proceed normally.
        echo "  [WARN] Cannot verify resource ownership (AccessDenied on DescribeStackResource)."
        echo "  Skipping ownership check. Add cloudformation:DescribeStackResource to the deploy role."
      elif [ "${RES_STATUS}" = "LOOKUP_FAILED" ]; then
        echo "  [WARN] '${STACK}' (${STACK_STATUS}) does not own '${FIRST_LOGICAL_ID}'."
        echo "  Resource exists in AWS but not in this stack. Clearing to re-import."
        cfn_delete_stack_robust "${STACK}" "${REGION}" "  "
        STACK_STATUS="DOES_NOT_EXIST"
        echo "  [OK] Stack cleared -- import path will re-adopt resource."
      fi
    fi
  fi

  # Detect whether this template creates IAM resources (requires capabilities).
  # Generic check: any AWS::IAM:: resource type triggers CAPABILITY_NAMED_IAM.
  EXTRA_CAPS=""
  if grep -q "Type: AWS::IAM::" "${TEMPLATE}" 2>/dev/null; then
    EXTRA_CAPS="--capabilities CAPABILITY_NAMED_IAM"
  fi

  # If this module has an import-config.json and the EXISTING stack does not exist:
  #   - Check if the NEW stack already exists (already migrated -- skip)
  #   - Otherwise try to locate retained resources via resolve_import --fallback-by-tag
  #     If resources found -> CFN Import into EXISTING stack (re-run after cleanup)
  #     If no resources found -> normal deploy (fresh environment)
  if [ -f "${IMPORT_CONFIG}" ] && [ "${STACK_STATUS}" = "DOES_NOT_EXIST" ]; then
    NEW_STATUS=$(aws cloudformation describe-stacks \
      --stack-name "${NEW_STACK}" --region "${REGION}" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    if [ "${NEW_STATUS}" != "DOES_NOT_EXIST" ]; then
      echo "  [OK] ${domain_module}: already migrated to NEW stack (${NEW_STATUS}) -- skipping"
      DEPLOYED+=("${STACK} (already migrated -- NEW stack owns resource)")
      echo ""
      continue
    fi

    # Attempt to find retained resources via CFN tags
    IMPORT_FILE="/tmp/tesco-ims-stage1-${ACCOUNT}-${DOMAIN}-${MODULE}.json"
    echo "  ${domain_module}: EXISTING stack absent -- checking for retained resources via tags..."

    RESOLVE_STDERR=$(mktemp)
    python3 new-structure/pipeline/resolve_import.py \
      --stack-name "${STACK}" \
      --config     "${IMPORT_CONFIG}" \
      --params     "${PARAMS}" \
      --region     "${REGION}" \
      --output     "${IMPORT_FILE}" \
      --fallback-by-tag 2>"${RESOLVE_STDERR}" && RESOLVE_OK=true || RESOLVE_OK=false
    if [ "${RESOLVE_OK}" = "false" ] && [ -s "${RESOLVE_STDERR}" ]; then
      echo "  [DEBUG] resolve_import errors:"
      cat "${RESOLVE_STDERR}"
    fi
    rm -f "${RESOLVE_STDERR}"

    if [ "${RESOLVE_OK}" = "true" ] && [ -f "${IMPORT_FILE}" ]; then
      echo "  ${domain_module}: retained resources found -- importing into EXISTING stack..."

      # Two-phase import (Phase 1 filtered IMPORT + Phase 2 full UPDATE).
      # Non-importable resources (Route, BucketPolicy) are created in Phase 2.
      if cfn_import_then_update \
            "${STACK}" "${REGION}" "${TEMPLATE}" "${IMPORT_CONFIG}" \
            "${PARAMS}" "${IMPORT_FILE}" "existing" \
            "${ACCOUNT}" "${DOMAIN}" "${MODULE}" "${EXTRA_CAPS}"; then
        DEPLOYED+=("${STACK} (imported from retained resources)")
        echo ""
        continue
      else
        echo "  [WARN] ${domain_module}: import failed -- falling back to normal deploy"
      fi
    else
      echo "  ${domain_module}: no retained resources found -- proceeding with fresh deploy"
    fi
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
