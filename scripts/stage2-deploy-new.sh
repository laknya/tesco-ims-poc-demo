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

# -- Version integrity check -------------------------------------------
echo ">> Verifying module version integrity (template hash vs version.json)..."
python3 new-structure/pipeline/check_module_versions.py
echo ""

# -- Schema validation -------------------------------------------------
echo ">> Validating account configs against module schemas..."
python3 new-structure/pipeline/validate_schema.py --account "${ACCOUNT}"
echo ""

DEPLOYED=()

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

# -- Deploy each module ------------------------------------------------
for domain_module in "${MODULES_TO_DEPLOY[@]}"; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"

  VERSION=$(python3 -c "import json; print(json.load(open('new-structure/modules/${domain_module}/version.json'))['version'])")
  TYPE=$(python3 -c "import json; print(json.load(open('new-structure/modules/${domain_module}/version.json'))['type_name'])")
  STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  TEMPLATE="new-structure/modules/${domain_module}/template.yaml"
  RESOLVED="/tmp/new-resolved-${ACCOUNT}-${DOMAIN}-${MODULE}.json"

  echo "  +- Module  : ${TYPE}  v${VERSION}"
  echo "  |  Stack   : ${STACK}"
  echo "  |  Template: ${TEMPLATE}"

  # Lint template before deploy
  cfn-lint "${TEMPLATE}"
  echo "  |  cfn-lint [OK]"

  # Step A: 4-layer parameter resolution
  echo "  +- Step A: Resolving parameters (4-layer config)..."
  python3 new-structure/pipeline/resolve_parameters.py \
    --account "${ACCOUNT}" \
    --domain  "${DOMAIN}" \
    --module  "${MODULE}" \
    --output  "${RESOLVED}"

  # Step B: Wait for any cross-stack dependencies before deploying.
  # Any resolved parameter ending in "StackName" is treated as a dependency:
  # the script polls until that stack reaches a ready or failed terminal state.
  # This makes parallel CI matrix jobs safe regardless of which module is added next.
  DEPS=$(python3 -c "
import json, sys
params = json.load(open('${RESOLVED}'))
for p in params:
    key = p.get('ParameterKey', '')
    if key.endswith('StackName'):
        print(f\"{key}={p['ParameterValue']}\")
" 2>/dev/null || true)

  for dep in ${DEPS}; do
    DEP_PARAM="${dep%%=*}"    # e.g. VpcStackName
    DEP_STACK="${dep##*=}"    # e.g. poc-NEW-networking-vpc-baseline-dev

    echo "  +- Cross-stack dependency detected"
    echo "  |  Parameter : ${DEP_PARAM}"
    echo "  |  Stack     : ${DEP_STACK}"
    echo "  |  Waiting for '${DEP_STACK}' to be ready before deploying ${MODULE}..."

    # Two separate timeouts:
    #   NOT_FOUND_GRACE (120s) -- time allowed for a parallel CI job to START creating
    #                            the dependency. After this we assume it isn't coming.
    #   IN_PROGRESS_MAX (600s) -- time allowed for a stack that IS creating to finish.
    WAITED=0
    NOT_FOUND_GRACE=120
    IN_PROGRESS_MAX=600
    SEEN_IN_PROGRESS=false

    while true; do
      # Capture stdout and stderr separately so we can distinguish
      # "stack does not exist" (valid wait) from any other AWS error (fail fast).
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
        CREATE_COMPLETE|UPDATE_COMPLETE)
          echo "  |  [OK] '${DEP_STACK}' is ready (${DEP_STATUS}) -- continuing with ${MODULE}"
          break ;;

        ROLLBACK_COMPLETE|ROLLBACK_FAILED|DELETE_COMPLETE|CREATE_FAILED|UPDATE_FAILED|UPDATE_ROLLBACK_FAILED)
          echo ""
          echo "  [FAIL] CANCELLED -- dependency '${DEP_STACK}' is in a failed state: ${DEP_STATUS}"
          echo "     '${MODULE}' requires '${DEP_STACK}' to be healthy before it can deploy."
          echo "     Fix '${DEP_STACK}' first, then re-run this stage."
          echo ""
          exit 1 ;;

        CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS)
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
            # Grace period expired -- no parallel job created the dependency.
            # Try to find and deploy the dependency module ourselves before
            # continuing. Covers delta-mode CI runs where only the dependent
            # module was in the matrix (e.g. only s3-bucket.json changed but
            # vpc-baseline was never deployed for this account).
            echo "  | Grace period expired. Checking whether dependency is a known module..."

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

  # Step C: Deploy (or import) from the ONE master template.
  #
  # If the module directory contains an import-config.json AND the new stack
  # does not yet exist, Stage 2 uses CloudFormation Resource Import instead of
  # a regular deploy.  This is the correct production pattern for globally unique
  # resources (e.g. S3 bucket names) that cannot be recreated:
  #
  #   1. Release the resource from the EXISTING stack using --retain-resources
  #      (the resource is NOT deleted -- only CFN ownership is released).
  #   2. Import the retained resource into the NEW stack via --change-set-type IMPORT.
  #
  # Any module without import-config.json (VPC, KMS) uses the standard deploy path.

  IMPORT_CONFIG="new-structure/modules/${domain_module}/import-config.json"
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")

  # Check whether the new stack already exists (re-run idempotency).
  NEW_STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  # Detect whether this template creates IAM resources (requires capabilities).
  EXTRA_CAPS=""
  if grep -q "Type: AWS::IAM::" "${TEMPLATE}" 2>/dev/null; then
    EXTRA_CAPS="--capabilities CAPABILITY_NAMED_IAM"
  fi

  if [ -f "${IMPORT_CONFIG}" ] && [ "${NEW_STACK_STATUS}" = "DOES_NOT_EXIST" ]; then
    echo "  +- Step C: Migrating via CFN Resource Import [ModuleVersion=${VERSION}]..."
    echo "  |  Globally unique resources cannot be recreated alongside the existing"
    echo "  |  stack. CFN Import transfers ownership without deleting the resource."

    # Build --resources-to-import JSON from import-config + resolved params.
    RESOURCES_TO_IMPORT=$(python3 -c "
import json, sys
cfg    = json.load(open('${IMPORT_CONFIG}'))
params = {p['ParameterKey']: p['ParameterValue']
          for p in json.load(open('${RESOLVED}'))}
result = []
for r in cfg['resources_to_import']:
    result.append({
        'ResourceType':      r['ResourceType'],
        'LogicalResourceId': r['LogicalResourceId'],
        'ResourceIdentifier': {r['IdentifierKey']: params[r['IdentifierParam']]}
    })
print(json.dumps(result))
")
    echo "  |  Resources to import: ${RESOURCES_TO_IMPORT}"

    # Release the resource from the existing stack (resources are RETAINED).
    OLD_STACK_STATUS=$(aws cloudformation describe-stacks \
      --stack-name "${OLD_STACK}" --region "${REGION}" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    if [ "${OLD_STACK_STATUS}" != "DOES_NOT_EXIST" ]; then
      RETAIN_IDS=$(python3 -c "
import json
cfg = json.load(open('${IMPORT_CONFIG}'))
print(' '.join(r['LogicalResourceId'] for r in cfg['resources_to_import']))
")
      echo "  |  Releasing '${OLD_STACK}' with --retain-resources ${RETAIN_IDS}..."
      echo "  |  (The resource is kept in AWS -- only CFN ownership is released)"
      aws cloudformation delete-stack \
        --stack-name "${OLD_STACK}" \
        --retain-resources ${RETAIN_IDS} \
        --region "${REGION}"
      aws cloudformation wait stack-delete-complete \
        --stack-name "${OLD_STACK}" \
        --region "${REGION}"
      echo "  |  [OK] '${OLD_STACK}' deleted, resources retained in AWS"
    else
      echo "  |  No existing stack found -- resource may be unmanaged, importing directly"
    fi

    # Import the retained resource into the new stack.
    CHANGESET_NAME="import-$(date +%s)"
    echo "  |  Creating IMPORT changeset '${CHANGESET_NAME}'..."
    # shellcheck disable=SC2086
    aws cloudformation create-change-set \
      --stack-name         "${STACK}" \
      --change-set-name    "${CHANGESET_NAME}" \
      --change-set-type    IMPORT \
      --resources-to-import "${RESOURCES_TO_IMPORT}" \
      --template-body      "file://${TEMPLATE}" \
      --parameters         "file://${RESOLVED}" \
      --tags "Key=POCStage,Value=new" "Key=Account,Value=${ACCOUNT}" \
             "Key=Domain,Value=${DOMAIN}" "Key=Module,Value=${MODULE}" \
             "Key=ModuleVersion,Value=${VERSION}" "Key=ModuleType,Value=${TYPE}" \
             "Key=Repo,Value=tesco-ims-poc-demo" \
      --region "${REGION}" \
      ${EXTRA_CAPS}

    echo "  |  Waiting for changeset to be ready..."
    aws cloudformation wait change-set-create-complete \
      --stack-name      "${STACK}" \
      --change-set-name "${CHANGESET_NAME}" \
      --region          "${REGION}"

    echo "  |  Executing import changeset..."
    aws cloudformation execute-change-set \
      --stack-name      "${STACK}" \
      --change-set-name "${CHANGESET_NAME}" \
      --region          "${REGION}"

    echo "  |  Waiting for stack to reach CREATE_COMPLETE..."
    aws cloudformation wait stack-create-complete \
      --stack-name "${STACK}" \
      --region     "${REGION}"

    echo "     [OK] ${STACK} imported [ModuleVersion=${VERSION}]"

  else
    echo "  +- Step C: Deploying from master template [ModuleVersion=${VERSION}]..."
    # shellcheck disable=SC2086
    aws cloudformation deploy \
      --stack-name        "${STACK}" \
      --template-file     "${TEMPLATE}" \
      --parameter-overrides "file://${RESOLVED}" \
      --tags POCStage=new Account="${ACCOUNT}" \
             Domain="${DOMAIN}" Module="${MODULE}" \
             ModuleVersion="${VERSION}" ModuleType="${TYPE}" \
             Repo=tesco-ims-poc-demo \
      --region "${REGION}" \
      --no-fail-on-empty-changeset \
      ${EXTRA_CAPS}
    echo "     [OK] ${STACK}  [ModuleVersion=${VERSION}]"
  fi

  DEPLOYED+=("${STACK}")
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
