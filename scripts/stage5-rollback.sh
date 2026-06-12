#!/bin/bash
# Stage 5: Full rollback — restore old stacks in under 5 minutes
# Repo: git@github.com:laknya/tesco-ims-poc-demo.git
set -e

ENV=${1:-dev}
REGION="eu-west-1"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  STAGE 5 — ROLLBACK (env: ${ENV})                    "
echo "╚══════════════════════════════════════════════════════╝"
echo ""
read -p "Type ROLLBACK to confirm full restore: " CONFIRM
[ "${CONFIRM}" = "ROLLBACK" ] || { echo "Rollback cancelled."; exit 0; }

START=$(date +%s)

echo ""
echo "► Restoring VPC stack..."
aws cloudformation deploy \
  --stack-name  "poc-OLD-vpc-${ENV}" \
  --template-file old-structure/cloudformation/vpc-template.yaml \
  --parameter-overrides file://old-structure/parameters/${ENV}/vpc.json \
  --tags POCStage=rollback Environment=${ENV} \
  --region "${REGION}"

echo ""
echo "► Restoring Subnets stack..."
TMP=$(mktemp)
python3 -c "
import json
params = json.load(open('old-structure/parameters/${ENV}/subnets.json'))
for p in params:
    if p['ParameterKey'] == 'VpcStackName':
        p['ParameterValue'] = 'poc-OLD-vpc-${ENV}'
print(json.dumps(params, indent=2))
" > "$TMP"

aws cloudformation deploy \
  --stack-name  "poc-OLD-subnets-${ENV}" \
  --template-file old-structure/cloudformation/subnets-template.yaml \
  --parameter-overrides file://"$TMP" \
  --tags POCStage=rollback Environment=${ENV} \
  --region "${REGION}"

echo ""
echo "► Removing new stack..."
aws cloudformation delete-stack \
  --stack-name "poc-NEW-vpc-subnets-${ENV}" --region "${REGION}"
aws cloudformation wait stack-delete-complete \
  --stack-name "poc-NEW-vpc-subnets-${ENV}" --region "${REGION}"

END=$(date +%s)
echo ""
echo "✅  ROLLBACK COMPLETE in $(( END - START ))s"
echo "    Old stacks restored. New stack removed."