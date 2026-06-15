#!/usr/bin/env python3
"""
add_deletion_policy.py

For a given live CloudFormation stack, ensures every resource has:
  DeletionPolicy: Retain
  UpdateReplacePolicy: Retain

Reads the live template from AWS, patches it, and updates the stack if any
resource was missing either policy. Waits for UPDATE_COMPLETE before returning.

Called by stage2-deploy-new.sh in Pass 0 (Safety Hardening) before any
EXISTING stacks are read, modified, or deleted.

Usage:
  python3 add_deletion_policy.py --stack-name STACK --region REGION [--dry-run]

Exit codes:
  0 -- all resources already have Retain, or stack does not exist / not updatable
  1 -- update failed
"""
import argparse
import sys
import time

try:
    import boto3
    import botocore.exceptions
    import yaml
except ImportError as e:
    sys.exit(f"[FAIL] Missing dependency: {e} -- run: pip install boto3 pyyaml")


# ---------------------------------------------------------------------------
# CloudFormation-aware YAML loader/dumper
#
# PyYAML's safe_load rejects intrinsic function tags like !Ref, !Sub, !GetAtt.
# We register a multi-constructor that stores them as _CfnTag objects, and a
# representer that writes them back as tagged YAML nodes. This lets us parse,
# patch, and re-serialize CFN YAML templates without corrupting any values.
# ---------------------------------------------------------------------------

class _CfnTag:
    def __init__(self, tag, value):
        self.tag = tag
        self.value = value


def _cfn_constructor(loader, tag, node):
    if isinstance(node, yaml.ScalarNode):
        return _CfnTag(tag, loader.construct_scalar(node))
    elif isinstance(node, yaml.SequenceNode):
        return _CfnTag(tag, loader.construct_sequence(node, deep=True))
    return _CfnTag(tag, loader.construct_mapping(node, deep=True))


def _cfn_representer(dumper, obj):
    if isinstance(obj.value, str):
        return dumper.represent_scalar(obj.tag, obj.value)
    elif isinstance(obj.value, list):
        return dumper.represent_sequence(obj.tag, obj.value)
    return dumper.represent_mapping(obj.tag, obj.value)


class _CfnLoader(yaml.SafeLoader):
    pass


class _CfnDumper(yaml.SafeDumper):
    pass


_CfnLoader.add_multi_constructor("", _cfn_constructor)
_CfnDumper.add_representer(_CfnTag, _cfn_representer)


def _load(text):
    return yaml.load(text, Loader=_CfnLoader)  # nosec B506


def _dump(obj):
    return yaml.dump(obj, Dumper=_CfnDumper, default_flow_style=False, allow_unicode=True)


# ---------------------------------------------------------------------------

def get_stack_info(cfn, stack_name):
    resp = cfn.get_template(StackName=stack_name, TemplateStage="Original")
    body = resp["TemplateBody"]

    desc = cfn.describe_stacks(StackName=stack_name)
    stack = desc["Stacks"][0]
    params = stack.get("Parameters") or []
    capabilities = stack.get("Capabilities") or []

    # boto3 returns JSON templates as a dict; YAML templates as a string
    if isinstance(body, str):
        template = _load(body)
    else:
        template = body

    return template, params, capabilities


def apply_retain_policies(template):
    """Return list of logical IDs that were patched (empty = nothing to do)."""
    changed = []
    for lid, resource in template.get("Resources", {}).items():
        if not isinstance(resource, dict):
            continue
        modified = False
        if resource.get("DeletionPolicy") != "Retain":
            resource["DeletionPolicy"] = "Retain"
            modified = True
        if resource.get("UpdateReplacePolicy") != "Retain":
            resource["UpdateReplacePolicy"] = "Retain"
            modified = True
        if modified:
            changed.append(lid)
    return changed


def wait_for_update(cfn, stack_name, timeout_seconds=300):
    waited = 0
    while waited < timeout_seconds:
        resp = cfn.describe_stacks(StackName=stack_name)
        status = resp["Stacks"][0]["StackStatus"]
        if status == "UPDATE_COMPLETE":
            return True
        if any(s in status for s in ("FAILED", "ROLLBACK")):
            return False
        time.sleep(15)
        waited += 15
    return False


UPDATABLE_STATES = {
    "CREATE_COMPLETE",
    "UPDATE_COMPLETE",
    "IMPORT_COMPLETE",
    "UPDATE_ROLLBACK_COMPLETE",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stack-name", required=True)
    ap.add_argument("--region", default="eu-west-1")
    ap.add_argument("--dry-run", action="store_true",
                    help="Show what would change without calling update-stack")
    args = ap.parse_args()

    cfn = boto3.client("cloudformation", region_name=args.region)

    try:
        desc = cfn.describe_stacks(StackName=args.stack_name)
        status = desc["Stacks"][0]["StackStatus"]
    except botocore.exceptions.ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        msg  = e.response.get("Error", {}).get("Message", "")
        if code == "ValidationError" and "does not exist" in msg:
            print(f"  SKIP: stack '{args.stack_name}' does not exist")
            sys.exit(0)
        print(f"  [FAIL] AWS error describing stack: {code} -- {msg}")
        sys.exit(1)

    if status not in UPDATABLE_STATES:
        print(f"  SKIP: '{args.stack_name}' is in {status} -- not updatable, skipping")
        sys.exit(0)

    try:
        template, params, capabilities = get_stack_info(cfn, args.stack_name)
    except Exception as e:
        print(f"  [FAIL] Could not read template for '{args.stack_name}': {e}")
        sys.exit(1)

    changed = apply_retain_policies(template)

    if not changed:
        print(f"  [OK] NO_CHANGES: all resources already have DeletionPolicy: Retain")
        sys.exit(0)

    print(f"  CHANGED: {len(changed)} resource(s) missing DeletionPolicy: Retain")
    for lid in changed:
        print(f"    + {lid}")

    if args.dry_run:
        print(f"  [DRY-RUN] Would update '{args.stack_name}' -- no changes made")
        sys.exit(0)

    template_body = _dump(template)

    use_prev_params = [
        {"ParameterKey": p["ParameterKey"], "UsePreviousValue": True}
        for p in params
    ]

    if "CAPABILITY_NAMED_IAM" not in capabilities:
        capabilities.append("CAPABILITY_NAMED_IAM")

    print(f"  Updating stack '{args.stack_name}'...")
    try:
        cfn.update_stack(
            StackName=args.stack_name,
            TemplateBody=template_body,
            Parameters=use_prev_params,
            Capabilities=capabilities,
        )
    except botocore.exceptions.ClientError as e:
        msg = e.response.get("Error", {}).get("Message", "")
        if "No updates are to be performed" in msg:
            print(f"  [OK] NO_CHANGES: CloudFormation confirms no effective changes")
            sys.exit(0)
        print(f"  [FAIL] update_stack error: {msg}")
        sys.exit(1)

    print(f"  Waiting for UPDATE_COMPLETE (up to 5 min)...")
    if wait_for_update(cfn, args.stack_name):
        print(f"  [OK] '{args.stack_name}' updated -- DeletionPolicy: Retain on all resources")
    else:
        try:
            final = cfn.describe_stacks(StackName=args.stack_name)["Stacks"][0]["StackStatus"]
        except Exception:
            final = "UNKNOWN"
        print(f"  [FAIL] Update did not reach UPDATE_COMPLETE (final status: {final})")
        sys.exit(1)


if __name__ == "__main__":
    main()
