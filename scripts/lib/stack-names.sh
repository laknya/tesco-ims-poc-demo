#!/bin/bash
# -----------------------------------------------------------------------------
#  Stack naming library -- source this file from every stage script.
#  Compatible with bash 3.2+ (macOS default) -- no associative arrays.
#
#  WHY this exists
#  ---------------
#  Without this library every stage script contained a manually typed shorthand
#  ("vpc", "kms", "s3") that had no relationship to the actual module path on
#  disk (networking/vpc-baseline, security/kms-key, …). Adding a 4th module
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
#   DOMAIN  : networking | security | shared-services | …
#   MODULE  : vpc-baseline | kms-key | s3-bucket | …
#   ACCOUNT : dev | sandbox | coll-dev | coll-ppe | …
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
#   Prints one "domain/module" line per template found under
#   existing-structure/{account}/*-template.yaml, translated to the canonical
#   domain/module path via _module_for_abbrev().
#   Stage 1 loops over this to deploy EXISTING stacks without hardcoding names.
discover_existing_modules() {
  local account="$1"
  local base="existing-structure/${account}"
  if [ ! -d "${base}" ]; then
    echo "ERROR: No existing-structure found for account '${account}' under ${base}" >&2
    return 1
  fi
  # VPC must be first -- S3 template uses Fn::ImportValue from the VPC stack.
  # Explicit ordering here prevents a first-run failure when templates would
  # otherwise deploy alphabetically (kms -> s3 -> vpc).
  for abbrev in vpc kms s3; do
    local template="${base}/${abbrev}-template.yaml"
    [ -f "${template}" ] || continue
    _module_for_abbrev "${abbrev}"
  done
}

# _module_for_abbrev ABBREV
#   Maps a legacy template abbreviation to its canonical domain/module path.
#   This is the single registration point for the legacy->new module mapping.
#   Adding a 4th module here is the only change needed across all stage scripts.
_module_for_abbrev() {
  case "$1" in
    vpc) echo "networking/vpc-baseline" ;;
    kms) echo "security/kms-key" ;;
    s3)  echo "shared-services/s3-bucket" ;;
    *)
      echo "ERROR: No mapping for legacy template abbreviation '${1}'" \
           "— add it to _module_for_abbrev() in scripts/lib/stack-names.sh" >&2
      return 1
      ;;
  esac
}

# _abbrev_for_module DOMAIN/MODULE
#   Reverse of _module_for_abbrev -- used by stages 1 and 5 to find the
#   params file and template file for a given domain/module.
_abbrev_for_module() {
  case "$1" in
    "networking/vpc-baseline")   echo "vpc" ;;
    "security/kms-key")          echo "kms" ;;
    "shared-services/s3-bucket") echo "s3"  ;;
    *)
      echo "ERROR: No legacy abbreviation for module '${1}'" \
           "— add it to _abbrev_for_module() in scripts/lib/stack-names.sh" >&2
      return 1
      ;;
  esac
}
