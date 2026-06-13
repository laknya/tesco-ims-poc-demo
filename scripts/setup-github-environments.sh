#!/bin/bash
# One-time setup: create GitHub Environments with approval gates for the migration pipeline.
#
# Prerequisites:
#   gh auth login          (GitHub CLI, authenticated)
#   AWS console access     (to update the OIDC role trust policy)
#
# Usage:
#   bash scripts/setup-github-environments.sh
#
# What this does:
#   1. Creates five environments: tesco-ims-deploy-existing, tesco-ims-deploy-new,
#      tesco-ims-parity-check, tesco-ims-cutover, tesco-ims-rollback
#   2. Sets you as the required reviewer for all five (editable in Settings → Environments)
#   3. Restricts deployments to the main branch only
#   4. Prints the IAM trust policy update you must apply in the AWS console

set -e

# ── Config ────────────────────────────────────────────────────────────────────
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
if [ -z "${REPO}" ]; then
  echo "❌  Cannot determine repo. Run: export GITHUB_REPOSITORY=owner/repo"
  exit 1
fi

REVIEWER="${GITHUB_ACTOR:-$(gh api user -q .login 2>/dev/null)}"
if [ -z "${REVIEWER}" ]; then
  echo "❌  Cannot determine GitHub username. Run: export GITHUB_ACTOR=your-username"
  exit 1
fi

ACCOUNT_ID="${AWS_ACCOUNT_ID:-641079926471}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  TESCO IMS Migration — GitHub Environments Setup     "
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Repo     : ${REPO}"
echo "  Reviewer : ${REVIEWER}"
echo "  Account  : ${ACCOUNT_ID}"
echo ""

# ── Helper: create one environment ───────────────────────────────────────────
create_env() {
  local env_name="$1"
  local description="$2"

  echo "► Creating environment: ${env_name}"

  # Create/update environment via API
  # Note: prevent_self_review cannot be set without a reviewer — omit it here
  gh api --method PUT \
    "/repos/${REPO}/environments/${env_name}" \
    --field "wait_timer=0" \
    > /dev/null

  # Set required reviewer (the person running this script)
  REVIEWER_ID=$(gh api "/users/${REVIEWER}" -q .id)
  gh api --method PUT \
    "/repos/${REPO}/environments/${env_name}" \
    --input - <<EOF > /dev/null
{
  "reviewers": [{"type": "User", "id": ${REVIEWER_ID}}],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
EOF

  # Restrict to main branch only
  gh api --method POST \
    "/repos/${REPO}/environments/${env_name}/deployment-branch-policies" \
    --field "name=main" \
    > /dev/null

  echo "  ✅  ${env_name} — reviewer: ${REVIEWER}, branch: main"
}

# ── Create all five gates ─────────────────────────────────────────────────────
create_env "tesco-ims-deploy-existing"    "Gate before deploying legacy per-account stacks"
create_env "tesco-ims-deploy-new"    "Gate before deploying centralized modules alongside old"
create_env "tesco-ims-parity-check"  "Gate before running OLD == NEW 5-check validation"
create_env "tesco-ims-cutover"       "Gate before deleting existing stacks (destructive — irreversible)"
create_env "tesco-ims-rollback"      "Gate before emergency rollback (restores old, removes new)"

# ── IAM trust policy ─────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ACTION REQUIRED: Update IAM trust policy in AWS console     "
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Role: arn:aws:iam::${ACCOUNT_ID}:role/tesco-ims-migration-deploy-role"
echo ""
echo "  When a job uses 'environment:', GitHub issues an OIDC token"
echo "  with a DIFFERENT sub claim:"
echo ""
echo "    Before environment:  repo:${REPO}:ref:refs/heads/main"
echo "    After  environment:  repo:${REPO}:environment:tesco-ims-deploy-existing"
echo ""
echo "  Replace the existing StringEquals sub condition with StringLike:"
echo ""
cat <<POLICY
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
          },
          "StringLike": {
            "token.actions.githubusercontent.com:sub": "repo:${REPO}:*"
          }
        }
      }
    ]
  }
POLICY
echo ""
echo "  Steps:"
echo "  1. Open: https://console.aws.amazon.com/iam/home#/roles/tesco-ims-migration-deploy-role"
echo "  2. Trust relationships → Edit trust policy"
echo "  3. Paste the JSON above (replacing the existing policy)"
echo "  4. Update policy"
echo ""

# ── Validation: list environments ────────────────────────────────────────────
echo "► Verifying environments:"
gh api "/repos/${REPO}/environments" -q '.environments[] | "  ✅  \(.name)"'

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Setup complete.                                     "
echo "║                                                      "
echo "║  To change reviewers:                                "
echo "║  GitHub → Settings → Environments → <name>          "
echo "║  → Required reviewers → Add people or teams         "
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Next: push to main to trigger the pipeline."
echo "  You will receive an email when each gate is waiting for approval."
