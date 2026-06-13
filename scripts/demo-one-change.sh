#!/bin/bash
# DEMO SCRIPT — "One change in _defaults, all accounts get it"
#
# This is the key business demo moment:
#   "Old world: change a tag or policy default → edit 68 files (VPC + KMS = 136 files)"
#   "New world: change it in _defaults → all 68 accounts automatically pick it up"
#
# Usage: bash scripts/demo-one-change.sh

set -e

VPC_DEFAULTS="new-structure/config/_defaults/networking/vpc-baseline.json"
KMS_DEFAULTS="new-structure/config/_defaults/security/kms-key.json"

pip install pyyaml -q 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  DEMO: One Change → All Accounts                     "
echo "║  Modules: VPC Baseline + KMS Key                     "
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Shared _defaults (inherited by ALL accounts, ALL modules):"
echo ""
echo "  VPC defaults:"
python3 -c "import json; d=json.load(open('${VPC_DEFAULTS}')); [print(f'    {k:<28} = {v}') for k,v in d.items()]"
echo ""
echo "  KMS defaults:"
python3 -c "import json; d=json.load(open('${KMS_DEFAULTS}')); [print(f'    {k:<28} = {v}') for k,v in d.items()]"
echo ""

echo "  SCENARIO: Finance asks us to update CostCentre from"
echo "  TESCO-IMS-PLATFORM to TESCO-IMS-PLATFORM-2026"
echo ""
echo "  EXISTING WAY: Edit CostCentre in 68 vpc-template.yaml files"
echo "           AND 68 kms-template.yaml files = 136 file edits"
echo "  NEW WAY: Edit 1 line in _defaults/networking + 1 line in"
echo "           _defaults/security = 2 file edits"
echo ""
read -p "Press ENTER to see resolver run for the dev account..."

echo ""
echo "  Resolving parameters BEFORE the change:"
echo "  ─────────────────────────────────────────"

echo ""
echo "  [dev] VPC:"
python3 new-structure/pipeline/resolve_parameters.py \
  --account dev \
  --domain  networking \
  --module  vpc-baseline \
  --output  "/tmp/resolved-dev-vpc.json" 2>&1 | grep -E "(Layer|CostCentre)" | sed 's/^/    /'
COST=$(python3 -c "import json; params={p['ParameterKey']:p['ParameterValue'] for p in json.load(open('/tmp/resolved-dev-vpc.json'))}; print(params.get('CostCentre','?'))")
echo "    → CostCentre = ${COST}"

echo ""
echo "  [dev] KMS:"
python3 new-structure/pipeline/resolve_parameters.py \
  --account dev \
  --domain  security \
  --module  kms-key \
  --output  "/tmp/resolved-dev-kms.json" 2>&1 | grep -E "(Layer|CostCentre)" | sed 's/^/    /'
COST=$(python3 -c "import json; params={p['ParameterKey']:p['ParameterValue'] for p in json.load(open('/tmp/resolved-dev-kms.json'))}; print(params.get('CostCentre','?'))")
echo "    → CostCentre = ${COST}"

echo ""
echo "─────────────────────────────────────────────────────────"
echo "  Making the change: 2 files, 2 lines (VPC + KMS defaults)"
echo "─────────────────────────────────────────────────────────"
echo ""

python3 -c "
import json
for path, label in [('${VPC_DEFAULTS}', 'VPC'), ('${KMS_DEFAULTS}', 'KMS')]:
    with open(path) as f:
        d = json.load(f)
    old_val = d['CostCentre']
    d['CostCentre'] = 'TESCO-IMS-PLATFORM-2026'
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
    print(f'  Changed [{label}]: CostCentre  {old_val!r}  →  \"TESCO-IMS-PLATFORM-2026\"')
print()
print('  2 files changed, 2 lines changed')
print('  (vs 136 file edits in the old structure)')
"

echo ""
read -p "Press ENTER to re-run resolver — watch dev pick up both changes..."
echo ""
echo "  Resolving parameters AFTER the change:"
echo "  ─────────────────────────────────────────"

echo ""
echo "  [dev] VPC:"
python3 new-structure/pipeline/resolve_parameters.py \
  --account dev \
  --domain  networking \
  --module  vpc-baseline \
  --output  "/tmp/resolved-dev-vpc.json" 2>&1 | grep -E "(Layer|CostCentre)" | sed 's/^/    /'
COST=$(python3 -c "import json; params={p['ParameterKey']:p['ParameterValue'] for p in json.load(open('/tmp/resolved-dev-vpc.json'))}; print(params.get('CostCentre','?'))")
echo "    → CostCentre = ${COST}"

echo ""
echo "  [dev] KMS:"
python3 new-structure/pipeline/resolve_parameters.py \
  --account dev \
  --domain  security \
  --module  kms-key \
  --output  "/tmp/resolved-dev-kms.json" 2>&1 | grep -E "(Layer|CostCentre)" | sed 's/^/    /'
COST=$(python3 -c "import json; params={p['ParameterKey']:p['ParameterValue'] for p in json.load(open('/tmp/resolved-dev-kms.json'))}; print(params.get('CostCentre','?'))")
echo "    → CostCentre = ${COST}"

echo ""
echo "─────────────────────────────────────────────────────────"
echo "  Both VPC and KMS now have CostCentre = TESCO-IMS-PLATFORM-2026"
echo "  On next deploy, ALL modules for ALL 68 real accounts get this."
echo "─────────────────────────────────────────────────────────"
echo ""

# Restore original values
python3 -c "
import json
for path in ['${VPC_DEFAULTS}', '${KMS_DEFAULTS}']:
    with open(path) as f:
        d = json.load(f)
    d['CostCentre'] = 'TESCO-IMS-PLATFORM'
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
print('  (Restored _defaults to original values for demo repeatability)')
"
echo ""
