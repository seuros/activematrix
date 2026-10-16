//! A fake Matrix homeserver for tests.
//!
//! It serves the client-server endpoints activematrixd uses, over real HTTP
//! on 127.0.0.1, with:
//!
//! - **scripted sync**: tests queue sync batches per user; `/sync` long-polls
//!   until one arrives or the client's timeout passes;
//! - **transaction-id dedup**: a repeated `PUT .../send/{type}/{txn}` returns
//!   the first event id and records nothing new, as Synapse does;
//! - **fault injection**: the next matching request answers with a chosen
//!   status (429 with `Retry-After`, 500, 401 `M_UNKNOWN_TOKEN`, ...);
//! - **a request log** for assertions.
//!
//! Rust tests use [`FakeHomeserver`] directly. The `activematrix-fakehs`
//! binary serves the same thing plus an admin API under `/_fake/` for tests
//! written in other languages.

mod server;
mod state;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use rama::graceful::Shutdown;
use rama::http::server::HttpServer;
use rama::rt::Executor;
use rama::service::service_fn;
use rama::tcp::server::TcpListener;
use serde_json::Value;
use tokio::sync::oneshot;

pub use state::{Fault, Recorded, Sent};

use state::Shared;

pub const SERVER_NAME: &str = "matrix.test";

/// A running fake homeserver. Dropping it stops the server.
pub struct FakeHomeserver {
    addr: SocketAddr,
    shared: Arc<Shared>,
    stop: Option<oneshot::Sender<()>>,
}

impl FakeHomeserver {
    /// Starts on an ephemeral port of 127.0.0.1.
    pub async fn start() -> anyhow::Result<Self> {
        Self::start_on("127.0.0.1:0".parse()?).await
    }

    pub async fn start_on(addr: SocketAddr) -> anyhow::Result<Self> {
        let shared = Arc::new(Shared::default());
        let (stop, stopped) = oneshot::channel::<()>();
        let graceful = Shutdown::new(async move {
            // A dropped sender also means stop.
            let _ = stopped.await;
        });
        let executor = Executor::graceful(graceful.guard());
        let listener = TcpListener::bind_address(addr, executor.clone())
            .await
            .map_err(|e| anyhow::anyhow!(e))?;
        let addr = listener.local_addr()?;

        let app_state = Arc::clone(&shared);
        let app = service_fn(move |request| server::handle(Arc::clone(&app_state), request));
        tokio::spawn(async move {
            listener.serve(HttpServer::auto(executor).service(app)).await;
        });
        tokio::spawn(async move {
            // The limit only bounds open long-polls at shutdown.
            let _ = graceful.shutdown_with_limit(Duration::from_secs(5)).await;
        });
        Ok(Self { addr, shared, stop: Some(stop) })
    }

    pub fn url(&self) -> String {
        format!("http://{}", self.addr)
    }

    pub const fn addr(&self) -> SocketAddr {
        self.addr
    }

    /// Registers a user and returns the access token it can use right away.
    /// `password` enables `/login` for it.
    pub fn add_user(&self, localpart: &str, password: Option<&str>) -> String {
        self.shared.add_user(localpart, password)
    }

    /// Queues one sync response body for `user_id` (the server adds
    /// `next_batch`). Wakes a waiting long-poll.
    pub fn push_sync(&self, user_id: &str, batch: Value) {
        self.shared.push_sync(user_id, batch);
    }

    /// Answers the next request whose path starts with `path_prefix` (and
    /// method matches, when given) with `fault` instead of handling it.
    pub fn inject(&self, method: Option<&str>, path_prefix: &str, fault: Fault) {
        self.shared.inject(method, path_prefix, fault);
    }

    /// Makes `token` unknown: later requests with it get 401 M_UNKNOWN_TOKEN.
    pub fn revoke(&self, token: &str) {
        self.shared.revoke(token);
    }

    /// Message and state events the server accepted, in order.
    pub fn sent(&self) -> Vec<Sent> {
        self.shared.sent()
    }

    /// Every request the server saw, in order.
    pub fn requests(&self) -> Vec<Recorded> {
        self.shared.requests()
    }

    /// The `since` token of `user_id`'s latest `/sync`, if any.
    pub fn last_since(&self, user_id: &str) -> Option<String> {
        self.shared.last_since(user_id)
    }

    /// Waits until `predicate` holds for the sent events, or panics after
    /// `timeout`.
    pub async fn wait_for_sent(
        &self,
        timeout: Duration,
        predicate: impl Fn(&[Sent]) -> bool,
    ) -> Vec<Sent> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let sent = self.sent();
            if predicate(&sent) {
                return sent;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "timed out waiting for sent events; have {sent:#?}"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}

impl Drop for FakeHomeserver {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            // The server may already have stopped; nothing to do then.
            let _ = stop.send(());
        }
    }
}

/// Sync batch builders, for `push_sync`.
pub mod batch {
    use serde_json::{Value, json};

    /// A joined room's timeline with one `m.room.message` text event.
    pub fn message(room_id: &str, sender: &str, event_id: &str, body: &str) -> Value {
        json!({ "rooms": { "join": { room_id: { "timeline": { "events": [{
            "type": "m.room.message",
            "event_id": event_id,
            "sender": sender,
            "origin_server_ts": 1_760_000_000_000_u64,
            "content": { "msgtype": "m.text", "body": body },
        }] } } } } })
    }

    /// An invite to `room_id` from `inviter`, as stripped state.
    pub fn invite(room_id: &str, inviter: &str, target: &str) -> Value {
        json!({ "rooms": { "invite": { room_id: { "invite_state": { "events": [
            { "type": "m.room.name", "state_key": "", "sender": inviter,
              "content": { "name": "Invited" } },
            { "type": "m.room.member", "state_key": target, "sender": inviter,
              "content": { "membership": "invite" } },
        ] } } } } })
    }
}
