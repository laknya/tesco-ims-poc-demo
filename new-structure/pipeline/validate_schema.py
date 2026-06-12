#!/usr/bin/env python3
"""
TESCO IMS — Account Config Schema Validator

Validates each account's config JSON against the module's parameters.schema.json.
Catches missing required parameters BEFORE deployment — not at 2am during a failed stack update.

Usage:
  python3 validate_schema.py                          # validate all accounts, all modules
  python3 validate_schema.py --account dev            # one account
  python3 validate_schema.py --domain security        # one domain
  python3 validate_schema.py --module kms-key         # one module
"""

import json
import argparse
import sys
from pathlib import Path


CONFIG_ROOT  = Path("new-structure/config")
MODULES_ROOT = Path("new-structure/modules")


def load_json(path: Path) -> dict:
    return json.loads(path.read_text()) if path.exists() else {}


def load_schema(domain: str, module: str) -> dict:
    p = MODULES_ROOT / domain / module / "parameters.schema.json"
    return json.loads(p.read_text()) if p.exists() else {}


def load_defaults(domain: str, module: str) -> dict:
    p = CONFIG_ROOT / "_defaults" / domain / f"{module}.json"
    return load_json(p)


def validate_account(account: str, domain: str, module: str) -> list[str]:
    """Returns list of error strings (empty = pass)."""
    schema   = load_schema(domain, module)
    if not schema:
        return []

    defaults = load_defaults(domain, module)
    account_cfg_path = CONFIG_ROOT / "accounts" / account / domain / f"{module}.json"
    account_cfg = load_json(account_cfg_path)

    merged = {**defaults, **account_cfg}
    required = schema.get("required", [])
    properties = schema.get("properties", {})

    errors = []

    for param in required:
        if param not in merged:
            errors.append(
                f"Missing required param '{param}' "
                f"(not in _defaults or accounts/{account}/{domain}/{module}.json)"
            )

    for param, value in merged.items():
        if param in properties:
            prop_def = properties[param]
            allowed = prop_def.get("enum")
            pattern = prop_def.get("pattern")
            if allowed and str(value) not in allowed:
                errors.append(
                    f"Param '{param}' = '{value}' not in allowed values: {allowed}"
                )

    return errors


def run(account_filter=None, domain_filter=None, module_filter=None) -> bool:
    accounts_dir = CONFIG_ROOT / "accounts"
    if not accounts_dir.exists():
        print("No accounts directory found.")
        return False

    accounts = sorted([d.name for d in accounts_dir.iterdir() if d.is_dir()])
    if account_filter:
        accounts = [a for a in accounts if a == account_filter]

    all_ok = True
    results = []

    for account in accounts:
        account_path = accounts_dir / account
        for domain_path in sorted(account_path.iterdir()):
            if not domain_path.is_dir():
                continue
            domain = domain_path.name
            if domain_filter and domain != domain_filter:
                continue

            for cfg_file in sorted(domain_path.glob("*.json")):
                module = cfg_file.stem
                if module_filter and module != module_filter:
                    continue

                schema_path = MODULES_ROOT / domain / module / "parameters.schema.json"
                if not schema_path.exists():
                    continue

                errors = validate_account(account, domain, module)
                results.append((account, domain, module, errors))
                if errors:
                    all_ok = False

    print(f"\n{'─'*60}")
    print(f"  Account Config Schema Validation")
    print(f"  {'Account':<15} {'Module':<35} {'Result'}")
    print(f"{'─'*60}")

    for account, domain, module, errors in results:
        label = f"{domain}/{module}"
        if errors:
            print(f"  ❌  {account:<15} {label:<35} FAIL")
            for e in errors:
                print(f"       → {e}")
        else:
            print(f"  ✅  {account:<15} {label:<35} OK")

    print(f"{'─'*60}")

    if all_ok:
        print(f"\n  All account configs valid against module schemas. ✅\n")
    else:
        print(f"\n  Schema validation FAILED. Fix config errors before deploying.\n")

    return all_ok


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Validate account configs against module schemas")
    ap.add_argument("--account", help="Filter to one account")
    ap.add_argument("--domain",  help="Filter to one domain")
    ap.add_argument("--module",  help="Filter to one module")
    args = ap.parse_args()

    ok = run(args.account, args.domain, args.module)
    sys.exit(0 if ok else 1)
