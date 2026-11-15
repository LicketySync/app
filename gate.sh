#!/usr/bin/env bash
# The gate every change to the app must pass before it is committed (the
# plan's Engineering practice): core's checks but coverage, mutants, fuzzing
# and the simulator. Pins first (ci/check-pins.sh, then each tool's version),
# then fmt; clippy pedantic with -D warnings on the host and for Android; the
# tests and doc-tests; rustdoc with warnings denied; cargo-deny; cargo-audit
# denying warnings (.cargo/audit.toml lists the three it allows); cargo-machete;
# cargo-vet; cargo-udeps; typos; core's Semgrep project rules (TM-7) and
# no-hostnames check (TM-31) over the app; gitleaks over the history and the
# working tree (skipped when gitleaks is not installed); core's check that
# every action is pinned by commit; and the tests of the CI scripts. The APKs,
# their merged manifests and the emulator are CI's (android.yml), as is the
# iOS build (ios.yml).
#
# Core's checks that do not apply to the app, and why:
# - cargo-geiger: deferred to phases 3 and 4 (the shells proper). Run as core
#   runs it, it counts unsafe code for the host, where Tauri's runtime crates
#   are not built (they are a dependency on Android and iOS only), and core's
#   ci/geiger.sh scans the crates of core's own workspace against its
#   baseline; the phones' graph needs a cross-target scan and a baseline of
#   its own.
# - The dep-info check: core's ci/check-dep-info.sh allows a crate to read only
#   the files its Semgrep scope lists (core's ci/scope.py), with no build
#   script; the app's crate reads its page, isolation page, configuration and
#   icons through Tauri's generated context, and the files Tauri's build script
#   writes, all of which that scope refuses.
# - Core's Semgrep rule for build scripts (.semgrep/build-scripts.yml): it
#   allows only core's; the app has one, Tauri's (mobile/build.rs), which
#   generates the context above. The word rules, which do apply, cannot see
#   what #[tauri::mobile_entry_point] expands (mobile/src/shell.rs says so).
#
# Needs: the tools at their pins (ci/pins.env), the nightly toolchain, and the
# Android NDK at $ANDROID_HOME/ndk/$ANDROID_NDK (clippy for Android builds
# aws-lc-sys with the NDK's clang). Needs the network: cargo fetches core at
# CORE_REV, cargo-audit and cargo-deny fetch the advisory database. Works from
# any directory and stops at the first failing step.
set -euo pipefail
shopt -s inherit_errexit
cd "$(dirname "$0")"

step() { echo "== $*"; "$@"; }

# The pins: ci/pins.env well formed, and every copy that must agree with it.
step ci/check-pins.sh
# shellcheck source=ci/pins.env
. ci/pins.env

# need <what> <pinned> <found>: stop unless the two are equal.
need() {
  if [ "$2" != "$3" ]; then
    echo "$1 $2 is needed (ci/pins.env); found: ${3:-none}" >&2
    exit 1
  fi
}
# version <command...>: the first X.Y.Z its output names.
version() {
  "$@" 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}
need rustc "$RUST_STABLE" "$(RUSTUP_AUTO_INSTALL=0 version rustc --version)"
if ! rustup toolchain list | grep -q "^$RUST_NIGHTLY-"; then
  echo "Rust $RUST_NIGHTLY is needed (ci/pins.env) for cargo-udeps" >&2
  exit 1
fi
need cargo-deny "$CARGO_DENY" "$(version cargo deny --version)"
need cargo-audit "$CARGO_AUDIT" "$(version cargo audit --version)"
need cargo-machete "$CARGO_MACHETE" "$(version cargo machete --version)"
need cargo-vet "$CARGO_VET" "$(version cargo vet --version)"
need cargo-udeps "$CARGO_UDEPS" "$(version cargo "+$RUST_NIGHTLY" udeps --version)"
need typos "$TYPOS" "$(version typos --version)"
need tauri-cli "$TAURI_CLI" "$(version cargo tauri --version)"
need semgrep "$SEMGREP" "$(version semgrep --version)"

# Cargo's checkout of core at CORE_REV, whose scripts and rules run below.
core=$(ci/core-dir.sh)

# Clippy for Android: aws-lc-sys (beneath rustls in net) builds with the
# NDK's clang, as the Tauri command line sets it up for the APKs.
ndk_bin="${ANDROID_HOME:?ANDROID_HOME is not set}/ndk/$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [ ! -d "$ndk_bin" ]; then
  echo "the NDK $ANDROID_NDK is needed at $ndk_bin" >&2
  exit 1
fi
android=(env
  "CC_aarch64_linux_android=$ndk_bin/aarch64-linux-android24-clang"
  "AR_aarch64_linux_android=$ndk_bin/llvm-ar"
  "CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$ndk_bin/aarch64-linux-android24-clang")

step cargo fmt --all --check
step cargo clippy --locked --workspace --all-targets -- -D warnings
step "${android[@]}" cargo clippy --locked --workspace --lib --target aarch64-linux-android -- -D warnings
step cargo test --locked --workspace
step env RUSTDOCFLAGS='-D warnings' cargo doc --locked --workspace --no-deps --document-private-items
step cargo deny check
step cargo audit --deny warnings
step cargo machete
step cargo vet --locked
step cargo "+$RUST_NIGHTLY" udeps --locked --workspace --all-targets
step typos
# Core's project rules over every file git tracks or sees untracked, with
# nosemgrep comments ignored; no file skipped for its size or kind.
step semgrep scan --metrics=off --disable-version-check --quiet \
  --config "$core/.semgrep/project.yml" --config "$core/.semgrep/manifests.yml" \
  --error --disable-nosem --max-target-bytes=0 --no-exclude-binary-files \
  --timeout-threshold=0 --timeout 60 .
step ci/no-hostnames.sh
# tree: a copy of the files git tracks and the untracked ones it does not
# ignore, for gitleaks to scan as a directory (as core's ci/gitleaks.sh does).
tree() {
  local dir
  dir=$(mktemp -d)
  git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do
      if [ -e "$f" ] || [ -L "$f" ]; then cp --parents --no-dereference -t "$dir" -- "$f"; fi
    done
  echo "$dir"
}
if command -v gitleaks > /dev/null; then
  step gitleaks git --redact --no-banner --exit-code 1 .
  scan=$(tree)
  trap 'rm -rf "$scan"' EXIT
  step gitleaks dir --redact --no-banner --exit-code 1 "$scan"
else
  echo "== skipped: gitleaks (not installed; CI runs it)"
fi
step "$core/ci/pinned-actions.sh" .github/workflows
# The CI scripts' tests, from another directory than this one, as CI runs
# them from its workspace's root; ci/check-manifest.sh itself runs on CI's APKs.
step env -C / "$PWD/ci/test-check-pins.sh"
step env -C / "$PWD/ci/test-check-manifest.sh"
echo "== gate passed"
