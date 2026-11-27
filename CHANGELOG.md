# Changelog

All notable changes to the LicketySync app are recorded here. Each entry says
what changed and why.

## Unreleased

- Dependencies: the daily audit failed on two advisories, fixed by updating `Cargo.lock`. RUSTSEC-2026-0592: `url` 2.5.8 and earlier overflow the stack in `Url::origin()` on nested `blob:` URLs (fixed in 2.5.9; `url` is beneath `multiaddr`, `reqwest`, `tauri` and others; `form_urlencoded` 1.2.3 comes with it). RUSTSEC-2026-0594: `cookie` 0.18.2 and earlier can repeat private-cookie nonces in a process that forks (fixed in 0.18.3; `cookie` is beneath `tauri`, `tauri-runtime` and `wry`). No built code calls `Url::origin`, `url::quirks::origin`, or the private jar's `add` or `add_original`, so neither flaw was reachable. cargo-vet: the `url` and `cookie` exemptions move to the new versions, and `form_urlencoded` 1.2.3, which the imported audits do not yet cover, gets one.
- cargo-vet: 79 exemption notes said the crate was the desktop back end's, "never built for the phones". None is built for any target: 57 are Tauri's
  Linux, macOS and Windows dependencies, which the app depends on for Android and iOS only; 9 are jni's Windows-only dependencies; 12 are in `Cargo.lock` only
  (optional dependencies of serde_with, chrono and flate2); 1 is reqwest's wasm32 dependency. Each note now says so; notes only, and cargo-vet ignores them.
- CI: the daily audit failed on RUSTSEC-2026-0543, new in the advisory database: chrono is
  unmaintained (every version; no fix). chrono is in `Cargo.lock` but never built: it is
  serde_with's optional `chrono_0_4` (serde_with is beneath `tauri-utils`), which serde_with's
  `std` and `alloc` features name only as weak dependency features (`chrono_0_4?/std`) and nothing
  turns on, and cargo locks such a dependency all the same (rust-lang/cargo#10801). cargo-audit,
  which reads the lockfile, reports it; cargo-deny, which resolves features, does not. No release of
  serde_with or `tauri-utils` drops it. `.cargo/audit.toml` now ignores the advisory; `deny.toml`
  does not, so that cargo-deny stays a second alarm should chrono ever be built for its targets.
  `ci/check-chrono.sh`, in the gate and CI, keeps the ignore from hiding a real dependency: it fails
  if any locked chrono is built for any target, with every feature of every workspace member on, as
  a normal, build or dev dependency; if cargo cannot answer with the lockfile as it is, or the
  lockfile cannot be read; and once chrono leaves `Cargo.lock`, so that the ignore goes with it.
  `ci/test-check-chrono.sh` tests it, a case for each. chrono's cargo-vet exemption no longer calls
  it the desktop back end's.
- CI: two test fixes. The peer ID test finds cargo's checkout of core by any directory name that is
  at least 7 leading digits of `CORE_REV`, not only the first 7, since cargo's abbreviation length
  is not stable; it still requires exactly one match. `ci/test-check-pins.sh` checked the count of
  its whole file list, which the four fixed files keep at 4 or more, so its "no workflow" guard
  never fired; it now checks the workflow glob alone, and a test shows the guard failing on a tree
  without workflows.
- Docs: the README describes the phone shell as the foundation the shells proper (desktop in phase
  3, phones in phase 4) build on, not as a spike in progress.
- CI: the fixes the first runs on main called for.
  - The peer ID test read core's vector through `cargo metadata --offline`, which needs every
    package of the lockfile, the other platforms' among them, where a build for one host downloads
    only its own, so it failed on a fresh runner. It now reads the vector from cargo's checkout of
    core at `CORE_REV`, under `$CARGO_HOME/git/checkouts/`, and still fails when a move of
    `CORE_REV` changes the vector.
  - Gradle's dependency verification refused `kotlinx-coroutines-bom-1.8.0.pom`: the metadata had
    been recorded from a warm Gradle cache, which never fetched nine BOM and parent POM files a
    fresh one does. It is now recorded from an empty Gradle home, and a build from another empty one
    passes it; the nine match Maven Central's published checksums.
  - The iOS link failed on SystemConfiguration's symbols: if-watch, beneath net's QUIC and TCP
    transports, calls it on Apple platforms, and a Rust static library does not carry the framework
    to Xcode's link. `tauri.conf.json` names it (`bundle.iOS.frameworks`), and a test holds it
    there.
  - The emulator evidence's upload is skipped when an earlier step failed before the emulator ran.
  - The emulator did not start: android-emulator-runner installs `platforms;android-<api-level>`,
    and the job passed the platform number, 37, where the SDK names the level `android-37.0` (it
    has 37.0, 37.1 and 37.2, no 37). `ci/pins.env` now pins the emulator's level as the SDK names
    it (`ANDROID_API_LEVEL`), which the runner uses for the platform and the system image alike, and
    `ci/check-pins.sh` refuses any other source for it.
- The phone shell (phase 0's spike C): `mobile/`, a Tauri 2 app for Android and iOS that shows the
  page in `ui/` and links the core crates `licketysync-keys` and `licketysync-net`, a git dependency
  on the public core repository pinned by rev to `CORE_REV` (`ci/pins.env`). The page shows
  "LicketySync", the peer ID the keys crate gives its public device test seed, and whether two
  swarms of the net crate connect over QUIC on the phone's own loopback ("QUIC loopback: ok"), which
  proves the transport and aws-lc-rs on Android. On iOS the net crate builds no swarm yet (no
  process-memory limit there), so the page reports the check as failed: there it is compile-only.
  - The page is static HTML with one script, not Leptos yet: a WebAssembly page needs
    `'wasm-unsafe-eval'` in the content security policy, and Leptos would bring trunk's
    wasm-bindgen download and over a hundred more crates to vet, for a page of three lines.
  - The shell's security settings (TM-20, TM-27, TM-29, TM-31). The boundary is the capability: one,
    for the one window, holding only the `status` command, which the build script declares so that
    Tauri refuses every other app command. Tauri's isolation pattern is defence in depth: its hook
    passes only `status`, but Tauri encrypts a message's arguments and not its command name, so a
    script in the page could resend an encrypted message under another name; the capability still
    refuses it. Also: a content security policy of `default-src 'self'`; the prototype frozen; a
    navigation guard that keeps the page on the app's own origin; Tauri's `custom-protocol` feature,
    so that every build, debug included, serves the page from the app as a release does; no plugin
    but that guard, so no updater; the page writes what the shell returns with `textContent` only.
    The page's own stylesheet hides Tauri's isolation frame, since the policy refuses the inline
    style Tauri hides it with.
  - The Android manifest asks for one permission, INTERNET (a socket needs it even on loopback),
    allows no cleartext traffic, drops the template's file provider, turns off the WebView's Safe
    Browsing lookups and metrics, and backs nothing up: `allowBackup` is off and the data extraction
    rules exclude every domain from cloud backup and from device-to-device transfer, which
    `allowBackup` no longer stops from Android 12 on. emoji2's initializer, which appcompat brings
    and which asks Google Play services for an emoji font, is removed. `ci/check-manifest.sh` holds
    each built APK's merged manifest to the permissions, components, exported flags, element kinds,
    attributes and meta-data (by parent) allowed (`ci/test-check-manifest.sh` tests it); unit tests
    read the manifest, the configuration, the capability and the page.
  - What still reaches a host, found with networking on (`ci/emulator-check.sh --network`): each
    time the WebView starts it asks Google Play services' font provider for its fonts ("Google Sans"
    at weights 400, 500 and 700, "Google Sans Flex", "Noto Color Emoji Compat"); Google Play
    services downloads any it lacks from fonts.gstatic.com (about 3 MB on a fresh device) and counts
    the bytes against the app. The page's own fonts are not the trigger, and nothing found in the
    app turns it off. CI's emulator check therefore runs in airplane mode, where the loopback check
    passes.
  - Tauri builds here for Android and iOS only: its desktop back ends need GTK and WebKitGTK. On
    the host the crate holds the functions behind the command, and its tests run there.
  - `forbid(unsafe_code)` holds for the crate's own code; the entry points Tauri's
    `mobile_entry_point` macro writes (JNI on Android, `start_app` on iOS) are foreign-function
    code that neither rustc's lint nor the project's text rules see, since another crate's macro
    expands them.
  - Tauri brings cryptography of its own, which `deny.toml` confines to it: AES-256-GCM in
    `tauri-utils` (the isolation pattern's message arguments, under a key drawn when the app
    starts) and SHA-256 in `tauri-codegen` and `wry` (the content security policy's hashes). Tauri
    on the phones also depends on reqwest, without TLS, for a development-server proxy that
    `custom-protocol` compiles out: compiled, not linked.
  - Cargo.lock starts from core's, so that the crates both share keep core's reviewed versions; the
    rest are each the newest release out for 7 days. `deny.toml` covers the phones and CI's hosts;
    cargo-audit denies warnings but three listed in `.cargo/audit.toml` (paste, unmaintained, as in
    core; proc-macro-error and glib, beneath Tauri's Linux desktop back end, which never builds).
    `supply-chain/` is core's with an exemption for each crate Tauri adds, each noted as runtime on
    the phones, on the IPC path, build-time only, desktop only, or the base of an imported delta.
  - `mobile/gen/android` is the project `cargo tauri android init` generates, with the manifest
    above, Gradle 9.9.0 and its own wrapper jar (the distribution's SHA-256 set), the Android Gradle
    plugin 9.5.1, Kotlin 2.4.21, androidx webkit 1.18.0, appcompat 1.8.0, activity-ktx 1.13.0,
    lifecycle-process 2.11.0 and material 1.14.0, and no test dependencies. Gradle's dependency
    verification is on: `gradle/verification-metadata.xml` holds the SHA-256 of each artifact as
    first downloaded (trust on first use, signatures not checked). Cross-checked once against the
    repositories' published checksum files: 740 of 767 artifacts match (Google Maven and Maven
    Central's `.sha256`, or their `.sha1` against the downloaded file), none differs. 27 could not
    be cross-checked and stay trust-on-first-use: Kotlin Multiplatform metadata jars, AARs published
    under another name than the one Gradle gives them, and gradle-kotlin-dsl-plugins. PGP
    verification for Maven Central is not on: it needs a reviewed keyring of each publisher's key.
    Still to come: an advisory feed for the Gradle components (GitHub's dependency graph submission
    or osv-scanner).
- The app's gate and CI. `gate.sh` runs core's checks but coverage, mutants, fuzzing and the
  simulator: the pins first (`ci/check-pins.sh`: `ci/pins.env` well formed, no copy of a pin in any
  workflow, which reads them all from `ci/pins.env` at run time, and every rev, compileSdk and
  targetSdk equal to its pin, each occurrence compared; a rev on every git dependency; the pins
  exported once in every job; iOS's rustup override exactly `"$RUST_STABLE"`;
  `ci/test-check-pins.sh` tests it), then fmt, clippy pedantic with `-D warnings` on the host and
  for Android, the tests, rustdoc, cargo-deny, cargo-audit, cargo-machete, cargo-vet, cargo-udeps,
  typos, core's Semgrep project rules and no-hostnames check over the app, gitleaks over the history
  and the working tree, core's check that every action is pinned by commit, and the CI scripts'
  tests. `gate.sh` says why cargo-geiger, the dep-info check and core's build-script rule do not
  apply yet. CI: `checks`, `android` (clippy for Android, both debug APKs and their merged
  manifests, and the x86_64 one on an emulator of the pinned build, API level and system image
  revision), `ios` (an unsigned simulator build with Rust pinned for Xcode's build phase too, the
  generated entitlements and Info.plist printed and uploaded; then, not blocking, a simulator
  screenshot), and `audit`, which runs cargo-audit every day. The `android` job accepts the Android
  SDK's licence on the runner. Dependabot updates cargo (not the core crates), Gradle and GitHub
  Actions with a 7-day cooldown.
