#!/usr/bin/env python3
"""
TESCO IMS — Module Version Integrity Check

Validates that every module's version.json is in sync with its template.yaml.
The stored template_hash must match the current SHA256 of template.yaml.

If the hashes differ the module template was changed without bumping version.json —
this is a breaking-change gate in CI (blocks PRs).

Usage:
  python3 check_module_versions.py            # check all modules (CI mode)
  python3 check_module_versions.py --update   # refresh hashes after a version bump

Aligns with AWS CFN Registry module versioning:
  Each version.json maps to one registered module version ARN:
    arn:aws:cloudformation:eu-west-1:641079926471:type/module/<TypeName>/<VersionId>
  See: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/module-versioning.html
"""

import json
import hashlib
import argparse
import sys
from pathlib import Path


MODULES_ROOT = Path("new-structure/modules")


def sha256_of(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def find_modules() -> list[Path]:
    return sorted(MODULES_ROOT.rglob("version.json"))


def check(update: bool = False) -> bool:
    version_files = find_modules()
    if not version_files:
        print("No version.json files found under new-structure/modules/")
        return False

    all_ok = True
    print(f"\n{'─'*60}")
    print(f"  Module Version Integrity Check")
    print(f"  {'Module':<35} {'Stored':<12} {'Status'}")
    print(f"{'─'*60}")

    for vf in version_files:
        module_dir = vf.parent
        template = module_dir / "template.yaml"

        if not template.exists():
            print(f"  ⚠️  {module_dir}: version.json present but template.yaml missing")
            all_ok = False
            continue

        meta = json.loads(vf.read_text())
        current_hash = sha256_of(template)
        stored_hash  = meta.get("template_hash", "")
        version      = meta.get("version", "?")
        type_name    = meta.get("type_name", module_dir.name)
        module_label = f"{module_dir.parent.name}/{module_dir.name}"

        if current_hash == stored_hash:
            print(f"  ✅  {module_label:<35} v{version:<11} hash OK")
        elif update:
            meta["template_hash"] = current_hash
            vf.write_text(json.dumps(meta, indent=2) + "\n")
            print(f"  🔄  {module_label:<35} v{version:<11} hash UPDATED")
        else:
            print(f"  ❌  {module_label:<35} v{version:<11} HASH MISMATCH")
            print(f"       template.yaml was changed without bumping version.json")
            print(f"       Stored : {stored_hash[:30]}...")
            print(f"       Current: {current_hash[:30]}...")
            print(f"")
            print(f"       To fix, bump the version in {vf} and re-run with --update:")
            print(f"         1. Edit version.json: increment 'version', update 'changelog'")
            print(f"         2. python3 new-structure/pipeline/check_module_versions.py --update")
            print(f"         3. Commit both template.yaml and version.json together")
            print(f"")
            print(f"       CFN Registry equivalent:")
            print(f"         aws cloudformation register-type \\")
            print(f"           --type MODULE --type-name {type_name} \\")
            print(f"           --schema-handler-package s3://tesco-ims-cfn-modules/{module_label}-v?.?.?.zip")
            all_ok = False

    print(f"{'─'*60}")

    if all_ok:
        print(f"\n  All module versions are in sync. ✅\n")
    else:
        print(f"\n  Version check FAILED. PR cannot be merged until all modules are in sync.\n")

    return all_ok


def list_versions():
    version_files = find_modules()
    print(f"\n{'─'*60}")
    print(f"  Registered Module Versions (local registry)")
    print(f"  {'Module':<35} {'Version':<10} {'Type Name'}")
    print(f"{'─'*60}")
    for vf in version_files:
        meta = json.loads(vf.read_text())
        module_label = f"{vf.parent.parent.name}/{vf.parent.name}"
        print(f"  {'✅' if meta.get('status')=='default' else '  '}"
              f"  {module_label:<35} v{meta.get('version','?'):<9} {meta.get('type_name','')}")
    print(f"{'─'*60}")
    print(f"\n  (✅ = current default version)\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Check module version integrity")
    ap.add_argument("--update", action="store_true",
                    help="Refresh template_hash in version.json (run after bumping version)")
    ap.add_argument("--list",   action="store_true",
                    help="List all registered module versions")
    args = ap.parse_args()

    if args.list:
        list_versions()
        sys.exit(0)

    ok = check(update=args.update)
    sys.exit(0 if ok else 1)
