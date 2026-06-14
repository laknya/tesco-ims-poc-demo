#!/bin/bash
# Stage 2 -- Deploy NEW centralized modules.
#
# Usage:
#   bash stage2-deploy-new.sh <account> [domain/module ...]
#
#   <account>          : dev | sandbox | coll-dev | coll-ppe
#   [domain/module ...]: optional filter -- only deploy these modules.
#                        If omitted, all modules for the account are deployed.
#                        In CI, the detect_changes.py matrix passes exactly one
#                        module per job so each is deployed independently.
#
# Examples
#   bash stage2-deploy-new.sh dev
#     -> discovers and deploys all modules configured for dev
#
#   bash stage2-deploy-new.sh dev networking/vpc-baseline
#     -> deploys ONLY vpc-baseline for dev (CI delta path)
#
#   bash stage2-deploy-new.sh dev networking/vpc-baseline shared-services/s3-bucket
#     -> deploys only those two modules
#
# THREE-PASS MIGRATION FLOW:
#   Pass A: Pre-flight    -- version check all modules upfront (fail fast)
#   Pass B: Resolve       -- while EXISTING stacks still exist, resolve import IDs
#   Pass C: Release       -- delete ALL EXISTING stacks in reverse order
#   Pass D: Import/Deploy -- import (or deploy) ALL NEW stacks in forward order
set -e

ACCOUNT=${1:-dev}
shift || true   # remaining args are the optional module filter list
MODULES_FILTER=("$@")

REGION="eu-west-1"

# shellcheck source=scripts/lib/stack-names.sh
source "$(dirname "$0")/lib/stack-names.sh"

echo ""
echo "+======================================================+"
echo "|  STAGE 2 -- Deploy NEW centralized modules            "
echo "|  Account  : ${ACCOUNT}                               "
if [ ${#MODULES_FILTER[@]} -gt 0 ]; then
echo "|  Mode     : DELTA -- deploying changed modules only   "
for m in "${MODULES_FILTER[@]}"; do
echo "|    -> ${m}"
done
else
echo "|  Mode     : FULL  -- deploying all modules for account"
fi
echo "+======================================================+"
echo ""

pip install pyyaml cfn-lint -q 2>/dev/null || true

# -- Schema validation -------------------------------------------------
echo ">> Validating account configs against module schemas..."
python3 new-structure/pipeline/validate_schema.py --account "${ACCOUNT}"
echo ""

# -- Build the deploy list: all discovered modules OR the explicit filter --
MODULES_TO_DEPLOY=()
while IFS= read -r domain_module; do
  if [ ${#MODULES_FILTER[@]} -eq 0 ]; then
    MODULES_TO_DEPLOY+=("${domain_module}")
  else
    for f in "${MODULES_FILTER[@]}"; do
      if [ "${f}" = "${domain_module}" ]; then
        MODULES_TO_DEPLOY+=("${domain_module}")
        break
      fi
    done
  fi
done < <(discover_new_modules "${ACCOUNT}")

if [ ${#MODULES_TO_DEPLOY[@]} -eq 0 ]; then
  echo "[WARN]  No modules matched the filter for account '${ACCOUNT}'. Nothing deployed."
  exit 0
fi

echo ">> Modules to deploy (${#MODULES_TO_DEPLOY[@]}):"
for dm in "${MODULES_TO_DEPLOY[@]}"; do
  echo "    ${dm}"
done
echo ""

# ==========================================================================
# PASS A: Pre-flight -- version integrity check for ALL modules upfront.
# Fail fast before touching any AWS resource.
# ==========================================================================
echo ">> PASS A: Pre-flight -- version integrity check..."
python3 new-structure/pipeline/check_module_versions.py
echo ""

for domain_module in "${MODULES_TO_DEPLOY[@]}"; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"
  TEMPLATE="new-structure/modules/${domain_module}/template.yaml"

  # Lint template before deploy
  cfn-lint "${TEMPLATE}"
  echo "  [OK] cfn-lint ${domain_module}"
done
echo "  [OK] Pre-flight passed for all ${#MODULES_TO_DEPLOY[@]} module(s)"
echo ""

# ==========================================================================
# PASS B: Resolve -- while ALL EXISTING stacks still exist, resolve import
# identifiers for each module that has an import-config.json.
# Save resolved import JSON to /tmp for use in Pass D.
# Skip if the NEW stack already exists (already migrated -- idempotent re-run).
# ==========================================================================
echo ">> PASS B: Resolve -- capturing physical resource IDs from EXISTING stacks..."
echo ""

for domain_module in "${MODULES_TO_DEPLOY[@]}"; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"

  IMPORT_CONFIG="new-structure/modules/${domain_module}/import-config.json"
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  NEW_STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  RESOLVED="/tmp/new-resolved-${ACCOUNT}-${DOMAIN}-${MODULE}.json"
  IMPORT_FILE="/tmp/tesco-ims-import-${ACCOUNT}-${DOMAIN}-${MODULE}.json"

  if [ ! -f "${IMPORT_CONFIG}" ]; then
    echo "  ${domain_module}: no import-config.json -- will deploy fresh in Pass D"
    continue
  fi

  # Check if NEW stack already exists -- idempotent re-run
  NEW_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${NEW_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "${NEW_STATUS}" != "DOES_NOT_EXIST" ]; then
    echo "  ${domain_module}: NEW stack already exists (${NEW_STATUS}) -- skipping resolve"
    continue
  fi

  # Resolve parameters first (needed for param-source identifiers)
  python3 new-structure/pipeline/resolve_parameters.py \
    --account "${ACCOUNT}" \
    --domain  "${DOMAIN}" \
    --module  "${MODULE}" \
    --output  "${RESOLVED}" >/dev/null

  echo "  ${domain_module}: resolving import identifiers from EXISTING stack '${OLD_STACK}'..."
  python3 new-structure/pipeline/resolve_import.py \
    --stack-name "${OLD_STACK}" \
    --config     "${IMPORT_CONFIG}" \
    --params     "${RESOLVED}" \
    --region     "${REGION}" \
    --output     "${IMPORT_FILE}" \
    --fallback-by-tag

  echo "  [OK] ${domain_module}: import identifiers saved to ${IMPORT_FILE}"
  echo ""
done

echo ">> PASS B complete."
echo ""

# ==========================================================================
# PASS C: Release -- delete ALL EXISTING stacks in REVERSE discovery order.
# S3 must be deleted before VPC because S3 imports VPC's exported VpcId --
# an exported value cannot be deleted while a stack imports it.
# DeletionPolicy: Retain keeps resources in AWS -- only CFN ownership released.
# Skip if EXISTING stack is already gone.
# ==========================================================================
echo ">> PASS C: Release -- deleting EXISTING stacks (reverse order)..."
echo ""

# Collect modules in reverse order for deletion
REVERSE_MODULES=()
while IFS= read -r domain_module; do
  REVERSE_MODULES=("${domain_module}" "${REVERSE_MODULES[@]}")
done < <(printf '%s\n' "${MODULES_TO_DEPLOY[@]}")

for domain_module in "${REVERSE_MODULES[@]}"; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")

  OLD_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${OLD_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "${OLD_STATUS}" = "DOES_NOT_EXIST" ]; then
    echo "  ${domain_module}: EXISTING stack '${OLD_STACK}' not found -- skipping"
    continue
  fi

  echo "  ${domain_module}: releasing '${OLD_STACK}' (DeletionPolicy: Retain preserves resources)..."
  cfn_delete_stack_robust "${OLD_STACK}" "${REGION}" "  |"
  echo "  [OK] ${domain_module}: EXISTING stack released"
  echo ""
done

echo ">> PASS C complete."
echo ""

# ==========================================================================
# PASS D: Import/Deploy -- import or deploy ALL NEW stacks in FORWARD order.
# For modules with import-config.json: use --change-set-type IMPORT with
# the pre-resolved identifiers from Pass B.
# For modules without import-config.json: use aws cloudformation deploy.
# Skip if NEW stack already exists (idempotent re-run).
# ==========================================================================
echo ">> PASS D: Import/Deploy -- creating NEW stacks..."
echo ""

DEPLOYED=()

for domain_module in "${MODULES_TO_DEPLOY[@]}"; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"

  VERSION=$(python3 -c "import json; print(json.load(open('new-structure/modules/${domain_module}/version.json'))['version'])")
  TYPE=$(python3 -c "import json; print(json.load(open('new-structure/modules/${domain_module}/version.json'))['type_name'])")
  NEW_STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  TEMPLATE="new-structure/modules/${domain_module}/template.yaml"
  RESOLVED="/tmp/new-resolved-${ACCOUNT}-${DOMAIN}-${MODULE}.json"
  IMPORT_CONFIG="new-structure/modules/${domain_module}/import-config.json"
  IMPORT_FILE="/tmp/tesco-ims-import-${ACCOUNT}-${DOMAIN}-${MODULE}.json"

  echo "  +- Module  : ${TYPE}  v${VERSION}"
  echo "  |  Stack   : ${NEW_STACK}"
  echo "  |  Template: ${TEMPLATE}"

  # Check whether the new stack already exists (re-run idempotency).
  NEW_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${NEW_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "${NEW_STATUS}" != "DOES_NOT_EXIST" ]; then
    echo "  |  [OK] NEW stack already exists (${NEW_STATUS}) -- skipping"
    DEPLOYED+=("${NEW_STACK}")
    echo ""
    continue
  fi

  # Resolve parameters (may already exist from Pass B for import modules)
  if [ ! -f "${RESOLVED}" ]; then
    echo "  +- Step: Resolving parameters (4-layer config)..."
    python3 new-structure/pipeline/resolve_parameters.py \
      --account "${ACCOUNT}" \
      --domain  "${DOMAIN}" \
      --module  "${MODULE}" \
      --output  "${RESOLVED}"
  fi

  # Step: Wait for any cross-stack dependencies before deploying.
  # Any resolved parameter ending in "StackName" is treated as a dependency.
  DEPS=$(python3 -c "
import json, sys
params = json.load(open('${RESOLVED}'))
for p in params:
    key = p.get('ParameterKey', '')
    if key.endswith('StackName'):
        print(f\"{key}={p['ParameterValue']}\")
" 2>/dev/null || true)

  for dep in ${DEPS}; do
    DEP_PARAM="${dep%%=*}"
    DEP_STACK="${dep##*=}"

    echo "  +- Cross-stack dependency detected"
    echo "  |  Parameter : ${DEP_PARAM}"
    echo "  |  Stack     : ${DEP_STACK}"
    echo "  |  Waiting for '${DEP_STACK}' to be ready before deploying ${MODULE}..."

    WAITED=0
    NOT_FOUND_GRACE=120
    IN_PROGRESS_MAX=600
    SEEN_IN_PROGRESS=false

    while true; do
      AWS_OUT=$(aws cloudformation describe-stacks \
        --stack-name "${DEP_STACK}" --region "${REGION}" \
        --query 'Stacks[0].StackStatus' --output text 2>/tmp/aws_dep_err_$$.txt)
      AWS_EXIT=$?

      if [ ${AWS_EXIT} -ne 0 ]; then
        AWS_ERR=$(cat /tmp/aws_dep_err_$$.txt)
        rm -f /tmp/aws_dep_err_$$.txt
        if echo "${AWS_ERR}" | grep -qi "does not exist"; then
          DEP_STATUS="DOES_NOT_EXIST"
        else
          echo ""
          echo "  [FAIL] CANCELLED -- AWS error while checking dependency '${DEP_STACK}'"
          echo "     Error   : ${AWS_ERR}"
          echo "     Check   : AWS credentials, region (${REGION}), and IAM permissions"
          echo "     Hint    : The deploy role needs cloudformation:DescribeStacks"
          echo ""
          exit 1
        fi
      else
        rm -f /tmp/aws_dep_err_$$.txt
        DEP_STATUS="${AWS_OUT}"
      fi

      case "${DEP_STATUS}" in
        CREATE_COMPLETE|UPDATE_COMPLETE|IMPORT_COMPLETE|IMPORT_ROLLBACK_COMPLETE)
          echo "  |  [OK] '${DEP_STACK}' is ready (${DEP_STATUS}) -- continuing with ${MODULE}"
          break ;;

        ROLLBACK_COMPLETE|ROLLBACK_FAILED|DELETE_COMPLETE|CREATE_FAILED|UPDATE_FAILED|UPDATE_ROLLBACK_FAILED)
          echo ""
          echo "  [FAIL] CANCELLED -- dependency '${DEP_STACK}' is in a failed state: ${DEP_STATUS}"
          echo "     '${MODULE}' requires '${DEP_STACK}' to be healthy before it can deploy."
          echo "     Fix '${DEP_STACK}' first, then re-run this stage."
          echo ""
          exit 1 ;;

        CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS|IMPORT_IN_PROGRESS)
          SEEN_IN_PROGRESS=true
          if [ "${WAITED}" -ge "${IN_PROGRESS_MAX}" ]; then
            echo ""
            echo "  [FAIL] CANCELLED -- timed out after ${IN_PROGRESS_MAX}s waiting for '${DEP_STACK}'"
            echo "     Stack has been in progress for over $((IN_PROGRESS_MAX/60)) minutes."
            echo "     Check CloudFormation console for errors on '${DEP_STACK}'."
            echo ""
            exit 1
          fi
          echo "  |  [WAIT] '${DEP_STACK}' is deploying (${DEP_STATUS}) -- ${WAITED}s elapsed, waiting 20s..."
          sleep 20
          WAITED=$((WAITED + 20)) ;;

        DOES_NOT_EXIST)
          if [ "${WAITED}" -ge "${NOT_FOUND_GRACE}" ]; then
            DEP_DOMAIN_MODULE=""
            while IFS= read -r dm; do
              CANDIDATE=$(cfn_stack_name "NEW" "${dm%/*}" "${dm#*/}" "${ACCOUNT}")
              if [ "${CANDIDATE}" = "${DEP_STACK}" ]; then
                DEP_DOMAIN_MODULE="${dm}"
                break
              fi
            done < <(discover_new_modules "${ACCOUNT}")

            if [ -n "${DEP_DOMAIN_MODULE}" ]; then
              echo ""
              echo "  | Dependency '${DEP_STACK}' is not deployed yet."
              echo "  | Auto-deploying '${DEP_DOMAIN_MODULE}' first so '${MODULE}' can proceed."
              echo ""
              bash "$(dirname "$0")/stage2-deploy-new.sh" "${ACCOUNT}" "${DEP_DOMAIN_MODULE}"
              echo ""
              echo "  | '${DEP_DOMAIN_MODULE}' deployed. Resuming '${MODULE}'..."
              break
            else
              echo ""
              echo "  [FAIL] CANCELLED -- '${DEP_STACK}' does not exist after ${NOT_FOUND_GRACE}s"
              echo "     and does not match any known module for account '${ACCOUNT}'."
              echo "     Check that '${DEP_PARAM}' in your account config points to the correct stack name."
              echo ""
              exit 1
            fi
          fi
          echo "  |  [WAIT] '${DEP_STACK}' not found yet (${WAITED}s elapsed, grace period ${NOT_FOUND_GRACE}s)"
          echo "  |     Waiting in case a parallel CI job is about to create it..."
          sleep 20
          WAITED=$((WAITED + 20)) ;;

        *)
          echo "  |  [WAIT] '${DEP_STACK}' status: ${DEP_STATUS} -- waiting 20s... (${WAITED}s elapsed)"
          sleep 20
          WAITED=$((WAITED + 20)) ;;
      esac
    done
  done

  # Detect whether this template creates IAM resources (requires capabilities).
  EXTRA_CAPS=""
  if grep -q "Type: AWS::IAM::" "${TEMPLATE}" 2>/dev/null; then
    EXTRA_CAPS="--capabilities CAPABILITY_NAMED_IAM"
  fi

  if [ -f "${IMPORT_CONFIG}" ] && [ -f "${IMPORT_FILE}" ]; then
    # Import path: two-phase (Phase 1 filtered IMPORT + Phase 2 full UPDATE).
    # Physical IDs were resolved in Pass B from the EXISTING stack.
    # Non-importable resources (Route, BucketPolicy) are created fresh in Phase 2.
    echo "  +- Step D: Migrating via CFN Resource Import [ModuleVersion=${VERSION}]..."

    if ! cfn_import_then_update \
          "${NEW_STACK}" "${REGION}" "${TEMPLATE}" "${IMPORT_CONFIG}" \
          "${RESOLVED}" "${IMPORT_FILE}" "new" \
          "${ACCOUNT}" "${DOMAIN}" "${MODULE}" "${EXTRA_CAPS}" \
          "${VERSION}" "${TYPE}"; then
      echo "  [FAIL] Import migration failed for '${NEW_STACK}'."
      echo "     Check CloudFormation console for '${NEW_STACK}' events."
      exit 1
    fi

    echo "     [OK] ${NEW_STACK} [ModuleVersion=${VERSION}]"

  else
    # Deploy path: no import-config.json, or no pre-resolved import file.
    echo "  +- Step D: Deploying from master template [ModuleVersion=${VERSION}]..."
    # shellcheck disable=SC2086
    aws cloudformation deploy \
      --stack-name        "${NEW_STACK}" \
      --template-file     "${TEMPLATE}" \
      --parameter-overrides "file://${RESOLVED}" \
      --tags POCStage=new Account="${ACCOUNT}" \
             Domain="${DOMAIN}" Module="${MODULE}" \
             ModuleVersion="${VERSION}" ModuleType="${TYPE}" \
             Repo=tesco-ims-poc-demo \
      --region "${REGION}" \
      --no-fail-on-empty-changeset \
      ${EXTRA_CAPS}
    echo "     [OK] ${NEW_STACK}  [ModuleVersion=${VERSION}]"
  fi

  DEPLOYED+=("${NEW_STACK}")
  echo ""

done

echo "+======================================================+"
echo "|  [OK]  Deployed ${#DEPLOYED[@]} module(s) (${ACCOUNT})  "
echo "+======================================================+"
echo ""
for S in "${DEPLOYED[@]}"; do
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${S}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
  printf "  %-54s -> %s\n" "${S}" "${STATUS}"
done
echo ""
echo "  Run scripts/stage3-validate-parity.sh ${ACCOUNT} next."
