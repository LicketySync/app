#!/usr/bin/env bash
# The pins, written once (ci/pins.env), and every place that must agree:
# - pins.env: each line a comment, blank, or KEY=value with a plain value;
#   no key twice.
# - The workflows hold no pin: every job runs ci/pins-to-env.sh into
#   "$GITHUB_ENV" exactly once, no workflow sets RUSTUP_TOOLCHAIN itself, a
#   rustup override (ios.yml must have one, for Xcode's build phase) is
#   exactly `rustup override set "$RUST_STABLE"`, every input that names a version
#   (toolchain, java-version, api-level, system-image-api-level,
#   emulator-build, each tool of install-action's `tool:`) reads it from that
#   environment, and no pinned value of four or more characters appears in a
#   workflow as a word.
# - mobile/Cargo.toml: every git dependency names a rev, and every
#   `rev = "…"` is CORE_REV (at least one); no branch or tag.
# - mobile/gen/android/app/build.gradle.kts: every compileSdk and targetSdk is
#   ANDROID_PLATFORM (at least one of each).
# It compares every occurrence, so a second copy that differs fails, and it
# fails closed: only grep's "no match" counts as an answer.
# Usage: ci/check-pins.sh [repo-root]. Run by gate.sh; tested by
# ci/test-check-pins.sh.
set -euo pipefail
shopt -s inherit_errexit
cd "${1:-$(dirname "$0")/..}"
g() { grep "$@" || [ $? -eq 1 ]; }
fail=0
bad() {
  echo "check-pins: $*" >&2
  fail=1
}

pins=ci/pins.env
malformed=$(g -nvE '^(#.*|[A-Z0-9_]+=[A-Za-z0-9.+_:-]+)?$' "$pins")
[ -z "$malformed" ] || bad "$pins: lines that are not a comment, blank or KEY=value: $malformed"
dups=$(g -oE '^[A-Z0-9_]+=' "$pins" | sort | uniq -d)
[ -z "$dups" ] || bad "$pins: keys set twice: $dups"
pin() { sed -n "s/^$1=//p" "$pins"; }

shopt -s nullglob
workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
[ ${#workflows[@]} -gt 0 ] || bad "no workflow"
for wf in "${workflows[@]}"; do
  # Each job and the number of times it exports the pins.
  per_job=$(awk '
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^[^ #]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; jobs[job] = 0; next }
    in_jobs && job != "" && /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*app\/ci\/pins-to-env\.sh >> "\$GITHUB_ENV"[[:space:]]*$/ { jobs[job]++ }
    END { for (j in jobs) print j, jobs[j] }' "$wf")
  [ -n "$per_job" ] || bad "$wf: no job"
  wrong=$(printf '%s\n' "$per_job" | g -vE ' 1$')
  [ -z "$wrong" ] || bad "$wf: jobs that do not export the pins exactly once (job, count): $wrong"
  override=$(g -nE 'rustup[[:space:]]+override' "$wf" | g -vE '^[0-9]+:[[:space:]]*#' |
    g -vE '^[0-9]+:[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*rustup override set "\$RUST_STABLE"[[:space:]]*$')
  [ -z "$override" ] || bad "$wf: a rustup override other than \`rustup override set \"\$RUST_STABLE\"\`: $override"
  if [ "$(basename "$wf")" = ios.yml ] && ! grep -qE 'run:[[:space:]]*rustup override set "\$RUST_STABLE"' "$wf"; then
    bad "$wf: no rustup override for Xcode's build phase"
  fi
  set_toolchain=$(g -nE 'RUSTUP_TOOLCHAIN[[:space:]]*[:=]' "$wf")
  [ -z "$set_toolchain" ] || bad "$wf sets RUSTUP_TOOLCHAIN itself: $set_toolchain"
  literal=$(g -nE '^[[:space:]]*(-[[:space:]]+)?(toolchain|java-version|api-level|system-image-api-level|emulator-build):' "$wf" |
    g -vE ':[[:space:]]*\$\{\{ env\.[A-Z0-9_]+ \}\}[[:space:]]*$')
  [ -z "$literal" ] || bad "$wf: a version input that does not read the environment: $literal"
  tools=$(g -E '^[[:space:]]*tool:' "$wf" | sed -E 's/^[[:space:]]*tool:[[:space:]]*//' | tr ',' '\n' |
    g -vE '^[a-z0-9-]+@\$\{\{ env\.[A-Z0-9_]+ \}\}[[:space:]]*$')
  [ -z "$tools" ] || bad "$wf: a tool not pinned through the environment: $tools"
  while IFS= read -r value; do
    [ "${#value}" -ge 4 ] || continue
    copy=$(g -nwF -- "$value" "$wf")
    [ -z "$copy" ] || bad "$wf holds the pinned value $value: $copy"
  done < <(g -E '^[A-Z0-9_]+=' "$pins" | sed 's/^[^=]*=//')
done

core_rev=$(pin CORE_REV)
no_rev=$(g -nE '\bgit[[:space:]]*=' mobile/Cargo.toml Cargo.toml | g -vE '\brev[[:space:]]*=[[:space:]]*"[0-9a-f]{40}"')
[ -z "$no_rev" ] || bad "a git dependency without a full rev: $no_rev"
moving=$(g -nE '\b(branch|tag)[[:space:]]*=' mobile/Cargo.toml Cargo.toml)
[ -z "$moving" ] || bad "a git dependency on a branch or tag: $moving"
revs=$(g -oE 'rev[[:space:]]*=[[:space:]]*"[^"]*"' mobile/Cargo.toml | sed -E 's/.*"(.*)"/\1/')
[ -n "$revs" ] || bad "mobile/Cargo.toml names no rev"
other=$(printf '%s\n' "$revs" | g -vxF -- "$core_rev")
[ -z "$other" ] || bad "mobile/Cargo.toml: revs other than CORE_REV $core_rev: $other"

gradle=mobile/gen/android/app/build.gradle.kts
platform=$(pin ANDROID_PLATFORM)
for key in compileSdk targetSdk; do
  values=$(g -oE "\b$key[[:space:]]*=[[:space:]]*[^[:space:]]+" "$gradle" | sed -E 's/.*=[[:space:]]*//')
  [ -n "$values" ] || bad "$gradle sets no $key"
  other=$(printf '%s\n' "$values" | g -vxF -- "$platform")
  [ -z "$other" ] || bad "$gradle: $key other than ANDROID_PLATFORM $platform: $other"
done

[ "$fail" -eq 0 ] || exit 1
echo "check-pins: ok"
