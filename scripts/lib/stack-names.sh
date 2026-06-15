#!/bin/bash
# -----------------------------------------------------------------------------
#  Stack naming library -- source this file from every stage script.
#  Compatible with bash 3.2+ (macOS default) -- no associative arrays.
#
#  WHY this exists
#  ---------------
#  Without this library every stage script contained a manually typed shorthand
#  ("vpc", "kms", "s3") that had no relationship to the actual module path on
#  disk (networking/vpc-baseline, security/kms-key, ...). Adding a 4th module
#  required editing all 5 stage scripts by hand.
#
#  NAMING FORMULA
#  --------------
#  CloudFormation stack name: poc-{STAGE}-{domain}-{module}-{account}
#
#  Examples
#    poc-EXISTING-networking-vpc-baseline-dev
#    poc-NEW-networking-vpc-baseline-dev
#    poc-EXISTING-security-kms-key-dev
#    poc-NEW-security-kms-key-dev
#    poc-EXISTING-shared-services-s3-bucket-dev
#    poc-NEW-shared-services-s3-bucket-dev
#
#  The formula is identical for EXISTING and NEW stacks -- only the stage token
#  differs. Parity validation just swaps EXISTING->NEW for the same module.
#
#  NOTE on "StackSets" vs "Stacks"
#  ---------------------------------
#  This POC uses individual CloudFormation STACKS (single account, eu-west-1).
#  In production, AWS CloudFormation STACKSETS would be used to fan the same
#  template out across all accounts and regions from a management account in one
#  operation. The StackSet name follows the same formula without the account
#  suffix:  poc-NEW-{domain}-{module}
#  Each StackSet instance is identified by (account-id, region).
# -----------------------------------------------------------------------------

# cfn_stack_name STAGE DOMAIN MODULE ACCOUNT
#   Returns the CloudFormation stack name for a given module deployment.
#   STAGE   : EXISTING | NEW
#   DOMAIN  : networking | security | shared-services | ...
#   MODULE  : vpc-baseline | kms-key | s3-bucket | ...
#   ACCOUNT : dev | sandbox | coll-dev | coll-ppe | ...
cfn_stack_name() {
  local stage="$1"
  local domain="$2"
  local module="$3"
  local account="$4"
  echo "poc-${stage}-${domain}-${module}-${account}"
}

# discover_new_modules ACCOUNT
#   Prints one "domain/module" line per module configured for ACCOUNT by
#   scanning new-structure/config/accounts/{account}/**/*.json.
#   Stage scripts loop over this output -- no module names are hardcoded.
#
#   Example output for account=dev:
#     networking/vpc-baseline
#     security/kms-key
#     shared-services/s3-bucket
discover_new_modules() {
  local account="$1"
  local base="new-structure/config/accounts/${account}"
  if [ ! -d "${base}" ]; then
    echo "ERROR: No module configs found for account '${account}' under ${base}" >&2
    return 1
  fi
  find "${base}" -name "*.json" | sort | while IFS= read -r f; do
    local rel="${f#${base}/}"           # e.g. networking/vpc-baseline.json
    local domain="${rel%/*}"            # networking
    local module
    module=$(basename "${rel}" ".json") # vpc-baseline
    echo "${domain}/${module}"
  done
}

# discover_existing_modules ACCOUNT
#   Prints one "domain/module" line per module found under
#   existing-structure/{account}/, by scanning for files that follow
#   the naming convention:  {domain}__{module}-template.yaml
#
#   The double-underscore (__) separates domain from module, allowing both
#   to contain single hyphens (e.g. shared-services__s3-bucket).
#
#   Files are returned sorted alphabetically, which naturally gives the
#   correct dependency order:
#     networking/vpc-baseline   (no deps -- VPC is a root module)
#     security/kms-key          (no deps -- KMS is a root module)
#     shared-services/s3-bucket (depends on VPC via Fn::ImportValue)
#
#   Adding a new module to an account requires only:
#     1. existing-structure/{account}/{domain}__{module}-template.yaml
#     2. existing-structure/{account}/{domain}__{module}-params.json
#   No changes to any script are needed.
discover_existing_modules() {
  local account="$1"
  local base="existing-structure/${account}"
  if [ ! -d "${base}" ]; then
    echo "ERROR: No existing-structure found for account '${account}' under ${base}" >&2
    return 1
  fi
  find "${base}" -name "*__*-template.yaml" | sort | while IFS= read -r template; do
    local filename
    filename=$(basename "${template}" "-template.yaml")  # e.g. networking__vpc-baseline
    local domain="${filename%%__*}"                        # networking
    local module="${filename##*__}"                        # vpc-baseline
    echo "${domain}/${module}"
  done
}

# cfn_delete_stack_robust STACK REGION [LOG_PREFIX]
#   Deletes a CloudFormation stack, handling DELETE_FAILED automatically.
#
#   If the stack is already in DELETE_FAILED (previous failed run), OR if a
#   plain delete-stack lands in DELETE_FAILED, the function:
#     1. Fetches the failed resource logical IDs from stack events
#     2. Retries delete-stack --retain-resources on those IDs
#   This is the only valid use case for --retain-resources (DELETE_FAILED state).
#
#   Resources with DeletionPolicy: Retain in their template are automatically
#   retained by CloudFormation; this function handles cases where CFN cannot
#   even reach that step (e.g. export-in-use, IAM deny, etc.).
#
#   Returns 0 on DELETE_COMPLETE / DOES_NOT_EXIST, non-zero on timeout.
cfn_delete_stack_robust() {
  local stack="$1"
  local region="$2"
  local prefix="${3:-  |}"

  local cur_status
  cur_status=$(aws cloudformation describe-stacks \
    --stack-name "${stack}" --region "${region}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "${cur_status}" = "DOES_NOT_EXIST" ]; then
    echo "${prefix}  Stack '${stack}' does not exist -- nothing to delete"
    return 0
  fi

  # If already in DELETE_FAILED from a previous run, go straight to retain-retry.
  if [ "${cur_status}" = "DELETE_FAILED" ]; then
    echo "${prefix}  [WARN] '${stack}' is in DELETE_FAILED -- retrying with --retain-resources"
    _cfn_retain_retry "${stack}" "${region}" "${prefix}"
    return $?
  fi

  echo "${prefix}  Deleting '${stack}'..."
  echo "${prefix}  DeletionPolicy: Retain keeps resources in AWS -- only CFN ownership is released."
  aws cloudformation delete-stack --stack-name "${stack}" --region "${region}"

  local attempts=0
  while true; do
    local status
    status=$(aws cloudformation describe-stacks \
      --stack-name "${stack}" --region "${region}" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    case "${status}" in
      DOES_NOT_EXIST|DELETE_COMPLETE)
        echo "${prefix}  [OK] '${stack}' released"
        return 0 ;;

      DELETE_FAILED)
        echo "${prefix}  [WARN] delete-stack landed in DELETE_FAILED -- checking events..."
        # Print the specific failure reason from events for diagnosis
        aws cloudformation describe-stack-events \
          --stack-name "${stack}" --region "${region}" \
          --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
          --output text 2>/dev/null | head -10 | sed "s/^/${prefix}    /"
        _cfn_retain_retry "${stack}" "${region}" "${prefix}"
        return $? ;;

      DELETE_IN_PROGRESS)
        sleep 10
        attempts=$((attempts + 1))
        if [ "${attempts}" -ge 90 ]; then
          echo "${prefix}  [FAIL] Timed out (15 min) waiting for '${stack}' deletion"
          return 1
        fi ;;

      *)
        sleep 10
        attempts=$((attempts + 1))
        if [ "${attempts}" -ge 90 ]; then
          echo "${prefix}  [FAIL] Timed out (15 min) -- '${stack}' stuck in '${status}'"
          return 1
        fi
        # Stack stayed in a non-delete status (e.g. CREATE_COMPLETE). In a parallel
        # CI matrix, CFN silently refuses delete-stack when another stack is still
        # importing this stack's exports -- the API returns 0 but the deletion never
        # starts. Re-issue delete-stack on every retry; it will be accepted as soon
        # as the blocking importer (e.g. S3 EXISTING) is removed by its own job.
        aws cloudformation delete-stack \
          --stack-name "${stack}" --region "${region}" 2>/dev/null || true
        ;;
    esac
  done
}

# cfn_import_then_update STACK REGION FULL_TEMPLATE IMPORT_CONFIG PARAMS \
#                        RESOURCES_JSON STAGE_TAG ACCOUNT DOMAIN MODULE [EXTRA_CAPS]
#   Two-phase CFN Resource Import:
#     Phase 1 (IMPORT): create+execute an IMPORT change set using a FILTERED
#       template that contains only importable resources. Non-importable types
#       (AWS::EC2::Route, AWS::S3::BucketPolicy) are stripped by
#       generate_import_template.py. Without this, CFN rejects the import with
#       "Resources [X] is missing from ResourceToImport list".
#     Phase 1.5 (CLEANUP): delete any physical resource that would collide when
#       Phase 2 recreates it (e.g. an existing 0.0.0.0/0 route).
#     Phase 2 (UPDATE): deploy the FULL template so CFN creates the stripped
#       resources fresh.
#
#   RESOURCES_JSON : path to the resolved --resources-to-import array (file)
#   STAGE_TAG      : value for the POCStage tag (e.g. existing | new | rollback)
#   Returns 0 on success, non-zero on any failure.
cfn_import_then_update() {
  local stack="$1" region="$2" full_template="$3" import_config="$4"
  local params="$5" resources_json="$6" stage_tag="$7"
  local account="$8" domain="$9" module="${10}" extra_caps="${11:-}"
  local version="${12:-}" mtype="${13:-}"
  local prefix="  "

  # Optional ModuleVersion / ModuleType tags applied in Phase 2 (deploy).
  # NOTE: stack tags are NOT set in Phase 1 -- a CFN IMPORT change set rejects
  # them ("you cannot modify or add [Tags]"). All tags are applied in Phase 2.
  local dep_version_tags=""
  if [ -n "${version}" ]; then
    dep_version_tags="ModuleVersion=${version}"
  fi
  if [ -n "${mtype}" ]; then
    dep_version_tags="${dep_version_tags} ModuleType=${mtype}"
  fi

  local import_template actions_file
  import_template=$(mktemp /tmp/tesco-ims-import-tmpl-XXXXXX.yaml)
  actions_file=$(mktemp /tmp/tesco-ims-import-actions-XXXXXX.json)

  echo "${prefix}Phase 1: generating filtered import template..."
  if ! python3 new-structure/pipeline/generate_import_template.py \
        --template "${full_template}" \
        --config   "${import_config}" \
        --output   "${import_template}" \
        --actions-output "${actions_file}"; then
    echo "${prefix}[FAIL] Could not generate filtered import template."
    rm -f "${import_template}" "${actions_file}"
    return 1
  fi

  local resources_to_import changeset_name
  resources_to_import=$(cat "${resources_json}")
  changeset_name="import-$(date +%s)"

  echo "${prefix}Phase 1: creating IMPORT change set '${changeset_name}'..."
  # No --tags here: CFN rejects stack tags during an import operation. Tags are
  # applied in Phase 2 (deploy) instead.
  # shellcheck disable=SC2086
  if ! aws cloudformation create-change-set \
        --stack-name          "${stack}" \
        --change-set-name     "${changeset_name}" \
        --change-set-type     IMPORT \
        --resources-to-import "${resources_to_import}" \
        --template-body       "file://${import_template}" \
        --parameters          "file://${params}" \
        --region "${region}" \
        ${extra_caps}; then
    echo "${prefix}[FAIL] create-change-set (IMPORT) call failed."
    rm -f "${import_template}" "${actions_file}"
    return 1
  fi

  if ! _cfn_wait_changeset "${stack}" "${changeset_name}" "${region}" "${prefix}"; then
    rm -f "${import_template}" "${actions_file}"
    return 1
  fi

  echo "${prefix}Phase 1: executing IMPORT change set..."
  aws cloudformation execute-change-set \
    --stack-name "${stack}" --change-set-name "${changeset_name}" --region "${region}"

  if ! _cfn_wait_status "${stack}" "${region}" "IMPORT_COMPLETE" "${prefix}"; then
    rm -f "${import_template}" "${actions_file}"
    return 1
  fi
  echo "${prefix}[OK] Phase 1 complete -- resources imported."

  # Phase 1.5a: re-attach any VPCGatewayAttachment listed as Option A in
  # the import-config. The attachment is not CFN-importable so it is left
  # unmanaged, but it must exist before Phase 2 creates PublicRoute.
  _cfn_repair_gateway_attachment "${import_config}" "${resources_json}" "${region}" "${prefix}"

  # Phase 1.5: delete physical resources that would collide in Phase 2.
  _cfn_cleanup_conflicts "${actions_file}" "${resources_json}" "${region}" "${prefix}"

  # Phase 2: deploy the FULL template to create the stripped resources fresh.
  echo "${prefix}Phase 2: deploying full template (adds non-importable resources)..."
  # shellcheck disable=SC2086
  if ! aws cloudformation deploy \
        --stack-name          "${stack}" \
        --template-file       "${full_template}" \
        --parameter-overrides "file://${params}" \
        --tags POCStage="${stage_tag}" Account="${account}" \
               Domain="${domain}" Module="${module}" Repo=tesco-ims-poc-demo ${dep_version_tags} \
        --region "${region}" \
        --no-fail-on-empty-changeset \
        ${extra_caps}; then
    echo "${prefix}[FAIL] Phase 2 deploy failed for '${stack}'."
    _cfn_dump_failures "${stack}" "${region}" "${prefix}"
    rm -f "${import_template}" "${actions_file}"
    return 1
  fi

  echo "${prefix}[OK] Phase 2 complete -- '${stack}' fully reconciled to template."
  rm -f "${import_template}" "${actions_file}"
  return 0
}

# Internal: print the most recent stack events to surface the failure reason.
# Shows the 10 newest events (reverse-chronological). After a Phase 2 failure
# the CREATE_FAILED / UPDATE_FAILED events are always within the first 10 entries.
# The old FAILED-filter approach was unreliable: it missed events when the stack
# rolled back quickly and the describe call raced the rollback completion.
_cfn_dump_failures() {
  local stack="$1" region="$2" prefix="${3:-  }"
  echo "${prefix}---- recent events for '${stack}' ----"
  aws cloudformation describe-stack-events \
    --stack-name "${stack}" --region "${region}" \
    --query "StackEvents[:10].[LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
    --output text 2>/dev/null | sed "s/^/${prefix}  /"
  echo "${prefix}--------------------------------------"
}

# Internal: wait for a change set to reach CREATE_COMPLETE. Returns non-zero on FAILED.
_cfn_wait_changeset() {
  local stack="$1" cs="$2" region="$3" prefix="${4:-  }"
  local waited=0 status reason
  while true; do
    status=$(aws cloudformation describe-change-set \
      --stack-name "${stack}" --change-set-name "${cs}" --region "${region}" \
      --query 'Status' --output text 2>/dev/null || echo "UNKNOWN")
    case "${status}" in
      CREATE_COMPLETE) echo "${prefix}  change set ready"; return 0 ;;
      FAILED)
        reason=$(aws cloudformation describe-change-set \
          --stack-name "${stack}" --change-set-name "${cs}" --region "${region}" \
          --query 'StatusReason' --output text 2>/dev/null || echo "unknown")
        echo "${prefix}  [FAIL] change set FAILED: ${reason}"
        aws cloudformation delete-change-set \
          --stack-name "${stack}" --change-set-name "${cs}" --region "${region}" 2>/dev/null || true
        return 1 ;;
      *) sleep 10; waited=$((waited + 10)) ;;
    esac
    if [ "${waited}" -ge 300 ]; then
      echo "${prefix}  [FAIL] Timed out waiting for change set"
      return 1
    fi
  done
}

# Internal: wait for a stack to reach TARGET status. Returns non-zero on a failure state.
_cfn_wait_status() {
  local stack="$1" region="$2" target="$3" prefix="${4:-  }"
  local waited=0 status
  while true; do
    status=$(aws cloudformation describe-stacks \
      --stack-name "${stack}" --region "${region}" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")
    case "${status}" in
      "${target}") return 0 ;;
      *ROLLBACK_COMPLETE|*ROLLBACK_FAILED|CREATE_FAILED|UPDATE_FAILED|IMPORT_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_FAILED)
        echo "${prefix}  [FAIL] stack '${stack}' reached ${status} (wanted ${target})"
        return 1 ;;
      *) sleep 15; waited=$((waited + 15)) ;;
    esac
    if [ "${waited}" -ge 600 ]; then
      echo "${prefix}  [FAIL] Timed out waiting for '${stack}' -> ${target}"
      return 1
    fi
  done
}

# Internal: ensure VPCGatewayAttachment is in place for any module that lists
# AWS::EC2::VPCGatewayAttachment in option_a_resources.
# The attachment cannot be imported via CFN, so it is left unmanaged (Option A).
# When the owning stack is deleted and re-imported, the attachment may be gone;
# this function detects and repairs it before Phase 2 tries to create PublicRoute.
_cfn_repair_gateway_attachment() {
  local import_config="$1" resources_json="$2" region="$3" prefix="${4:-  }"

  # Skip if this module has no option_a VPCGatewayAttachment.
  local needs_attachment
  needs_attachment=$(python3 -c "
import json, sys
c = json.load(open('${import_config}'))
opt = c.get('option_a_resources', [])
print('yes' if any(r.get('ResourceType') == 'AWS::EC2::VPCGatewayAttachment' for r in opt) else 'no')
" 2>/dev/null) || needs_attachment="no"
  [ "${needs_attachment}" = "yes" ] || return 0

  # Resolve the physical VPC and IGW IDs from the import resources JSON.
  local vpc_id igw_id
  vpc_id=$(python3 -c "
import json, sys
res = json.load(open('${resources_json}'))
m = {r['LogicalResourceId']: r['ResourceIdentifier'] for r in res}
print(m.get('VPC', {}).get('VpcId', ''))
" 2>/dev/null)
  igw_id=$(python3 -c "
import json, sys
res = json.load(open('${resources_json}'))
m = {r['LogicalResourceId']: r['ResourceIdentifier'] for r in res}
print(m.get('InternetGateway', {}).get('InternetGatewayId', ''))
" 2>/dev/null)

  if [ -z "${vpc_id}" ] || [ -z "${igw_id}" ]; then
    echo "${prefix}  [WARN] Phase 1.5a: could not resolve VPC/IGW IDs -- skipping attachment repair"
    return 0
  fi

  # Check whether the IGW is already attached to our VPC.
  local attached_vpc
  attached_vpc=$(aws ec2 describe-internet-gateways \
    --internet-gateway-ids "${igw_id}" --region "${region}" \
    --query "InternetGateways[0].Attachments[?State=='available'].VpcId" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -w "${vpc_id}" || true)

  if [ -n "${attached_vpc}" ]; then
    echo "${prefix}  Phase 1.5a: IGW ${igw_id} already attached to ${vpc_id} -- nothing to do"
    return 0
  fi

  echo "${prefix}  Phase 1.5a: IGW ${igw_id} is detached -- re-attaching to ${vpc_id}..."
  if aws ec2 attach-internet-gateway \
      --internet-gateway-id "${igw_id}" \
      --vpc-id "${vpc_id}" \
      --region "${region}"; then
    echo "${prefix}  [OK] Phase 1.5a: IGW attached to ${vpc_id}"
  else
    echo "${prefix}  [FAIL] Phase 1.5a: attach-internet-gateway failed -- Phase 2 PublicRoute will fail"
    return 1
  fi
}

# Internal: delete physical resources that would collide when Phase 2 recreates them.
#   Currently handles AWS::EC2::Route (an existing 0.0.0.0/0 route blocks recreate).
#   actions_file   : sidecar from generate_import_template.py (dropped resources)
#   resources_json : resolved --resources-to-import array (for route table physical IDs)
_cfn_cleanup_conflicts() {
  local actions_file="$1" resources_json="$2" region="$3" prefix="${4:-  }"
  [ -s "${actions_file}" ] || return 0

  # Emit cleanup directives for each dropped resource that needs physical cleanup
  # before Phase 2 can create it fresh:
  #   ROUTE <route_table_id> <cidr>         -- pre-existing default route
  #   BUCKETPOLICY <bucket_name> -          -- pre-existing S3 bucket policy
  python3 - "${actions_file}" "${resources_json}" <<'PYEOF' | while read -r kind phys_id extra; do
import json, sys
actions = json.load(open(sys.argv[1]))
resolved = json.load(open(sys.argv[2]))

# Build logical-id -> physical-id map from the resolved import array.
phys = {}
for r in resolved:
    rid = r.get("ResourceIdentifier", {})
    logical = r.get("LogicalResourceId")
    rtype = r.get("ResourceType", "")
    if rtype == "AWS::EC2::RouteTable":
        phys[logical] = rid.get("RouteTableId", "")
    elif rtype == "AWS::S3::Bucket":
        phys[logical] = rid.get("BucketName", "")

for a in actions:
    rtype = a.get("ResourceType")
    if rtype == "AWS::EC2::Route":
        rt_logical = a.get("RouteTableLogicalId")
        rt_phys = phys.get(rt_logical, "")
        cidr = a.get("DestinationCidrBlock", "0.0.0.0/0")
        if rt_phys:
            print(f"ROUTE {rt_phys} {cidr}")
    elif rtype == "AWS::S3::BucketPolicy":
        bucket_logical = a.get("BucketLogicalId")
        bucket_name = phys.get(bucket_logical, "")
        if bucket_name:
            print(f"BUCKETPOLICY {bucket_name} -")
PYEOF
    case "${kind}" in
      ROUTE)
        echo "${prefix}Phase 1.5: removing pre-existing route ${extra} on ${phys_id} (avoids recreate conflict)..."
        aws ec2 delete-route --route-table-id "${phys_id}" \
          --destination-cidr-block "${extra}" --region "${region}" 2>/dev/null \
          && echo "${prefix}  [OK] stale route removed" \
          || echo "${prefix}  (no conflicting route present -- nothing to remove)"
        ;;
      BUCKETPOLICY)
        echo "${prefix}Phase 1.5: removing pre-existing bucket policy on '${phys_id}' (avoids recreate conflict)..."
        aws s3api delete-bucket-policy --bucket "${phys_id}" --region "${region}" 2>/dev/null \
          && echo "${prefix}  [OK] stale bucket policy removed" \
          || echo "${prefix}  (no bucket policy present -- nothing to remove)"
        ;;
    esac
  done
  return 0
}

# Internal helper: retry delete-stack --retain-resources on a DELETE_FAILED stack.
_cfn_retain_retry() {
  local stack="$1"
  local region="$2"
  local prefix="${3:-  |}"

  # Collect the logical resource IDs that are in DELETE_FAILED.
  local failed
  failed=$(aws cloudformation describe-stack-events \
    --stack-name "${stack}" --region "${region}" \
    --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].LogicalResourceId' \
    --output text 2>/dev/null | tr '\t' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')

  if [ -z "${failed}" ]; then
    # No DELETE_FAILED events found -- retain ALL resources so CFN can force through.
    failed=$(aws cloudformation describe-stack-resources \
      --stack-name "${stack}" --region "${region}" \
      --query 'StackResources[].LogicalResourceId' \
      --output text 2>/dev/null | tr '\t' ' ')
  fi

  echo "${prefix}  Retaining: ${failed}"
  # shellcheck disable=SC2086
  aws cloudformation delete-stack \
    --stack-name "${stack}" \
    --retain-resources ${failed} \
    --region "${region}"

  local attempts=0
  while true; do
    local status
    status=$(aws cloudformation describe-stacks \
      --stack-name "${stack}" --region "${region}" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    case "${status}" in
      DOES_NOT_EXIST|DELETE_COMPLETE)
        echo "${prefix}  [OK] '${stack}' released (retain-retry succeeded)"
        return 0 ;;
      DELETE_FAILED)
        echo "${prefix}  [FAIL] Stack still in DELETE_FAILED after retain-retry"
        echo "${prefix}  Run: aws cloudformation describe-stack-events --stack-name ${stack} --region ${region}"
        return 1 ;;
      DELETE_IN_PROGRESS)
        sleep 10
        attempts=$((attempts + 1))
        if [ "${attempts}" -ge 60 ]; then
          echo "${prefix}  [FAIL] Timed out waiting for retain-retry to complete"
          return 1
        fi ;;
      *)
        sleep 10
        attempts=$((attempts + 1)) ;;
    esac
  done
}
