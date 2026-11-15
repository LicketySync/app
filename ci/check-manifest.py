# The merged manifest of a built APK, as `aapt2 dump xmltree --file
# AndroidManifest.xml` prints it, held to what the shell's security settings allow (TM-31):
# - every element of a kind on an explicit list, and every attribute of each
#   kind on that kind's list, so that a setting the libraries or a change add
#   (a network security configuration, a shared user ID, a process, testOnly,
#   a tools: attribute) fails until the list says it may be there;
# - the permissions asked for (uses-permission and uses-permission-sdk-23
#   alike) and defined, the latter signature-level;
# - every activity, provider, receiver and service, with its exported flag
#   and guarding permission;
# - every meta-data by name and parent: under the application only the
#   WebView's Safe Browsing and metrics switches, both off; under androidx's
#   InitializationProvider only the lifecycle and profile installer
#   initializers (emoji2's, which fetches a font from Google, among the ones
#   that fail);
# - no backup or device transfer, no cleartext.
# A line of a kind the parser does not know, or an element line without its
# (line=N), fails as well.
# Usage: python3 -I ci/check-manifest.py <dump> <package>. Exit 1 on any
# difference, each printed. Run by ci/check-manifest.sh; tested by
# ci/test-check-manifest.sh.
import re
import sys

ANDROID = "http://schemas.android.com/apk/res/android:"
NAMESPACE = re.compile(r"^\s*N: \S+=\S+ \(line=\d+\)$")
ELEMENT = re.compile(r"^(\s*)E: (\S+) \(line=\d+\)$")
ATTRIBUTE = re.compile(r"^\s*A: (\S+?)(?:\(0x[0-9a-f]+\))?=(.*)$")

# Each element kind the merged manifest may hold, with the attributes it may
# carry (android: names without their namespace; others as aapt2 prints them).
ATTRIBUTES = {
    "manifest": {
        "versionCode",
        "versionName",
        "compileSdkVersion",
        "compileSdkVersionCodename",
        "package",
        "platformBuildVersionCode",
        "platformBuildVersionName",
    },
    "uses-sdk": {"minSdkVersion", "targetSdkVersion"},
    "uses-permission": {"name"},
    "uses-feature": {"name", "required"},
    "permission": {"name", "protectionLevel"},
    "application": {
        "theme",
        "label",
        "icon",
        "debuggable",
        "allowBackup",
        "extractNativeLibs",
        "usesCleartextTraffic",
        "appComponentFactory",
        "dataExtractionRules",
    },
    "meta-data": {"name", "value"},
    "activity": {"label", "name", "exported", "launchMode", "configChanges"},
    "provider": {"name", "exported", "authorities"},
    "receiver": {"name", "permission", "enabled", "exported", "directBootAware"},
    "intent-filter": set(),
    "action": {"name"},
    "category": {"name"},
}

# The meta-data each parent may hold, the parent named by its tag and, for a
# component, its name.
META_DATA = {
    ("application", None): {
        "android.webkit.WebView.EnableSafeBrowsing",
        "android.webkit.WebView.MetricsOptOut",
    },
    ("provider", "androidx.startup.InitializationProvider"): {
        "androidx.lifecycle.ProcessLifecycleInitializer",
        "androidx.profileinstaller.ProfileInstallerInitializer",
    },
}


def value(text):
    """An attribute's value: the quoted string, or the bare token."""
    if text.startswith('"'):
        return text[1 : text.index('"', 1)]
    return text.split(" ")[0]


def level_of(text):
    """A protection level as a number, or None."""
    try:
        return int(text, 16)
    except (TypeError, ValueError):
        return None


def parse(lines):
    """Each element as [tag, attributes, parent's index], and the errors in
    lines the parser does not recognise."""
    out, stack, errors = [], [], []
    for number, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        if not line.strip() or NAMESPACE.match(line):
            continue
        m = ELEMENT.match(line)
        if m:
            depth = len(m.group(1))
            while stack and stack[-1][0] >= depth:
                stack.pop()
            out.append([m.group(2), {}, stack[-1][1] if stack else None])
            stack.append((depth, len(out) - 1))
            continue
        m = ATTRIBUTE.match(line)
        if m and out:
            name = m.group(1)
            key = name.removeprefix(ANDROID) if name.startswith(ANDROID) else name
            if key in out[-1][1]:
                errors.append(f"line {number}: {key} twice on one {out[-1][0]}")
            out[-1][1][key] = value(m.group(2))
            continue
        errors.append(f"line {number}: not a namespace, element or attribute line: {line.strip()}")
    return out, errors


def check(lines, package):
    found, errors = parse(lines)
    if not found or found[0][0] != "manifest":
        errors.append("no manifest element first")
    for tag, attrs, _ in found:
        if tag not in ATTRIBUTES:
            errors.append(f"an element outside the allowed list: {tag}")
            continue
        extra = sorted(set(attrs) - ATTRIBUTES[tag])
        if extra:
            errors.append(f"{tag} {attrs.get('name', '')}: attributes outside its list: {extra}")
    by_tag = lambda tag: [attrs for t, attrs, _ in found if t == tag]

    receiver_permission = f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
    asked = sorted(
        a.get("name", "?") for a in by_tag("uses-permission") + by_tag("uses-permission-sdk-23")
    )
    if asked != sorted(["android.permission.INTERNET", receiver_permission]):
        errors.append(f"uses-permission: {asked}")
    defined = [(a.get("name"), a.get("protectionLevel")) for a in by_tag("permission")]
    if [(n, level_of(p)) for n, p in defined] != [(receiver_permission, 2)]:
        errors.append(f"permission (signature only, 0x2): {defined}")

    apps = by_tag("application")
    app = apps[0] if len(apps) == 1 else {}
    for key, want in [("allowBackup", "false"), ("usesCleartextTraffic", "false")]:
        if app.get(key) != want:
            errors.append(f"application {key}: {app.get(key)}, not {want}")
    if not app.get("dataExtractionRules", "").startswith("@"):
        errors.append("application has no dataExtractionRules")

    for tag, attrs, parent in found:
        if tag != "meta-data":
            continue
        ptag, pattrs, _ = found[parent] if parent is not None else (None, {}, None)
        where = (ptag, pattrs.get("name") if ptag != "application" else None)
        if attrs.get("name") not in META_DATA.get(where, set()):
            errors.append(f"meta-data {attrs.get('name')} under {where}: not on its list")
    meta = {
        a.get("name"): a.get("value")
        for tag, a, parent in found
        if tag == "meta-data" and parent is not None and found[parent][0] == "application"
    }
    for key, want in [
        ("android.webkit.WebView.EnableSafeBrowsing", "false"),
        ("android.webkit.WebView.MetricsOptOut", "true"),
    ]:
        if meta.get(key) != want:
            errors.append(f"meta-data {key}: {meta.get(key)}, not {want}")

    components = sorted(
        (tag, a.get("name"), a.get("exported"), a.get("permission"))
        for tag, a, _ in found
        if tag in ("activity", "activity-alias", "provider", "receiver", "service")
    )
    allowed = sorted(
        [
            ("activity", f"{package}.MainActivity", "true", None),
            ("provider", "androidx.startup.InitializationProvider", "false", None),
            (
                "receiver",
                "androidx.profileinstaller.ProfileInstallReceiver",
                "true",
                "android.permission.DUMP",
            ),
        ]
    )
    if components != allowed:
        errors.append(f"components (tag, name, exported, permission): {components}")
    return errors


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        errors = check(f.readlines(), sys.argv[2])
    for e in errors:
        print(f"check-manifest: {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print("check-manifest: ok")


if __name__ == "__main__":
    main()
