// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Tauri's build step, for the phones only (the crate's docs say why). The
//! app's one command, `status`, is declared here, so that Tauri generates its
//! permission (`allow-status`) and refuses every app command that no
//! capability allows (TM-27).

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let os = std::env::var("CARGO_CFG_TARGET_OS")?;
    if os == "android" || os == "ios" {
        tauri_build::try_build(
            tauri_build::Attributes::new()
                .app_manifest(tauri_build::AppManifest::new().commands(&["status"])),
        )?;
    }
    Ok(())
}
