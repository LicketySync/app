#!/usr/bin/env bash
# ci/check-chrono.sh on a copy of the workspace's manifests and lockfile,
# which must pass, and on copies changed one way each, every one of which must
# fail, and say why: chrono built one way each, a second chrono older or newer
# than serde_with's, a lockfile that does not match the manifests, chrono out
# of the lockfile, and a lockfile that cannot be read. Needs cargo and the
# network or cargo's cache (the cases that add a dependency relock the copy's
# workspace). Works from any directory. Run by gate.sh and CI.
set -euo pipefail
shopt -s inherit_errexit
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The copy: the root manifest, the lockfile, the toolchain file, every
# workspace member's manifest, and an empty file for each of its targets.
mkdir -p "$tmp/base"
cp "$repo/Cargo.toml" "$repo/Cargo.lock" "$repo/rust-toolchain.toml" "$tmp/base/"
metadata=$(cargo metadata --locked --no-deps --format-version 1 --manifest-path "$repo/Cargo.toml")
python3 -I -c '
import json, os, shutil, sys
meta, out = json.load(sys.stdin), sys.argv[1]
for p in meta["packages"]:
    for f in [p["manifest_path"]] + [t["src_path"] for t in p["targets"]]:
        rel = os.path.relpath(f, meta["workspace_root"])
        if rel.startswith(".."):
            sys.exit(f"test-check-chrono: {f} is outside the workspace")
        os.makedirs(os.path.join(out, os.path.dirname(rel)), exist_ok=True)
        if f == p["manifest_path"]:
            shutil.copyfile(f, os.path.join(out, rel))
        else:
            open(os.path.join(out, rel), "a").close()
' "$tmp/base" <<< "$metadata"
"$here/check-chrono.sh" "$tmp/base" > /dev/null
failures=0
# must_fail <case> <message> [<other>]: the copy changed by the function
# <case>, run in it, must fail with the message, and without the other.
must_fail() {
  rm -rf "$tmp/case"
  cp -r "$tmp/base" "$tmp/case"
  if ! (cd "$tmp/case" && "$1"); then
    echo "test-check-chrono: $1 could not change the copy" >&2
    failures=$((failures + 1))
  elif "$here/check-chrono.sh" "$tmp/case" 2> "$tmp/err" > /dev/null; then
    echo "test-check-chrono: $1 passed" >&2
    failures=$((failures + 1))
  elif ! grep -qF -- "$2" "$tmp/err" || { [ -n "${3:-}" ] && grep -qF -- "$3" "$tmp/err"; }; then
    echo "test-check-chrono: $1 failed for another reason:" >&2
    cat "$tmp/err" >&2
    failures=$((failures + 1))
  fi
}
# append <file> <table> <line>...: the table, with the lines, at the end of
# the file.
append() {
  printf '\n[%s]\n' "$2" >> "$1" && printf '%s\n' "${@:3}" >> "$1"
}
# add <table> <line>...: the table appended to mobile/Cargo.toml, and the
# workspace relocked.
add() { append mobile/Cargo.toml "$@" && cargo update --workspace --quiet; }
chrono=('version = "0.4.45"' 'default-features = false')
# serde_with's chrono feature turned on, for a target the app does not build
# for; then chrono itself, one way each.
other_target() {
  add "target.'cfg(target_os = \"freebsd\")'.dependencies.serde_with" 'version = "3.24.0"' 'features = ["chrono"]'
}
feature() {
  append mobile/Cargo.toml features 'dates = ["dep:chrono"]' &&
    add dependencies.chrono "${chrono[@]}" 'optional = true'
}
build_dependency() { add build-dependencies.chrono "${chrono[@]}"; }
dev_dependency() { add dev-dependencies.chrono "${chrono[@]}"; }
# new_crate <dir> <name> <version>: a crate of the copy, with an empty library.
new_crate() {
  mkdir -p "$1/src" && : > "$1/src/lib.rs" &&
    append "$1/Cargo.toml" package "name = \"$2\"" "version = \"$3\"" 'edition = "2024"'
}
# A member outside the default members that depends on chrono.
other_member() {
  sed -i 's/^members = \["mobile"\]$/members = ["mobile", "other"]\ndefault-members = ["mobile"]/' Cargo.toml &&
    grep -qxF 'default-members = ["mobile"]' Cargo.toml && new_crate other other 0.0.1 &&
    append other/Cargo.toml dependencies.chrono "${chrono[@]}" && cargo update --workspace --quiet
}
# A second chrono in the lockfile, built: a crate of the copy named chrono,
# at a version Cargo.lock lists before serde_with's 0.4.45, or after it.
local_chrono() {
  new_crate chrono chrono "$1" && add dependencies.chrono 'path = "../chrono"'
}
older_chrono() { local_chrono 0.3.0; }
newer_chrono() { local_chrono 0.5.0; }
# A dependency the lockfile does not have, not relocked.
stale_lockfile() { append mobile/Cargo.toml dependencies.log 'version = "0.4"'; }
# chrono's package and serde_with's edge to it, out of the lockfile.
out_of_lockfile() {
  awk -v RS= -v ORS='\n\n' '!/^\[\[package\]\]\nname = "chrono"\n/' Cargo.lock |
    grep -vxF ' "chrono",' > lock && mv lock Cargo.lock
}
unreadable_lockfile() { rm Cargo.lock && mkdir Cargo.lock; }
must_fail other_target "chrono is built"
must_fail feature "chrono is built"
must_fail build_dependency "chrono is built"
must_fail dev_dependency "chrono is built"
must_fail other_member "chrono is built"
must_fail older_chrono "chrono is built"
must_fail newer_chrono "chrono is built"
must_fail stale_lockfile "because --locked was passed"
must_fail out_of_lockfile "chrono is not in Cargo.lock"
must_fail unreadable_lockfile "cannot read Cargo.lock" "not in Cargo.lock"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "test-check-chrono: ok"
