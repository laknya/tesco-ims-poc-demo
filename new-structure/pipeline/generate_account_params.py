#!/usr/bin/env python3
"""
TESCO IMS Landing Zone -- Registry-to-Parameters Generator
Repo: git@github.com:laknya/tesco-ims-poc-demo.git

Reads config/_accounts-registry.yaml and generates one JSON parameter
file per account under config/generated/account-metadata/.

Generated files are gitignored -- they are recreated at deploy time
from the single source of truth (the registry).

Usage:
    python3 new-structure/pipeline/generate_account_params.py
"""

import json
import yaml
from pathlib import Path

REGISTRY = "new-structure/config/_accounts-registry.yaml"
OUTPUT_DIR = "new-structure/config/generated/account-metadata"


def main():
    with open(REGISTRY) as f:
        registry = yaml.safe_load(f) or {}

    accounts = registry.get("accounts", {})
    out_dir = Path(OUTPUT_DIR)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"\nGenerating parameters from registry: {REGISTRY}")
    print(f"{'-'*52}")

    for account_key, account_data in accounts.items():
        params = [
            {"ParameterKey": "AccountId",    "ParameterValue": account_data.get("id", "")},
            {"ParameterKey": "AccountName",  "ParameterValue": account_data.get("name", "")},
            {"ParameterKey": "Environment",  "ParameterValue": account_data.get("environment", "")},
            {"ParameterKey": "AccountGroup", "ParameterValue": account_data.get("group", "")},
            {"ParameterKey": "OU",           "ParameterValue": account_data.get("ou", "")},
            {"ParameterKey": "Application",  "ParameterValue": account_data.get("application", "")},
        ]

        output_file = out_dir / f"{account_key}.json"
        output_file.write_text(json.dumps(params, indent=2))
        print(f"  [OK] {account_key:<30} -> {output_file}")

    print(f"{'-'*52}")
    print(f"  Generated {len(accounts)} parameter files from {len(accounts)}-entry registry.")
    print(f"  Old way: {len(accounts)} separate _account.yaml files (manual, error-prone)")
    print(f"  New way: 1 registry -> auto-generate at deploy time\n")


if __name__ == "__main__":
    main()
