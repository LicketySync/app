#!/usr/bin/env bash
# The merged manifest of a built APK, checked by ci/check-manifest.py (which
# says what it allows). Usage: ci/check-manifest.sh <apk>. Needs aapt2 from
# the SDK's build tools at ANDROID_BUILD_TOOLS (ci/pins.env).
set -euo pipefail
shopt -s inherit_errexit
here=$(cd "$(dirname "$0")" && pwd)
apk=${1:?usage: ci/check-manifest.sh <apk>}
build_tools=$(sed -n 's/^ANDROID_BUILD_TOOLS=//p' "$here/pins.env")
aapt2="${ANDROID_HOME:?ANDROID_HOME is not set}/build-tools/$build_tools/aapt2"
dump=$(mktemp)
trap 'rm -f "$dump"' EXIT
"$aapt2" dump xmltree --file AndroidManifest.xml "$apk" > "$dump"
python3 -I "$here/check-manifest.py" "$dump" com.licketysync.mobile
