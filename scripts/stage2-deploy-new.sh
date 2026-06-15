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
# FIVE-PASS MIGRATION FLOW:
#   Pass A: Pre-flight    -- version check + cfn-lint all modules (no AWS, fail fast)
#   Pass 0: Safety harden -- add DeletionPolicy: Retain to every EXISTING stack resource
#   Pass B: Resolve       -- while EXISTING stacks still exist, resolve import IDs
#   [GATE: type TRANSFER to continue]
#   Pass C: Release       -- delete ALL EXISTING stacks in reverse order
#   Pass D: Import/Deploy -- import (or deploy) ALL NEW stacks in forward order
set -e

ACCOUNT=${1:-dev}
shift || true   # remaining args are the optional module filter list
MODULES_FILTER=("$@")

REGION="eu-west-1"

# shellcheck source=scripts/lib/stack-names.sh
source "$(dirname "$0")/lib/stack-names.sh"

# -- Migration log setup ---------------------------------------------------
# Creates logs/migration-{account}-{date}-{time}.log in the repo root.
# All log writes are fire-and-forget (|| true) so a logging failure never
# aborts the migration itself.
mkdir -p logs
MIGRATION_LOG="logs/migration-${ACCOUNT}-$(date '+%Y%m%d-%H%M%S').log"
MIGRATION_START_EPOCH=$(date +%s)

_mlog() {
  echo "$@" >> "${MIGRATION_LOG}" 2>/dev/null || true
}

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

# In CI, warn early if TRANSFER was not confirmed so the log is unambiguous.
if [ "${CI}" = "true" ] && [ "${TRANSFER_CONFIRM:-}" != "TRANSFER" ]; then
  echo "+======================================================+"
  echo "|  DRY RUN -- Pass C (ownership transfer) will NOT run "
  echo "|  confirm_release was not set to TRANSFER             "
  echo "|  Passes A, 0, and B will complete (read-only checks) "
  echo "|  No EXISTING stacks will be deleted or transferred   "
  echo "+======================================================+"
  echo ""
fi

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

# Write log header now that we know which modules are in scope
{
  echo "========================================================"
  echo "TESCO IMS MIGRATION LOG"
  echo "========================================================"
  echo "Account  : ${ACCOUNT}"
  echo "Region   : ${REGION}"
  echo "Started  : $(date '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Script   : stage2-deploy-new.sh"
  echo ""
  echo "Modules queued (${#MODULES_TO_DEPLOY[@]}):"
  for dm in "${MODULES_TO_DEPLOY[@]}"; do
    echo "  ${dm}"
  done
  echo ""
  echo "========================================================"
  echo "PASS B -- RESOURCE MAPPING"
  echo "Captured from EXISTING stacks before ownership transfer."
  echo "========================================================"
} >> "${MIGRATION_LOG}" 2>/dev/null || true

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
# PASS 0: Safety hardening -- add DeletionPolicy: Retain to every resource in
# every EXISTING stack before any stack is read, modified, or deleted.
#
# Without DeletionPolicy: Retain, deleting an EXISTING stack in Pass C would
# permanently destroy the physical AWS resources (VPCs, KMS keys, S3 buckets).
# This pass is fully idempotent: if Retain is already present it exits in
# seconds. It is the first AWS touch in the migration.
# ==========================================================================
echo ">> PASS 0: Safety hardening -- ensuring DeletionPolicy: Retain on all EXISTING stacks..."
echo "   (Idempotent -- safe to re-run. Exits immediately if Retain is already in place.)"
echo ""

for domain_module in "${MODULES_TO_DEPLOY[@]}"; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"
  OLD_STACK=$(cfn_stack_name "EXISTING" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")

  echo "  ${domain_module}: checking '${OLD_STACK}'..."
  python3 new-structure/pipeline/add_deletion_policy.py \
    --stack-name "${OLD_STACK}" \
    --region     "${REGION}" || {
    echo ""
    echo "  [FAIL] ${domain_module}: safety hardening failed for '${OLD_STACK}'."
    echo "         Fix the error above and re-run. Migration aborted."
    exit 1
  }
done

echo ""
echo ">> PASS 0 complete. All EXISTING stacks have DeletionPolicy: Retain on every resource."
echo "   Resources are safe -- deleting an EXISTING stack in Pass C will NOT destroy AWS resources."
echo ""

# ==========================================================================
# PRE-CLASSIFICATION: check each module's NEW stack status before Pass B.
#
# NEEDS_MIGRATE -- NEW stack absent or stuck -- runs Pass B (resolve IDs),
#                  Pass C (release EXISTING), and Pass D (import/deploy)
# NEEDS_UPDATE  -- NEW stack healthy         -- bypasses TRANSFER gate,
#                  only smart param refresh in Pass D
#
# This prevents the TRANSFER gate from listing already-migrated stacks and
# avoids DRY RUN aborting when all NEW stacks are already healthy.
# ==========================================================================
NEEDS_MIGRATE=()
NEEDS_UPDATE=()

echo ">> Pre-classifying modules (checking NEW stack status)..."
for domain_module in "${MODULES_TO_DEPLOY[@]}"; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"
  _PC_STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  _PC_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${_PC_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")
  case "${_PC_STATUS}" in
    ROLLBACK_COMPLETE|ROLLBACK_FAILED|CREATE_FAILED|UPDATE_ROLLBACK_FAILED|\
    IMPORT_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_FAILED|DELETE_FAILED|DOES_NOT_EXIST)
      NEEDS_MIGRATE+=("${domain_module}")
      echo "  ${domain_module}: NEW=${_PC_STATUS} -> [MIGRATE] (Pass B/C/D)"
      ;;
    *)
      NEEDS_UPDATE+=("${domain_module}")
      echo "  ${domain_module}: NEW=${_PC_STATUS} -> [UPDATE] (Pass D smart-check only)"
      ;;
  esac
done
echo ""
if [ ${#NEEDS_MIGRATE[@]} -gt 0 ]; then
  echo "  Will MIGRATE (TRANSFER gate required): ${NEEDS_MIGRATE[*]}"
fi
if [ ${#NEEDS_UPDATE[@]} -gt 0 ]; then
  echo "  Will UPDATE  (no TRANSFER gate)      : ${NEEDS_UPDATE[*]}"
fi
echo ""

# ==========================================================================
# PASS B: Resolve -- while ALL EXISTING stacks still exist, resolve import
# identifiers for each module that has an import-config.json.
# Save resolved import JSON to /tmp for use in Pass D.
# Only runs for NEEDS_MIGRATE modules -- NEEDS_UPDATE already have healthy NEW
# stacks and do not need import identifier resolution.
# ==========================================================================
echo ">> PASS B: Resolve -- capturing physical resource IDs from EXISTING stacks..."
echo ""

for domain_module in "${NEEDS_MIGRATE[@]}"; do
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

  # Check NEW stack status: skip healthy stacks, treat stuck states like
  # DOES_NOT_EXIST so Pass D can clear and re-import them.
  NEW_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${NEW_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  case "${NEW_STATUS}" in
    ROLLBACK_COMPLETE|ROLLBACK_FAILED|CREATE_FAILED|UPDATE_ROLLBACK_FAILED|\
    IMPORT_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_FAILED|DELETE_FAILED)
      echo "  ${domain_module}: NEW stack stuck in ${NEW_STATUS} -- will clear and re-import in Pass D"
      ;;
    DOES_NOT_EXIST)
      ;;
    *)
      echo "  ${domain_module}: NEW stack already exists (${NEW_STATUS}) -- skipping resolve"
      continue
      ;;
  esac

  # Resolve parameters first (needed for param-source identifiers)
  python3 new-structure/pipeline/resolve_parameters.py \
    --account "${ACCOUNT}" \
    --domain  "${DOMAIN}" \
    --module  "${MODULE}" \
    --output  "${RESOLVED}" >/dev/null

  # Resolve import IDs from the EXISTING stack if it is still present.
  # If EXISTING is already gone (re-run after partial failure), fall back to
  # locating retained resources via CFN tags (same recovery path as stage1).
  OLD_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${OLD_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "${OLD_STATUS}" != "DOES_NOT_EXIST" ]; then
    echo "  ${domain_module}: resolving import identifiers from EXISTING stack '${OLD_STACK}'..."
    python3 new-structure/pipeline/resolve_import.py \
      --stack-name "${OLD_STACK}" \
      --config     "${IMPORT_CONFIG}" \
      --params     "${RESOLVED}" \
      --region     "${REGION}" \
      --output     "${IMPORT_FILE}" \
      --fallback-by-tag
  else
    echo "  ${domain_module}: EXISTING stack gone -- locating retained resources via tags (re-run recovery)..."
    RESOLVE_STDERR=$(mktemp)
    python3 new-structure/pipeline/resolve_import.py \
      --stack-name "${OLD_STACK}" \
      --config     "${IMPORT_CONFIG}" \
      --params     "${RESOLVED}" \
      --region     "${REGION}" \
      --output     "${IMPORT_FILE}" \
      --fallback-by-tag \
      --validate 2>"${RESOLVE_STDERR}" || {
      cat "${RESOLVE_STDERR}"
      rm -f "${RESOLVE_STDERR}"
      echo "  [FAIL] ${domain_module}: cannot locate retained resources -- they may have been deleted."
      echo "     Run stage1-deploy-existing.sh to re-establish the EXISTING stack, then retry."
      exit 1
    }
    rm -f "${RESOLVE_STDERR}"
  fi

  echo "  [OK] ${domain_module}: import identifiers saved to ${IMPORT_FILE}"

  # Write the full resource mapping to the migration log.
  # This is the key record: what physical ID maps to what logical ID BEFORE
  # the EXISTING stack is deleted and ownership moves to the NEW stack.
  {
    echo ""
    echo "--- ${domain_module} ---"
    echo "  EXISTING stack : ${OLD_STACK}  (status: ${OLD_STATUS})"
    echo "  NEW stack      : ${NEW_STACK}  (to be created)"
    echo "  Resolved params: ${RESOLVED}"
    echo "  Import IDs file: ${IMPORT_FILE}"
    echo ""

    # Section 1: resolved parameter values from the 4-layer config system
    echo "  Resolved parameters (4-layer config merge):"
    printf "  %-44s  %s\n" "Parameter" "Value"
    printf "  %s\n" "--------------------------------------------  -----------------------------------------------"
    python3 -c "
import json
try:
    params = json.load(open('${RESOLVED}'))
    for p in params:
        k = p.get('ParameterKey', '')
        v = p.get('ParameterValue', '')
        print('  {:<44}  {}'.format(k, v))
except Exception as e:
    print('  [could not parse params file: ' + str(e) + ']')
"
    echo ""

    # Section 2: physical resource IDs captured from the EXISTING stack --
    # the exact mapping that CFN Resource Import will use
    echo "  Physical resource mapping (captured from EXISTING stack before release):"
    printf "  %-40s  %-44s  %s\n" "Logical ID" "Resource Type" "Physical ID"
    printf "  %s\n" "----------------------------------------  --------------------------------------------  ----------------------------------------"
    python3 -c "
import json
try:
    data = json.load(open('${IMPORT_FILE}'))
    for r in data:
        lid   = r.get('LogicalResourceId', '')
        rtype = r.get('ResourceType', '')
        phys  = list(r.get('ResourceIdentifier', {}).values())
        phys_str = ', '.join(str(v) for v in phys) if phys else 'n/a'
        print('  {:<40}  {:<44}  {}'.format(lid, rtype, phys_str))
except Exception as e:
    print('  [could not parse import file: ' + str(e) + ']')
"
    echo ""

    # Section 3: Option A -- permanently unmanaged (retained in AWS, no stack owns them)
    echo "  Option A resources (retained in AWS forever, not owned by any CFN stack):"
    python3 -c "
import json
try:
    cfg = json.load(open('${IMPORT_CONFIG}'))
    option_a = cfg.get('option_a_resources', [])
    if option_a:
        for r in option_a:
            print('    {:<40}  {:<44}'.format(r.get('LogicalResourceId',''), r.get('ResourceType','')))
            print('      Reason: ' + r.get('reason','n/a'))
    else:
        print('    (none)')
except Exception as e:
    print('    [could not parse: ' + str(e) + ']')
"
    echo ""

    # Section 4: Phase 2 fresh creates -- deleted at Phase 1.5, recreated by Phase 2
    echo "  Phase 2 recreate resources (not importable -- deleted at 1.5, created fresh at Phase 2):"
    python3 -c "
import json
try:
    cfg = json.load(open('${IMPORT_CONFIG}'))
    phase2 = cfg.get('phase2_resources', [])
    if phase2:
        for r in phase2:
            print('    {:<40}  {:<44}'.format(r.get('LogicalResourceId',''), r.get('ResourceType','')))
            print('      Reason: ' + r.get('reason','n/a'))
    else:
        print('    (none)')
except Exception as e:
    print('    [could not parse: ' + str(e) + ']')
"
    echo ""
  } >> "${MIGRATION_LOG}" 2>/dev/null || true

  echo ""
done

echo ">> PASS B complete."
echo ""

# ==========================================================================
# CONFIRMATION GATE -- between Pass B and Pass C.
#
# Pass C deletes ALL EXISTING stacks. This is the real point of no return.
# Physical resources are retained (DeletionPolicy: Retain) but CloudFormation
# ownership is released. Rollback is still possible via stage5 but requires
# re-importing retained resources.
#
# Local runs:  require typing "TRANSFER" before proceeding.
# CI runs:     TRANSFER_CONFIRM env var must also equal "TRANSFER" -- blank or
#              any other value aborts. There is no silent fallthrough.
# ==========================================================================
if [ ${#NEEDS_MIGRATE[@]} -eq 0 ]; then
  echo ""
  echo "+======================================================+"
  echo "|  ALL MODULES ALREADY MIGRATED                        "
  echo "|                                                      "
  echo "|  All NEW stacks are healthy -- no EXISTING stacks    "
  echo "|  need to be released. Skipping TRANSFER gate.        "
  echo "|  Pass D will smart-check for param/version changes.  "
  echo "+======================================================+"
  echo ""
  if [ "${CI}" = "true" ] && [ "${TRANSFER_CONFIRM:-}" != "TRANSFER" ]; then
    echo ">> DRY RUN -- TRANSFER not confirmed. Skipping Pass D."
    echo ">> All modules are already migrated. To apply param/version changes,"
    echo ">> re-run with confirm_release = TRANSFER."
    exit 0
  fi
else
  echo ""
  echo "+======================================================+"
  echo "|  READY TO TRANSFER OWNERSHIP                         "
  echo "|                                                      "
  echo "|  Pass B is complete. All resource mappings captured. "
  echo "|  Migration log: ${MIGRATION_LOG}"
  echo "|                                                      "
  echo "|  Pass C will DELETE the following EXISTING stacks:   "
  for dm in "${NEEDS_MIGRATE[@]}"; do
    OLD=$(cfn_stack_name "EXISTING" "${dm%/*}" "${dm#*/}" "${ACCOUNT}")
    echo "|    ${OLD}"
  done
  echo "|                                                      "
  echo "|  AWS resources are RETAINED (DeletionPolicy: Retain) "
  echo "|  Rollback via stage5-rollback.sh is still possible.  "
  echo "+======================================================+"
  echo ""

  if [ "${CI}" = "true" ]; then
    if [ "${TRANSFER_CONFIRM:-}" = "TRANSFER" ]; then
      echo ">> CI mode -- TRANSFER confirmed. Proceeding with Pass C."
    else
      echo ">> Aborted -- set confirm_release = TRANSFER in the workflow dispatch to proceed."
      echo ">> EXISTING stacks are untouched. Re-run when ready."
      exit 0
    fi
  else
    read -r -p ">> Type TRANSFER to confirm -- this will delete EXISTING stacks and transfer CloudFormation ownership to the new modules. Anything else cancels: " _TRANSFER_CONFIRM
    if [ "${_TRANSFER_CONFIRM}" != "TRANSFER" ]; then
      echo ""
      echo ">> Migration cancelled. EXISTING stacks untouched."
      echo ">> Re-run when ready. Pass B output is in: ${MIGRATION_LOG}"
      exit 0
    fi
    echo ""
  fi

  _mlog ""
  _mlog "CONFIRMATION GATE"
  _mlog "  $(date '+%Y-%m-%d %H:%M:%S UTC')  Proceeding with Pass C (release EXISTING stacks)"
  if [ "${CI}" = "true" ]; then
    _mlog "  Mode: CI -- TRANSFER confirmed via workflow dispatch input"
  else
    _mlog "  Mode: interactive -- operator typed TRANSFER"
  fi
fi

# ==========================================================================
# PASS C: Release -- delete ALL EXISTING stacks in REVERSE discovery order.
# S3 must be deleted before VPC because S3 imports VPC's exported VpcId --
# an exported value cannot be deleted while a stack imports it.
# DeletionPolicy: Retain keeps resources in AWS -- only CFN ownership released.
# Skip if EXISTING stack is already gone.
# ==========================================================================
echo ">> PASS C: Release -- deleting EXISTING stacks (reverse order)..."
echo ""

{
  echo "========================================================"
  echo "PASS C -- OWNERSHIP RELEASE"
  echo "Deleting EXISTING stacks. DeletionPolicy: Retain keeps"
  echo "all AWS resources alive throughout."
  echo "========================================================"
} >> "${MIGRATION_LOG}" 2>/dev/null || true

# Collect NEEDS_MIGRATE modules in reverse order for deletion.
# NEEDS_UPDATE modules are skipped -- their NEW stacks are already healthy.
REVERSE_MODULES=()
while IFS= read -r domain_module; do
  REVERSE_MODULES=("${domain_module}" "${REVERSE_MODULES[@]}")
done < <(printf '%s\n' "${NEEDS_MIGRATE[@]}")

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
  _mlog "  $(date '+%H:%M:%S')  RELEASING  ${OLD_STACK}"
  cfn_delete_stack_robust "${OLD_STACK}" "${REGION}" "  |"
  _mlog "  $(date '+%H:%M:%S')  RELEASED   ${OLD_STACK}  (AWS resources retained)"
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

{
  echo ""
  echo "========================================================"
  echo "PASS D -- CFN IMPORT / DEPLOY"
  echo "Creating NEW stacks. Resources imported from retained"
  echo "AWS infrastructure (not recreated)."
  echo "========================================================"
} >> "${MIGRATION_LOG}" 2>/dev/null || true

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
  # Stuck states (ROLLBACK_COMPLETE etc.) are cleared automatically -- resources
  # are retained by DeletionPolicy: Retain so re-import can recover them.
  NEW_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${NEW_STACK}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  case "${NEW_STATUS}" in
    ROLLBACK_COMPLETE|ROLLBACK_FAILED|CREATE_FAILED|UPDATE_ROLLBACK_FAILED|\
    IMPORT_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_FAILED|DELETE_FAILED)
      echo "  |  [WARN] '${NEW_STACK}' stuck in ${NEW_STATUS}."
      echo "  |  Clearing stuck stack (DeletionPolicy: Retain preserves AWS resources)..."
      cfn_delete_stack_robust "${NEW_STACK}" "${REGION}" "  |"
      echo "  |  [OK] Stuck stack cleared -- proceeding with re-import"
      ;;
    DOES_NOT_EXIST)
      ;;
    *)
      echo "  |  [OK] NEW stack exists (${NEW_STATUS}) -- checking for changes..."

      # Resolve fresh parameters before comparing.
      if [ ! -f "${RESOLVED}" ]; then
        python3 new-structure/pipeline/resolve_parameters.py \
          --account "${ACCOUNT}" --domain "${DOMAIN}" --module "${MODULE}" \
          --output  "${RESOLVED}"
      fi

      # Fetch live stack parameters and deployed version tag.
      LIVE_PARAMS_FILE="/tmp/tesco-live-params-${ACCOUNT}-${DOMAIN}-${MODULE}.json"
      aws cloudformation describe-stacks \
        --stack-name "${NEW_STACK}" --region "${REGION}" \
        --query 'Stacks[0].Parameters' --output json 2>/dev/null \
        > "${LIVE_PARAMS_FILE}" || echo "[]" > "${LIVE_PARAMS_FILE}"

      LIVE_VERSION=$(aws cloudformation describe-stacks \
        --stack-name "${NEW_STACK}" --region "${REGION}" \
        --query 'Stacks[0].Tags[?Key==`ModuleVersion`].Value | [0]' \
        --output text 2>/dev/null || echo "")

      # Compare resolved params against live params and module version.
      # Prints "no" when nothing changed, "yes (<reason>)" when update is needed.
      DEPLOY_NEEDED=$(python3 - "${RESOLVED}" "${LIVE_PARAMS_FILE}" "${VERSION}" "${LIVE_VERSION}" <<'PYEOF'
import json, sys

resolved_path, live_path, target_ver, live_ver = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

resolved = {p['ParameterKey']: p['ParameterValue'] for p in json.load(open(resolved_path))}
try:
    raw = json.load(open(live_path))
    live = {p['ParameterKey']: p['ParameterValue'] for p in (raw or [])}
except Exception:
    print("yes (could not read live params)")
    sys.exit(0)

param_diff = sorted(k for k in set(list(resolved) + list(live)) if resolved.get(k) != live.get(k))
ver_diff   = target_ver.strip() != live_ver.strip()

if not param_diff and not ver_diff:
    print("no")
else:
    reasons = []
    if param_diff:
        reasons.append(f"params: {', '.join(param_diff)}")
    if ver_diff:
        reasons.append(f"version: {live_ver.strip() or 'none'} -> {target_ver.strip()}")
    print("yes (" + "; ".join(reasons) + ")")
PYEOF
      )
      rm -f "${LIVE_PARAMS_FILE}"

      if [ "${DEPLOY_NEEDED}" = "no" ]; then
        echo "  |  [SKIP] No changes detected -- stack is already up to date"
        _mlog "  $(date '+%H:%M:%S')  SKIPPED    ${NEW_STACK}  v${VERSION}  (no param or version changes)"
        DEPLOYED+=("${NEW_STACK}")
        echo ""
        continue
      fi

      echo "  |  Changes detected: ${DEPLOY_NEEDED}"
      echo "  |  Deploying update..."
      EXTRA_CAPS=""
      if grep -q "Type: AWS::IAM::" "${TEMPLATE}" 2>/dev/null; then
        EXTRA_CAPS="--capabilities CAPABILITY_NAMED_IAM"
      fi
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
      echo "  |  [OK] ${NEW_STACK} [ModuleVersion=${VERSION}]"
      _mlog "  $(date '+%H:%M:%S')  UPDATED    ${NEW_STACK}  v${VERSION}  (${DEPLOY_NEEDED})"
      DEPLOYED+=("${NEW_STACK}")
      echo ""
      continue
      ;;
  esac

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
      # Capture exit code explicitly with || to prevent set -e from exiting
      # when the stack does not yet exist (AWS CLI exits 254 for missing stacks).
      AWS_EXIT=0
      AWS_OUT=$(aws cloudformation describe-stacks \
        --stack-name "${DEP_STACK}" --region "${REGION}" \
        --query 'Stacks[0].StackStatus' --output text 2>/tmp/aws_dep_err_$$.txt) || AWS_EXIT=$?

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
          # Only UPDATE_COMPLETE / CREATE_COMPLETE guarantee that Outputs are
          # exported and available for Fn::ImportValue in dependent stacks.
          # IMPORT_COMPLETE means Phase 1 only -- Phase 2 (which adds Outputs)
          # has not run yet. Treating IMPORT_COMPLETE as ready caused S3 Phase 1
          # to fail when KMS/VPC exports were not yet live.
          echo "  |  [OK] '${DEP_STACK}' is ready (${DEP_STATUS}) -- continuing with ${MODULE}"
          break ;;

        ROLLBACK_COMPLETE|ROLLBACK_FAILED|DELETE_COMPLETE|CREATE_FAILED|\
        UPDATE_FAILED|UPDATE_ROLLBACK_COMPLETE|UPDATE_ROLLBACK_FAILED|\
        IMPORT_ROLLBACK_COMPLETE|IMPORT_ROLLBACK_FAILED)
          echo ""
          echo "  [FAIL] CANCELLED -- dependency '${DEP_STACK}' is in a failed state: ${DEP_STATUS}"
          echo "     '${MODULE}' requires '${DEP_STACK}' to be healthy before it can deploy."
          echo "     Fix '${DEP_STACK}' first, then re-run this stage."
          echo ""
          exit 1 ;;

        CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS|\
        IMPORT_IN_PROGRESS|IMPORT_COMPLETE)
          # IMPORT_COMPLETE = Phase 1 done, Phase 2 (UPDATE) not yet started.
          # Outputs are not exported until Phase 2 finishes at UPDATE_COMPLETE.
          # Keep waiting.
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
    _mlog "  $(date '+%H:%M:%S')  IMPORTED   ${NEW_STACK}  v${VERSION}  (two-phase CFN import)"

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
    _mlog "  $(date '+%H:%M:%S')  DEPLOYED   ${NEW_STACK}  v${VERSION}  (fresh deploy, no import)"
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

# Write migration log footer
{
  MIGRATION_END_EPOCH=$(date +%s)
  MIGRATION_DURATION=$(( MIGRATION_END_EPOCH - MIGRATION_START_EPOCH ))
  echo ""
  echo "========================================================"
  echo "MIGRATION COMPLETE"
  echo "========================================================"
  echo "Account  : ${ACCOUNT}"
  echo "Finished : $(date '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Duration : ${MIGRATION_DURATION}s"
  echo "Modules  : ${#DEPLOYED[@]} deployed"
  echo ""
  echo "Final stack status:"
  for S in "${DEPLOYED[@]}"; do
    STATUS=$(aws cloudformation describe-stacks \
      --stack-name "${S}" --region "${REGION}" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
    printf "  %-56s  %s\n" "${S}" "${STATUS}"
  done
  echo ""
  echo "Next step: scripts/stage3-validate-parity.sh ${ACCOUNT}"
  echo "========================================================"
} >> "${MIGRATION_LOG}" 2>/dev/null || true

echo ""
echo "  Migration log: ${MIGRATION_LOG}"
