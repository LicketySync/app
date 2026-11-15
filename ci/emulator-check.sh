#!/usr/bin/env bash
# Spike C's pass conditions C1 and C4 on a running Android emulator: installs
# the debug APK, opens it, waits until the page shows the test seed's peer ID
# and "QUIC loopback: ok", takes a screenshot, and fails if the app crashed or
# the page shows anything else. The page is read through the accessibility
# tree (uiautomator), which holds the WebView's text.
# By default airplane mode is on: the loopback check needs no network. With
# --network it stays off, and the check also fails when the app's UID moved
# any bytes over a network (the system's per-UID counters, which count no
# loopback traffic), printing the font provider's log (FontLog) beside them:
# Google Play services downloads fonts on an app's behalf and counts the bytes
# against it.
# Usage: ci/emulator-check.sh [--network] <apk> <output directory>
# Writes screenshot.png, ui.xml and logcat.txt into the output directory.
set -euo pipefail
shopt -s inherit_errexit
network=
if [ "${1:-}" = --network ]; then
  network=yes
  shift
fi
apk=${1:?usage: ci/emulator-check.sh <apk> <output directory>}
out=${2:?usage: ci/emulator-check.sh <apk> <output directory>}
package=com.licketysync.mobile
# The keys crate's vector for its device test seed (device.json).
peer_id=12D3KooWLbwYSoxYfCSHg726dZA3cCSdzeMG18brSyhACQ2mo24f
mkdir -p "$out"

if [ -n "$network" ]; then
  adb shell cmd connectivity airplane-mode disable
else
  adb shell cmd connectivity airplane-mode enable
fi
# A fresh install: a new UID, whose network counters start at zero.
adb uninstall "$package" > /dev/null 2>&1 || true
adb install -r "$apk"
uid=$(adb shell pm list packages -U "$package" | sed -n 's/.*uid://p' | tr -d '\r')
adb logcat -c
adb shell am start -W -n "$package/.MainActivity"

# The page asks for the status once it loads; the loopback check has 30 s.
shown=
for _ in $(seq 60); do
  adb shell uiautomator dump /sdcard/ui.xml > /dev/null 2>&1 || true
  adb exec-out cat /sdcard/ui.xml > "$out/ui.xml" 2> /dev/null || true
  if grep -q "$peer_id" "$out/ui.xml" && grep -qE 'text="(ok|failed: [^"]*)"' "$out/ui.xml"; then
    shown=yes
    break
  fi
  sleep 1
done
adb exec-out screencap -p > "$out/screenshot.png"
adb logcat -d > "$out/logcat.txt"

status=0
if [ -z "$shown" ]; then
  echo "the page did not show the peer ID $peer_id and a loopback result" >&2
  status=1
elif ! grep -q 'text="ok"' "$out/ui.xml"; then
  echo "the QUIC loopback check did not pass:" >&2
  grep -oE 'text="failed: [^"]*"' "$out/ui.xml" >&2 || true
  status=1
fi
if ! adb shell pidof "$package" > /dev/null; then
  echo "$package is not running" >&2
  status=1
fi
# The app's crashes only: uiautomator, which reads the page above, can crash
# itself on a busy emulator ("FATAL EXCEPTION: UiAutomation"), and that is
# not the app's. A Java crash names the process ("Process: <package>, PID:"),
# a native one its tombstone (">>> <package> <<<").
crashes=$(adb logcat -d -b crash | grep -E "Process: $package,|>>> $package <<<" || true)
if [ -n "$crashes" ]; then
  echo "the app crashed:" >&2
  printf '%s\n' "$crashes" >&2
  status=1
fi
if grep -E "Process: $package,|>>> $package <<<|ANR in $package" "$out/logcat.txt" >&2; then
  status=1
fi
if [ -n "$network" ]; then
  adb shell dumpsys netstats --poll > /dev/null
  adb shell dumpsys netstats detail > "$out/netstats.txt"
  # The bytes in and out of the app's UID, from its untagged buckets (tag
  # 0x0), which hold its totals; a tagged bucket counts a share of them again.
  moved=$(awk -v uid="uid=$uid" '
    /ident=/ { mine = index($0, uid " ") > 0 && index($0, " tag=0x0") > 0 }
    mine && /rb=/ { for (i = 1; i <= NF; i++) if ($i ~ /^(rb|tb)=/) { split($i, kv, "="); n += kv[2] } }
    END { print n + 0 }' "$out/netstats.txt")
  grep "FontLog" "$out/logcat.txt" > "$out/fontlog.txt" || true
  if [ "$moved" -ne 0 ]; then
    echo "the app's UID ($uid) moved $moved bytes over a network; the font provider's log:" >&2
    cat "$out/fontlog.txt" >&2
    status=1
  fi
fi
[ "$status" -eq 0 ] && echo "emulator-check: peer ID $peer_id, QUIC loopback: ok, no crash"
exit "$status"
