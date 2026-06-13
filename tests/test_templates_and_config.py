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


# ── cfn-lint ──────────────────────────────────────────────────────────────────

class TestCfnLint:

    @pytest.mark.parametrize("template", [
        str(p.relative_to(REPO_ROOT)) for p in ALL_TEMPLATES
    ], ids=lambda p: p.replace("/", "·"))
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
    ], ids=lambda p: p.replace("/", "·"))
    def test_description_under_1024_bytes(self, template):
        """
        CloudFormation enforces a 1024-byte limit on the template Description field.
        cfn-lint only checks character count and misses multi-byte Unicode chars
        (e.g. box-drawing ─ is 3 bytes). This test catches the gap before any AWS call.
        """
        import re
        content = Path(template).read_text(encoding="utf-8")
        m = re.search(r'^Description\s*:\s*[>|]?-?\s*\n?((?:[ \t].+\n?)*|(?![\n]).+)',
                      content, re.MULTILINE)
        if not m:
            return  # no Description field — nothing to check
        # Extract value: strip key, strip leading whitespace from block scalars
        block = content[m.start():]
        next_key = re.search(r'\n(?:Parameters|Metadata|Resources|Outputs|Mappings|Conditions)\s*:', block)
        raw = block[:next_key.start() if next_key else len(block)]
        value = re.sub(r'^Description\s*:\s*[>|]?-?\s*', '', raw).strip()
        value = re.sub(r'^[ \t]{1,2}', '', value, flags=re.MULTILINE)
        byte_len = len(value.encode("utf-8"))
        assert byte_len <= 1024, (
            f"{template}: Description is {byte_len} bytes — exceeds CloudFormation's 1024-byte limit. "
            f"Shorten the text (watch for Unicode box-drawing chars — each '─' costs 3 bytes)."
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

    def test_s3_template_has_deny_non_vpc_statement(self):
        """S3 bucket policy must include DenyNonVpcAccess (cross-stack VPC reference)."""
        s3_template = MODULES_DIR / "shared-services" / "s3-bucket" / "template.yaml"
        content = s3_template.read_text()
        assert "DenyNonVpcAccess" in content, \
            "S3 template missing DenyNonVpcAccess bucket policy statement"
        assert "Fn::ImportValue" in content, \
            "S3 template must use Fn::ImportValue for VpcStackName cross-stack reference"

    def test_vpc_template_exports_vpc_id(self):
        """VPC template must export VpcId for cross-stack consumers."""
        vpc_template = MODULES_DIR / "networking" / "vpc-baseline" / "template.yaml"
        content = vpc_template.read_text()
        assert "VpcId" in content, "VPC template must export VpcId"
        assert "Export:" in content


# ── JSON config syntax ────────────────────────────────────────────────────────

class TestJsonSyntax:

    @pytest.mark.parametrize("json_file", [
        str(p.relative_to(REPO_ROOT)) for p in ALL_JSON_CONFIGS
    ], ids=lambda p: p.replace("/", "·"))
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


# ── YAML syntax and registry structure ───────────────────────────────────────

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


# ── Stack naming convention ───────────────────────────────────────────────────

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
                    f"{script.name}: found hardcoded old-style stack name '{pattern}' — use cfn_stack_name()"

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

    def test_abbrev_round_trip(self):
        """_module_for_abbrev and _abbrev_for_module must be inverse of each other."""
        pairs = [("vpc", "networking/vpc-baseline"),
                 ("kms", "security/kms-key"),
                 ("s3",  "shared-services/s3-bucket")]
        for abbrev, domain_module in pairs:
            result = run([
                "bash", "-c",
                f'source scripts/lib/stack-names.sh && _module_for_abbrev "{abbrev}"'
            ])
            assert result.stdout.strip() == domain_module, \
                f"_module_for_abbrev({abbrev}) expected '{domain_module}'"

            result2 = run([
                "bash", "-c",
                f'source scripts/lib/stack-names.sh && _abbrev_for_module "{domain_module}"'
            ])
            assert result2.stdout.strip() == abbrev, \
                f"_abbrev_for_module({domain_module}) expected '{abbrev}'"

    def test_unknown_abbrev_returns_error(self):
        result = run([
            "bash", "-c",
            'source scripts/lib/stack-names.sh && _module_for_abbrev "unknown" 2>&1; echo "exit:$?"'
        ])
        output = result.stdout + result.stderr
        assert "ERROR" in output or "exit:1" in output, \
            "Unknown abbreviation should produce an error"
