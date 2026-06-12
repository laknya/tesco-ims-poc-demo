#!/usr/bin/env python3
"""
TESCO IMS POC — Parameter Resolver
Repo: git@github.com:laknya/tesco-ims-poc-demo.git

Merges 3 layers for this POC:
  Layer 1: new-structure/config/_defaults/{domain}/{module}.json
  Layer 2: new-structure/config/environments/{env}/{domain}/{module}.json
  Layer 3: new-structure/config/accounts/{env}/{domain}/{module}.json (if exists)
"""

import json, argparse, sys
from pathlib import Path


def load(path: str) -> dict:
    p = Path(path)
    if p.exists():
        data = json.loads(p.read_text())
        print(f"  ✅ Layer loaded : {path}  ({len(data)} params)")
        return data
    print(f"  ⬜ Not found    : {path}")
    return {}


def resolve(env: str, domain: str, module: str) -> dict:
    base = "new-structure/config"
    params = {}

    print(f"\n{'─'*52}")
    print(f"Resolving: env={env}  domain={domain}  module={module}")
    print(f"{'─'*52}")

    # Layer 1 — shared defaults (all environments)
    params.update(load(f"{base}/_defaults/{domain}/{module}.json"))

    # Layer 2 — environment-specific values (dev vs prod)
    params.update(load(f"{base}/environments/{env}/{domain}/{module}.json"))

    # Layer 3 — account-level delta (optional fine-tuning)
    params.update(load(f"{base}/accounts/{env}/{domain}/{module}.json"))

    print(f"\n  → Final : {len(params)} merged parameters")
    return params


def to_cfn_format(params: dict) -> list:
    return [
        {"ParameterKey": k, "ParameterValue": str(v)}
        for k, v in params.items()
    ]


if __name__ == "__main__":
    ap = argparse.ArgumentParser(
        description="Resolve layered parameters for tesco-ims-poc-demo"
    )
    ap.add_argument("--env",    required=True, help="dev or prod")
    ap.add_argument("--domain", required=True, help="e.g. networking")
    ap.add_argument("--module", required=True, help="e.g. vpc-subnets")
    ap.add_argument("--output", default="/tmp/resolved-params.json")
    args = ap.parse_args()

    resolved  = resolve(args.env, args.domain, args.module)
    cfn_ready = to_cfn_format(resolved)

    Path(args.output).write_text(json.dumps(cfn_ready, indent=2))

    print(f"\nResolved parameter file → {args.output}")
    print(f"{'─'*52}")
    for p in cfn_ready:
        print(f"  {p['ParameterKey']:<26} = {p['ParameterValue']}")
    print(f"{'─'*52}\n")