// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Asks the shell for its one command, `status`, and writes what comes back
// as text only (TM-20): `textContent`, never markup.
"use strict";

function show(id, text) {
  document.getElementById(id).textContent = text;
}

window.__TAURI_INTERNALS__
  .invoke("status")
  .then((status) => {
    show("peer-id", status.peer_id);
    show("quic-loopback", status.quic_loopback);
  })
  .catch((error) => {
    show("quic-loopback", `error: ${error}`);
  });
