#!/usr/bin/env bash
# Prints the directory of cargo's checkout of core at CORE_REV, which
# mobile/Cargo.toml's git dependencies name: the app runs core's scripts and
# Semgrep rules from it. Fails unless cargo's metadata names exactly one.
# Usage: ci/core-dir.sh (from anywhere; runs `cargo metadata --locked`).
set -euo pipefail
shopt -s inherit_errexit
cd "$(dirname "$0")/.."
metadata=$(cargo metadata --locked --format-version 1)
python3 -I -c '
import json, os, sys
packages = json.load(sys.stdin)["packages"]
roots = {
    os.path.dirname(os.path.dirname(os.path.dirname(p["manifest_path"])))
    for p in packages
    if p["name"] == "licketysync-keys" and (p["source"] or "").startswith("git+")
}
if len(roots) != 1:
    sys.exit(f"core-dir: {len(roots)} checkouts of core in the metadata")
print(roots.pop())
' <<< "$metadata"
