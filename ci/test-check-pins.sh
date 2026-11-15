#!/usr/bin/env bash
# ci/check-pins.sh on a copy of this repository's files it reads, which must
# pass, and on copies changed one way each, every one of which must fail.
# Works from any directory. Run by gate.sh and CI.
set -euo pipefail
shopt -s inherit_errexit
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$repo"
shopt -s nullglob
files=(ci/pins.env Cargo.toml mobile/Cargo.toml mobile/gen/android/app/build.gradle.kts .github/workflows/*.yml)
if [ ${#files[@]} -lt 4 ]; then
  echo "test-check-pins: no workflow under $repo/.github/workflows" >&2
  exit 1
fi
for f in "${files[@]}"; do
  mkdir -p "$tmp/base/$(dirname "$f")"
  cp "$f" "$tmp/base/$f"
done
"$here/check-pins.sh" "$tmp/base" > /dev/null
failures=0
# must_fail <name> <file> <sed script>: the copy with the file changed by the
# script must fail.
must_fail() {
  rm -rf "$tmp/case"
  cp -r "$tmp/base" "$tmp/case"
  sed -E -i "$3" "$tmp/case/$2"
  if cmp -s "$tmp/base/$2" "$tmp/case/$2"; then
    echo "test-check-pins: $1 changed nothing" >&2
    failures=$((failures + 1))
  elif "$here/check-pins.sh" "$tmp/case" 2> /dev/null > /dev/null; then
    echo "test-check-pins: $1 passed" >&2
    failures=$((failures + 1))
  fi
}
g=mobile/gen/android/app/build.gradle.kts
must_fail malformed-line ci/pins.env '$ a\
JDK = 25'
must_fail duplicate-key ci/pins.env '$ a\
TYPOS=1.0.0'
must_fail mismatched-duplicate-compile-sdk "$g" 's/^(.*compileSdk = [0-9]+)$/\1\n    compileSdk = 36/'
must_fail other-target-sdk "$g" 's/targetSdk = [0-9]+/targetSdk = 36/'
must_fail no-target-sdk "$g" '/targetSdk/d'
must_fail mismatched-rev mobile/Cargo.toml '0,/rev = "[0-9a-f]+"/s//rev = "0000000000000000000000000000000000000000"/'
must_fail literal-toolchain .github/workflows/checks.yml '0,/toolchain: \$\{\{ env.RUST_STABLE \}\}/s//toolchain: 1.99.1/'
must_fail literal-tool .github/workflows/checks.yml 's/typos@\$\{\{ env.TYPOS \}\}/typos@1.51.1/'
must_fail pinned-value-copied .github/workflows/android.yml '0,/^jobs:/s//# JDK 25.0.5+8\njobs:/'
must_fail toolchain-set-in-workflow .github/workflows/checks.yml 's/^env:$/env:\n  RUSTUP_TOOLCHAIN: stable/'
must_fail job-without-pins .github/workflows/checks.yml '0,/app\/ci\/pins-to-env.sh >> "\$GITHUB_ENV"/s//app\/ci\/other.sh >> "$GITHUB_ENV"/'
must_fail literal-rustup-override .github/workflows/ios.yml 's/rustup override set "\$RUST_STABLE"/rustup override set 1.98.0/'
must_fail no-rustup-override .github/workflows/ios.yml '/rustup override set/d'
# One job exports twice and another not at all: the totals still match.
must_fail export-moved-between-jobs .github/workflows/checks.yml '0,/(run: app\/ci\/pins-to-env\.sh >> "\$GITHUB_ENV")/s//\1\n      - \1/; /^  gitleaks:/,${/pins-to-env/d}'
must_fail git-without-rev mobile/Cargo.toml '0,/, rev = "[0-9a-f]+"/s///'
must_fail git-on-a-branch mobile/Cargo.toml '0,/rev = "[0-9a-f]+"/s//rev = "6beadae98da55b8e055bd4e575ed69b373ee9102", branch = "main"/'
if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "test-check-pins: ok"
