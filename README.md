# TESCO IMS AWS Landing Zone - POC Demo

This repo is a proof-of-concept for transforming how we manage the TESCO IMS
AWS Landing Zone. The short version: we had 391 duplicate CloudFormation templates
spread across 68 accounts, and we fixed it.

**AWS Region:** `eu-west-1`  |  **Accounts used in this demo:** `dev`, `sandbox`, `coll-dev`, `coll-ppe`

---

## Table of Contents

1. [Why Does This Exist?](#why-does-this-exist)
2. [What We Built Instead](#what-we-built-instead)
3. [By the Numbers](#by-the-numbers)
4. [How This Repo is Laid Out](#how-this-repo-is-laid-out)
5. [Module Structure](#module-structure)
   - [template.yaml](#templateyaml)
   - [parameters.schema.json](#parameterschemajson)
   - [import-config.json](#import-configjson)
   - [version.json](#versionjson)
6. [The Three Modules in This POC](#the-three-modules-in-this-poc)
   - [networking/vpc-baseline](#networkingvpc-baseline)
   - [security/kms-key](#securitykms-key)
   - [shared-services/s3-bucket](#shared-servicess3-bucket)
7. [The 4-Layer Parameter System](#the-4-layer-parameter-system)
8. [Accounts Registry](#accounts-registry)
9. [How the Migration Works](#how-the-migration-works)
10. [Non-Importable Resource Types](#non-importable-resource-types)
11. [Migration Scripts](#migration-scripts)
    - [stage1 -- Set Up the Demo BEFORE State](#stage1-deploy-existingsh----set-up-the-demo-before-state)
    - [stage2 -- The Core Migration](#stage2-deploy-newsh----the-core-migration)
    - [stage3 -- Prove OLD Equals NEW](#stage3-validate-paritysh----prove-old-equals-new)
    - [stage4 -- Make the New Structure Permanent](#stage4-cutoversh----make-the-new-structure-permanent)
    - [stage5 -- Emergency Restore](#stage5-rollbacksh----emergency-restore-last-resort)
12. [Pipeline Scripts](#pipeline-scripts)
13. [CI/CD Pipelines](#cicd-pipelines)
    - [End-to-End Pipeline Flow](#end-to-end-pipeline-flow)
    - [How to Run the Pipelines](#how-to-run-the-pipelines)
14. [Safety Invariants](#safety-invariants)
15. [Running the Demo -- Step by Step](#running-the-demo----step-by-step)
    - [Part 1 -- Local Demo (No AWS Needed)](#part-1----the-local-demo-no-aws-needed)
    - [Part 2 -- Live AWS Migration Demo](#part-2----the-live-aws-migration-demo)
16. [Adding a New Module](#adding-a-new-module)
17. [Adding a New Account](#adding-a-new-account)
18. [Running Locally (No AWS Needed)](#running-locally-no-aws-needed)

---

## Why Does This Exist?

Here is the honest starting point. Every AWS account had its own folder with a
full copy of every CloudFormation template:

```
existing-structure/
  dev/
    networking__vpc-baseline-template.yaml   <- 160 lines, all values hardcoded
    networking__vpc-baseline-params.json
    security__kms-key-template.yaml          <- nearly identical, just different values
    shared-services__s3-bucket-template.yaml <- same again
  coll-dev/   <- exact same files, copy-pasted
  coll-ppe/   <- exact same files again
  ... (64 more account folders, all the same)
```

When you wanted to change a tag, you had to edit 68 files. Miss one and that
account quietly drifts. When you needed to add a new account, you copied 10+
files and hoped you updated every default correctly.

That is the problem this POC solves.

---

## What We Built Instead

One master template per module, shared by every account. The only thing that
lives per-account is a tiny JSON file (usually 4-8 lines) declaring what is
different for that account. Everything else is inherited from shared defaults.

```
new-structure/modules/networking/vpc-baseline/template.yaml        <- one file, serves all accounts
new-structure/config/_defaults/networking/vpc-baseline.json        <- shared values (all accounts)
new-structure/config/accounts/dev/networking/vpc-baseline.json     <- only what differs for dev (4 lines)
new-structure/config/accounts/sandbox/networking/vpc-baseline.json <- only what differs for sandbox (4 lines)
```

Now changing a tag is editing 1 line in `_defaults/`. Adding an account is one
registry entry plus a 4-line delta file.

---

## By the Numbers

| | Before | After |
|---|---|---|
| Update a governance tag | Edit 68 files | Edit 1 line in `_defaults/` |
| Add a new account | Copy 10+ files, update all defaults | 1 registry entry + 4-line delta |
| Rotate a KMS key principal | Edit 68 templates | Edit 1 JSON config file |

---

## How This Repo is Laid Out

```
tesco-ims-poc-demo/
+-- existing-structure/        <- the OLD approach (kept here so demos can show the before state)
|   +-- dev/
|   |   +-- networking__vpc-baseline-template.yaml
|   |   +-- networking__vpc-baseline-params.json
|   |   +-- security__kms-key-template.yaml
|   |   +-- ...
|   +-- coll-dev/  (same files)
|   +-- coll-ppe/  (same files)
+-- new-structure/             <- the NEW approach
|   +-- modules/               <- one master template per module
|   +-- config/                <- the 4 parameter layers plus the accounts registry
|   +-- pipeline/              <- Python scripts that resolve, validate, and import
+-- scripts/                   <- bash migration scripts (stages 1 through 5)
|   +-- lib/stack-names.sh     <- helper functions shared by all stage scripts
+-- tests/                     <- 195 pytest tests, none of them need AWS credentials
+-- .github/workflows/         <- CI/CD pipelines
+-- DEMO-SCRIPT.md             <- 30-minute presentation guide for stakeholders
```

---

## Module Structure

Every module lives at `new-structure/modules/{domain}/{module}/` and always has
exactly 4 files. Here is what each one does:

```
new-structure/modules/{domain}/{module}/
  template.yaml              <- ONE master CloudFormation template (no hardcoded values)
  parameters.schema.json     <- JSON Schema contract (validated before every deploy)
  import-config.json         <- CFN Resource Import manifest (how to migrate from EXISTING)
  version.json               <- version number, SHA256 hash, changelog, CFN registry type name
```

### template.yaml

This is the master CloudFormation template. The key rule is that there are zero
hardcoded values in it -- every value is either a `!Ref` or a `!Sub` on a
parameter. This is what makes the same file work for every account.

Every resource also has `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain`
so that even if a CloudFormation stack gets deleted, the actual AWS resources
(VPCs, subnets, KMS keys, S3 buckets) stay alive. This is the safety net that
makes the whole migration reversible.

The template is run through cfn-lint on every PR so syntax errors never reach AWS.

### parameters.schema.json

Before the pipeline touches AWS, it validates every account's config JSON against
this schema. The schema uses JSON Schema draft-07 and has `additionalProperties: false`
which means if you add a key that does not exist in the schema, it fails
immediately with a clear error. This catches typos and missing required fields
before CloudFormation ever sees them.

### import-config.json

This file is the "how do we migrate" manifest. It declares which resources in the
template are importable into CloudFormation ownership, and exactly how to find
the physical ID of each one in AWS. There are three ways an ID can be found:

- `stack-resource` -- look it up from the live EXISTING stack while it still exists
- `param` -- read the value directly from the resolved parameters JSON (e.g. a known bucket name)
- `literal` -- it is a fixed string written directly in this config file

This file is read by two scripts: `generate_import_template.py` builds the Phase 1
filtered template using it, and `resolve_import.py` uses it to build the import
identifiers list.

### version.json

Contains three things:
- `template_hash` -- SHA256 of `template.yaml`. CI checks this on every push and
  fails if the template was changed without bumping the version. This stops silent
  unversioned changes from reaching AWS.
- `type_name` -- the CloudFormation private registry type name (this is for the
  production path where modules are published as proper CFN extensions)
- `status` -- the registry version the pipeline deploys by default

---

## The Three Modules in This POC

### networking/vpc-baseline

This module manages the core network for an account.

**Stack name:** `poc-NEW-networking-vpc-baseline-{account}`

What it creates and manages:

| Resource | Description |
|---|---|
| `AWS::EC2::VPC` | VPC with configurable CIDR and DNS settings |
| `AWS::EC2::InternetGateway` | Internet gateway |
| `AWS::EC2::Subnet` x4 | Two public subnets (AZ-a and AZ-b) and two private subnets |
| `AWS::EC2::RouteTable` | Route table for the public subnets |
| `AWS::EC2::SubnetRouteTableAssociation` x2 | Associates each public subnet to the route table |

It exports `VpcId`, `VpcCidr`, `IgwId`, and all four subnet IDs so the KMS and
S3 modules can reference them.

Two resource types are intentionally NOT in this template:

| Resource | Why we left it out |
|---|---|
| `AWS::EC2::Route` (0.0.0.0/0) | Deleting and recreating it briefly cuts internet connectivity. We never touch it. |
| `AWS::EC2::VPCGatewayAttachment` | AWS uses a readOnlyProperty called `AttachmentType` as the import identifier but never exposes its value via any API. There is no way to discover it, so we cannot import it. |

Both of these resources stay alive in AWS without any CloudFormation managing them.
This is fine -- they continue to work, we just do not manage their lifecycle.

### security/kms-key

This module manages the platform KMS key for an account.

**Stack name:** `poc-NEW-security-kms-key-{account}`

It creates one `AWS::KMS::Key` (AES-256, 30-day deletion window, auto-rotation
enabled) and one `AWS::KMS::Alias`. The key thing here is that the key policy
principals (`KeyAdminArn`, `KeyUsageArn`) are parameters, not hardcoded ARNs.
The security team controls those values through the config JSON files -- rotating
a principal never requires touching the template.

This module has no cross-stack dependencies and deploys first. Two importable
resources: the key (by KeyId) and the alias (by AliasName).

### shared-services/s3-bucket

This module manages the platform S3 bucket for an account.

**Stack name:** `poc-NEW-shared-services-s3-bucket-{account}`

It creates a KMS-encrypted, versioned S3 bucket with public access blocked and a
90-day lifecycle rule. It also creates a bucket policy that denies all access
from outside the VPC -- the bucket policy uses `Fn::ImportValue` to pull in the
VPC stack's exported `VpcId`. The VPC and S3 module are explicitly linked.

The bucket policy (`AWS::S3::BucketPolicy`) is not CFN-importable. During the
migration it gets deleted at Phase 1.5 and recreated fresh at Phase 2. The bucket
itself is importable by its name.

This module depends on the VPC and KMS modules being deployed first. The pipeline
waits for them automatically.

---

## The 4-Layer Parameter System

Parameters come from 4 config layers that are merged in order. Later layers win
over earlier ones. This is how one master template can serve every account with
different values.

```
new-structure/config/

  _defaults/{domain}/{module}.json                 Layer 1 -- org-wide shared values (lowest priority)
  environments/{env}/{domain}/{module}.json         Layer 2 -- optional env-specific overrides
  ous/{ou}/{domain}/{module}.json                   Layer 3 -- optional OU-specific overrides
  accounts/{account}/{domain}/{module}.json         Layer 4 -- per-account delta (highest priority)
```

The resolver script (`resolve_parameters.py`) reads `_accounts-registry.yaml` to
find out which environment and OU an account belongs to, then applies all 4 layers.

Here is a real example for `sandbox / networking / vpc-baseline`:

Layer 1 -- `_defaults/networking/vpc-baseline.json` (4 values -- only true org-wide constants):
```json
{
  "EnableDnsHostnames": "true",
  "EnableDnsSupport":   "true",
  "CostCentre":         "TESCO-IMS-PLATFORM",
  "ManagedBy":          "github-actions"
}
```

Layer 4 -- `accounts/sandbox/networking/vpc-baseline.json` (8 values -- all account-specific):
```json
{
  "AccountId":          "999888777666",
  "Environment":        "dev",
  "VpcCidr":            "10.99.0.0/16",
  "VpcName":            "sandbox-vpc",
  "PublicSubnetACidr":  "10.99.1.0/24",
  "PublicSubnetBCidr":  "10.99.2.0/24",
  "PrivateSubnetACidr": "10.99.10.0/24",
  "PrivateSubnetBCidr": "10.99.11.0/24"
}
```

The resolver merges these and produces a single flat 12-parameter file for
CloudFormation. Every account declares its own CIDRs explicitly -- no account
can accidentally inherit another account's subnet ranges.

Why CIDRs are NOT in defaults: in a real AWS estate where accounts are connected
via Transit Gateway or VPC peering, a silent CIDR collision causes routing
failures that are hard to diagnose. Making CIDRs required in every account delta
means the pipeline catches a missing CIDR before CloudFormation ever runs.

All four accounts in this POC:

| Account   | VpcCidr        | Public Subnets              | Private Subnets               |
|-----------|----------------|-----------------------------|-------------------------------|
| dev       | 10.0.0.0/16    | 10.0.1.0/24, 10.0.2.0/24   | 10.0.10.0/24, 10.0.11.0/24   |
| sandbox   | 10.99.0.0/16   | 10.99.1.0/24, 10.99.2.0/24 | 10.99.10.0/24, 10.99.11.0/24 |
| coll-dev  | 10.1.0.0/16    | 10.1.1.0/24, 10.1.2.0/24   | 10.1.10.0/24, 10.1.11.0/24   |
| coll-ppe  | 10.2.0.0/16    | 10.2.1.0/24, 10.2.2.0/24   | 10.2.10.0/24, 10.2.11.0/24   |

---

## Accounts Registry

`new-structure/config/_accounts-registry.yaml` is a single file that replaces
what used to be N individual per-account config files. Every account's environment
and OU membership is declared here:

```yaml
accounts:
  dev:       { id: "641079926471", environment: dev, ou: non-production/dev }
  sandbox:   { id: "999888777666", environment: dev, ou: non-production/sandbox }
  coll-dev:  { id: "111222333444", environment: dev, ou: production/workload }
  coll-ppe:  { id: "222333444555", environment: ppe, ou: production/workload }
```

`resolve_parameters.py` reads this to know which Layer 2 and Layer 3 files
to apply when resolving parameters for a given account.

`generate_account_params.py` reads this and auto-generates
`config/generated/account-metadata/{account}.json` for every account. These
generated files supply the `AccountId` and `Environment` fields so you do not
have to repeat them in every module delta.

---

## How the Migration Works

The migration transfers CloudFormation ownership of every resource from the old
per-account stacks into the new centralized module stacks. No new resources are
created. No resources are deleted. Only which stack "owns" them changes.

This works because AWS CloudFormation supports `--change-set-type IMPORT`, which
lets you adopt an existing AWS resource into a new stack without recreating it.
For this to be safe, every resource in every template must have
`DeletionPolicy: Retain` -- this guarantees that if a stack is deleted, the
physical AWS resource stays alive.

The migration for each module follows a two-phase import pattern:

```
Phase 1     -- filtered IMPORT changeset: importable resources only, no Outputs or Tags yet
Phase 1.5   -- cleanup: delete physical resources that would conflict with Phase 2
               (e.g. the stale 0.0.0.0/0 route, the existing BucketPolicy)
Phase 2     -- full UPDATE: adds non-importable resources, Outputs, and Tags
```

Phase 1.5 exists because some resources cannot be imported (Route, BucketPolicy)
but they already exist in AWS. Phase 2 would try to CREATE them and fail because
they are already there. So we delete them first, then Phase 2 creates them fresh.

---

## Non-Importable Resource Types

Two resource types cannot be CFN-imported and cannot be safely recreated:

**`AWS::EC2::Route`** (the default internet route 0.0.0.0/0)
Recreating this route even briefly drops internet connectivity for anything in
the VPC. We do not touch it. It stays in AWS, unmanaged by CloudFormation,
and keeps working.

**`AWS::EC2::VPCGatewayAttachment`** (the IGW-to-VPC attachment)
AWS uses a property called `AttachmentType` as the identifier for importing this
resource. But `AttachmentType` is a readOnlyProperty that AWS sets internally --
there is no EC2 API call that returns it. The import identifier is literally
impossible to discover at runtime, so we cannot import this resource type.

Both of these are omitted from the NEW and EXISTING templates entirely. They
survive through `DeletionPolicy: Retain` on the stacks that originally created
them and continue working as unmanaged resources.

---

## Migration Scripts

All the migration scripts live in `scripts/`. They all share helper functions
from `scripts/lib/stack-names.sh`.

Every stack name is built deterministically from the domain, module, and account.
Nothing is hardcoded:

| Type | Pattern | Example |
|---|---|---|
| Old stacks | `poc-EXISTING-{domain}-{module}-{account}` | `poc-EXISTING-networking-vpc-baseline-dev` |
| New stacks | `poc-NEW-{domain}-{module}-{account}` | `poc-NEW-networking-vpc-baseline-dev` |

Module discovery also happens automatically. Scripts find modules by looking for
files named `{domain}__{module}-template.yaml`. Add a new file there and it
appears in every stage script with no code changes.

### stage1-deploy-existing.sh -- Set Up the Demo BEFORE State

This deploys the old per-account templates so your audience can see what the
68-stack world looks like in the CloudFormation console before the migration runs.

It is idempotent. If a stack is stuck in a failed state it clears it first
(resources are retained). If an account was already migrated it re-imports the
retained resources back into a fresh EXISTING stack.

```bash
bash scripts/stage1-deploy-existing.sh dev
```

### stage2-deploy-new.sh -- The Core Migration

This is the main script. It transfers CloudFormation ownership from the old
per-account stacks to the new centralized modules. Nothing gets deleted or
recreated in AWS -- only the CFN ownership changes.

It runs in four passes:

```
Pass A  pre-flight  -- version check + cfn-lint all modules before touching AWS
Pass B  resolve     -- read physical IDs from EXISTING stacks while they still exist
Pass C  release     -- delete all EXISTING stacks (DeletionPolicy: Retain keeps AWS resources)
Pass D  import      -- create NEW stacks using CFN Resource Import (two-phase)
```

If something goes wrong and you need to re-run, the script auto-detects stuck
stacks (`ROLLBACK_COMPLETE`, `UPDATE_ROLLBACK_COMPLETE`, etc.), clears them while
keeping the AWS resources, and resumes.

```bash
bash scripts/stage2-deploy-new.sh dev                           # all modules
bash scripts/stage2-deploy-new.sh dev networking/vpc-baseline   # just one module
```

### stage3-validate-parity.sh -- Prove OLD Equals NEW

Runs 5 checks comparing the old and new stacks side by side to confirm they are
functionally equivalent:

1. Same parameter keys and values
2. Same AWS resource types
3. Same CloudFormation output keys
4. Same VPC CIDR and DNS settings (networking module only)
5. Same subnet CIDR blocks, sorted (networking module only)

For the modules in this POC, parity auto-passes because the EXISTING stack is
already gone after stage 2 -- CFN ownership has been fully transferred.

```bash
bash scripts/stage3-validate-parity.sh dev
```

### stage4-cutover.sh -- Make the New Structure Permanent

This retires any remaining EXISTING stacks and makes the new centralized modules
the only source of truth. It has four safeguards so nothing gets accidentally
deleted:

1. Only runs from `workflow_dispatch` (never triggered automatically)
2. Requires typing `CUTOVER` as a workflow input
3. Requires a reviewer to click Approve on the `tesco-ims-cutover` environment gate
4. Re-runs parity checks inside the script -- any failure aborts before deleting anything

For modules migrated via CFN Import, the EXISTING stacks are already gone from
stage 2 and cutover just skips them.

```bash
bash scripts/stage4-cutover.sh dev
```

### stage5-rollback.sh -- Emergency Restore (Last Resort)

If something critical went wrong after cutover and you cannot fix it forward,
this script restores the old EXISTING stacks from the AWS resources retained by
`DeletionPolicy: Retain`.

Use this only as a last resort. Requires typing `ROLLBACK` to confirm. Three-pass flow:

```
Pass A  resolve  -- capture physical IDs from NEW stacks while they exist
Pass B  release  -- delete NEW stacks (resources stay in AWS)
Pass C  restore  -- re-import retained resources back into EXISTING stacks
```

```bash
bash scripts/stage5-rollback.sh dev
```

---

## Pipeline Scripts

These Python scripts live in `new-structure/pipeline/` and do all the heavy lifting.

**`resolve_parameters.py`** -- Merges the 4 config layers into a flat
`[{ParameterKey, ParameterValue}]` JSON file that CloudFormation can consume directly.

```bash
python3 new-structure/pipeline/resolve_parameters.py \
  --account dev --domain networking --module vpc-baseline --output /tmp/resolved.json
```

**`resolve_import.py`** -- Builds the `--resources-to-import` JSON array for a
CFN import changeset. Has three fallback levels when the source stack is gone:
first it tries CFN system tags, then falls back to finding resources by their
CIDR blocks and VPC attachment, then fails with a clear error if neither works.

**`generate_import_template.py`** -- Produces the Phase 1 filtered template by
stripping non-importable resources (`AWS::EC2::Route`, `AWS::S3::BucketPolicy`),
Outputs, and Metadata. Also outputs a cleanup-actions file describing what needs
to be deleted at Phase 1.5.

**`validate_parity.py`** -- Runs the 5-check side-by-side comparison between
old and new stacks using boto3.

**`detect_changes.py`** -- Maps git-changed files to the set of
`(account, domain, module)` triples that need to be redeployed. Used by CI for
delta deploys -- only changed modules get queued.

**`validate_schema.py`** -- Validates every account JSON config against its
module's `parameters.schema.json` before any AWS call is made.

**`check_module_versions.py`** -- Recomputes each template's SHA256 and fails
CI if it does not match `version.json`. Prevents silent unversioned changes.

**`generate_account_params.py`** -- Reads `_accounts-registry.yaml` and
generates `config/generated/account-metadata/{account}.json` for every account.

---

## CI/CD Pipelines

All workflows are in `.github/workflows/`.

### migration-pipeline.yml -- The Main Pipeline

Runs on every push and PR. AWS deployment jobs only run on the `main` branch.

```
push / PR
  -> 01 Validate (no AWS)       cfn-lint + pytest + schema check + resolver smoke tests
       -> 02 Detect Changes     git diff -> build deploy matrix (account, domain, module)
            -> [GATE] 03 Deploy NEW    one job per changed module
                 -> [GATE] 04 Parity   one job per changed module
```

By default it only deploys modules whose files actually changed. If you need to
force a full redeploy, use `workflow_dispatch` with `deploy_mode=full`.

For modules using CFN Import, parity auto-passes when the EXISTING stack is
already gone -- no side-by-side comparison is needed because the resources are
already managed by the new stack.

### demo-setup-existing.yml -- Before-State Setup

Triggered manually only. Run this before a demo to deploy the old per-account
EXISTING stacks so your audience can see the before state in the CloudFormation
console. Completely independent from the migration pipeline.

### migration-cutover.yml -- Stage 4 Cutover

Triggered manually only. Requires `confirm = CUTOVER` input and environment gate
approval. Runs `stage4-cutover.sh` which re-runs parity internally before
deleting anything.

### migration-rollback.yml -- Stage 5 Rollback

Triggered manually only. Emergency use. Requires `confirm = ROLLBACK` input and
environment gate approval.

---

### End-to-End Pipeline Flow

Here is how the three pipelines connect for a full migration from BEFORE to DONE:

```
STEP 1 -- Show the before state
  GitHub Actions -> demo-setup-existing.yml -> Run workflow -> account: dev
  Result: poc-EXISTING-networking-vpc-baseline-dev (and kms, s3) appear in AWS console

STEP 2 -- Run the migration
  GitHub Actions -> migration-pipeline.yml -> Run workflow -> deploy_mode: full
  OR just push to main (delta mode detects changed files automatically)
  Result: NEW stacks created, EXISTING stacks released, resources transferred

STEP 3 -- Cut over (make it permanent)
  GitHub Actions -> migration-cutover.yml -> Run workflow -> confirm: CUTOVER
  Click Approve on the environment gate when prompted
  Result: any remaining EXISTING stacks retired, NEW stacks are now canonical
```

Visual summary:

```
  demo-setup-existing.yml          migration-pipeline.yml           migration-cutover.yml
  [Manual trigger]                 [Push / PR / Manual]             [Manual trigger only]
          |                                 |                                 |
          v                                 v                                 v
  Deploy EXISTING stacks  ->  Validate -> Detect -> Deploy NEW -> Parity  -> Cutover
  (the BEFORE state)                                                          (AFTER state)
```

### How to Run the Pipelines

**Before a demo:** Go to GitHub Actions, find `demo-setup-existing.yml`, click
"Run workflow", choose `account: dev`, and run it. Wait for it to go green. Your
EXISTING stacks are now live in the AWS console.

**To run the migration:** Go to `migration-pipeline.yml`, click "Run workflow",
set `deploy_mode: full` (to deploy everything, not just changed files), and run
it. The validate and detect-changes jobs run first with no AWS access. Then the
deploy-new and parity jobs run against AWS. All four must go green.

**To cut over:** Go to `migration-cutover.yml`, click "Run workflow", type
`CUTOVER` exactly into the confirm field. The pipeline will pause at an
environment gate -- a reviewer clicks Approve in GitHub. The script then re-runs
parity one more time internally before deleting anything. If parity fails the
cutover aborts automatically.

**If something goes wrong:** Go to `migration-rollback.yml`, click "Run
workflow", type `ROLLBACK` into the confirm field. Same environment gate applies.
This restores the EXISTING stacks from the AWS resources that were retained
throughout the migration.

---

## Safety Invariants

These properties hold everywhere in the codebase and are the reason the migration
is safe to run and re-run:

- **`DeletionPolicy: Retain` on every resource in every template.** Deleting a
  CloudFormation stack never deletes the actual AWS resources. This is the
  fundamental safety net.

- **Parity must pass before cutover.** There are four confirmation layers
  (environment gate, typed input, interactive confirm, internal parity preflight)
  between an engineer and a destructive action.

- **All scripts are idempotent.** Re-running after a failure self-heals. Stuck
  stacks are detected, cleared, and re-imported without touching the underlying
  AWS resources.

- **Nothing is hardcoded in the scripts.** Module names come from file discovery.
  Stack names are built from a formula. Adding a new module file is all you need
  to do -- no script changes required.

---

## Adding a New Module

```
1. new-structure/modules/{domain}/{module}/template.yaml            <- master template (no hardcoded values)
2. new-structure/modules/{domain}/{module}/parameters.schema.json   <- JSON Schema for the params
3. new-structure/modules/{domain}/{module}/version.json             <- version number and SHA256 hash
4. new-structure/modules/{domain}/{module}/import-config.json       <- only if migrating existing resources
5. new-structure/config/_defaults/{domain}/{module}.json            <- org-wide default values
6. new-structure/config/accounts/{account}/{domain}/{module}.json   <- per-account delta for each account
```

Keep `{domain}/{module}` exactly consistent across all 6 files. That path is the
key that ties everything together. `detect_changes.py` discovers the new module
automatically from the file path -- no pipeline changes needed.

---

## Adding a New Account

1. Add one entry to `new-structure/config/_accounts-registry.yaml`:

```yaml
  my-new-account:
    id: "123456789012"
    environment: dev
    ou: non-production/dev
```

2. Add a delta file for each module: `new-structure/config/accounts/my-new-account/{domain}/{module}.json`

For most modules this is 4 lines:
```json
{
  "AccountId":   "123456789012",
  "Environment": "dev",
  "VpcCidr":     "10.5.0.0/16",
  "VpcName":     "my-new-account-vpc"
}
```

3. Regenerate account metadata:

```bash
python3 new-structure/pipeline/generate_account_params.py
```

4. Run the migration pipeline with `deploy_mode=full` targeting the new account.

No template files to copy. No pipeline code to change.

---

## Running the Demo -- Step by Step

This section covers the full sequence from zero to a live demo in front of
stakeholders. There are two parts: things you do locally (no AWS), and things
you trigger through GitHub Actions (needs AWS credentials configured).

### Part 1 -- The Local Demo (No AWS Needed)

Run this first to show the problem and the solution side by side. Takes about
10 minutes and works on any laptop.

**Step 1 -- Show the problem**

Open `existing-structure/dev/networking__vpc-baseline-template.yaml` in your
editor. This is 160 lines with every value hardcoded. Then open
`existing-structure/coll-dev/networking__vpc-baseline-template.yaml` next to
it. Point out they are nearly identical -- 96% duplicated content.

**Step 2 -- Run the resolver to show the solution**

```bash
python3 new-structure/pipeline/resolve_parameters.py \
  --account sandbox \
  --domain  networking \
  --module  vpc-baseline
```

Walk through what it outputs: 8 values came from `_defaults/`, 4 account-specific
values came from `accounts/sandbox/`. Total: 12 parameters. Same 12 parameters
that are in the old hardcoded file -- but now generated from 4 lines.

**Step 3 -- Show "one change propagates everywhere"**

```bash
bash scripts/demo-one-change.sh
```

This edits one value in `_defaults/` and re-runs the resolver for all 3 demo
accounts. The audience sees the same change appear in every account's output
automatically. That is the moment that lands with stakeholders.

---

### Part 2 -- The Live AWS Migration Demo

This requires AWS credentials and takes 20-30 minutes. Run the GitHub Actions
pipelines in this exact order:

```
BEFORE STATE (run first, before any stakeholders arrive)
+------------------------------------------------------------+
|  GitHub Actions -> demo-setup-existing.yml                |
|  Run workflow -> account: dev                             |
|  Wait for green                                           |
|  Shows: poc-EXISTING-networking-vpc-baseline-dev          |
|          poc-EXISTING-security-kms-key-dev                |
|          poc-EXISTING-shared-services-s3-bucket-dev       |
|  in the CloudFormation console                            |
+------------------------------------------------------------+
                           |
                           | (audience can now see the old stacks in AWS)
                           v
MIGRATION (run live in front of the audience)
+------------------------------------------------------------+
|  GitHub Actions -> migration-pipeline.yml                 |
|  Run workflow -> deploy_mode: full                        |
|  Watch the 4 jobs run in the GitHub Actions UI:           |
|    01 Validate -> 02 Detect Changes ->                    |
|    03 Deploy NEW -> 04 Parity                             |
|  While it runs, explain each phase                        |
|  Result: NEW stacks appear in CloudFormation console      |
+------------------------------------------------------------+
                           |
                           | (pause here to show parity results)
                           v
CUTOVER (optional -- only if you want to show the full journey)
+------------------------------------------------------------+
|  GitHub Actions -> migration-cutover.yml                  |
|  Run workflow -> confirm: CUTOVER (type exactly)          |
|  Reviewer clicks Approve on the environment gate          |
|  Script re-runs parity internally before deleting         |
|  Result: EXISTING stacks gone, NEW stacks are canonical   |
+------------------------------------------------------------+
```

**What to say at each step:**

- **Before migration:** "Look at the CloudFormation console -- three stacks, one
  per service, all managed per-account. This is what 68 accounts looks like."

- **During migration:** "Watch what happens. We are not deleting anything. We are
  transferring CloudFormation ownership from the old stacks to the new centralized
  module. The VPC, the subnets, the KMS key -- they all stay alive throughout."

- **After parity passes:** "Five checks -- parameters, resource types, output keys,
  VPC CIDR, subnet CIDRs. All green. The new module produces identical
  infrastructure to the per-account template. This is the proof."

- **During cutover:** "Now we retire the old stacks. The reviewer approves the
  environment gate. The script runs parity one more time before touching anything.
  Any failure here aborts. The new centralized module is now the only source of truth."

**If something goes wrong during the demo:**

```bash
# Run rollback pipeline to restore the old stacks instantly
# GitHub Actions -> migration-rollback.yml -> confirm: ROLLBACK
```

Or locally:
```bash
bash scripts/stage5-rollback.sh dev
```

Old stacks are back in under 3 minutes. No data lost. Everything comes back
from the retained AWS resources.

---

## Running Locally (No AWS Needed)

```bash
# Install everything you need
pip install cfn-lint boto3 pyyaml pytest jsonschema

# See the problem -- lint the old per-account template
cfn-lint existing-structure/dev/networking__vpc-baseline-template.yaml

# See the solution -- lint the new shared master template
cfn-lint new-structure/modules/networking/vpc-baseline/template.yaml

# Validate all JSON config files
find . -name "*.json" -not -path "./.git/*" | while read f; do
  python3 -c "import json; json.load(open('$f'))" && echo "[OK] $f"
done

# Run the 4-layer parameter resolver for any account
python3 new-structure/pipeline/resolve_parameters.py \
  --account dev --domain networking --module vpc-baseline --output /tmp/resolved.json

# Generate account metadata from the registry
python3 new-structure/pipeline/generate_account_params.py

# Run the full test suite (195 tests, no AWS credentials needed)
pytest tests/ -m "not aws" --tb=short -q

# Run the business demo (one change propagates to all accounts)
bash scripts/demo-one-change.sh
```
