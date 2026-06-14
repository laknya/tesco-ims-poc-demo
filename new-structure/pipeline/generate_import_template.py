#!/usr/bin/env python3
"""
generate_import_template.py
===========================
Emits a FILTERED CloudFormation template for use in a CFN Resource Import
change set (--change-set-type IMPORT).

WHY THIS EXISTS
---------------
A CFN IMPORT change set requires that EVERY resource in the template appears
in the --resources-to-import list. But some resource types are NOT importable:
  - AWS::EC2::Route
  - AWS::S3::BucketPolicy
  (and others)

If the full template contains a non-importable resource, CFN rejects the import:
  "Resources [PublicRoute] is missing from ResourceToImport list"

The standard AWS pattern is TWO-PHASE:
  Phase 1 (IMPORT): import only the importable resources, using this filtered template.
  Phase 2 (UPDATE): deploy the FULL template -- CFN then creates the remaining
                    (non-importable) resources fresh.

This script produces the Phase 1 template by keeping only the resources whose
LogicalResourceId appears in the module's import-config.json, plus dropping any
Outputs / DependsOn entries that reference the removed resources.

It also writes a sidecar JSON (--actions-output) describing the dropped resources
so the caller can clean up any conflicting physical resources before Phase 2
(e.g. delete an existing 0.0.0.0/0 route that would otherwise collide).

Usage:
  python3 generate_import_template.py \
      --template new-structure/modules/networking/vpc-baseline/template.yaml \
      --config   new-structure/modules/networking/vpc-baseline/import-config.json \
      --output   /tmp/vpc-import-template.yaml \
      [--actions-output /tmp/vpc-import-actions.json]
"""

import argparse
import json
import sys

import yaml


# ---------------------------------------------------------------------------
# CFN intrinsic-tag support for PyYAML.
# CloudFormation templates use short-form tags (!Ref, !Sub, !GetAtt, ...).
# Plain SafeLoader cannot parse them, so we register a generic constructor and
# a matching representer that round-trips them losslessly.
# ---------------------------------------------------------------------------

class CfnTag:
    """Holds a CloudFormation intrinsic short tag and its value."""
    def __init__(self, tag, value):
        self.tag = tag
        self.value = value


def _cfn_multi_constructor(loader, tag_suffix, node):
    tag = "!" + tag_suffix
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    elif isinstance(node, yaml.MappingNode):
        value = loader.construct_mapping(node, deep=True)
    else:
        value = None
    return CfnTag(tag, value)


def _cfn_representer(dumper, data):
    if isinstance(data.value, str):
        return dumper.represent_scalar(data.tag, data.value)
    if isinstance(data.value, list):
        return dumper.represent_sequence(data.tag, data.value)
    if isinstance(data.value, dict):
        return dumper.represent_mapping(data.tag, data.value)
    return dumper.represent_scalar(data.tag, "")


class _CfnLoader(yaml.SafeLoader):
    pass


class _CfnDumper(yaml.SafeDumper):
    pass


_CfnLoader.add_multi_constructor("!", _cfn_multi_constructor)
_CfnDumper.add_representer(CfnTag, _cfn_representer)


# ---------------------------------------------------------------------------
# DependsOn cleanup
# ---------------------------------------------------------------------------

def _clean_depends_on(resource, dropped):
    """Remove DependsOn entries that point at dropped resources."""
    dep = resource.get("DependsOn")
    if dep is None:
        return
    if isinstance(dep, str):
        if dep in dropped:
            del resource["DependsOn"]
    elif isinstance(dep, list):
        kept = [d for d in dep if d not in dropped]
        if kept:
            resource["DependsOn"] = kept
        else:
            del resource["DependsOn"]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate a filtered CFN template for Resource Import (Phase 1)."
    )
    parser.add_argument("--template", required=True, help="Full module template (YAML)")
    parser.add_argument("--config", required=True, help="import-config.json for the module")
    parser.add_argument("--output", required=True, help="Path to write the filtered template")
    parser.add_argument("--actions-output",
                        help="Optional: write dropped-resource details for pre-Phase-2 cleanup")
    args = parser.parse_args()

    with open(args.template) as fh:
        template = yaml.load(fh, Loader=_CfnLoader)
    with open(args.config) as fh:
        config = json.load(fh)

    importable = {e["LogicalResourceId"] for e in config.get("resources_to_import", [])}
    all_resources = template.get("Resources", {})

    dropped = {lid for lid in all_resources if lid not in importable}

    # Build the dropped-resource action sidecar BEFORE we mutate the template.
    dropped_actions = []
    for lid in sorted(dropped):
        res = all_resources[lid]
        entry = {"LogicalResourceId": lid, "ResourceType": res.get("Type")}
        if res.get("Type") == "AWS::EC2::Route":
            props = res.get("Properties", {})
            rt_ref = props.get("RouteTableId")
            cidr = props.get("DestinationCidrBlock")
            # RouteTableId is typically !Ref <LogicalId>; capture the referenced logical id.
            if isinstance(rt_ref, CfnTag) and rt_ref.tag == "!Ref":
                entry["RouteTableLogicalId"] = rt_ref.value
            if isinstance(cidr, str):
                entry["DestinationCidrBlock"] = cidr
        dropped_actions.append(entry)

    # Keep only importable resources.
    template["Resources"] = {
        lid: res for lid, res in all_resources.items() if lid in importable
    }

    # Clean DependsOn references to dropped resources.
    for res in template["Resources"].values():
        _clean_depends_on(res, dropped)

    # Drop sections a CFN IMPORT change set will not accept. CFN rejects adding
    # or modifying Outputs ("you cannot modify or add [Outputs]") and likewise
    # template-level Metadata during import. The import template must contain only
    # the resources being imported (plus Parameters). Phase 2 (full-template
    # deploy) re-adds Outputs/Exports/Metadata after the resources are adopted.
    had_outputs = "Outputs" in template
    template.pop("Outputs", None)
    template.pop("Metadata", None)

    with open(args.output, "w") as fh:
        yaml.dump(template, fh, Dumper=_CfnDumper, sort_keys=False, default_flow_style=False)

    if args.actions_output:
        with open(args.actions_output, "w") as fh:
            json.dump(dropped_actions, fh, indent=2)

    kept = sorted(template["Resources"].keys())
    print(f"[generate_import_template] kept {len(kept)} importable resource(s): {kept}")
    if dropped:
        print(f"[generate_import_template] dropped {len(dropped)} non-importable "
              f"resource(s) (created fresh in Phase 2): {sorted(dropped)}")
    if had_outputs:
        print(f"[generate_import_template] stripped Outputs section "
              f"(re-added in Phase 2 -- CFN import cannot add Outputs)")
    print(f"[generate_import_template] -> {args.output}")


if __name__ == "__main__":
    main()
