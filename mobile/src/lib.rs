// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The phone shell of LicketySync: a Tauri 2 app for Android and iOS that
//! shows the page in `ui/` and links the core crates (phase 0's spike C).
//!
//! The page asks the shell one thing, the `status` command: the peer ID the
//! keys crate gives the public test seed, and whether two swarms of the net
//! crate connect over QUIC on the phone's own loopback. That command stands
//! in for the local API and is not the design (TM-21): the plan's UI talks
//! only to the service's local API.
//!
//! The Tauri crates build here for Android and iOS only, so on any other
//! target this crate holds just the functions behind the command, which the
//! tests run on the host.

use core::fmt;
use core::time::Duration;

use futures::StreamExt as _;
use futures::future::{self, Either};
use libp2p_core::Multiaddr;
use libp2p_core::multiaddr::Protocol;
use libp2p_core::transport::TransportError;
use libp2p_swarm::{DialError, ListenError, SwarmEvent};
use licketysync_keys::device::Libp2pIdentity;
use licketysync_keys::secret::DeviceSeed;
use licketysync_net::identity;
use licketysync_net::limits::Limits;
use licketysync_net::node::{self, BuildError, Swarm};

#[cfg(any(target_os = "android", target_os = "ios"))]
mod shell;

/// The keys crate's device test seed, `a0 a1 … bf`
/// (`crates/keys/tests/vectors/device.json`): public, never a real key
/// (TM-6).
const DEVICE_SEED: [u8; 32] = [
    0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf,
    0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf,
];

/// The seed of the loopback check's other swarm, `c0 c1 … df`: public too.
const OTHER_SEED: [u8; 32] = [
    0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf,
    0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf,
];

/// How long the loopback check may take before it reports failure.
pub const LOOPBACK_DEADLINE: Duration = Duration::from_secs(30);

/// The peer ID of the keys crate's device test seed, as text
/// (`12D3KooW…`).
///
/// # Errors
///
/// What [`identity::peer_id`] returns, as text: never, for a key the keys
/// crate derived.
pub fn peer_id_text() -> Result<String, String> {
    let identity = Libp2pIdentity::from_device_seed(&DeviceSeed::from_bytes(DEVICE_SEED));
    match identity::peer_id(&identity) {
        Ok(peer) => Ok(peer.to_base58()),
        Err(e) => Err(e.to_string()),
    }
}

/// A platform the shell runs on, for the navigation guard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    /// Android, where Tauri serves the page from `http://tauri.localhost`.
    Android,
    /// iOS, where Tauri serves it from `tauri://localhost`.
    Ios,
}

impl Platform {
    /// The scheme and host of the app's own origin on this platform.
    #[must_use]
    pub fn origin(self) -> (&'static str, &'static str) {
        match self {
            Self::Android => ("http", "tauri.localhost"),
            Self::Ios => ("tauri", "localhost"),
        }
    }
}

/// Whether the page may navigate to a URL of this scheme, host and explicit
/// port: only to the app's own origin on `platform`, with no port. Tauri lets
/// the isolation frame load before it asks.
#[must_use]
pub fn navigation_allowed(
    platform: Platform,
    scheme: &str,
    host: Option<&str>,
    port: Option<u16>,
) -> bool {
    let (own_scheme, own_host) = platform.origin();
    scheme == own_scheme && host == Some(own_host) && port.is_none()
}

/// Why the loopback check failed.
#[derive(Debug)]
#[non_exhaustive]
pub enum LoopbackError {
    /// A swarm was not built (on iOS, always: `net` has no process-memory
    /// limit there yet, TM-22's residual (d)).
    Build(BuildError),
    /// A swarm could not listen on 127.0.0.1.
    Listen(Box<TransportError<std::io::Error>>),
    /// The dial was refused before it started, or failed.
    Dial(Box<DialError>),
    /// The listener refused the connection.
    Incoming(Box<ListenError>),
    /// A swarm stopped listening before it reported its address.
    ListenerClosed,
    /// The two swarms were not connected within [`LOOPBACK_DEADLINE`].
    TimedOut,
}

impl fmt::Display for LoopbackError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Build(e) => write!(f, "no swarm: {e}"),
            Self::Listen(e) => write!(f, "no listener on 127.0.0.1: {e}"),
            Self::Dial(e) => write!(f, "the dial failed: {e}"),
            Self::Incoming(e) => write!(f, "the listener refused the connection: {e}"),
            Self::ListenerClosed => write!(f, "a listener closed before it had an address"),
            Self::TimedOut => write!(f, "not connected within {LOOPBACK_DEADLINE:?}"),
        }
    }
}

impl std::error::Error for LoopbackError {}

/// Two swarms of the net crate, each with a public test identity, connect
/// over QUIC on 127.0.0.1: one listens, the other listens too (so that its
/// dial leaves from a loopback socket, as `net`'s node module explains) and
/// dials the first, naming the peer ID it expects. Done when each side
/// reports the connection to the other. Nothing leaves the device (TM-31).
/// Must run inside a Tokio runtime with time enabled.
///
/// # Errors
///
/// [`LoopbackError`]: a swarm was not built, could not listen, or the dial
/// failed, was refused, or did not finish within [`LOOPBACK_DEADLINE`].
pub async fn quic_loopback() -> Result<(), LoopbackError> {
    tokio::time::timeout(LOOPBACK_DEADLINE, connect())
        .await
        .unwrap_or(Err(LoopbackError::TimedOut))
}

async fn connect() -> Result<(), LoopbackError> {
    let limits = Limits::default();
    let mut listener = swarm_of(DEVICE_SEED, &limits)?;
    let mut dialer = swarm_of(OTHER_SEED, &limits)?;
    let address = listening(&mut listener).await?;
    listening(&mut dialer).await?;
    let listener_peer = *listener.local_peer_id();
    let dialer_peer = *dialer.local_peer_id();
    dialer
        .dial(
            node::dial_opts::DialOpts::peer_id(listener_peer)
                .addresses(vec![address])
                .build(),
        )
        .map_err(|e| LoopbackError::Dial(Box::new(e)))?;
    let (mut listener_sees_dialer, mut dialer_sees_listener) = (false, false);
    while !(listener_sees_dialer && dialer_sees_listener) {
        match future::select(listener.select_next_some(), dialer.select_next_some()).await {
            Either::Left((event, _)) => match event {
                SwarmEvent::ConnectionEstablished { peer_id, .. } if peer_id == dialer_peer => {
                    listener_sees_dialer = true;
                }
                SwarmEvent::IncomingConnectionError { error, .. } => {
                    return Err(LoopbackError::Incoming(Box::new(error)));
                }
                _ => {}
            },
            Either::Right((event, _)) => match event {
                SwarmEvent::ConnectionEstablished { peer_id, .. } if peer_id == listener_peer => {
                    dialer_sees_listener = true;
                }
                SwarmEvent::OutgoingConnectionError { error, .. } => {
                    return Err(LoopbackError::Dial(Box::new(error)));
                }
                _ => {}
            },
        }
    }
    Ok(())
}

fn swarm_of(seed: [u8; 32], limits: &Limits) -> Result<Swarm, LoopbackError> {
    let identity = Libp2pIdentity::from_device_seed(&DeviceSeed::from_bytes(seed));
    node::build(&identity, limits).map_err(LoopbackError::Build)
}

/// Listens on QUIC on 127.0.0.1 (a port the system picks) and returns the
/// address once the swarm reports it.
async fn listening(swarm: &mut Swarm) -> Result<Multiaddr, LoopbackError> {
    let loopback = Multiaddr::empty()
        .with(Protocol::Ip4(core::net::Ipv4Addr::LOCALHOST))
        .with(Protocol::Udp(0))
        .with(Protocol::QuicV1);
    swarm
        .listen_on(loopback)
        .map_err(|e| LoopbackError::Listen(Box::new(e)))?;
    loop {
        match swarm.select_next_some().await {
            SwarmEvent::NewListenAddr { address, .. } => return Ok(address),
            SwarmEvent::ListenerClosed { .. } | SwarmEvent::ListenerError { .. } => {
                return Err(LoopbackError::ListenerClosed);
            }
            _ => {}
        }
    }
}

/// What the page shows for the loopback check: `ok`, or why it failed.
#[must_use]
pub fn loopback_text(result: &Result<(), LoopbackError>) -> String {
    match result {
        Ok(()) => "ok".to_owned(),
        Err(e) => format!("failed: {e}"),
    }
}

#[cfg(test)]
mod tests;
