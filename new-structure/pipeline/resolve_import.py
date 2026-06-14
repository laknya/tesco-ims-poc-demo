#!/usr/bin/env python3
"""
resolve_import.py
=================
Builds the --resources-to-import JSON array for CFN Resource Import.

Reads an import-config.json and resolves every resource identifier from one
of three sources:
  stack-resource  physical resource ID via describe-stack-resource
  param           value from the resolved CFN parameters JSON file
  literal         hardcoded string value in the config itself

When --fallback-by-tag is set and the source stack no longer exists (e.g.
during a stage1 re-run after stacks were cleaned up), the resolver uses
AWS resource tags (aws:cloudformation:stack-name / logical-id) to locate
retained resources.

Exit codes:
  0  success -- JSON written to --output or stdout
  1  config / resolution error
  2  AWS API error

Usage:
  python3 resolve_import.py
      --stack-name poc-EXISTING-networking-vpc-baseline-dev
      --config     new-structure/modules/networking/vpc-baseline/import-config.json
      --params     /tmp/resolved-vpc.json
      --region     eu-west-1
      [--output    /tmp/vpc-import.json]
      [--fallback-by-tag]
      [--validate]
"""

import argparse
import json
import sys

import boto3
from botocore.exceptions import ClientError


# ---------------------------------------------------------------------------
# Tag-based fallback: locate retained resources after a stack is deleted.
# CFN tags (aws:cloudformation:stack-name, aws:cloudformation:logical-id)
# remain on resources even after the owning stack is deleted.
# ---------------------------------------------------------------------------

def _tag_filter(stack_name, logical_id):
    return [
        {"Name": "tag:aws:cloudformation:stack-name", "Values": [stack_name]},
        {"Name": "tag:aws:cloudformation:logical-id", "Values": [logical_id]},
    ]


def _lookup_ec2_by_tag(resource_type, stack_name, logical_id, ec2):
    """Return the physical resource ID for an EC2 resource using CFN tags."""
    filters = _tag_filter(stack_name, logical_id)
    try:
        if resource_type == "AWS::EC2::VPC":
            r = ec2.describe_vpcs(Filters=filters)
            items = r.get("Vpcs", [])
            if items:
                return items[0]["VpcId"]

        elif resource_type == "AWS::EC2::Subnet":
            r = ec2.describe_subnets(Filters=filters)
            items = r.get("Subnets", [])
            if items:
                return items[0]["SubnetId"]

        elif resource_type == "AWS::EC2::InternetGateway":
            r = ec2.describe_internet_gateways(Filters=filters)
            items = r.get("InternetGateways", [])
            if items:
                return items[0]["InternetGatewayId"]

        elif resource_type == "AWS::EC2::RouteTable":
            r = ec2.describe_route_tables(Filters=filters)
            items = r.get("RouteTables", [])
            if items:
                return items[0]["RouteTableId"]

        elif resource_type == "AWS::EC2::SubnetRouteTableAssociation":
            # Physical ID in CFN is the association ID (rtbassoc-xxx).
            # The association lives on the route table -- find by tag on the assoc.
            r = ec2.describe_route_tables(
                Filters=[{"Name": "tag:aws:cloudformation:stack-name", "Values": [stack_name]}]
            )
            for rt in r.get("RouteTables", []):
                for assoc in rt.get("Associations", []):
                    tags = {t["Key"]: t["Value"] for t in assoc.get("Tags", [])}
                    if tags.get("aws:cloudformation:logical-id") == logical_id:
                        return assoc["RouteTableAssociationId"]

        elif resource_type == "AWS::EC2::Route":
            # Route physical ID in CFN is "rtb-xxx|0.0.0.0/0".
            # Tags may not exist on individual routes; fall back to route table.
            r = ec2.describe_route_tables(
                Filters=[{"Name": "tag:aws:cloudformation:stack-name", "Values": [stack_name]}]
            )
            for rt in r.get("RouteTables", []):
                for route in rt.get("Routes", []):
                    if route.get("DestinationCidrBlock") == "0.0.0.0/0":
                        return rt["RouteTableId"] + "|0.0.0.0/0"

    except ClientError as exc:
        print(f"    [WARN] Tag lookup failed for {logical_id}: {exc}", file=sys.stderr)

    return None


def _lookup_kms_by_tag(resource_type, stack_name, logical_id, kms):
    if resource_type == "AWS::KMS::Key":
        try:
            paginator = kms.get_paginator("list_keys")
            for page in paginator.paginate():
                for key in page["Keys"]:
                    try:
                        tags_r = kms.list_resource_tags(KeyId=key["KeyId"])
                        tags = {t["TagKey"]: t["TagValue"] for t in tags_r.get("Tags", [])}
                        if (tags.get("aws:cloudformation:stack-name") == stack_name
                                and tags.get("aws:cloudformation:logical-id") == logical_id):
                            return key["KeyId"]
                    except ClientError:
                        pass
        except ClientError as exc:
            print(f"    [WARN] KMS tag lookup failed: {exc}", file=sys.stderr)
    elif resource_type == "AWS::KMS::Alias":
        try:
            paginator = kms.get_paginator("list_aliases")
            for page in paginator.paginate():
                for alias in page["Aliases"]:
                    if alias.get("AliasName", "").startswith("alias/tesco-ims"):
                        # Match by the alias name we'd expect for this stack
                        return alias["AliasName"]
        except ClientError as exc:
            print(f"    [WARN] KMS alias lookup failed: {exc}", file=sys.stderr)
    return None


def _lookup_s3_by_param(resource_type, params):
    if resource_type == "AWS::S3::Bucket":
        return params.get("BucketName")
    return None


def lookup_by_cfn_tag(resource_type, stack_name, logical_id, region, params):
    """Locate a retained resource using CFN tags or param values."""
    if resource_type.startswith("AWS::EC2::"):
        ec2 = boto3.client("ec2", region_name=region)
        return _lookup_ec2_by_tag(resource_type, stack_name, logical_id, ec2)
    elif resource_type.startswith("AWS::KMS::"):
        kms = boto3.client("kms", region_name=region)
        return _lookup_kms_by_tag(resource_type, stack_name, logical_id, kms)
    elif resource_type == "AWS::S3::Bucket":
        return _lookup_s3_by_param(resource_type, params)
    return None


# ---------------------------------------------------------------------------
# Identifier resolution
# ---------------------------------------------------------------------------

def resolve_identifier(id_spec, resource_type, stack_name, stack_cache,
                       params, cfn, region, fallback_by_tag):
    """Return the string value for one identifier entry."""
    source = id_spec["Source"]

    if source == "literal":
        return id_spec["Value"]

    if source == "param":
        key = id_spec["Param"]
        if key not in params:
            print(f"  [FAIL] Param '{key}' not found in resolved params.", file=sys.stderr)
            sys.exit(1)
        return params[key]

    if source == "stack-resource":
        logical_id = id_spec["StackLogicalId"]
        if logical_id in stack_cache:
            return stack_cache[logical_id]

        # Try describe-stack-resource first
        if stack_name:
            try:
                r = cfn.describe_stack_resource(
                    StackName=stack_name,
                    LogicalResourceId=logical_id,
                )
                physical_id = r["StackResourceDetail"]["PhysicalResourceId"]
                stack_cache[logical_id] = physical_id
                print(f"    {logical_id}: {physical_id}  (from stack)")
                return physical_id
            except ClientError as exc:
                code = exc.response["Error"]["Code"]
                if code not in ("ValidationError", "StackInstanceNotFoundException"):
                    print(f"  [FAIL] AWS error looking up {logical_id}: {exc}", file=sys.stderr)
                    sys.exit(2)
                # Stack does not exist -- try tag fallback below

        if not fallback_by_tag:
            print(
                f"  [FAIL] Stack '{stack_name}' not found and --fallback-by-tag not set. "
                f"Cannot resolve '{logical_id}'.",
                file=sys.stderr,
            )
            sys.exit(1)

        # Tag-based fallback
        print(f"    {logical_id}: stack gone, trying tag lookup...")
        physical_id = lookup_by_cfn_tag(resource_type, stack_name, logical_id, region, params)
        if not physical_id:
            print(
                f"  [FAIL] Could not locate '{logical_id}' ({resource_type}) "
                f"via CFN tags on stack '{stack_name}'.",
                file=sys.stderr,
            )
            sys.exit(1)
        print(f"    {logical_id}: {physical_id}  (from tag fallback)")
        stack_cache[logical_id] = physical_id
        return physical_id

    print(f"  [FAIL] Unknown identifier source '{source}'.", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Resource existence validation (--validate)
# ---------------------------------------------------------------------------

def validate_resource(resource_type, identifier, region):
    """
    Return True if the resource exists in AWS, False otherwise.
    Raises on unexpected AWS errors.
    """
    try:
        if resource_type == "AWS::S3::Bucket":
            s3 = boto3.client("s3", region_name=region)
            s3.head_bucket(Bucket=identifier.get("BucketName", ""))
            return True

        elif resource_type == "AWS::KMS::Key":
            kms = boto3.client("kms", region_name=region)
            kms.describe_key(KeyId=identifier.get("KeyId", ""))
            return True

        elif resource_type == "AWS::KMS::Alias":
            kms = boto3.client("kms", region_name=region)
            kms.describe_key(KeyId=identifier.get("AliasName", ""))
            return True

        elif resource_type == "AWS::EC2::VPC":
            ec2 = boto3.client("ec2", region_name=region)
            r = ec2.describe_vpcs(VpcIds=[identifier.get("VpcId", "")])
            return bool(r.get("Vpcs"))

        elif resource_type == "AWS::EC2::Subnet":
            ec2 = boto3.client("ec2", region_name=region)
            r = ec2.describe_subnets(SubnetIds=[identifier.get("SubnetId", "")])
            return bool(r.get("Subnets"))

        elif resource_type == "AWS::EC2::InternetGateway":
            ec2 = boto3.client("ec2", region_name=region)
            r = ec2.describe_internet_gateways(
                InternetGatewayIds=[identifier.get("InternetGatewayId", "")]
            )
            return bool(r.get("InternetGateways"))

        elif resource_type == "AWS::EC2::RouteTable":
            ec2 = boto3.client("ec2", region_name=region)
            r = ec2.describe_route_tables(
                RouteTableIds=[identifier.get("RouteTableId", "")]
            )
            return bool(r.get("RouteTables"))

        elif resource_type in (
            "AWS::EC2::VPCGatewayAttachment",
            "AWS::EC2::Route",
            "AWS::EC2::SubnetRouteTableAssociation",
        ):
            # These are relationship resources; existence is implied by their
            # parent resources existing. Skip deep validation.
            return True

    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code in ("404", "NoSuchBucket", "InvalidVpcID.NotFound",
                    "InvalidSubnetID.NotFound", "InvalidInternetGatewayId.NotFound",
                    "InvalidRouteTableId.NotFound", "NotFoundException",
                    "DisabledException"):
            return False
        raise

    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Resolve CFN Resource Import identifiers from import-config.json"
    )
    parser.add_argument("--stack-name",
                        help="Source stack name for stack-resource identifier lookups")
    parser.add_argument("--config", required=True, help="Path to import-config.json")
    parser.add_argument("--params", required=True,
                        help="Path to resolved CFN parameters JSON ([{ParameterKey, ParameterValue}])")
    parser.add_argument("--region", default="eu-west-1")
    parser.add_argument("--output",
                        help="Write output to this file (default: stdout)")
    parser.add_argument("--fallback-by-tag", action="store_true",
                        help="If source stack is gone, locate resources via CFN tags")
    parser.add_argument("--validate", action="store_true",
                        help="Verify each resource exists in AWS before writing output")
    args = parser.parse_args()

    # Load inputs
    with open(args.config) as fh:
        config = json.load(fh)
    with open(args.params) as fh:
        raw_params = json.load(fh)
    params = {p["ParameterKey"]: p["ParameterValue"] for p in raw_params}

    cfn = boto3.client("cloudformation", region_name=args.region)
    stack_cache = {}

    print(f"[resolve_import] config  : {args.config}")
    print(f"[resolve_import] params  : {args.params}")
    if args.stack_name:
        print(f"[resolve_import] stack   : {args.stack_name}")
    print()

    resources_to_import = []
    errors = []

    for resource in config["resources_to_import"]:
        rtype = resource["ResourceType"]
        logical_id = resource["LogicalResourceId"]
        print(f"  Resolving {logical_id} ({rtype})")

        identifier = {}
        for id_spec in resource["Identifiers"]:
            key = id_spec["Key"]
            value = resolve_identifier(
                id_spec, rtype, args.stack_name, stack_cache,
                params, cfn, args.region, args.fallback_by_tag,
            )
            identifier[key] = value

        if args.validate:
            exists = validate_resource(rtype, identifier, args.region)
            if not exists:
                msg = f"  [FAIL] Resource {logical_id} ({rtype}) not found in AWS: {identifier}"
                print(msg, file=sys.stderr)
                errors.append(msg)
            else:
                print(f"    [OK] exists in AWS")

        resources_to_import.append({
            "ResourceType": rtype,
            "LogicalResourceId": logical_id,
            "ResourceIdentifier": identifier,
        })
        print()

    if errors:
        print(f"\n[FAIL] {len(errors)} resource(s) not found in AWS. Aborting.", file=sys.stderr)
        sys.exit(1)

    result = json.dumps(resources_to_import, indent=2)

    if args.output:
        with open(args.output, "w") as fh:
            fh.write(result)
        print(f"[resolve_import] -> {args.output}")
    else:
        print(result)

    print(f"\n[resolve_import] [OK] {len(resources_to_import)} resource(s) resolved.")


if __name__ == "__main__":
    main()
