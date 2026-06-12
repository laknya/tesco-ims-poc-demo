#!/bin/bash
# Stage 4: Delete old stacks — new stack becomes canonical
# Repo: git@github.com:laknya/tesco-ims-poc-demo.git
set -e

ENV=${1:-dev}
REGION="eu-west-1"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  STAGE 4 — Cutover (env: ${ENV})                     "
echo "╚══════════════════════════════════════════════════════╝"
echo ""

echo "Pre-flight: final parity check..."
python3 new-structure/pipeline/validate_parity.py \
  --old-vpc-stack    "poc-OLD-vpc-${ENV}" \
  --old-subnet-stack "poc-OLD-subnets-${ENV}" \
  --new-stack        "poc-NEW-vpc-subnets-${ENV}" \
  --region           "${REGION}" \
  || { echo "❌ Parity failed — cutover aborted."; exit 1; }

echo ""
read -p "Type YES to delete old stacks and complete cutover: " CONFIRM
[ "${CONFIRM}" = "YES" ] || { echo "Cutover cancelled."; exit 0; }

echo ""
echo "► Deleting poc-OLD-subnets-${ENV}..."
aws cloudformation delete-stack \
  --stack-name "poc-OLD-subnets-${ENV}" --region "${REGION}"
aws cloudformation wait stack-delete-complete \
  --stack-name "poc-OLD-subnets-${ENV}" --region "${REGION}"
echo "  Done."

echo ""
echo "► Deleting poc-OLD-vpc-${ENV}..."
aws cloudformation delete-stack \
  --stack-name "poc-OLD-vpc-${ENV}" --region "${REGION}"
aws cloudformation wait stack-delete-complete \
  --stack-name "poc-OLD-vpc-${ENV}" --region "${REGION}"
echo "  Done."

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  CUTOVER COMPLETE (${ENV})                        "
echo "║                                                      "
echo "║  Retired:                                            "
echo "║    old-structure/cloudformation/vpc-template.yaml   "
echo "║    old-structure/cloudformation/subnets-template.yaml"
echo "║    old-structure/parameters/${ENV}/vpc.json           "
echo "║    old-structure/parameters/${ENV}/subnets.json       "
echo "║                                                      "
echo "║  Now active:                                         "
echo "║    new-structure/modules/networking/vpc-subnets/     "
echo "║    new-structure/config/_defaults/networking/        "
echo "║    new-structure/config/environments/${ENV}/networking/"
echo "╚══════════════════════════════════════════════════════╝"