# LicketySync — app

The shared web UI (Rust, compiled to WebAssembly) and the Tauri 2 shells for
Windows, macOS, Linux, Android and iOS. One interface everywhere; the shell owns
what the platform owns (tray, notifications, file dialogs, safe areas), the page
uses the system font, accent colour and light or dark setting.

Arrives in phase 3 (desktop) and phase 4 (phones). The same UI bundle is the
browser client published from the `web` repository.

Planned layout:

```
ui/        Leptos crate: the interface, built to WebAssembly with trunk
desktop/   Tauri 2 project for Windows, macOS, Linux
mobile/    Tauri 2 mobile project with the Kotlin and Swift plugins
e2e/       Playwright tests against the UI in its shell
```

Depends on `licketysync-*` crates from the `core` repository. MPL-2.0.
