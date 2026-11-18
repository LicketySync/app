#!/usr/bin/env bash
# chrono is unmaintained (RUSTSEC-2026-0543), and .cargo/audit.toml ignores
# the advisory because chrono is in Cargo.lock without being built: it is
# serde_with's optional chrono_0_4, which serde_with's std and alloc features
# name only as weak dependency features (chrono_0_4?/std) and nothing turns
# on, and cargo locks such a dependency all the same (rust-lang/cargo#10801).
# This keeps the ignore from hiding a real dependency: it fails if any locked
# chrono, each version on its own, is built for any target, with every
# feature of every workspace member on, as a normal, build or dev dependency.
# It fails closed: if cargo cannot answer with the lockfile as it is, or the
# lockfile cannot be read. It also fails once chrono is out of Cargo.lock, so
# that the ignore goes with it.
# The Tauri command line turns tauri features on when it builds, which this
# sees in mobile/Cargo.toml: custom-protocol, on there already, and those
# tauri.conf.json calls for (isolation, on already), which it first writes
# there. tauri-build, which the gate's clippy for Android runs, fails unless
# the committed manifest has them, all but tray-icon, whose crate tauri builds
# for the desktop only, never for the phones the command line builds here.
# Usage: ci/check-chrono.sh [repo-root]. Run by gate.sh and CI; tested by
# ci/test-check-chrono.sh.
set -euo pipefail
shopt -s inherit_errexit
cd "${1:-$(dirname "$0")/..}"
g() { grep "$@" || [ $? -eq 1 ]; }
# Each locked chrono's version: in Cargo.lock, a package's version line
# follows its name line.
versions=$(g -A1 -xF 'name = "chrono"' Cargo.lock | sed -n 's/^version = "\(.*\)"$/\1/p') || {
  echo "check-chrono: cannot read Cargo.lock" >&2
  exit 1
}
if [ -z "$versions" ]; then
  echo "check-chrono: chrono is not in Cargo.lock: remove RUSTSEC-2026-0543 from .cargo/audit.toml (and deny.toml's note of it), and this check" >&2
  exit 1
fi
built=""
for version in $versions; do
  tree=$(cargo tree --locked --quiet --workspace --invert "chrono@$version" \
    --edges normal,build,dev --target all --all-features)
  [ -z "$tree" ] || built+="$tree"$'\n'
done
if [ -n "$built" ]; then
  echo "check-chrono: chrono is built, which the ignore of RUSTSEC-2026-0543 would hide:" >&2
  printf '%s' "$built" >&2
  exit 1
fi
echo "check-chrono: ok"
