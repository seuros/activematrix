//! Everything the fake homeserver remembers, behind one mutex.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Mutex, MutexGuard, PoisonError};

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

#[derive(Debug, Clone)]
pub struct Session {
    pub user_id: String,
    pub device_id: String,
}

/// An event a client asked the server to accept.
pub struct NewEvent<'a> {
    pub room_id: &'a str,
    pub event_type: &'a str,
    pub state_key: Option<&'a str>,
    pub txn_id: Option<&'a str>,
    pub content: Value,
}

pub enum AuthError {
    Missing,
    Unknown,
}

#[derive(Default)]
pub struct Shared {
    pub sync_wake: Notify,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    sessions: HashMap<String, Session>,
    revoked: HashSet<String>,
    passwords: HashMap<String, String>,
    syncs: HashMap<String, VecDeque<Value>>,
    last_since: HashMap<String, String>,
    sent: Vec<Sent>,
    txns: HashMap<(String, String), String>,
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
    fn lock(&self) -> MutexGuard<'_, Inner> {
        // A test that panicked while holding the lock already failed; keep
        // serving so the rest of its assertions report something useful.
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

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

    pub fn session(&self, token: Option<&str>) -> Result<Session, AuthError> {
        let token = token.ok_or(AuthError::Missing)?;
        let inner = self.lock();
        if inner.revoked.contains(token) {
            return Err(AuthError::Unknown);
        }
        inner.sessions.get(token).cloned().ok_or(AuthError::Unknown)
    }

    pub fn revoke(&self, token: &str) {
        self.lock().revoked.insert(token.to_owned());
    }

    pub fn push_sync(&self, user_id: &str, batch: Value) {
        self.lock().syncs.entry(user_id.to_owned()).or_default().push_back(batch);
        self.sync_wake.notify_waiters();
    }

    /// The next queued batch for `user_id`, with `next_batch` filled in.
    pub fn take_sync(&self, user_id: &str) -> Option<Value> {
        let mut inner = self.lock();
        let mut batch = inner.syncs.get_mut(user_id)?.pop_front()?;
        let next_batch = format!("s{}", inner.next());
        drop(inner);
        if let Value::Object(fields) = &mut batch {
            fields.insert("next_batch".into(), Value::String(next_batch));
        }
        Some(batch)
    }

    pub fn empty_sync(&self) -> Value {
        serde_json::json!({ "next_batch": format!("s{}", self.lock().next()) })
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
    pub fn send(&self, token: &str, session: &Session, event: NewEvent<'_>) -> String {
        let mut inner = self.lock();
        let txn_key = event.txn_id.map(|txn| (token.to_owned(), txn.to_owned()));
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
            user_id: session.user_id.clone(),
            room_id: event.room_id.to_owned(),
            event_type: event.event_type.to_owned(),
            state_key: event.state_key.map(str::to_owned),
            txn_id: event.txn_id.map(str::to_owned),
            event_id: event_id.clone(),
            content: event.content,
        });
        drop(inner);
        event_id
    }

    pub fn new_id(&self, prefix: &str) -> String {
        format!("{prefix}{}:{SERVER_NAME}", self.lock().next())
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
}
