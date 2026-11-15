// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The isolation pattern's hook (TM-27), defence in depth. A message the page
// sends the shell through Tauri's API passes through here, in a sandboxed
// frame of its own, before Tauri encrypts its arguments for the shell; this
// hook passes only the one command the page uses. It is not the boundary:
// Tauri encrypts the arguments but not the command name, so a script in the
// page can resend an encrypted message under another name. The boundary is
// the capability (mobile/capabilities/status.json), which allows only
// `status`, and the shell refuses every other command.
"use strict";

window.__TAURI_ISOLATION_HOOK__ = (message) => {
  if (message.cmd !== "status") {
    throw new Error("the shell answers only status");
  }
  return message;
};
