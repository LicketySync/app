#!/usr/bin/env bash
# ci/check-manifest.py on the merged manifest of a real debug APK
# (ci/fixtures/merged-manifest.txt, aapt2's dump of it) and on copies changed
# one way each, every one of which must fail. Run by gate.sh.
set -euo pipefail
shopt -s inherit_errexit
here=$(cd "$(dirname "$0")" && pwd)
fixture="$here/fixtures/merged-manifest.txt"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
package=com.licketysync.mobile
python3 -I "$here/check-manifest.py" "$fixture" "$package" > /dev/null
failures=0
# must_fail <name> <sed script>: the fixture changed by the script must fail.
must_fail() {
  sed -E "$2" "$fixture" > "$tmp/$1"
  if cmp -s "$fixture" "$tmp/$1"; then
    echo "test-check-manifest: $1 changed nothing" >&2
    failures=$((failures + 1))
  elif python3 -I "$here/check-manifest.py" "$tmp/$1" "$package" 2> /dev/null; then
    echo "test-check-manifest: $1 passed" >&2
    failures=$((failures + 1))
  fi
}
must_fail another-permission 's/android.permission.INTERNET/android.permission.CAMERA/'
must_fail backup 's/(allowBackup\(0x[0-9a-f]+\))=false/\1=true/'
must_fail cleartext 's/(usesCleartextTraffic\(0x[0-9a-f]+\))=false/\1=true/'
must_fail no-extraction-rules '/dataExtractionRules/d'
must_fail safe-browsing '/EnableSafeBrowsing/{n;s/=false/=true/}'
must_fail metrics '/MetricsOptOut/{n;s/=true/=false/}'
must_fail exported-provider '/E: provider/,/E: /{s/(exported\(0x[0-9a-f]+\))=false/\1=true/}'
must_fail unguarded-receiver '/android.permission.DUMP/d'
must_fail another-service 's/E: receiver/E: service/'
must_fail emoji 's/androidx.profileinstaller.ProfileInstallerInitializer/androidx.emoji2.text.EmojiCompatInitializer/'
must_fail level 's/protectionLevel\(0x[0-9a-f]+\)=0x00000002/protectionLevel(0x01010009)=0x00000000/'
# Elements of kinds the checks do not otherwise read: a permission asked for
# on Android 6 and later only, a permission group, a permission tree, and a
# query for other apps.
must_fail sdk-23-permission 's/E: uses-permission \(line=11\)/E: uses-permission-sdk-23 (line=11)/'
must_fail extra-sdk-23-permission 's/^(\s*)E: uses-feature (.*)$/\1E: uses-permission-sdk-23 (line=1)\n\1  A: http:\/\/schemas.android.com\/apk\/res\/android:name(0x01010003)="android.permission.CAMERA"\n\1E: uses-feature \2/'
must_fail permission-group 's/E: uses-feature/E: permission-group/'
must_fail permission-tree 's/E: uses-feature/E: permission-tree/'
must_fail queries 's/E: uses-feature/E: queries/'
# A meta-data that is not on its parent's list: another startup initializer,
# another setting under the application, and one under the activity.
must_fail other-initializer 's/androidx.lifecycle.ProcessLifecycleInitializer/androidx.work.WorkManagerInitializer/'
must_fail application-meta-data '/MetricsOptOut/{n;s/$/\n          E: meta-data (line=50)\n            A: http:\/\/schemas.android.com\/apk\/res\/android:name(0x01010003)="com.example.Setting" (Raw: "com.example.Setting")/}'
must_fail activity-meta-data '/launchMode/s/$/\n              E: meta-data (line=73)\n                A: http:\/\/schemas.android.com\/apk\/res\/android:name(0x01010003)="android.webkit.WebView.MetricsOptOut" (Raw: "x")/'
# Attributes outside an element's list.
must_fail network-security-config '/dataExtractionRules/s/$/\n        A: http:\/\/schemas.android.com\/apk\/res\/android:networkSecurityConfig(0x01010527)=@0x7f120001/'
must_fail test-only '/dataExtractionRules/s/$/\n        A: http:\/\/schemas.android.com\/apk\/res\/android:testOnly(0x01010272)=true/'
must_fail shared-user-id '/A: package=/s/$/\n    A: http:\/\/schemas.android.com\/apk\/res\/android:sharedUserId(0x0101000b)="com.example.shared" (Raw: "com.example.shared")/'
must_fail component-process '/directBootAware/s/$/\n            A: http:\/\/schemas.android.com\/apk\/res\/android:process(0x01010011)=":other" (Raw: ":other")/'
must_fail tools-attribute '/launchMode/s/$/\n            A: http:\/\/schemas.android.com\/tools:node=merge/'
# Lines the parser does not know, and an element line without its number.
must_fail unknown-line-kind '/E: uses-sdk/s/$/\n        X: something/'
must_fail element-without-line 's/E: uses-feature \(line=14\)/E: uses-feature/'
if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "test-check-manifest: ok"
