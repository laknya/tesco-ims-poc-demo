"""
Tests for CloudFormation template validity and config file syntax.

Covers:
  - cfn-lint on all 6 templates (3 existing-structure, 3 new-structure)
  - JSON syntax for all parameter files
  - YAML syntax for _accounts-registry.yaml
  - Accounts registry structure and required fields
  - Stack naming convention consistency
  - Exports/outputs match the cross-stack reference pattern
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

from conftest import REPO_ROOT, CONFIG_DIR, MODULES_DIR, EXISTING_DIR, run


def cfn_lint(template_path: str) -> subprocess.CompletedProcess:
    return run(["cfn-lint", template_path])


ALL_TEMPLATES = sorted([
    *MODULES_DIR.rglob("template.yaml"),
    *EXISTING_DIR.rglob("*-template.yaml"),
])

ALL_JSON_CONFIGS = sorted([
    p for p in REPO_ROOT.rglob("*.json")
    if ".git" not in str(p) and "generated" not in str(p)
])

ALL_YAML_FILES = sorted([
    p for p in REPO_ROOT.rglob("*.yaml")
    if ".git" not in str(p)
    and "node_modules" not in str(p)
])


# -- cfn-lint ------------------------------------------------------------------

class TestCfnLint:

    @pytest.mark.parametrize("template", [
        str(p.relative_to(REPO_ROOT)) for p in ALL_TEMPLATES
    ], ids=lambda p: p.replace("/", "."))
    def test_template_passes_cfn_lint(self, template):
        result = cfn_lint(template)
        assert result.returncode == 0, \
            f"cfn-lint FAILED for {template}:\n{result.stdout}\n{result.stderr}"

    def test_new_templates_resources_use_ref_not_literals(self):
        """
        New master templates must not hardcode literal values in Resources.
        Parameters may still have Default: (acceptable for boolean flags like
        EnableDnsHostnames). The key rule is Resources must use !Ref / !Sub / etc.
        rather than literal strings for environment-specific values.
        """
        # These resource-level patterns indicate a hardcoded literal where a Ref
        # should be used. We check that none appear inside the Resources block.
        suspicious_patterns = [
            "eu-west-1",            # hardcoded region
            "641079926471",         # hardcoded account ID in resources
            "TESCO-IMS-PLATFORM",   # hardcoded cost centre in resources
        ]
        for template_path in sorted(MODULES_DIR.rglob("template.yaml")):
            content = template_path.read_text()
            # Only check the Resources section (after "Resources:")
            resources_section = content.split("Resources:", 1)[-1] if "Resources:" in content else ""
            for pattern in suspicious_patterns:
                assert pattern not in resources_section, \
                    f"{template_path.relative_to(REPO_ROOT)}: hardcoded '{pattern}' found in Resources section"

    @pytest.mark.parametrize("template", [
        str(p.relative_to(REPO_ROOT)) for p in ALL_TEMPLATES
    ], ids=lambda p: p.replace("/", "."))
    def test_description_under_1024_bytes(self, template):
        """
        CloudFormation enforces a 1024-byte limit on the template Description field.
        cfn-lint only checks character count and misses multi-byte Unicode chars
        (e.g. box-drawing - is 3 bytes). This test catches the gap before any AWS call.
        """
        import re
        content = Path(template).read_text(encoding="utf-8")
        m = re.search(r'^Description\s*:\s*[>|]?-?\s*\n?((?:[ \t].+\n?)*|(?![\n]).+)',
                      content, re.MULTILINE)
        if not m:
            return  # no Description field -- nothing to check
        # Extract value: strip key, strip leading whitespace from block scalars
        block = content[m.start():]
        next_key = re.search(r'\n(?:Parameters|Metadata|Resources|Outputs|Mappings|Conditions)\s*:', block)
        raw = block[:next_key.start() if next_key else len(block)]
        value = re.sub(r'^Description\s*:\s*[>|]?-?\s*', '', raw).strip()
        value = re.sub(r'^[ \t]{1,2}', '', value, flags=re.MULTILINE)
        byte_len = len(value.encode("utf-8"))
        assert byte_len <= 1024, (
            f"{template}: Description is {byte_len} bytes -- exceeds CloudFormation's 1024-byte limit. "
            f"Shorten the text (watch for Unicode box-drawing chars -- each '-' costs 3 bytes)."
        )

    def test_existing_templates_have_hardcoded_defaults(self):
        """Existing per-account templates should show the 'Default:' problem."""
        for template_path in sorted(EXISTING_DIR.rglob("*-template.yaml")):
            content = template_path.read_text()
            assert "Default:" in content, \
                f"{template_path.name}: expected hardcoded Default: values (old-style template)"

    def test_new_templates_export_outputs(self):
        """All new module templates must have an Outputs section with Export names."""
        for template_path in sorted(MODULES_DIR.rglob("template.yaml")):
            content = template_path.read_text()
            assert "Outputs:" in content, \
                f"{template_path.relative_to(REPO_ROOT)}: missing Outputs section"
            assert "Export:" in content, \
                f"{template_path.relative_to(REPO_ROOT)}: missing Export in Outputs (needed for cross-stack refs)"

    def test_s3_template_has_depend_on_bucket(self):
        """S3BucketPolicy must have DependsOn: S3Bucket (explicit ordering)."""
        s3_template = MODULES_DIR / "shared-services" / "s3-bucket" / "template.yaml"
        content = s3_template.read_text()
        assert "DependsOn: S3Bucket" in content, \
            "S3BucketPolicy must have explicit DependsOn: S3Bucket"

    def test_s3_template_has_admin_and_writer_statements(self):
        """S3 bucket policy must include AdminAccess and WriterAccess statements."""
        s3_template = MODULES_DIR / "shared-services" / "s3-bucket" / "template.yaml"
        content = s3_template.read_text()
        assert "AdminAccess" in content, \
            "S3 template missing AdminAccess bucket policy statement"
        assert "WriterAccess" in content, \
            "S3 template missing WriterAccess bucket policy statement"

    def test_s3_template_has_deny_non_vpc_statement(self):
        """
        S3 bucket policy must include DenyNonVpcAccess using Fn::ImportValue of the VPC stack.
        This is a key demo feature: shows cross-stack Fn::ImportValue in action so
        developers see how to use CloudFormation exports to enforce network-level access control.
        """
        s3_template = MODULES_DIR / "shared-services" / "s3-bucket" / "template.yaml"
        content = s3_template.read_text()
        assert "DenyNonVpcAccess" in content, \
            "S3 template missing DenyNonVpcAccess statement (cross-stack VPC reference demo)"
        assert "Fn::ImportValue" in content, \
            "S3 template missing Fn::ImportValue (needed to import VpcId from VPC stack)"
        assert "VpcStackName" in content, \
            "S3 template missing VpcStackName parameter (supplies the stack name for the import)"

    def test_vpc_template_exports_vpc_id(self):
        """VPC template must export VpcId for cross-stack consumers."""
        vpc_template = MODULES_DIR / "networking" / "vpc-baseline" / "template.yaml"
        content = vpc_template.read_text()
        assert "VpcId" in content, "VPC template must export VpcId"
        assert "Export:" in content

    def _validate_import_config_schema(self, import_cfg_path):
        """Validate an import-config.json uses the new Identifiers array schema."""
        cfg = json.loads(import_cfg_path.read_text())
        assert "resources_to_import" in cfg, \
            f"{import_cfg_path.name}: must have 'resources_to_import'"
        assert len(cfg["resources_to_import"]) > 0, \
            f"{import_cfg_path.name}: resources_to_import must not be empty"
        for entry in cfg["resources_to_import"]:
            assert "ResourceType" in entry, \
                f"{import_cfg_path.name}: entry missing ResourceType"
            assert "LogicalResourceId" in entry, \
                f"{import_cfg_path.name}: entry missing LogicalResourceId"
            assert "Identifiers" in entry, \
                f"{import_cfg_path.name}: entry missing Identifiers array (new schema)"
            assert isinstance(entry["Identifiers"], list), \
                f"{import_cfg_path.name}: Identifiers must be a list"
            for id_spec in entry["Identifiers"]:
                assert "Key" in id_spec, \
                    f"{import_cfg_path.name}: identifier spec missing 'Key'"
                assert "Source" in id_spec, \
                    f"{import_cfg_path.name}: identifier spec missing 'Source'"
                assert id_spec["Source"] in ("stack-resource", "param", "literal"), \
                    f"{import_cfg_path.name}: unknown Source '{id_spec['Source']}'"
        return cfg

    def test_s3_module_has_import_config(self):
        """
        S3 bucket is globally unique and cannot be recreated alongside an existing stack.
        The module must have import-config.json so stage 2 uses CFN Resource Import
        instead of a regular deploy (which would fail with EarlyValidation::ResourceExistenceCheck).
        """
        import_cfg = MODULES_DIR / "shared-services" / "s3-bucket" / "import-config.json"
        assert import_cfg.exists(), \
            "S3 module is missing import-config.json. Stage 2 requires it to use " \
            "--change-set-type IMPORT and avoid S3 bucket name collision."
        cfg = self._validate_import_config_schema(import_cfg)
        entry = cfg["resources_to_import"][0]
        assert entry["ResourceType"] == "AWS::S3::Bucket"
        assert entry["LogicalResourceId"] == "S3Bucket"
        # S3 bucket name is resolved from params (bucket name is known up front)
        assert any(i["Source"] == "param" for i in entry["Identifiers"]), \
            "S3 import-config should use Source=param for BucketName"

    def test_vpc_module_has_import_config(self):
        """
        VPC baseline module must have import-config.json covering all 11 EC2 resources.
        The CFN Import approach moves VPC ownership from EXISTING to NEW stack without
        recreating any resources.
        """
        import_cfg = MODULES_DIR / "networking" / "vpc-baseline" / "import-config.json"
        assert import_cfg.exists(), \
            "VPC module is missing import-config.json. Stage 2 requires it to use " \
            "--change-set-type IMPORT to transfer VPC ownership."
        cfg = self._validate_import_config_schema(import_cfg)
        logical_ids = {e["LogicalResourceId"] for e in cfg["resources_to_import"]}
        expected = {
            "VPC", "InternetGateway", "GatewayAttachment",
            "PublicSubnetA", "PublicSubnetB", "PrivateSubnetA", "PrivateSubnetB",
            "PublicRouteTable", "PublicRoute",
            "PublicSubnetAAssoc", "PublicSubnetBAssoc",
        }
        missing = expected - logical_ids
        assert not missing, \
            f"VPC import-config.json is missing resources: {missing}"

    def test_kms_module_has_import_config(self):
        """
        KMS key module must have import-config.json for both KMSKey and KMSAlias.
        Both resources are retained when EXISTING stack is deleted, then imported
        into the NEW stack so the key ARN and alias remain identical.
        """
        import_cfg = MODULES_DIR / "security" / "kms-key" / "import-config.json"
        assert import_cfg.exists(), \
            "KMS module is missing import-config.json. Stage 2 requires it to use " \
            "--change-set-type IMPORT to transfer KMS key ownership."
        cfg = self._validate_import_config_schema(import_cfg)
        logical_ids = {e["LogicalResourceId"] for e in cfg["resources_to_import"]}
        assert "KMSKey" in logical_ids, \
            "KMS import-config.json must include KMSKey"
        assert "KMSAlias" in logical_ids, \
            "KMS import-config.json must include KMSAlias"

    def test_critical_new_resources_have_deletion_policy_retain(self):
        """
        Key infrastructure resources in new-structure templates must have
        DeletionPolicy: Retain so an accidental stack delete does not destroy VPCs,
        KMS keys, or S3 buckets.  Also required by CloudFormation for any resource
        being imported via --change-set-type IMPORT.
        """
        must_retain = {
            "networking/vpc-baseline": [
                "AWS::EC2::VPC",
                "AWS::EC2::Subnet",
                "AWS::EC2::InternetGateway",
                "AWS::EC2::RouteTable",
                "AWS::EC2::VPCGatewayAttachment",
                "AWS::EC2::Route",
                "AWS::EC2::SubnetRouteTableAssociation",
            ],
            "security/kms-key":        ["AWS::KMS::Key", "AWS::KMS::Alias"],
            "shared-services/s3-bucket": ["AWS::S3::Bucket"],
        }
        for module_path, resource_types in must_retain.items():
            template = MODULES_DIR / module_path / "template.yaml"
            content = template.read_text()
            for rtype in resource_types:
                assert f"Type: {rtype}" in content, \
                    f"{template.name}: expected resource Type: {rtype} not found"
                assert "DeletionPolicy: Retain" in content, \
                    (f"{template.relative_to(REPO_ROOT)}: missing DeletionPolicy: Retain. "
                     f"Add it to protect {rtype} from accidental stack deletion.")


# -- JSON config syntax --------------------------------------------------------

class TestJsonSyntax:

    @pytest.mark.parametrize("json_file", [
        str(p.relative_to(REPO_ROOT)) for p in ALL_JSON_CONFIGS
    ], ids=lambda p: p.replace("/", "."))
    def test_json_file_parses(self, json_file):
        try:
            json.loads(Path(json_file).read_text())
        except json.JSONDecodeError as e:
            pytest.fail(f"Invalid JSON in {json_file}: {e}")

    def test_existing_params_all_have_parameter_key_value_format(self):
        """Existing-structure params must be [{ParameterKey, ParameterValue}] format."""
        for params_file in sorted(EXISTING_DIR.rglob("*-params.json")):
            data = json.loads(params_file.read_text())
            assert isinstance(data, list), \
                f"{params_file.name}: should be a list"
            for entry in data:
                assert "ParameterKey"   in entry, f"{params_file.name}: missing ParameterKey"
                assert "ParameterValue" in entry, f"{params_file.name}: missing ParameterValue"

    def test_new_account_configs_are_flat_dicts(self):
        """New-structure account configs must be flat {key: value} dicts."""
        accounts_dir = CONFIG_DIR / "accounts"
        for cfg in sorted(accounts_dir.rglob("*.json")):
            data = json.loads(cfg.read_text())
            assert isinstance(data, dict), f"{cfg.name}: should be a dict"
            for k, v in data.items():
                assert isinstance(v, str), \
                    f"{cfg}: value for '{k}' should be a string, got {type(v)}"

    def test_defaults_configs_are_flat_dicts(self):
        defaults_dir = CONFIG_DIR / "_defaults"
        for cfg in sorted(defaults_dir.rglob("*.json")):
            data = json.loads(cfg.read_text())
            assert isinstance(data, dict), f"{cfg.name}: _defaults config should be a dict"


# -- IAM ARN hygiene ----------------------------------------------------------

class TestIamArnHygiene:

    # Role names that were placeholders during development and must never reach AWS.
    PLACEHOLDER_ROLES = [
        "github-actions-deploy",   # replaced by tesco-ims-migration-deploy-role
    ]

    def test_no_placeholder_role_arns_in_existing_params(self):
        """Existing-structure param files must not reference placeholder IAM roles."""
        for params_file in sorted(EXISTING_DIR.rglob("*-params.json")):
            data = json.loads(params_file.read_text())
            for entry in data:
                val = entry.get("ParameterValue", "")
                for placeholder in self.PLACEHOLDER_ROLES:
                    assert placeholder not in val, (
                        f"{params_file.name}: ParameterValue '{val}' references "
                        f"placeholder role '{placeholder}' -- update to the real role ARN"
                    )

    def test_no_placeholder_role_arns_in_account_configs(self):
        """New-structure account config JSON files must not reference placeholder IAM roles."""
        accounts_dir = CONFIG_DIR / "accounts"
        for cfg in sorted(accounts_dir.rglob("*.json")):
            data = json.loads(cfg.read_text())
            for key, val in data.items():
                for placeholder in self.PLACEHOLDER_ROLES:
                    assert placeholder not in str(val), (
                        f"{cfg.relative_to(REPO_ROOT)}: '{key}' references "
                        f"placeholder role '{placeholder}' -- update to the real role ARN"
                    )


# -- YAML syntax and registry structure ---------------------------------------

class TestYamlAndRegistry:

    def test_accounts_registry_parses(self):
        with open(CONFIG_DIR / "_accounts-registry.yaml") as f:
            data = yaml.safe_load(f)
        assert "accounts" in data, "Registry missing top-level 'accounts' key"

    def test_every_account_has_required_fields(self):
        with open(CONFIG_DIR / "_accounts-registry.yaml") as f:
            registry = yaml.safe_load(f)["accounts"]
        required = {"id", "name", "environment", "ou"}
        for account, meta in registry.items():
            missing = required - set(meta.keys())
            assert not missing, \
                f"Account '{account}' missing registry fields: {missing}"

    def test_account_ids_are_12_digit_strings(self):
        with open(CONFIG_DIR / "_accounts-registry.yaml") as f:
            registry = yaml.safe_load(f)["accounts"]
        for account, meta in registry.items():
            acc_id = str(meta["id"])
            assert len(acc_id) == 12 and acc_id.isdigit(), \
                f"Account '{account}' id '{acc_id}' must be a 12-digit string"

    def test_all_non_cfn_yamls_parse(self):
        """
        Parse YAML files that don't use CloudFormation-specific tags (!Ref, !Sub, etc.).
        CFN templates are validated by cfn-lint instead (TestCfnLint above).
        """
        cfn_tag_markers = ("!Ref", "!Sub", "!GetAtt", "!Select", "!If", "!ImportValue")
        for yaml_file in ALL_YAML_FILES:
            content = yaml_file.read_text()
            # Skip files that use CFN intrinsic function short-form tags
            if any(tag in content for tag in cfn_tag_markers):
                continue
            try:
                yaml.safe_load(content)
            except yaml.YAMLError as e:
                pytest.fail(f"Invalid YAML in {yaml_file}: {e}")


# -- Stack naming convention ---------------------------------------------------

class TestStackNamingConvention:

    def test_stack_names_lib_sourced_in_all_stage_scripts(self):
        """All stage scripts must source scripts/lib/stack-names.sh."""
        stage_scripts = sorted((REPO_ROOT / "scripts").glob("stage*.sh"))
        assert len(stage_scripts) >= 5, "Expected at least 5 stage scripts"
        for script in stage_scripts:
            content = script.read_text()
            assert "stack-names.sh" in content, \
                f"{script.name}: must source scripts/lib/stack-names.sh"

    def test_no_hardcoded_poc_vpc_short_names_in_stage_scripts(self):
        """Stage scripts must not use old short-form names like poc-NEW-vpc-dev."""
        forbidden_patterns = ["poc-NEW-vpc-", "poc-NEW-kms-", "poc-NEW-s3-",
                              "poc-EXISTING-vpc-", "poc-EXISTING-kms-", "poc-EXISTING-s3-"]
        stage_scripts = sorted((REPO_ROOT / "scripts").glob("stage*.sh"))
        for script in stage_scripts:
            content = script.read_text()
            for pattern in forbidden_patterns:
                assert pattern not in content, \
                    f"{script.name}: found hardcoded old-style stack name '{pattern}' -- use cfn_stack_name()"

    def test_cfn_stack_name_formula(self):
        """Verify the naming formula produces the expected output."""
        result = run([
            "bash", "-c",
            'source scripts/lib/stack-names.sh && cfn_stack_name "NEW" "networking" "vpc-baseline" "dev"'
        ])
        assert result.returncode == 0
        assert result.stdout.strip() == "poc-NEW-networking-vpc-baseline-dev"

    def test_discover_new_modules_finds_all_dev_modules(self):
        result = run([
            "bash", "-c",
            "source scripts/lib/stack-names.sh && discover_new_modules dev"
        ])
        assert result.returncode == 0
        modules = result.stdout.strip().splitlines()
        assert "networking/vpc-baseline"    in modules
        assert "security/kms-key"           in modules
        assert "shared-services/s3-bucket"  in modules

    def test_discover_existing_modules_uses_filename_convention(self):
        """
        discover_existing_modules() must derive domain/module from the filename
        convention {domain}__{module}-template.yaml with no hardcoded lookup table.
        Adding a new module requires only adding a file -- no script change.
        """
        result = run([
            "bash", "-c",
            "source scripts/lib/stack-names.sh && discover_existing_modules dev"
        ])
        assert result.returncode == 0, f"discover_existing_modules failed: {result.stderr}"
        modules = result.stdout.strip().splitlines()
        assert "networking/vpc-baseline"    in modules
        assert "security/kms-key"           in modules
        assert "shared-services/s3-bucket"  in modules

    def test_existing_templates_follow_naming_convention(self):
        """
        All existing-structure template files must follow {domain}__{module}-template.yaml.
        The double-underscore separates domain from module (both may contain hyphens).
        This naming convention is what makes discover_existing_modules() generic.
        """
        for account_dir in sorted(EXISTING_DIR.iterdir()):
            if not account_dir.is_dir():
                continue
            for template in sorted(account_dir.glob("*-template.yaml")):
                name = template.stem  # e.g. networking__vpc-baseline-template -> networking__vpc-baseline
                # After stripping -template suffix:
                stem = template.name.replace("-template.yaml", "")
                assert "__" in stem, (
                    f"{template.relative_to(REPO_ROOT)}: template file does not follow "
                    f"the {{domain}}__{{module}}-template.yaml naming convention. "
                    f"Rename it so discover_existing_modules() can derive domain/module from the filename."
                )
