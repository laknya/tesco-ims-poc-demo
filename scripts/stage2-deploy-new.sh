#!/bin/bash
# Stage 2 — Deploy NEW centralized modules.
#
# Usage:
#   bash stage2-deploy-new.sh <account> [domain/module ...]
#
#   <account>          : dev | sandbox | coll-dev | coll-ppe
#   [domain/module ...]: optional filter — only deploy these modules.
#                        If omitted, all modules for the account are deployed.
#                        In CI, the detect_changes.py matrix passes exactly one
#                        module per job so each is deployed independently.
#
# Examples
#   bash stage2-deploy-new.sh dev
#     → discovers and deploys all modules configured for dev
#
#   bash stage2-deploy-new.sh dev networking/vpc-baseline
#     → deploys ONLY vpc-baseline for dev (CI delta path)
#
#   bash stage2-deploy-new.sh dev networking/vpc-baseline shared-services/s3-bucket
#     → deploys only those two modules
set -e

ACCOUNT=${1:-dev}
shift || true   # remaining args are the optional module filter list
MODULES_FILTER=("$@")

REGION="eu-west-1"

# shellcheck source=scripts/lib/stack-names.sh
source "$(dirname "$0")/lib/stack-names.sh"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  STAGE 2 — Deploy NEW centralized modules            "
echo "║  Account  : ${ACCOUNT}                               "
if [ ${#MODULES_FILTER[@]} -gt 0 ]; then
echo "║  Mode     : DELTA — deploying changed modules only   "
for m in "${MODULES_FILTER[@]}"; do
echo "║    → ${m}"
done
else
echo "║  Mode     : FULL  — deploying all modules for account"
fi
echo "╚══════════════════════════════════════════════════════╝"
echo ""

pip install pyyaml cfn-lint -q 2>/dev/null || true

# ── Version integrity check ───────────────────────────────────────────
echo "► Verifying module version integrity (template hash vs version.json)..."
python3 new-structure/pipeline/check_module_versions.py
echo ""

# ── Schema validation ─────────────────────────────────────────────────
echo "► Validating account configs against module schemas..."
python3 new-structure/pipeline/validate_schema.py --account "${ACCOUNT}"
echo ""

DEPLOYED=()

# ── Build the deploy list: all discovered modules OR the explicit filter ──
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
  echo "⚠️  No modules matched the filter for account '${ACCOUNT}'. Nothing deployed."
  exit 0
fi

echo "► Modules to deploy (${#MODULES_TO_DEPLOY[@]}):"
for dm in "${MODULES_TO_DEPLOY[@]}"; do
  echo "    ${dm}"
done
echo ""

# ── Deploy each module ────────────────────────────────────────────────
for domain_module in "${MODULES_TO_DEPLOY[@]}"; do
  DOMAIN="${domain_module%/*}"
  MODULE="${domain_module#*/}"

  VERSION=$(python3 -c "import json; print(json.load(open('new-structure/modules/${domain_module}/version.json'))['version'])")
  TYPE=$(python3 -c "import json; print(json.load(open('new-structure/modules/${domain_module}/version.json'))['type_name'])")
  STACK=$(cfn_stack_name "NEW" "${DOMAIN}" "${MODULE}" "${ACCOUNT}")
  TEMPLATE="new-structure/modules/${domain_module}/template.yaml"
  RESOLVED="/tmp/new-resolved-${ACCOUNT}-${DOMAIN}-${MODULE}.json"

  echo "  ┌─ Module  : ${TYPE}  v${VERSION}"
  echo "  │  Stack   : ${STACK}"
  echo "  │  Template: ${TEMPLATE}"

  # Lint template before deploy
  cfn-lint "${TEMPLATE}"
  echo "  │  cfn-lint ✅"

  # Step A: 4-layer parameter resolution
  echo "  ├─ Step A: Resolving parameters (4-layer config)..."
  python3 new-structure/pipeline/resolve_parameters.py \
    --account "${ACCOUNT}" \
    --domain  "${DOMAIN}" \
    --module  "${MODULE}" \
    --output  "${RESOLVED}"

  # Step B: Deploy from the ONE master template
  echo "  └─ Step B: Deploying from master template [ModuleVersion=${VERSION}]..."

  EXTRA_CAPS=""
  [[ "${MODULE}" == "kms-key" ]] && EXTRA_CAPS="--capabilities CAPABILITY_NAMED_IAM"

  # shellcheck disable=SC2086
  aws cloudformation deploy \
    --stack-name  "${STACK}" \
    --template-file "${TEMPLATE}" \
    --parameter-overrides "file://${RESOLVED}" \
    --tags POCStage=new Account="${ACCOUNT}" \
           Domain="${DOMAIN}" Module="${MODULE}" \
           ModuleVersion="${VERSION}" ModuleType="${TYPE}" \
           Repo=tesco-ims-poc-demo \
    --region "${REGION}" \
    --no-fail-on-empty-changeset \
    ${EXTRA_CAPS}
  echo "     ✅ ${STACK}  [ModuleVersion=${VERSION}]"
  DEPLOYED+=("${STACK}")
  echo ""

done

echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  Deployed ${#DEPLOYED[@]} module(s) (${ACCOUNT})  "
echo "╚══════════════════════════════════════════════════════╝"
echo ""
for S in "${DEPLOYED[@]}"; do
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${S}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
  printf "  %-54s → %s\n" "${S}" "${STATUS}"
done
echo ""
echo "  Run scripts/stage3-validate-parity.sh ${ACCOUNT} next."
