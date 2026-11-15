#!/usr/bin/env bash
# Core's no-hostnames check (core/ci/no-hostnames.sh, which says what it
# catches and what it misses) on the app's Rust: every hostname or IPv4
# address in a string literal must be in core's spec/allowed-hosts.txt,
# which the app shares (TM-31). Core's script reads crates/ under a root, so
# this copies the app's Rust files into a temporary root laid out that way.
# Usage: ci/no-hostnames.sh. Run by gate.sh and CI.
set -euo pipefail
shopt -s inherit_errexit
here=$(cd "$(dirname "$0")" && pwd)
core=$("$here/core-dir.sh")
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/crates" "$root/spec"
cp "$core/spec/allowed-hosts.txt" "$root/spec/"
cd "$here/.."
git ls-files -z --cached --others --exclude-standard -- '*.rs' |
  while IFS= read -r -d '' f; do
    cp --parents --no-dereference -t "$root/crates" -- "$f"
  done
"$core/ci/no-hostnames.sh" "$root"
