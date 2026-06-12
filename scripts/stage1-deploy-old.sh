#!/bin/bash
# Stage 1: Deploy OLD structure (simulate live state from tescoiacpoc)
# Repo: git@github.com:laknya/tesco-ims-poc-demo.git
set -e

ENV=${1:-dev}
REGION="eu-west-1"
VPC_STACK="poc-OLD-vpc-${ENV}"
SUBNET_STACK="poc-OLD-subnets-${ENV}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  STAGE 1 — Deploy OLD structure (env: ${ENV})         "
echo "║  Simulates: tescoiacpoc live deployment               "
echo "╚══════════════════════════════════════════════════════╝"
echo ""

echo "► Deploying VPC stack: ${VPC_STACK}"
aws cloudformation deploy \
  --stack-name  "${VPC_STACK}" \
  --template-file old-structure/cloudformation/vpc-template.yaml \
  --parameter-overrides file://old-structure/parameters/${ENV}/vpc.json \
  --tags POCStage=old Environment=${ENV} Repo=tesco-ims-poc-demo \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

echo ""
echo "► Deploying Subnets stack: ${SUBNET_STACK}"
# Update VpcStackName param to match actual deployed stack
TMP=$(mktemp)
python3 -c "
import json
params = json.load(open('old-structure/parameters/${ENV}/subnets.json'))
for p in params:
    if p['ParameterKey'] == 'VpcStackName':
        p['ParameterValue'] = '${VPC_STACK}'
print(json.dumps(params, indent=2))
" > "$TMP"

aws cloudformation deploy \
  --stack-name  "${SUBNET_STACK}" \
  --template-file old-structure/cloudformation/subnets-template.yaml \
  --parameter-overrides file://"$TMP" \
  --tags POCStage=old Environment=${ENV} Repo=tesco-ims-poc-demo \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

echo ""
echo "✅  OLD stacks LIVE (${ENV})"
echo "    VPC     : ${VPC_STACK}"
echo "    Subnets : ${SUBNET_STACK}"
echo ""
echo "    These represent your existing tescoiacpoc deployment."
echo "    Do not modify them until cutover is confirmed safe."