#!/usr/bin/env python3
"""
detect_changes.py — 4-layer delta detection for module-based CD.

Answers the question: given these changed files, which (account, domain, module)
combinations actually need redeployment?

4-layer propagation rules (mirrors resolve_parameters.py merger order):
  Layer 1  modules/{domain}/{module}/template.yaml
           → ALL accounts that have a config for this module

  Layer 2  config/_defaults/{domain}/{module}.json
           → ALL accounts that have a config for this module

  Layer 3  config/environments/{env}/{domain}/{module}.json
           → all accounts whose registry entry has environment={env}

  Layer 4a config/ous/{ou}/{domain}/{module}.json
           → all accounts whose registry entry has ou starting with {ou}
  Layer 4b config/accounts/{account}/{domain}/{module}.json
           → ONLY that account

Usage
-----
  # From git diff (CI — push event)
  python3 detect_changes.py \\
      --base <before-sha> --head <after-sha> \\
      [--account dev]                          # filter to one account (optional)

  # From explicit file list (testing / manual)
  python3 detect_changes.py \\
      --files new-structure/modules/networking/vpc-baseline/template.yaml \\
      --files new-structure/config/accounts/dev/security/kms-key.json

  # Full-deploy override (bootstrapping / disaster recovery)
  python3 detect_changes.py --mode full

Output
------
  JSON to stdout:
    {
      "has_changes": true,
      "mode": "delta",
      "deploy_matrix": [
        {"account": "dev",     "domain": "networking",     "module": "vpc-baseline"},
        {"account": "coll-dev","domain": "networking",     "module": "vpc-baseline"},
        {"account": "dev",     "domain": "shared-services","module": "s3-bucket"}
      ],
      "summary": {
        "networking/vpc-baseline": ["dev", "coll-dev"],
        "shared-services/s3-bucket": ["dev"]
      }
    }
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

# ── Locate repo root ──────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CONFIG_DIR = REPO_ROOT / "new-structure" / "config"
MODULES_DIR = REPO_ROOT / "new-structure" / "modules"
REGISTRY_PATH = CONFIG_DIR / "_accounts-registry.yaml"


def load_registry() -> dict:
    with open(REGISTRY_PATH) as f:
        return yaml.safe_load(f)["accounts"]


def all_accounts_for_module(domain: str, module: str, registry: dict) -> list[str]:
    """Return every account that has a config file for domain/module."""
    accounts_dir = CONFIG_DIR / "accounts"
    result = []
    for account in registry:
        cfg = accounts_dir / account / domain / f"{module}.json"
        if cfg.exists():
            result.append(account)
    return result


def accounts_for_env(env: str, registry: dict) -> list[str]:
    return [a for a, meta in registry.items() if meta.get("environment") == env]


def accounts_for_ou(ou: str, registry: dict) -> list[str]:
    """Match accounts whose OU starts with the given ou prefix."""
    return [
        a for a, meta in registry.items()
        if meta.get("ou", "").startswith(ou)
    ]


# ── File path → (domain, module, propagation_scope) parser ───────────────────

# Compiled patterns in priority order — first match wins per file path.
_PATTERNS = [
    # modules/{domain}/{module}/template.yaml  → scope: all accounts with config
    (re.compile(r"^new-structure/modules/([^/]+)/([^/]+)/template\.yaml$"),
     "module_template"),

    # config/_defaults/{domain}/{module}.json  → scope: all accounts with config
    (re.compile(r"^new-structure/config/_defaults/([^/]+)/([^/]+)\.json$"),
     "defaults"),

    # config/environments/{env}/{domain}/{module}.json  → scope: env
    (re.compile(r"^new-structure/config/environments/([^/]+)/([^/]+)/([^/]+)\.json$"),
     "environment"),

    # config/ous/{ou}/{domain}/{module}.json  → scope: OU prefix
    (re.compile(r"^new-structure/config/ous/([^/]+)/([^/]+)/([^/]+)\.json$"),
     "ou"),

    # config/accounts/{account}/{domain}/{module}.json  → scope: single account
    (re.compile(r"^new-structure/config/accounts/([^/]+)/([^/]+)/([^/]+)\.json$"),
     "account"),

    # modules/{domain}/{module}/version.json  → treat same as template change
    (re.compile(r"^new-structure/modules/([^/]+)/([^/]+)/version\.json$"),
     "module_template"),
]


def resolve_file(path: str, registry: dict) -> list[tuple[str, str, str]]:
    """
    Given a changed file path, return list of (account, domain, module) triples
    that must be redeployed as a result.
    """
    results = []

    for pattern, scope in _PATTERNS:
        m = pattern.match(path)
        if not m:
            continue

        groups = m.groups()

        if scope == "module_template":
            domain, module = groups[0], groups[1]
            for account in all_accounts_for_module(domain, module, registry):
                results.append((account, domain, module))

        elif scope == "defaults":
            domain, module = groups[0], groups[1]
            for account in all_accounts_for_module(domain, module, registry):
                results.append((account, domain, module))

        elif scope == "environment":
            env, domain, module = groups[0], groups[1], groups[2]
            for account in accounts_for_env(env, registry):
                # Only include accounts that actually have a config for this module
                cfg = CONFIG_DIR / "accounts" / account / domain / f"{module}.json"
                if cfg.exists():
                    results.append((account, domain, module))

        elif scope == "ou":
            ou, domain, module = groups[0], groups[1], groups[2]
            for account in accounts_for_ou(ou, registry):
                cfg = CONFIG_DIR / "accounts" / account / domain / f"{module}.json"
                if cfg.exists():
                    results.append((account, domain, module))

        elif scope == "account":
            account, domain, module = groups[0], groups[1], groups[2]
            cfg = CONFIG_DIR / "accounts" / account / domain / f"{module}.json"
            if cfg.exists():
                results.append((account, domain, module))

        break  # first pattern match wins

    return results


def git_changed_files(base: str, head: str) -> list[str]:
    # GitHub sends 0000000... as before-SHA on the very first push to a branch.
    # git diff can't resolve it — fall back to listing all files in HEAD.
    if not base or base.startswith("0000000"):
        result = subprocess.run(
            ["git", "diff-tree", "--no-commit-id", "--name-only", "-r", head],
            capture_output=True, text=True, cwd=REPO_ROOT, check=True
        )
    else:
        result = subprocess.run(
            ["git", "diff", "--name-only", base, head],
            capture_output=True, text=True, cwd=REPO_ROOT, check=True
        )
    return [f.strip() for f in result.stdout.splitlines() if f.strip()]


def full_deploy_matrix(registry: dict) -> list[dict]:
    """Return every (account, domain, module) combination that exists."""
    items = []
    accounts_dir = CONFIG_DIR / "accounts"
    for account in sorted(registry.keys()):
        acc_dir = accounts_dir / account
        if not acc_dir.exists():
            continue
        for cfg in sorted(acc_dir.rglob("*.json")):
            rel = cfg.relative_to(acc_dir)  # e.g. networking/vpc-baseline.json
            domain = rel.parent.name
            module = rel.stem
            items.append({"account": account, "domain": domain, "module": module})
    return items


def build_output(triples: list[tuple], mode: str) -> dict:
    # Deduplicate preserving order
    seen = set()
    matrix = []
    for account, domain, module in triples:
        key = (account, domain, module)
        if key not in seen:
            seen.add(key)
            matrix.append({"account": account, "domain": domain, "module": module})

    # Summary: module → [accounts]
    summary: dict[str, list] = {}
    for item in matrix:
        dm = f"{item['domain']}/{item['module']}"
        summary.setdefault(dm, []).append(item["account"])

    return {
        "has_changes": len(matrix) > 0,
        "mode": mode,
        "deploy_matrix": matrix,
        "summary": summary,
    }


def main():
    ap = argparse.ArgumentParser(description="Detect which modules need redeployment.")
    ap.add_argument("--base",    help="Base git ref (commit before the change)")
    ap.add_argument("--head",    help="Head git ref (commit after the change)")
    ap.add_argument("--files",   action="append", default=[], metavar="PATH",
                    help="Explicit changed file paths (repeatable; skips git diff)")
    ap.add_argument("--account", help="Restrict output to a single account")
    ap.add_argument("--mode",    choices=["delta", "full"], default="delta",
                    help="'full' deploys every module regardless of changes")
    args = ap.parse_args()

    registry = load_registry()

    # ── Full mode — deploy everything ─────────────────────────────────────────
    if args.mode == "full":
        matrix = full_deploy_matrix(registry)
        if args.account:
            matrix = [m for m in matrix if m["account"] == args.account]
        output = build_output(
            [(m["account"], m["domain"], m["module"]) for m in matrix],
            "full"
        )
        print(json.dumps(output, indent=2))
        return

    # ── Delta mode — detect from git diff or explicit file list ───────────────
    if args.files:
        changed_files = args.files
    elif args.base and args.head:
        try:
            changed_files = git_changed_files(args.base, args.head)
        except subprocess.CalledProcessError as e:
            print(f"ERROR: git diff failed: {e.stderr}", file=sys.stderr)
            sys.exit(1)
    else:
        ap.error("Provide --base + --head for git diff, or --files for explicit list, or --mode full")

    print(f"Changed files ({len(changed_files)}):", file=sys.stderr)
    for f in changed_files:
        print(f"  {f}", file=sys.stderr)
    print(file=sys.stderr)

    triples = []
    for path in changed_files:
        resolved = resolve_file(path, registry)
        if resolved:
            print(f"  {path}", file=sys.stderr)
            for account, domain, module in resolved:
                print(f"    → {account}  {domain}/{module}", file=sys.stderr)
            triples.extend(resolved)

    # Filter to specific account if requested
    if args.account:
        triples = [(a, d, m) for a, d, m in triples if a == args.account]

    output = build_output(triples, "delta")

    if not output["has_changes"]:
        print("No module changes detected — nothing to deploy.", file=sys.stderr)

    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
