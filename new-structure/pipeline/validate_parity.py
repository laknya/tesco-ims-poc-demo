#!/usr/bin/env python3
"""
TESCO IMS POC — Parity Validator
Repo: git@github.com:laknya/tesco-ims-poc-demo.git

Compares OLD stack vs NEW stack to confirm identical infrastructure.
Must pass 100% before cutover is allowed.

Usage:
    python3 new-structure/pipeline/validate_parity.py \
        --old-stack poc-EXISTING-vpc-sandbox \
        --new-stack poc-NEW-vpc-sandbox \
        --region eu-west-1
"""

import boto3, sys, argparse
from typing import Tuple


def cfn(region): return boto3.client("cloudformation", region_name=region)
def ec2(region): return boto3.client("ec2",             region_name=region)


def stack_params(c, name):
    return {p["ParameterKey"]: p["ParameterValue"]
            for p in c.describe_stacks(StackName=name)["Stacks"][0].get("Parameters", [])}


def stack_resources(c, name):
    return {r["LogicalResourceId"]: r["ResourceType"]
            for r in c.list_stack_resources(StackName=name)["StackResourceSummaries"]}


def stack_output_keys(c, name):
    return {o["OutputKey"]
            for o in c.describe_stacks(StackName=name)["Stacks"][0].get("Outputs", [])}


def physical_id(c, stack, logical):
    return c.describe_stack_resource(
        StackName=stack, LogicalResourceId=logical
    )["StackResourceDetail"]["PhysicalResourceId"]


def vpc_details(e, vpc_id):
    vpc  = e.describe_vpcs(VpcIds=[vpc_id])["Vpcs"][0]
    dns1 = e.describe_vpc_attribute(VpcId=vpc_id, Attribute="enableDnsHostnames")["EnableDnsHostnames"]["Value"]
    dns2 = e.describe_vpc_attribute(VpcId=vpc_id, Attribute="enableDnsSupport")["EnableDnsSupport"]["Value"]
    return {"cidr": vpc["CidrBlock"], "dnsHostnames": str(dns1).lower(), "dnsSupport": str(dns2).lower()}


def subnet_cidrs(e, ids):
    if not ids: return []
    return sorted(s["CidrBlock"] for s in e.describe_subnets(SubnetIds=ids)["Subnets"])


def compare(label, old, new, skip=None) -> Tuple[bool, list]:
    skip = set(skip or [])
    issues = []
    for k in sorted(set(old) | set(new)):
        if k in skip: continue
        ov, nv = old.get(k, "<MISSING>"), new.get(k, "<MISSING>")
        if ov != nv:
            issues.append(f"    {k}: OLD={ov!r}  →  NEW={nv!r}")
    if issues:
        print(f"\n  ❌  {label}")
        [print(i) for i in issues]
    else:
        print(f"  ✅  {label}  ({len(old)} items match)")
    return not issues, issues


def run(old_stack, new_stack, region):
    c = cfn(region)
    e = ec2(region)

    print(f"\n{'═'*58}")
    print(f"  PARITY CHECK")
    print(f"  Old stack  : {old_stack}")
    print(f"  New stack  : {new_stack}")
    print(f"  Region     : {region}")
    print(f"{'═'*58}")

    results = []

    # 1 — Parameters
    print("\n[1] Parameters")
    ok, _ = compare("Parameters", stack_params(c, old_stack), stack_params(c, new_stack))
    results.append(ok)

    # 2 — Resource types (save result — reused by checks 4 and 5 to avoid duplicate API calls)
    print("\n[2] Resource types")
    old_resources = stack_resources(c, old_stack)
    new_resources = stack_resources(c, new_stack)
    ok, _ = compare("Resource types", old_resources, new_resources)
    results.append(ok)

    # 3 — Output keys
    print("\n[3] Stack output keys")
    old_keys = stack_output_keys(c, old_stack)
    new_keys = stack_output_keys(c, new_stack)
    if old_keys == new_keys:
        print(f"  ✅  Output keys match  ({len(old_keys)} outputs)")
        results.append(True)
    else:
        print(f"  ❌  Output key mismatch")
        print(f"      OLD only: {old_keys - new_keys}")
        print(f"      NEW only: {new_keys - old_keys}")
        results.append(False)

    # 4 — VPC config (VPC stacks only)
    print("\n[4] VPC configuration")
    if "VPC" not in old_resources:
        print(f"  ➖  N/A — no VPC resource in this stack (non-VPC module, skipping)")
    else:
        try:
            old_vpc_id = physical_id(c, old_stack, "VPC")
            new_vpc_id = physical_id(c, new_stack, "VPC")
            ok, _ = compare("VPC config (CIDR + DNS)", vpc_details(e, old_vpc_id), vpc_details(e, new_vpc_id))
            results.append(ok)
        except Exception as ex:
            print(f"  ❌  VPC comparison failed: {ex}")
            results.append(False)

    # 5 — Subnet CIDRs (VPC stacks only)
    print("\n[5] Subnet CIDRs")
    if "VPC" not in old_resources:
        print(f"  ➖  N/A — no VPC resource in this stack (non-VPC module, skipping)")
    else:
        try:
            def subnet_ids(stack):
                return [r["PhysicalResourceId"]
                        for r in c.list_stack_resources(StackName=stack)["StackResourceSummaries"]
                        if r["ResourceType"] == "AWS::EC2::Subnet"]

            old_cidrs = subnet_cidrs(e, subnet_ids(old_stack))
            new_cidrs = subnet_cidrs(e, subnet_ids(new_stack))
            if old_cidrs == new_cidrs:
                print(f"  ✅  Subnet CIDRs match: {old_cidrs}")
                results.append(True)
            else:
                print(f"  ❌  Subnet CIDR mismatch")
                print(f"      OLD: {old_cidrs}")
                print(f"      NEW: {new_cidrs}")
                results.append(False)
        except Exception as ex:
            print(f"  ❌  Subnet comparison failed: {ex}")
            results.append(False)

    # Summary
    passed = sum(results)
    total  = len(results)
    print(f"\n{'═'*58}")
    print(f"  Result: {passed}/{total} checks passed")
    if all(results):
        print("  ✅  PARITY CONFIRMED — safe to cut over")
    else:
        print("  ❌  PARITY FAILED    — do NOT cut over")
    print(f"{'═'*58}\n")
    return all(results)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--old-stack", required=True)
    ap.add_argument("--new-stack", required=True)
    ap.add_argument("--region",    default="eu-west-1")
    args = ap.parse_args()
    sys.exit(0 if run(args.old_stack, args.new_stack, args.region) else 1)
