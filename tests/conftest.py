"""
Shared pytest fixtures and helpers for the TESCO IMS POC test suite.
All tests run from the repository root — conftest.py sets the working directory.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

# Repository root = parent of the tests/ directory
REPO_ROOT = Path(__file__).resolve().parent.parent

# Key paths
PIPELINE_DIR  = REPO_ROOT / "new-structure" / "pipeline"
CONFIG_DIR    = REPO_ROOT / "new-structure" / "config"
MODULES_DIR   = REPO_ROOT / "new-structure" / "modules"
EXISTING_DIR  = REPO_ROOT / "existing-structure"
SCRIPTS_DIR   = REPO_ROOT / "scripts"
REGISTRY_PATH = CONFIG_DIR / "_accounts-registry.yaml"


@pytest.fixture(autouse=True)
def run_from_repo_root(monkeypatch):
    """Every test runs with CWD = repo root (pipeline scripts expect this)."""
    monkeypatch.chdir(REPO_ROOT)


@pytest.fixture(scope="session")
def registry() -> dict:
    with open(REGISTRY_PATH) as f:
        return yaml.safe_load(f)["accounts"]


@pytest.fixture(scope="session")
def all_modules() -> list[tuple[str, str]]:
    """All (domain, module) pairs that have a version.json."""
    result = []
    for v in sorted(MODULES_DIR.rglob("version.json")):
        module = v.parent.name
        domain = v.parent.parent.name
        result.append((domain, module))
    return result


@pytest.fixture(scope="session")
def all_account_configs() -> list[tuple[str, str, str]]:
    """All (account, domain, module) triples with a config JSON."""
    result = []
    accounts_dir = CONFIG_DIR / "accounts"
    for cfg in sorted(accounts_dir.rglob("*.json")):
        account = cfg.parts[cfg.parts.index("accounts") + 1]
        domain  = cfg.parent.name
        module  = cfg.stem
        result.append((account, domain, module))
    return result


def run(cmd: list, **kwargs) -> subprocess.CompletedProcess:
    """Run a command from REPO_ROOT, capture output."""
    return subprocess.run(
        cmd, capture_output=True, text=True,
        cwd=str(REPO_ROOT), **kwargs
    )


def python(script: str, *args) -> subprocess.CompletedProcess:
    """Run a pipeline Python script."""
    return run([sys.executable, str(PIPELINE_DIR / script), *args])


def resolve(account: str, domain: str, module: str, output: str = "/tmp/test-resolved.json"):
    """Run resolve_parameters.py and return parsed JSON output."""
    result = python(
        "resolve_parameters.py",
        "--account", account,
        "--domain",  domain,
        "--module",  module,
        "--output",  output,
    )
    assert result.returncode == 0, f"Resolver failed:\n{result.stderr}"
    return json.loads(Path(output).read_text())
