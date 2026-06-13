#!/usr/bin/env python3
"""
TESCO IMS Landing Zone -- Parameter Resolver
Repo: git@github.com:laknya/tesco-ims-poc-demo.git

Merges 4 layers for a given account/domain/module:
  Layer 1: config/_defaults/{domain}/{module}.json          (org-wide shared values)
  Layer 2: config/environments/{env}/{domain}/{module}.json (env-specific overrides)
  Layer 3: config/ous/{ou}/{domain}/{module}.json           (OU-specific overrides)
  Layer 4: config/accounts/{account}/{domain}/{module}.json (account delta -- highest precedence)

Account environment and OU are looked up from config/_accounts-registry.yaml.
"""

import json
import yaml
import argparse
import sys
from pathlib import Path


def load_registry(base: str) -> dict:
    path = Path(f"{base}/_accounts-registry.yaml")
    if path.exists():
        with open(path) as f:
            return yaml.safe_load(f) or {}
    return {}


def load_json(path: str) -> dict:
    p = Path(path)
    if p.exists():
        data = json.loads(p.read_text())
        print(f"  [OK] Layer loaded : {path}  ({len(data)} params)")
        return data
    print(f"        Not found    : {path}")
    return {}


def resolve(account: str, domain: str, module: str) -> dict:
    base = "new-structure/config"

    registry = load_registry(base)
    account_info = registry.get("accounts", {}).get(account, {})
    env = account_info.get("environment", "")
    ou  = account_info.get("ou", "")

    print(f"\n{'-'*56}")
    print(f"Resolving: account={account}  domain={domain}  module={module}")
    print(f"  Registry lookup -> env={env}  ou={ou}")
    print(f"{'-'*56}")

    params = {}

    # Layer 1 -- org-wide defaults
    params.update(load_json(f"{base}/_defaults/{domain}/{module}.json"))

    # Layer 2 -- environment overrides (optional)
    params.update(load_json(f"{base}/environments/{env}/{domain}/{module}.json"))

    # Layer 3 -- OU overrides (optional)
    ou_key = ou.replace("/", "-").strip("-")
    params.update(load_json(f"{base}/ous/{ou_key}/{domain}/{module}.json"))

    # Layer 4 -- account delta (highest precedence)
    params.update(load_json(f"{base}/accounts/{account}/{domain}/{module}.json"))

    print(f"\n  -> Final : {len(params)} merged parameters")
    return params


def to_cfn_format(params: dict) -> list:
    return [
        {"ParameterKey": k, "ParameterValue": str(v)}
        for k, v in params.items()
    ]


if __name__ == "__main__":
    ap = argparse.ArgumentParser(
        description="Resolve 4-layer parameters for tesco-ims-poc-demo"
    )
    ap.add_argument("--account", required=True, help="e.g. sandbox, coll-dev")
    ap.add_argument("--domain",  required=True, help="e.g. networking")
    ap.add_argument("--module",  required=True, help="e.g. vpc-baseline")
    ap.add_argument("--output",  default="/tmp/resolved-params.json")
    args = ap.parse_args()

    resolved  = resolve(args.account, args.domain, args.module)
    cfn_ready = to_cfn_format(resolved)

    Path(args.output).write_text(json.dumps(cfn_ready, indent=2))

    print(f"\nResolved parameter file -> {args.output}")
    print(f"{'-'*56}")
    for p in cfn_ready:
        print(f"  {p['ParameterKey']:<26} = {p['ParameterValue']}")
    print(f"{'-'*56}\n")
