// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The Tauri app: the page in `ui/`, served from the app itself, and the one
//! command it may call (TM-27).
//!
//! `#[tauri::mobile_entry_point]` writes the entry points the platform calls:
//! on Android the JNI functions of Tauri's, wry's and tao's `android_binding!`
//! macros, on iOS `start_app`: C-ABI exports under unmangled names, code
//! outside Rust's safety checks. `forbid(unsafe_code)` does not see them,
//! since rustc lints nothing another crate's macro expands, and neither do
//! the project's text rules, which read only this crate's source (core's
//! TM-7): they are Tauri's code, reviewed with it (TM-8). This crate writes
//! no foreign-function code of its own.

/// What the `status` command returns; the page writes each field as text
/// (TM-20).
#[derive(serde::Serialize)]
struct Status {
    /// The peer ID of the keys crate's device test seed.
    peer_id: String,
    /// `ok`, or why the QUIC loopback check failed.
    quic_loopback: String,
}

/// The page's one command.
#[tauri::command]
async fn status() -> Status {
    let peer_id = crate::peer_id_text().unwrap_or_else(|e| format!("error: {e}"));
    let quic_loopback = crate::loopback_text(&crate::quic_loopback().await);
    Status {
        peer_id,
        quic_loopback,
    }
}

/// Runs the app; the generated Android and iOS entry points call this.
#[tauri::mobile_entry_point]
fn run() {
    // The navigation guard: the page stays on the app's own origin.
    #[cfg(target_os = "android")]
    let platform = crate::Platform::Android;
    #[cfg(target_os = "ios")]
    let platform = crate::Platform::Ios;
    let guard = tauri::plugin::Builder::<tauri::Wry>::new("navigation-guard")
        .on_navigation(move |_, url| {
            crate::navigation_allowed(platform, url.scheme(), url.host_str(), url.port())
        })
        .build();
    let result = tauri::Builder::default()
        .plugin(guard)
        .invoke_handler(tauri::generate_handler![status])
        .run(tauri::generate_context!());
    if let Err(e) = result {
        // There is no window to show it in; Tauri sends stderr to the
        // system log (logcat on Android).
        #[allow(clippy::print_stderr, reason = "the one place left to report it")]
        {
            eprintln!("LicketySync could not start: {e}");
        }
    }
}
