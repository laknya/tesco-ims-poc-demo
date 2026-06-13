"""
AWS-dependent tests -- skipped unless AWS credentials are available.

These test the live CloudFormation pipeline (stages 1-5) and parity validator.
Mark: @pytest.mark.aws

Run locally (with credentials):  pytest -m aws
Skip in CI (no credentials):     pytest -m "not aws"
"""
import os
import subprocess
import sys

import pytest

from conftest import REPO_ROOT, run, python

# Skip entire module if no AWS credentials available
pytestmark = pytest.mark.aws

AWS_REGION  = "eu-west-1"
TEST_ACCOUNT = "dev"


def has_aws_credentials() -> bool:
    result = subprocess.run(
        ["aws", "sts", "get-caller-identity", "--region", AWS_REGION],
        capture_output=True, text=True
    )
    return result.returncode == 0


skip_no_aws = pytest.mark.skipif(
    not has_aws_credentials(),
    reason="AWS credentials not available -- set up OIDC or env vars to run these tests"
)


@skip_no_aws
class TestStage1DeployExisting:

    def test_deploy_existing_exits_zero(self):
        result = run(["bash", "scripts/stage1-deploy-existing.sh", TEST_ACCOUNT],
                     timeout=300)
        assert result.returncode == 0, f"stage1 failed:\n{result.stdout[-1000:]}"

    def test_existing_stacks_are_create_complete(self):
        import boto3
        cfn = boto3.client("cloudformation", region_name=AWS_REGION)
        for module in ["networking-vpc-baseline", "security-kms-key", "shared-services-s3-bucket"]:
            stack_name = f"poc-EXISTING-{module}-{TEST_ACCOUNT}"
            resp = cfn.describe_stacks(StackName=stack_name)
            status = resp["Stacks"][0]["StackStatus"]
            assert status in ("CREATE_COMPLETE", "UPDATE_COMPLETE"), \
                f"{stack_name}: unexpected status {status}"


@skip_no_aws
class TestStage2DeployNew:

    def test_deploy_new_single_module(self):
        result = run([
            "bash", "scripts/stage2-deploy-new.sh",
            TEST_ACCOUNT, "networking/vpc-baseline"
        ], timeout=300)
        assert result.returncode == 0, f"stage2 single module failed:\n{result.stdout[-1000:]}"

    def test_new_stack_has_module_version_tag(self):
        import boto3
        cfn = boto3.client("cloudformation", region_name=AWS_REGION)
        stack_name = f"poc-NEW-networking-vpc-baseline-{TEST_ACCOUNT}"
        resp = cfn.describe_stacks(StackName=stack_name)
        tags = {t["Key"]: t["Value"] for t in resp["Stacks"][0].get("Tags", [])}
        assert "ModuleVersion" in tags, \
            f"{stack_name}: missing ModuleVersion tag (version tracking not working)"

    def test_new_stack_has_module_type_tag(self):
        import boto3
        cfn = boto3.client("cloudformation", region_name=AWS_REGION)
        stack_name = f"poc-NEW-networking-vpc-baseline-{TEST_ACCOUNT}"
        resp = cfn.describe_stacks(StackName=stack_name)
        tags = {t["Key"]: t["Value"] for t in resp["Stacks"][0].get("Tags", [])}
        assert "ModuleType" in tags
        assert tags["ModuleType"].startswith("TescoIMS::")


@skip_no_aws
class TestStage3ParityCheck:

    def test_vpc_parity_passes(self):
        result = python(
            "validate_parity.py",
            "--old-stack", f"poc-EXISTING-networking-vpc-baseline-{TEST_ACCOUNT}",
            "--new-stack",  f"poc-NEW-networking-vpc-baseline-{TEST_ACCOUNT}",
            "--region",     AWS_REGION,
        )
        assert result.returncode == 0, \
            f"VPC parity check failed:\n{result.stdout}"

    def test_full_stage3_exits_zero(self):
        result = run(["bash", "scripts/stage3-validate-parity.sh", TEST_ACCOUNT],
                     timeout=120)
        assert result.returncode == 0, f"stage3 failed:\n{result.stdout[-1000:]}"
