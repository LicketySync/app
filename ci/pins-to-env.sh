#!/usr/bin/env bash
# Prints ci/pins.env's pins as KEY=value lines for "$GITHUB_ENV", and
# RUSTUP_TOOLCHAIN=<RUST_STABLE>, which pins every cargo and rustc a job runs
# (rust-toolchain.toml names stable). Every workflow job runs it first:
#   run: app/ci/pins-to-env.sh >> "$GITHUB_ENV"
set -euo pipefail
pins="$(dirname "$0")/pins.env"
grep -E '^[A-Z0-9_]+=' "$pins"
echo "RUSTUP_TOOLCHAIN=$(sed -n 's/^RUST_STABLE=//p' "$pins")"
