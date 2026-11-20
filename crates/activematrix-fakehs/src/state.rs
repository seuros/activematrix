//! Everything the fake homeserver remembers, behind one mutex.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Mutex, MutexGuard, PoisonError};

use rama::extensions::Extension;
use rama_x_ruma::{MatrixAuth, TokenIdentity};
use ruma::api::client::sync::sync_events::v3::{
    GlobalAccountData, Response as SyncResponse, Rooms,
};
use ruma::{OwnedDeviceId, OwnedUserId};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Notify;

use crate::SERVER_NAME;

/// What an injected fault answers with.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Fault {
    pub status: u16,
    #[serde(default)]
    pub errcode: Option<String>,
    /// Sent as the `Retry-After` header.
    #[serde(default)]
    pub retry_after_secs: Option<u64>,
    /// Sent as `retry_after_ms` in the error body.
    #[serde(default)]
    pub retry_after_ms: Option<u64>,
}

impl Fault {
    pub fn rate_limited(retry_after_secs: u64) -> Self {
        Self {
            status: 429,
            errcode: Some("M_LIMIT_EXCEEDED".into()),
            retry_after_secs: Some(retry_after_secs),
            retry_after_ms: Some(retry_after_secs * 1000),
        }
    }

    pub const fn server_error() -> Self {
        Self { status: 500, errcode: None, retry_after_secs: None, retry_after_ms: None }
    }

    pub fn status(status: u16, errcode: &str) -> Self {
        Self { status, errcode: Some(errcode.into()), retry_after_secs: None, retry_after_ms: None }
    }
}

/// A message, state or redaction event the server accepted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Sent {
    pub user_id: String,
    pub room_id: String,
    pub event_type: String,
    pub state_key: Option<String>,
    pub txn_id: Option<String>,
    pub event_id: String,
    pub content: Value,
}

/// One request as the server saw it.
#[derive(Debug, Clone, Serialize)]
pub struct Recorded {
    pub method: String,
    pub path: String,
    /// Percent-encoded, as sent.
    pub query: String,
    pub user_id: Option<String>,
    pub body: Value,
}

/// A queued sync batch: the parts of a `/sync` response tests script. The
/// server adds `next_batch`; any other field is a fixture mistake.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Batch {
    #[serde(default)]
    rooms: Rooms,
    #[serde(default)]
    account_data: GlobalAccountData,
}

impl Batch {
    pub fn parse(batch: Value) -> serde_json::Result<Self> {
        serde_json::from_value(batch)
    }
}

#[derive(Debug, Clone)]
struct Session {
    user_id: String,
    device_id: String,
}

/// An event a client asked the server to accept.
pub struct NewEvent {
    pub user_id: String,
    /// Transactions are scoped to the sending device.
    pub device_id: String,
    pub room_id: String,
    pub event_type: String,
    pub state_key: Option<String>,
    pub txn_id: Option<String>,
    pub content: Value,
}

#[derive(Debug, Default)]
pub struct Shared {
    pub sync_wake: Notify,
    inner: Mutex<Inner>,
}

impl Extension for Shared {}

impl MatrixAuth for Shared {
    fn resolve_token(&self, token: &str) -> impl Future<Output = TokenIdentity> + Send {
        let identity = self.session(token).and_then(|Session { user_id, device_id }| {
            let user_id = OwnedUserId::try_from(user_id).ok()?;
            Some(TokenIdentity::User { user_id, device_id: OwnedDeviceId::from(device_id) })
        });
        std::future::ready(identity.unwrap_or(TokenIdentity::Invalid { soft_logout: false }))
    }
}

#[derive(Debug, Default)]
struct Inner {
    sessions: HashMap<String, Session>,
    revoked: HashSet<String>,
    passwords: HashMap<String, String>,
    syncs: HashMap<String, VecDeque<Batch>>,
    last_since: HashMap<String, String>,
    sent: Vec<Sent>,
    /// (user_id, device_id, txn_id) -> event_id
    txns: HashMap<(String, String, String), String>,
    requests: Vec<Recorded>,
    faults: Vec<(Option<String>, String, Fault)>,
    counter: u64,
}

impl Inner {
    const fn next(&mut self) -> u64 {
        self.counter += 1;
        self.counter
    }

    fn issue_token(&mut self, user_id: &str) -> (String, String) {
        let n = self.next();
        let token = format!("syt_fake_{n}");
        let device_id = format!("FAKEDEV{n}");
        self.sessions.insert(
            token.clone(),
            Session { user_id: user_id.to_owned(), device_id: device_id.clone() },
        );
        (token, device_id)
    }
}

impl Shared {
    pub fn add_user(&self, localpart: &str, password: Option<&str>) -> String {
        let user_id = format!("@{localpart}:{SERVER_NAME}");
        let mut inner = self.lock();
        if let Some(password) = password {
            inner.passwords.insert(user_id.clone(), password.to_owned());
        }
        inner.issue_token(&user_id).0
    }

    /// `user` is a localpart or a full user id. Returns (user_id, token, device_id).
    pub fn login(&self, user: &str, password: &str) -> Option<(String, String, String)> {
        let user_id =
            if user.starts_with('@') { user.to_owned() } else { format!("@{user}:{SERVER_NAME}") };
        let mut inner = self.lock();
        if inner.passwords.get(&user_id).map(String::as_str) != Some(password) {
            return None;
        }
        let (token, device_id) = inner.issue_token(&user_id);
        drop(inner);
        Some((user_id, token, device_id))
    }

    /// The user id a live token belongs to.
    pub fn token_user(&self, token: &str) -> Option<String> {
        self.session(token).map(|session| session.user_id)
    }

    pub fn revoke(&self, token: &str) {
        self.lock().revoked.insert(token.to_owned());
    }

    pub fn push_sync(&self, user_id: &str, batch: Batch) {
        self.lock().syncs.entry(user_id.to_owned()).or_default().push_back(batch);
        self.sync_wake.notify_waiters();
    }

    /// The next queued batch for `user_id`, with `next_batch` filled in.
    pub fn take_sync(&self, user_id: &str) -> Option<SyncResponse> {
        let mut inner = self.lock();
        let batch = inner.syncs.get_mut(user_id)?.pop_front()?;
        let mut response = SyncResponse::new(format!("s{}", inner.next()));
        drop(inner);
        response.rooms = batch.rooms;
        response.account_data = batch.account_data;
        Some(response)
    }

    pub fn empty_sync(&self) -> SyncResponse {
        SyncResponse::new(format!("s{}", self.lock().next()))
    }

    pub fn note_since(&self, user_id: &str, since: Option<&str>) {
        if let Some(since) = since {
            self.lock().last_since.insert(user_id.to_owned(), since.to_owned());
        }
    }

    pub fn last_since(&self, user_id: &str) -> Option<String> {
        self.lock().last_since.get(user_id).cloned()
    }

    /// Records a sent event; a repeated transaction id returns the first
    /// event id and records nothing.
    pub fn send(&self, event: NewEvent) -> String {
        let mut inner = self.lock();
        let txn_key =
            event.txn_id.clone().map(|txn| (event.user_id.clone(), event.device_id.clone(), txn));
        if let Some(key) = &txn_key
            && let Some(event_id) = inner.txns.get(key)
        {
            return event_id.clone();
        }
        let event_id = format!("$fake{}", inner.next());
        if let Some(key) = txn_key {
            inner.txns.insert(key, event_id.clone());
        }
        inner.sent.push(Sent {
            user_id: event.user_id,
            room_id: event.room_id,
            event_type: event.event_type,
            state_key: event.state_key,
            txn_id: event.txn_id,
            event_id: event_id.clone(),
            content: event.content,
        });
        drop(inner);
        event_id
    }

    /// A fresh `{prefix}{n}`, unique for this server.
    pub fn new_local(&self, prefix: &str) -> String {
        format!("{prefix}{}", self.lock().next())
    }

    pub fn record(&self, request: Recorded) {
        self.lock().requests.push(request);
    }

    pub fn inject(&self, method: Option<&str>, path_prefix: &str, fault: Fault) {
        self.lock().faults.push((method.map(str::to_owned), path_prefix.to_owned(), fault));
    }

    /// Removes and returns the first fault matching this request.
    pub fn take_fault(&self, method: &str, path: &str) -> Option<Fault> {
        let mut inner = self.lock();
        let index = inner.faults.iter().position(|(m, prefix, _)| {
            m.as_deref().is_none_or(|m| m.eq_ignore_ascii_case(method))
                && path.starts_with(prefix.as_str())
        })?;
        Some(inner.faults.remove(index).2)
    }

    pub fn sent(&self) -> Vec<Sent> {
        self.lock().sent.clone()
    }

    pub fn requests(&self) -> Vec<Recorded> {
        self.lock().requests.clone()
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // A test that panicked while holding the lock already failed; keep
        // serving so the rest of its assertions report something useful.
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn session(&self, token: &str) -> Option<Session> {
        let inner = self.lock();
        if inner.revoked.contains(token) {
            return None;
        }
        inner.sessions.get(token).cloned()
    }
}
