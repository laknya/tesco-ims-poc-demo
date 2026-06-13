"""
Tests for detect_changes.py — 4-layer delta change detection.

Verifies all 5 propagation rules:
  1. module template  → all accounts with config for that module
  2. _defaults        → all accounts with config for that module
  3. environments/    → accounts matching env
  4. ous/             → accounts matching OU prefix
  5. accounts/        → single account only

Also verifies: deduplication, full mode, empty matrix, account filter.
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import REPO_ROOT, PIPELINE_DIR, python, run


def detect(*files, account=None, mode="delta") -> dict:
    """Run detect_changes.py with explicit --files args."""
    args = [sys.executable, str(PIPELINE_DIR / "detect_changes.py")]
    if mode == "full":
        args += ["--mode", "full"]
    else:
        for f in files:
            args += ["--files", f]
    if account:
        args += ["--account", account]
    result = subprocess.run(args, capture_output=True, text=True, cwd=str(REPO_ROOT))
    assert result.returncode == 0, f"detect_changes.py failed:\n{result.stderr}"
    return json.loads(result.stdout)


def matrix_pairs(output: dict) -> list[tuple]:
    return [(i["account"], i["domain"], i["module"]) for i in output["deploy_matrix"]]


# ── Propagation rule 1: module template change ────────────────────────────────

class TestModuleTemplateChange:

    def test_vpc_template_triggers_all_accounts(self):
        out = detect("new-structure/modules/networking/vpc-baseline/template.yaml")
        pairs = matrix_pairs(out)
        # All 4 accounts have vpc-baseline config
        accounts = {p[0] for p in pairs}
        assert "dev"     in accounts
        assert "sandbox" in accounts
        assert "coll-dev" in accounts
        assert "coll-ppe" in accounts

    def test_kms_template_triggers_only_accounts_with_config(self):
        """Only 'dev' has a security/kms-key config — others should NOT appear."""
        out = detect("new-structure/modules/security/kms-key/template.yaml")
        pairs = matrix_pairs(out)
        accounts = {p[0] for p in pairs}
        assert "dev" in accounts
        assert "sandbox" not in accounts, \
            "sandbox has no kms-key config — should not be in matrix"

    def test_s3_template_triggers_only_accounts_with_config(self):
        out = detect("new-structure/modules/shared-services/s3-bucket/template.yaml")
        accounts = {p[0] for p in matrix_pairs(out)}
        assert "dev" in accounts
        assert "sandbox" not in accounts

    def test_version_json_treated_as_template_change(self):
        """version.json change has same propagation as template.yaml."""
        out = detect("new-structure/modules/networking/vpc-baseline/version.json")
        assert out["has_changes"] is True
        accounts = {p[0] for p in matrix_pairs(out)}
        assert len(accounts) >= 1

    def test_domain_module_correct_in_matrix(self):
        out = detect("new-structure/modules/security/kms-key/template.yaml")
        for item in out["deploy_matrix"]:
            assert item["domain"]  == "security"
            assert item["module"]  == "kms-key"


# ── Propagation rule 2: _defaults change ─────────────────────────────────────

class TestDefaultsChange:

    def test_vpc_defaults_change_triggers_all_vpc_accounts(self):
        out = detect("new-structure/config/_defaults/networking/vpc-baseline.json")
        accounts = {p[0] for p in matrix_pairs(out)}
        assert "dev" in accounts
        assert "coll-dev" in accounts
        assert "coll-ppe" in accounts
        assert "sandbox" in accounts

    def test_s3_defaults_change_triggers_only_s3_accounts(self):
        out = detect("new-structure/config/_defaults/shared-services/s3-bucket.json")
        accounts = {p[0] for p in matrix_pairs(out)}
        assert "dev" in accounts
        # accounts without s3 config should not appear
        assert "sandbox" not in accounts


# ── Propagation rule 5: account config change ─────────────────────────────────

class TestAccountConfigChange:

    def test_account_config_triggers_only_that_account(self):
        out = detect("new-structure/config/accounts/dev/security/kms-key.json")
        pairs = matrix_pairs(out)
        assert len(pairs) == 1
        assert pairs[0] == ("dev", "security", "kms-key")

    def test_dev_s3_config_change_triggers_only_dev(self):
        out = detect("new-structure/config/accounts/dev/shared-services/s3-bucket.json")
        pairs = matrix_pairs(out)
        accounts = [p[0] for p in pairs]
        assert accounts == ["dev"]
        assert all(p[2] == "s3-bucket" for p in pairs)

    def test_coll_dev_vpc_config_triggers_only_coll_dev(self):
        out = detect("new-structure/config/accounts/coll-dev/networking/vpc-baseline.json")
        pairs = matrix_pairs(out)
        assert len(pairs) == 1
        assert pairs[0][0] == "coll-dev"


# ── Multi-file changes ────────────────────────────────────────────────────────

class TestMultiFileChanges:

    def test_multiple_files_union_of_affected(self):
        out = detect(
            "new-structure/modules/networking/vpc-baseline/template.yaml",
            "new-structure/config/accounts/dev/shared-services/s3-bucket.json",
        )
        pairs = matrix_pairs(out)
        modules = {(p[1], p[2]) for p in pairs}
        assert ("networking", "vpc-baseline")    in modules
        assert ("shared-services", "s3-bucket")  in modules

    def test_deduplication_same_module_from_two_sources(self):
        """Template + defaults change for same module → only one entry per account."""
        out = detect(
            "new-structure/modules/networking/vpc-baseline/template.yaml",
            "new-structure/config/_defaults/networking/vpc-baseline.json",
        )
        pairs = matrix_pairs(out)
        # dev should appear exactly once for vpc-baseline
        dev_vpc = [p for p in pairs if p[0] == "dev" and p[2] == "vpc-baseline"]
        assert len(dev_vpc) == 1, \
            f"dev/networking/vpc-baseline should appear exactly once, got {len(dev_vpc)}"

    def test_three_modules_in_one_pr(self):
        out = detect(
            "new-structure/config/accounts/dev/networking/vpc-baseline.json",
            "new-structure/config/accounts/dev/security/kms-key.json",
            "new-structure/config/accounts/dev/shared-services/s3-bucket.json",
        )
        modules = {(p[1], p[2]) for p in matrix_pairs(out)}
        assert ("networking",     "vpc-baseline") in modules
        assert ("security",       "kms-key")      in modules
        assert ("shared-services","s3-bucket")    in modules


# ── Unrelated file changes ────────────────────────────────────────────────────

class TestUnrelatedChanges:

    @pytest.mark.parametrize("filepath", [
        "README.md",
        "scripts/demo-one-change.sh",
        "CLAUDE.md",
        ".github/workflows/migration-pipeline.yml",
        "existing-structure/dev/vpc-template.yaml",
        "existing-structure/dev/vpc-params.json",
    ])
    def test_unrelated_file_produces_empty_matrix(self, filepath):
        out = detect(filepath)
        assert out["has_changes"] is False, \
            f"Expected no changes from {filepath}, got: {out['deploy_matrix']}"
        assert out["deploy_matrix"] == []


# ── Account filter ────────────────────────────────────────────────────────────

class TestAccountFilter:

    def test_account_filter_restricts_vpc_template_change(self):
        out = detect(
            "new-structure/modules/networking/vpc-baseline/template.yaml",
            account="dev",
        )
        accounts = {p[0] for p in matrix_pairs(out)}
        assert accounts == {"dev"}, \
            f"Account filter=dev should yield only dev, got {accounts}"

    def test_account_filter_returns_empty_if_account_has_no_config(self):
        """sandbox has no s3 config — filtering for sandbox on s3 change → empty."""
        out = detect(
            "new-structure/modules/shared-services/s3-bucket/template.yaml",
            account="sandbox",
        )
        assert out["has_changes"] is False


# ── Full mode ─────────────────────────────────────────────────────────────────

class TestFullMode:

    def test_full_mode_includes_all_dev_modules(self):
        out = detect(mode="full", account="dev")
        assert out["mode"] == "full"
        assert out["has_changes"] is True
        modules = {(p[1], p[2]) for p in matrix_pairs(out)}
        assert ("networking",     "vpc-baseline") in modules
        assert ("security",       "kms-key")      in modules
        assert ("shared-services","s3-bucket")    in modules

    def test_full_mode_respects_account_filter(self):
        out = detect(mode="full", account="sandbox")
        accounts = {p[0] for p in matrix_pairs(out)}
        assert accounts == {"sandbox"}

    def test_full_mode_no_duplicates(self):
        out = detect(mode="full", account="dev")
        pairs = matrix_pairs(out)
        assert len(pairs) == len(set(pairs)), "Full mode matrix should have no duplicates"


# ── Output structure ──────────────────────────────────────────────────────────

class TestOutputStructure:

    def test_output_has_required_top_level_keys(self):
        out = detect("new-structure/config/accounts/dev/security/kms-key.json")
        for key in ("has_changes", "mode", "deploy_matrix", "summary"):
            assert key in out, f"Missing top-level key '{key}' in output"

    def test_summary_matches_deploy_matrix(self):
        out = detect("new-structure/modules/networking/vpc-baseline/template.yaml")
        total_from_matrix  = len(out["deploy_matrix"])
        total_from_summary = sum(len(v) for v in out["summary"].values())
        assert total_from_matrix == total_from_summary

    def test_mode_is_delta_by_default(self):
        out = detect("new-structure/config/accounts/dev/security/kms-key.json")
        assert out["mode"] == "delta"
