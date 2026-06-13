"""
End-to-end pipeline integration tests — no AWS required.

Tests the full local pipeline flow: resolve → detect → stage2 filter → manifest.
These simulate what GitHub Actions does on every push, without touching AWS.
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

from conftest import REPO_ROOT, CONFIG_DIR, MODULES_DIR, python, run, resolve


# ── Full resolver pipeline ────────────────────────────────────────────────────

class TestResolverPipeline:

    def test_all_account_module_combinations_resolve(self, all_account_configs):
        """Every (account, domain, module) with a config file must resolve cleanly."""
        for account, domain, module in all_account_configs:
            out_path = f"/tmp/e2e-{account}-{domain}-{module}.json"
            params = resolve(account, domain, module, out_path)
            assert len(params) > 0, \
                f"resolve({account}, {domain}, {module}) returned empty params"
            # Every entry must have string values
            for p in params:
                assert isinstance(p["ParameterValue"], str), \
                    f"{account}/{domain}/{module}: non-string value for {p['ParameterKey']}"

    def test_resolver_writes_valid_cfn_file(self, tmp_path):
        out = str(tmp_path / "resolved.json")
        resolve("dev", "networking", "vpc-baseline", out)
        data = json.loads(Path(out).read_text())
        assert isinstance(data, list)
        # Verify it would be accepted as --parameter-overrides file://...
        for entry in data:
            assert set(entry.keys()) == {"ParameterKey", "ParameterValue"}

    def test_environment_isolation_sandbox_vs_dev(self):
        """sandbox and dev should get different VpcCidr (different account configs)."""
        dev_params  = {p["ParameterKey"]: p["ParameterValue"]
                       for p in resolve("dev",     "networking", "vpc-baseline")}
        sbx_params  = {p["ParameterKey"]: p["ParameterValue"]
                       for p in resolve("sandbox", "networking", "vpc-baseline")}
        assert dev_params["VpcCidr"] != sbx_params["VpcCidr"], \
            "dev and sandbox should have different VpcCidr values"

    def test_defaults_shared_across_accounts(self):
        """CostCentre default should be identical across all accounts (org-wide)."""
        with open(CONFIG_DIR / "_defaults/networking/vpc-baseline.json") as f:
            defaults = json.load(f)
        if "CostCentre" not in defaults:
            pytest.skip("CostCentre not in VPC defaults for this test")

        dev_params = {p["ParameterKey"]: p["ParameterValue"]
                     for p in resolve("dev", "networking", "vpc-baseline")}
        sbx_params = {p["ParameterKey"]: p["ParameterValue"]
                     for p in resolve("sandbox", "networking", "vpc-baseline")}

        assert dev_params["CostCentre"] == sbx_params["CostCentre"], \
            "CostCentre (from _defaults) should be identical across accounts"


# ── Stage 2 module filter ──────────────────────────────────────────────────────

class TestStage2ModuleFilter:

    def test_stage2_dry_run_single_module(self, tmp_path):
        """stage2-deploy-new.sh with a module filter only processes that module."""
        result = run([
            "bash", "-c",
            # Source the lib then run the filter logic (not the full AWS deploy)
            """
            source scripts/lib/stack-names.sh
            ACCOUNT=dev
            FILTER="networking/vpc-baseline"
            FOUND=0
            while IFS= read -r dm; do
              for f in $FILTER; do
                [ "$f" = "$dm" ] && FOUND=$((FOUND+1))
              done
            done < <(discover_new_modules "$ACCOUNT")
            echo "found:$FOUND"
            """
        ])
        assert "found:1" in result.stdout, \
            "Module filter should match exactly 1 module"

    def test_stage2_no_filter_finds_all_modules(self):
        result = run([
            "bash", "-c",
            """
            source scripts/lib/stack-names.sh
            COUNT=0
            while IFS= read -r dm; do
              COUNT=$((COUNT+1))
            done < <(discover_new_modules dev)
            echo "count:$COUNT"
            """
        ])
        count = int(result.stdout.strip().split("count:")[1])
        assert count >= 3, f"Expected at least 3 modules for dev, got {count}"


# ── Version manifest ──────────────────────────────────────────────────────────

class TestVersionManifest:

    def test_generate_version_manifest_exits_zero(self):
        result = python("generate_version_manifest.py")
        assert result.returncode == 0, \
            f"generate_version_manifest.py failed:\n{result.stderr}"

    def test_manifest_contains_all_modules(self):
        python("generate_version_manifest.py")
        manifest_path = REPO_ROOT / "new-structure/config/generated/version-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        assert "modules" in manifest
        assert "networking/vpc-baseline"    in manifest["modules"]
        assert "security/kms-key"           in manifest["modules"]
        assert "shared-services/s3-bucket"  in manifest["modules"]

    def test_manifest_accounts_section_matches_registry(self):
        python("generate_version_manifest.py")
        manifest_path = REPO_ROOT / "new-structure/config/generated/version-manifest.json"
        manifest = json.loads(manifest_path.read_text())

        with open(CONFIG_DIR / "_accounts-registry.yaml") as f:
            registry = yaml.safe_load(f)["accounts"]

        # Every account in the manifest must exist in the registry
        for account in manifest.get("accounts", {}):
            assert account in registry, \
                f"Manifest account '{account}' not found in registry"

    def test_manifest_module_versions_match_version_json(self):
        python("generate_version_manifest.py")
        manifest_path = REPO_ROOT / "new-structure/config/generated/version-manifest.json"
        manifest = json.loads(manifest_path.read_text())

        for dm, meta in manifest["modules"].items():
            domain, module = dm.split("/")
            version_file = MODULES_DIR / domain / module / "version.json"
            stored = json.loads(version_file.read_text())
            assert meta["version"] == stored["version"], \
                f"Manifest version mismatch for {dm}: {meta['version']} vs {stored['version']}"


# ── Account params generator ──────────────────────────────────────────────────

class TestAccountParamsGenerator:

    def test_generate_account_params_exits_zero(self):
        result = python("generate_account_params.py")
        assert result.returncode == 0, \
            f"generate_account_params.py failed:\n{result.stderr}"

    def test_generated_files_exist_for_all_registry_accounts(self):
        python("generate_account_params.py")
        generated_dir = REPO_ROOT / "new-structure/config/generated/account-metadata"

        with open(CONFIG_DIR / "_accounts-registry.yaml") as f:
            registry = yaml.safe_load(f)["accounts"]

        for account in registry:
            account_file = generated_dir / f"{account}.json"
            assert account_file.exists(), \
                f"Generated account metadata missing for '{account}'"

    def test_generated_files_are_valid_json(self):
        python("generate_account_params.py")
        generated_dir = REPO_ROOT / "new-structure/config/generated/account-metadata"
        for f in sorted(generated_dir.glob("*.json")):
            data = json.loads(f.read_text())
            assert isinstance(data, list), f"{f.name}: expected CFN param list"


# ── Full no-AWS pipeline simulation ───────────────────────────────────────────

class TestFullLocalPipeline:

    def test_full_validate_pipeline_passes(self):
        """Run every local validation step in sequence — mirrors the CI validate job."""
        steps = [
            # 1. version integrity
            [sys.executable, "new-structure/pipeline/check_module_versions.py"],
            # 2. schema validation
            [sys.executable, "new-structure/pipeline/validate_schema.py"],
            # 3. version manifest
            [sys.executable, "new-structure/pipeline/generate_version_manifest.py"],
            # 4. account params
            [sys.executable, "new-structure/pipeline/generate_account_params.py"],
        ]

        # 5. resolve all account/module combinations
        accounts_dir = CONFIG_DIR / "accounts"
        for cfg in sorted(accounts_dir.rglob("*.json")):
            account = cfg.parts[cfg.parts.index("accounts") + 1]
            domain  = cfg.parent.name
            module  = cfg.stem
            steps.append([
                sys.executable, "new-structure/pipeline/resolve_parameters.py",
                "--account", account, "--domain", domain, "--module", module,
                "--output", f"/tmp/e2e-full-{account}-{domain}-{module}.json",
            ])

        for cmd in steps:
            result = subprocess.run(
                cmd, capture_output=True, text=True, cwd=str(REPO_ROOT)
            )
            assert result.returncode == 0, \
                f"Step failed: {' '.join(cmd)}\n{result.stdout[-500:]}\n{result.stderr[-500:]}"

    def test_detect_changes_then_stage2_filter_consistency(self):
        """
        Simulate: PR changes s3-bucket config → detect_changes → stage2 module list.
        The module in the detect_changes output must be in discover_new_modules(dev).
        """
        detect_result = subprocess.run(
            [sys.executable, "new-structure/pipeline/detect_changes.py",
             "--files", "new-structure/config/accounts/dev/shared-services/s3-bucket.json",
             "--account", "dev"],
            capture_output=True, text=True, cwd=str(REPO_ROOT)
        )
        assert detect_result.returncode == 0
        detection = json.loads(detect_result.stdout)

        assert detection["has_changes"] is True
        changed = {f"{i['domain']}/{i['module']}" for i in detection["deploy_matrix"]}

        # Verify every detected module is discoverable by stage2
        discover_result = run([
            "bash", "-c",
            "source scripts/lib/stack-names.sh && discover_new_modules dev"
        ])
        assert discover_result.returncode == 0
        discoverable = set(discover_result.stdout.strip().splitlines())

        for module in changed:
            assert module in discoverable, \
                f"Detected module '{module}' not in discover_new_modules(dev)"
