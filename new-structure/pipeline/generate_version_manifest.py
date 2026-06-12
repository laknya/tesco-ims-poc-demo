#!/usr/bin/env python3
"""
TESCO IMS — Version Manifest Generator

Produces a JSON manifest showing which module version each account will use on next deploy.
This is the equivalent of querying the CFN Registry for the default version per account.

In native CFN Registry terms:
  aws cloudformation describe-type --type MODULE --type-name TescoIMS::Networking::VpcBaseline
  → shows the current default version ARN

Here we produce the same picture from our local version.json files + account configs.

Output: new-structure/config/generated/version-manifest.json

Usage:
  python3 generate_version_manifest.py
"""

import json
from pathlib import Path
from datetime import date


MODULES_ROOT = Path("new-structure/modules")
CONFIG_ROOT  = Path("new-structure/config")
OUTPUT_PATH  = CONFIG_ROOT / "generated" / "version-manifest.json"


def get_module_version(domain: str, module: str) -> dict:
    vf = MODULES_ROOT / domain / module / "version.json"
    if vf.exists():
        return json.loads(vf.read_text())
    return {}


def find_all_modules() -> list[tuple[str, str]]:
    result = []
    for domain_dir in sorted(MODULES_ROOT.iterdir()):
        if domain_dir.is_dir():
            for module_dir in sorted(domain_dir.iterdir()):
                if module_dir.is_dir() and (module_dir / "template.yaml").exists():
                    result.append((domain_dir.name, module_dir.name))
    return result


def find_accounts_for_module(domain: str, module: str) -> list[str]:
    result = []
    accounts_dir = CONFIG_ROOT / "accounts"
    if accounts_dir.exists():
        for account_dir in sorted(accounts_dir.iterdir()):
            cfg = account_dir / domain / f"{module}.json"
            if cfg.exists():
                result.append(account_dir.name)
    return result


def generate():
    modules = find_all_modules()
    manifest = {
        "generated": str(date.today()),
        "description": (
            "Shows which module version each account will use on next deploy. "
            "Equivalent to CFN Registry default version per account/region. "
            "See: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/module-versioning.html"
        ),
        "modules": {},
        "accounts": {}
    }

    for domain, module in modules:
        meta = get_module_version(domain, module)
        version     = meta.get("version", "unknown")
        type_name   = meta.get("type_name", f"TescoIMS::{domain.title()}::{module.title()}")
        module_key  = f"{domain}/{module}"
        accounts    = find_accounts_for_module(domain, module)

        manifest["modules"][module_key] = {
            "type_name":   type_name,
            "version":     version,
            "status":      meta.get("status", "default"),
            "released":    meta.get("released", ""),
            "changelog":   meta.get("changelog", ""),
            "deployed_to": accounts,
            "cfn_registry_arn": (
                f"arn:aws:cloudformation:eu-west-1:641079926471:"
                f"type/module/{type_name.replace('::', '-')}/00000001"
            )
        }

        for account in accounts:
            if account not in manifest["accounts"]:
                manifest["accounts"][account] = {}
            manifest["accounts"][account][module_key] = {
                "version":   version,
                "type_name": type_name
            }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(manifest, indent=2) + "\n")

    print(f"\n{'─'*60}")
    print(f"  Version Manifest")
    print(f"  {'Module':<35} {'Version':<10} {'Accounts'}")
    print(f"{'─'*60}")
    for mk, mv in manifest["modules"].items():
        print(f"  {mk:<35} v{mv['version']:<9} {', '.join(mv['deployed_to']) or '(none)'}")
    print(f"{'─'*60}")
    print(f"\n  Written to: {OUTPUT_PATH}\n")

    return manifest


if __name__ == "__main__":
    generate()
