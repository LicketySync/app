// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The functions behind the `status` command, on the host, and the shell's
//! security settings as its files hold them (TM-20, TM-27, TM-29, TM-31).

#![allow(
    clippy::unwrap_used,
    clippy::panic,
    clippy::indexing_slicing,
    reason = "test code"
)]

use core::fmt::Write as _;

use serde_json::Value;

use super::*;

const TAURI_CONF: &str = include_str!("../tauri.conf.json");
const CAPABILITY: &str = include_str!("../capabilities/status.json");
const PAGE_HTML: &str = include_str!("../../ui/index.html");
const PAGE_JS: &str = include_str!("../../ui/main.js");
const PAGE_CSS: &str = include_str!("../../ui/style.css");
const ISOLATION_HTML: &str = include_str!("../../isolation/index.html");
const ISOLATION_JS: &str = include_str!("../../isolation/index.js");
const ANDROID_MANIFEST: &str = include_str!("../gen/android/app/src/main/AndroidManifest.xml");
const DATA_RULES: &str =
    include_str!("../gen/android/app/src/main/res/xml/data_extraction_rules.xml");

fn json(text: &str) -> Value {
    serde_json::from_str(text).unwrap()
}

/// The names, among a checkout directory's entries, that are cargo's checkout
/// of `rev`: at least 7 leading hex digits of it. Cargo's abbreviation length
/// is not a promise.
fn checkout_names<'a>(rev: &str, names: &'a [String]) -> Vec<&'a str> {
    names
        .iter()
        .map(String::as_str)
        .filter(|name| name.len() >= 7 && rev.starts_with(name))
        .collect()
}

#[test]
fn checkout_names_match_any_abbreviation_of_seven_or_more() {
    let rev = "0123456789abcdef0123456789abcdef01234567";
    let names = |list: &[&str]| list.iter().map(|n| (*n).to_owned()).collect::<Vec<_>>();
    assert_eq!(checkout_names(rev, &names(&["0123456"])), ["0123456"]);
    assert_eq!(checkout_names(rev, &names(&["0123456789"])), ["0123456789"]);
    assert_eq!(checkout_names(rev, &names(&["fedcba9"])), [] as [&str; 0]);
    assert_eq!(checkout_names(rev, &names(&["012345"])), [] as [&str; 0]);
    assert_eq!(
        checkout_names(rev, &names(&["0123456", "0123456789", "other"])),
        ["0123456", "0123456789"]
    );
}

/// The keys crate's vector for its device test seed
/// (`crates/keys/tests/vectors/device.json`), read from cargo's checkout of
/// core at `CORE_REV`, so that a move of `CORE_REV` that changes the vector
/// fails here. Cargo checks a git dependency out under
/// `$CARGO_HOME/git/checkouts/<name>-<hash>/<abbreviated rev>/`
/// (`CARGO_HOME` defaulting to `~/.cargo`), and the build of this crate put
/// it there. (`cargo metadata --offline` cannot be asked instead: it needs
/// every package of the lockfile, the other platforms' among them, which a
/// build for one host never downloads.)
fn device_vector() -> Value {
    let manifest = include_str!("../Cargo.toml");
    let rev = manifest
        .split("rev = \"")
        .nth(1)
        .unwrap()
        .split('"')
        .next()
        .unwrap();
    assert_eq!(rev.len(), 40, "mobile/Cargo.toml's rev is a full commit");
    let home = std::env::var_os("CARGO_HOME").map_or_else(
        || std::path::PathBuf::from(std::env::var_os("HOME").unwrap()).join(".cargo"),
        std::path::PathBuf::from,
    );
    let checkouts = home.join("git").join("checkouts");
    let vectors: Vec<_> = std::fs::read_dir(&checkouts)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|dir| {
            dir.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("core-"))
        })
        .flat_map(|dir| {
            let names: Vec<String> = std::fs::read_dir(&dir)
                .unwrap()
                .filter_map(|entry| entry.unwrap().file_name().into_string().ok())
                .collect();
            checkout_names(rev, &names)
                .into_iter()
                .map(|name| dir.join(name).join("crates/keys/tests/vectors/device.json"))
                .collect::<Vec<_>>()
        })
        .filter(|path| path.is_file())
        .collect();
    assert_eq!(
        vectors.len(),
        1,
        "one checkout of core at {rev} under {}: {vectors:?}",
        checkouts.display()
    );
    json(&std::fs::read_to_string(&vectors[0]).unwrap())
}

#[test]
fn peer_id_of_the_test_seed_is_the_keys_vector() {
    let vector = device_vector();
    assert_eq!(hex(&DEVICE_SEED), vector["device_seed"].as_str().unwrap());
    assert_eq!(
        peer_id_text().unwrap(),
        vector["libp2p_peer_id_text"].as_str().unwrap()
    );
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::new(), |mut text, b| {
        write!(text, "{b:02x}").unwrap();
        text
    })
}

/// The navigation guard: only the app's own origin on each platform, with no
/// port, and not the other platform's.
#[test]
fn navigation_stays_on_the_app_origin() {
    use Platform::{Android, Ios};
    assert!(navigation_allowed(
        Android,
        "http",
        Some("tauri.localhost"),
        None
    ));
    assert!(navigation_allowed(Ios, "tauri", Some("localhost"), None));
    for (platform, scheme, host, port) in [
        (Android, "tauri", Some("localhost"), None),
        (Ios, "http", Some("tauri.localhost"), None),
        (Android, "http", Some("tauri.localhost"), Some(8080)),
        (Ios, "tauri", Some("localhost"), Some(1)),
        (Android, "https", Some("tauri.localhost"), None),
        (Android, "http", Some("localhost"), None),
        (Android, "http", Some("tauri.localhost.example"), None),
        (Android, "https", Some("remote.example"), None),
        (Android, "http", Some("ipc.localhost"), None),
        (Ios, "ipc", Some("localhost"), None),
        (Android, "file", None, None),
        (Android, "data", None, None),
        (Ios, "javascript", None, None),
    ] {
        assert!(
            !navigation_allowed(platform, scheme, host, port),
            "{platform:?} {scheme} {host:?} {port:?}"
        );
    }
}

#[test]
fn the_two_loopback_identities_differ() {
    assert_ne!(DEVICE_SEED, OTHER_SEED);
}

#[tokio::test(flavor = "multi_thread")]
async fn quic_loopback_connects_on_the_host() {
    let result = quic_loopback().await;
    assert_eq!(loopback_text(&result), "ok");
}

#[test]
fn loopback_text_says_why_it_failed() {
    assert_eq!(loopback_text(&Ok(())), "ok");
    assert_eq!(
        loopback_text(&Err(LoopbackError::TimedOut)),
        format!("failed: not connected within {LOOPBACK_DEADLINE:?}")
    );
}

/// TM-27: the isolation pattern, a CSP of `default-src 'self'` and nothing
/// else, the prototype frozen, the one capability, no global Tauri object;
/// TM-29: no plugin (so no updater), no remote URL, no development server.
#[test]
fn tauri_conf_keeps_the_security_settings() {
    let conf = json(TAURI_CONF);
    let security = &conf["app"]["security"];
    assert_eq!(security["csp"], "default-src 'self'");
    assert_eq!(security["pattern"]["use"], "isolation");
    assert_eq!(security["pattern"]["options"]["dir"], "../isolation");
    assert_eq!(security["freezePrototype"], true);
    assert_eq!(security["capabilities"], serde_json::json!(["status"]));
    let keys: Vec<&String> = security.as_object().unwrap().keys().collect();
    assert_eq!(keys, ["capabilities", "csp", "freezePrototype", "pattern"]);
    assert_eq!(conf["app"].get("withGlobalTauri"), None);
    assert_eq!(conf.get("plugins"), None);
    assert_eq!(conf["build"].as_object().unwrap().len(), 1);
    assert_eq!(conf["build"]["frontendDist"], "../ui");
    assert!(!TAURI_CONF.contains("http"), "no URL in tauri.conf.json");
}

/// The iOS link needs `SystemConfiguration`: if-watch, beneath net's QUIC and
/// TCP transports, calls it on Apple platforms, and Rust's static library
/// does not carry that framework to Xcode's link (app CI's first iOS run
/// failed on 37 undefined `SC*` symbols).
#[test]
fn ios_links_system_configuration_for_if_watch() {
    let conf = json(TAURI_CONF);
    assert_eq!(
        conf["bundle"]["iOS"]["frameworks"],
        serde_json::json!(["SystemConfiguration"])
    );
}

/// TM-27: one capability, for the one window, holding only the one command.
#[test]
fn the_one_capability_allows_only_status() {
    let capability = json(CAPABILITY);
    assert_eq!(capability["identifier"], "status");
    assert_eq!(capability["windows"], serde_json::json!(["main"]));
    assert_eq!(
        capability["permissions"],
        serde_json::json!(["allow-status"])
    );
    assert_eq!(capability.get("remote"), None);
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/capabilities");
    let files: Vec<_> = std::fs::read_dir(dir).unwrap().collect();
    assert_eq!(files.len(), 1, "one capability file");
}

/// TM-20: the page writes what the shell returns as text only, and has no
/// inline script; TM-31: it references nothing outside the app.
#[test]
fn the_page_writes_text_only_and_loads_nothing_remote() {
    for markup_sink in [
        "innerHTML",
        "outerHTML",
        "insertAdjacentHTML",
        "document.write",
        "eval(",
    ] {
        assert!(!PAGE_JS.contains(markup_sink), "main.js uses {markup_sink}");
        assert!(
            !ISOLATION_JS.contains(markup_sink),
            "isolation uses {markup_sink}"
        );
    }
    assert!(PAGE_JS.contains(".textContent = "));
    for html in [PAGE_HTML, ISOLATION_HTML] {
        assert!(!html.contains("<script>"), "an inline script");
        assert!(!html.contains("style="), "an inline style");
        for attribute in ["src=\"", "href=\""] {
            for rest in html.split(attribute).skip(1) {
                let value = rest.split('"').next().unwrap();
                assert!(
                    !value.contains(':') && !value.starts_with("//"),
                    "{value} is not the app's"
                );
            }
        }
    }
    assert!(
        !PAGE_CSS.contains("url(") && !PAGE_CSS.contains("@import"),
        "style.css loads something"
    );
    assert!(
        PAGE_CSS.contains("#__tauri_isolation__ {\n  display: none;"),
        "the isolation frame shows"
    );
}

/// C3: the Android manifest as written asks for one permission, INTERNET (a
/// socket, even on loopback, needs it), backs nothing up and transfers
/// nothing to another device, removes emoji2's initializer, which fetches a
/// font from Google, and turns off the `WebView`'s Safe Browsing lookups and
/// metrics, which contact Google (TM-31). `ci/check-manifest.sh` checks the
/// merged manifest of the built APK, with what the libraries add.
#[test]
fn android_manifest_keeps_the_security_settings() {
    let permissions: Vec<&str> = ANDROID_MANIFEST
        .split("<uses-permission")
        .skip(1)
        .map(|rest| rest.split("/>").next().unwrap().trim())
        .collect();
    assert_eq!(
        permissions,
        [r#"android:name="android.permission.INTERNET""#]
    );
    for setting in [
        r#"android:allowBackup="false""#,
        r#"android:dataExtractionRules="@xml/data_extraction_rules""#,
        r#"android:usesCleartextTraffic="false""#,
        r#"android:name="android.webkit.WebView.EnableSafeBrowsing"
            android:value="false""#,
        r#"android:name="android.webkit.WebView.MetricsOptOut"
            android:value="true""#,
        r#"android:name="androidx.emoji2.text.EmojiCompatInitializer"
                tools:node="remove""#,
    ] {
        assert!(ANDROID_MANIFEST.contains(setting), "missing {setting}");
    }
    for domain in [
        "root",
        "file",
        "database",
        "sharedpref",
        "external",
        "device_root",
        "device_file",
        "device_database",
        "device_sharedpref",
    ] {
        let exclude = format!(r#"<exclude domain="{domain}" "#);
        assert_eq!(DATA_RULES.matches(&exclude).count(), 2, "{domain}");
    }
    // Every rule excludes the whole domain, and the file holds nothing but
    // exclusions.
    assert_eq!(DATA_RULES.matches(r#"="." />"#).count(), 18);
    let elements: std::collections::BTreeSet<&str> = DATA_RULES
        .split('<')
        .skip(1)
        .filter_map(|rest| rest.split([' ', '>', '/']).next())
        .filter(|name| !name.is_empty() && !name.starts_with(['?', '!']))
        .collect();
    assert_eq!(
        elements,
        [
            "cloud-backup",
            "data-extraction-rules",
            "device-transfer",
            "exclude"
        ]
        .into_iter()
        .collect()
    );
}
