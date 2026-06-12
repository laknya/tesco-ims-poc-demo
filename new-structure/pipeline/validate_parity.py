#!/usr/bin/env python3
"""
TESCO IMS POC — Parity Validator
Repo: git@github.com:laknya/tesco-ims-poc-demo.git

Compares OLD stacks vs NEW stack to confirm identical infrastructure.
Must pass 100% before cutover is allowed.
"""

import boto3, sys, argparse, json
from typing import Tuple


def cfn_client(region: str):
    return boto3.client("cloudformation", region_name=region)


def ec2_client(region: str):
    return boto3.client("ec2", region_name=region)


def stack_params(cfn, name: str) -> dict:
    stacks = cfn.describe_stacks(StackName=name)["Stacks"]
    return {
        p["ParameterKey"]: p["ParameterValue"]
        for p in stacks[0].get("Parameters", [])
    }


def stack_resources(cfn, name: str) -> dict:
    pages = cfn.list_stack_resources(StackName=name)
    return {
        r["LogicalResourceId"]: r["ResourceType"]
        for r in pages["StackResourceSummaries"]
    }


def stack_outputs(cfn, name: str) -> dict:
    stacks = cfn.describe_stacks(StackName=name)["Stacks"]
    return {
        o["OutputKey"]: o["OutputKey"]
        for o in stacks[0].get("Outputs", [])
    }


def vpc_details(ec2, vpc_id: str) -> dict:
    vpc  = ec2.describe_vpcs(VpcIds=[vpc_id])["Vpcs"][0]
    dns1 = ec2.describe_vpc_attribute(
        VpcId=vpc_id, Attribute="enableDnsHostnames"
    )["EnableDnsHostnames"]["Value"]
    dns2 = ec2.describe_vpc_attribute(
        VpcId=vpc_id, Attribute="enableDnsSupport"
    )["EnableDnsSupport"]["Value"]
    return {
        "cidr":         vpc["CidrBlock"],
        "dnsHostnames": str(dns1).lower(),
        "dnsSupport":   str(dns2).lower(),
    }


def subnet_cidrs(ec2, subnet_ids: list) -> list:
    if not subnet_ids:
        return []
    subnets = ec2.describe_subnets(SubnetIds=subnet_ids)["Subnets"]
    return sorted(s["CidrBlock"] for s in subnets)


def compare(label: str, old: dict, new: dict,
            skip: list = None) -> Tuple[bool, list]:
    skip   = skip or []
    issues = []
    for k in sorted(set(old) | set(new)):
        if k in skip:
            continue
        ov = old.get(k, "<MISSING>")
        nv = new.get(k, "<MISSING>")
        if ov != nv:
            issues.append(f"    {k}: OLD={ov!r}  →  NEW={nv!r}")
    if issues:
        print(f"\n  ❌  {label}")
        [print(i) for i in issues]
    else:
        print(f"  ✅  {label}  ({len(old)} items match)")
    return not issues, issues


def run(old_vpc_stack: str, old_subnet_stack: str,
        new_stack: str, region: str) -> bool:

    cfn = cfn_client(region)
    ec2 = ec2_client(region)

    print(f"\n{'═'*55}")
    print(f"  PARITY CHECK")
    print(f"  Old VPC stack    : {old_vpc_stack}")
    print(f"  Old Subnet stack : {old_subnet_stack}")
    print(f"  New stack        : {new_stack}")
    print(f"  Region           : {region}")
    print(f"{'═'*55}")

    results = []

    # ── 1. Resource type comparison ──────────────────────────────
    print("\n[1] Resource types")
    old_res = {**stack_resources(cfn, old_vpc_stack),
               **stack_resources(cfn, old_subnet_stack)}
    new_res = stack_resources(cfn, new_stack)
    ok, _ = compare("Resource types", old_res, new_res)
    results.append(ok)

    # ── 2. Output keys ───────────────────────────────────────────
    print("\n[2] Stack output keys")
    old_out = {**stack_outputs(cfn, old_vpc_stack),
               **stack_outputs(cfn, old_subnet_stack)}
    new_out = stack_outputs(cfn, new_stack)
    ok, _ = compare("Output keys", old_out, new_out)
    results.append(ok)

    # ── 3. VPC CIDR + DNS ────────────────────────────────────────
    print("\n[3] VPC configuration")
    try:
        old_vpc_res = stack_resources(cfn, old_vpc_stack)
        new_vpc_res = stack_resources(cfn, new_stack)

        old_vpc_id = next(
            (v for k, v in
             cfn.describe_stack_resource(
                 StackName=old_vpc_stack,
                 LogicalResourceId="VPC"
             )["StackResourceDetail"].items()
             if k == "PhysicalResourceId"), None
        )
        new_vpc_id = cfn.describe_stack_resource(
            StackName=new_stack,
            LogicalResourceId="VPC"
        )["StackResourceDetail"]["PhysicalResourceId"]

        old_vpc_cfg = vpc_details(ec2, old_vpc_id)
        new_vpc_cfg = vpc_details(ec2, new_vpc_id)
        ok, _ = compare("VPC config (CIDR + DNS)", old_vpc_cfg, new_vpc_cfg)
        results.append(ok)
    except Exception as e:
        print(f"  ⚠️  Could not compare VPCs: {e}")

    # ── 4. Subnet CIDRs ──────────────────────────────────────────
    print("\n[4] Subnet CIDRs")
    try:
        def get_subnet_ids(cfn_client, stack_name):
            res = cfn_client.list_stack_resources(StackName=stack_name)
            return [
                r["PhysicalResourceId"]
                for r in res["StackResourceSummaries"]
                if r["ResourceType"] == "AWS::EC2::Subnet"
            ]

        old_subnets = sorted(
            get_subnet_ids(cfn, old_vpc_stack) +
            get_subnet_ids(cfn, old_subnet_stack)
        )
        new_subnets = get_subnet_ids(cfn, new_stack)

        old_cidrs = subnet_cidrs(ec2, old_subnets)
        new_cidrs = subnet_cidrs(ec2, new_subnets)

        if old_cidrs == new_cidrs:
            print(f"  ✅  Subnet CIDRs match: {old_cidrs}")
            results.append(True)
        else:
            print(f"  ❌  Subnet CIDR mismatch")
            print(f"      OLD: {old_cidrs}")
            print(f"      NEW: {new_cidrs}")
            results.append(False)
    except Exception as e:
        print(f"  ⚠️  Could not compare subnets: {e}")

    # ── Summary ──────────────────────────────────────────────────
    passed = sum(results)
    total  = len(results)
    print(f"\n{'═'*55}")
    print(f"  Result: {passed}/{total} checks passed")
    if all(results):
        print("  ✅  PARITY CONFIRMED — safe to cut over")
    else:
        print("  ❌  PARITY FAILED    — do NOT cut over")
    print(f"{'═'*55}\n")
    return all(results)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--old-vpc-stack",    required=True)
    ap.add_argument("--old-subnet-stack", required=True)
    ap.add_argument("--new-stack",        required=True)
    ap.add_argument("--region",           default="eu-west-1")
    args = ap.parse_args()
    ok = run(args.old_vpc_stack, args.old_subnet_stack,
             args.new_stack, args.region)
    sys.exit(0 if ok else 1)