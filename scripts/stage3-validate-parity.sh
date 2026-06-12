#!/bin/bash
# Stage 3: Automated parity validation before cutover
# Repo: git@github.com:laknya/tesco-ims-poc-demo.git
set -e

ENV=${1:-dev}
REGION="eu-west-1"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  STAGE 3 — Parity Validation (env: ${ENV})           "
echo "║  Proving: OLD stacks == NEW stack                    "
echo "╚══════════════════════════════════════════════════════╝"
echo ""

pip install boto3 -q

python3 new-structure/pipeline/validate_parity.py \
  --old-vpc-stack    "poc-OLD-vpc-${ENV}" \
  --old-subnet-stack "poc-OLD-subnets-${ENV}" \
  --new-stack        "poc-NEW-vpc-subnets-${ENV}" \
  --region           "${REGION}"

if [ $? -eq 0 ]; then
  echo "✅  Parity confirmed for ${ENV}. Proceed to stage4."
else
  echo "❌  Parity failed. Fix and re-run before proceeding."
  exit 1
fi