#!/bin/bash
# Stage 2: Deploy NEW centralized module (alongside old — no conflict)
# Repo: git@github.com:laknya/tesco-ims-poc-demo.git
set -e

ENV=${1:-dev}
REGION="eu-west-1"
NEW_STACK="poc-NEW-vpc-subnets-${ENV}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  STAGE 2 — Deploy NEW centralized module (env: ${ENV})"
echo "║  OLD stacks: untouched                               "
echo "╚══════════════════════════════════════════════════════╝"
echo ""

echo "► Step A: Resolving parameters (layered config)..."
python3 new-structure/pipeline/resolve_parameters.py \
  --env    "${ENV}" \
  --domain networking \
  --module vpc-subnets \
  --output /tmp/new-resolved-${ENV}.json

echo ""
echo "► Step B: Linting centralized template..."
pip install cfn-lint -q
cfn-lint new-structure/modules/networking/vpc-subnets/template.yaml
echo "    cfn-lint ✅"

echo ""
echo "► Step C: Deploying from centralized module..."
aws cloudformation deploy \
  --stack-name  "${NEW_STACK}" \
  --template-file new-structure/modules/networking/vpc-subnets/template.yaml \
  --parameter-overrides file:///tmp/new-resolved-${ENV}.json \
  --tags POCStage=new Environment=${ENV} Repo=tesco-ims-poc-demo \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

echo ""
echo "✅  NEW stack LIVE: ${NEW_STACK}"
echo ""
echo "Both old and new running in parallel:"
for S in "poc-OLD-vpc-${ENV}" "poc-OLD-subnets-${ENV}" "${NEW_STACK}"; do
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${S}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
  printf "  %-35s → %s\n" "${S}" "${STATUS}"
done
echo ""
echo "Run scripts/stage3-validate-parity.sh next."