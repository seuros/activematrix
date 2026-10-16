//! A Matrix client-server API client with only what the daemon needs.
//!
//! Endpoints are `v3` (every homeserver since Matrix 1.1); event content
//! passes through as raw JSON, so the daemon never has to understand the
//! events bots send. Errors say whether a retry can help.

mod http;
pub mod sync;

use std::fmt::Write as _;
use std::time::Duration;

use rama::http::Method;
use serde::Deserialize;
use serde_json::{Value, json};

pub use http::{Homeserver, MatrixError, install_crypto_provider};

use crate::crypto::AccessToken;

/// Requests other than `/sync` give up after this long.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Deserialize)]
pub struct WhoAmI {
    pub user_id: String,
    pub device_id: Option<String>,
}

#[derive(Debug)]
pub struct Login {
    pub user_id: String,
    pub device_id: String,
    pub access_token: AccessToken,
}

/// `user` is a localpart or a full user id.
pub async fn login(
    homeserver: &Homeserver,
    user: &str,
    password: &str,
    device_name: &str,
) -> Result<Login, MatrixError> {
    #[derive(Deserialize)]
    struct Response {
        user_id: String,
        device_id: String,
        access_token: String,
    }
    let body = json!({
        "type": "m.login.password",
        "identifier": { "type": "m.id.user", "user": user },
        "password": password,
        "initial_device_display_name": device_name,
    });
    let response: Response = homeserver
        .json(
            Method::POST,
            "/_matrix/client/v3/login",
            &[],
            None,
            Some(&body),
            REQUEST_TIMEOUT,
        )
        .await?;
    Ok(Login {
        user_id: response.user_id,
        device_id: response.device_id,
        access_token: AccessToken::new(response.access_token),
    })
}

/// An authenticated session on a homeserver.
#[derive(Clone)]
pub struct Client {
    homeserver: Homeserver,
    token: AccessToken,
    user_id: String,
}

impl Client {
    pub const fn new(homeserver: Homeserver, token: AccessToken, user_id: String) -> Self {
        Self {
            homeserver,
            token,
            user_id,
        }
    }

    pub fn user_id(&self) -> &str {
        &self.user_id
    }

    pub const fn homeserver(&self) -> &Homeserver {
        &self.homeserver
    }

    async fn call<T: serde::de::DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, &str)],
        body: Option<&Value>,
    ) -> Result<T, MatrixError> {
        self.homeserver
            .json(
                method,
                path,
                query,
                Some(&self.token),
                body,
                REQUEST_TIMEOUT,
            )
            .await
    }

    pub async fn whoami(&self) -> Result<WhoAmI, MatrixError> {
        self.call(Method::GET, "/_matrix/client/v3/account/whoami", &[], None)
            .await
    }

    /// Long-polls `/sync` for up to `timeout`.
    pub async fn sync(
        &self,
        since: Option<&str>,
        timeout: Duration,
        filter: &str,
    ) -> Result<sync::SyncResponse, MatrixError> {
        let timeout_ms = timeout.as_millis().to_string();
        let mut query = vec![("timeout", timeout_ms.as_str()), ("filter", filter)];
        if let Some(since) = since {
            query.push(("since", since));
        }
        // The server holds the request for `timeout`; allow for it.
        self.homeserver
            .json(
                Method::GET,
                "/_matrix/client/v3/sync",
                &query,
                Some(&self.token),
                None,
                timeout + REQUEST_TIMEOUT,
            )
            .await
    }

    /// Sends a message-like event. Repeating a `txn_id` is safe: the
    /// homeserver returns the first event id instead of posting again.
    pub async fn send_event(
        &self,
        room_id: &str,
        event_type: &str,
        txn_id: &str,
        content: &Value,
    ) -> Result<String, MatrixError> {
        let path = format!(
            "/_matrix/client/v3/rooms/{}/send/{}/{}",
            seg(room_id),
            seg(event_type),
            seg(txn_id)
        );
        event_id(&self.call(Method::PUT, &path, &[], Some(content)).await?)
    }

    pub async fn put_state(
        &self,
        room_id: &str,
        event_type: &str,
        state_key: &str,
        content: &Value,
    ) -> Result<String, MatrixError> {
        let path = format!(
            "/_matrix/client/v3/rooms/{}/state/{}/{}",
            seg(room_id),
            seg(event_type),
            seg(state_key)
        );
        event_id(&self.call(Method::PUT, &path, &[], Some(content)).await?)
    }

    pub async fn redact(
        &self,
        room_id: &str,
        event_id_to_redact: &str,
        txn_id: &str,
        reason: Option<&str>,
    ) -> Result<String, MatrixError> {
        let path = format!(
            "/_matrix/client/v3/rooms/{}/redact/{}/{}",
            seg(room_id),
            seg(event_id_to_redact),
            seg(txn_id)
        );
        let body = reason.map_or_else(|| json!({}), |reason| json!({ "reason": reason }));
        event_id(&self.call(Method::PUT, &path, &[], Some(&body)).await?)
    }

    /// Joins a room by id or alias; returns the room id.
    pub async fn join(&self, room: &str) -> Result<String, MatrixError> {
        let response: Value = self
            .call(
                Method::POST,
                &format!("/_matrix/client/v3/join/{}", seg(room)),
                &[],
                Some(&json!({})),
            )
            .await?;
        string_field(&response, "room_id")
    }

    /// `leave`, `forget`, `invite`, `kick`, `ban` or `unban`. Membership
    /// changes towards another user take `user_id`.
    pub async fn membership(
        &self,
        room_id: &str,
        action: &str,
        user_id: Option<&str>,
        reason: Option<&str>,
    ) -> Result<(), MatrixError> {
        let mut body = json!({});
        if let Some(user_id) = user_id {
            body["user_id"] = json!(user_id);
        }
        if let Some(reason) = reason {
            body["reason"] = json!(reason);
        }
        let path = format!("/_matrix/client/v3/rooms/{}/{}", seg(room_id), seg(action));
        self.call::<Value>(Method::POST, &path, &[], Some(&body))
            .await
            .map(drop)
    }

    /// `body` is a `/createRoom` request as the spec defines it.
    pub async fn create_room(&self, body: &Value) -> Result<String, MatrixError> {
        let response: Value = self
            .call(
                Method::POST,
                "/_matrix/client/v3/createRoom",
                &[],
                Some(body),
            )
            .await?;
        string_field(&response, "room_id")
    }

    pub async fn typing(
        &self,
        room_id: &str,
        typing: bool,
        timeout: Duration,
    ) -> Result<(), MatrixError> {
        let path = format!(
            "/_matrix/client/v3/rooms/{}/typing/{}",
            seg(room_id),
            seg(&self.user_id)
        );
        let body = if typing {
            json!({ "typing": true, "timeout": u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX) })
        } else {
            json!({ "typing": false })
        };
        self.call::<Value>(Method::PUT, &path, &[], Some(&body))
            .await
            .map(drop)
    }

    pub async fn receipt(
        &self,
        room_id: &str,
        event_id: &str,
        receipt_type: &str,
    ) -> Result<(), MatrixError> {
        let path = format!(
            "/_matrix/client/v3/rooms/{}/receipt/{}/{}",
            seg(room_id),
            seg(receipt_type),
            seg(event_id)
        );
        self.call::<Value>(Method::POST, &path, &[], Some(&json!({})))
            .await
            .map(drop)
    }

    /// `field` is `displayname` or `avatar_url`.
    pub async fn set_profile(&self, field: &str, value: &str) -> Result<(), MatrixError> {
        let path = format!(
            "/_matrix/client/v3/profile/{}/{}",
            seg(&self.user_id),
            seg(field)
        );
        self.call::<Value>(Method::PUT, &path, &[], Some(&json!({ field: value })))
            .await
            .map(drop)
    }

    /// Uploads media; returns its `mxc://` URI.
    pub async fn upload(
        &self,
        content_type: &str,
        filename: Option<&str>,
        bytes: Vec<u8>,
    ) -> Result<String, MatrixError> {
        let query: Vec<(&str, &str)> = filename
            .map(|name| vec![("filename", name)])
            .unwrap_or_default();
        let response: Value = self
            .homeserver
            .upload(
                "/_matrix/media/v3/upload",
                &query,
                &self.token,
                content_type,
                bytes,
                REQUEST_TIMEOUT,
            )
            .await?;
        string_field(&response, "content_uri")
    }
}

fn event_id(response: &Value) -> Result<String, MatrixError> {
    string_field(response, "event_id")
}

fn string_field(response: &Value, field: &str) -> Result<String, MatrixError> {
    response
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| MatrixError::Decode(format!("response has no {field}")))
}

/// Percent-encodes one path segment: everything but RFC 3986 unreserved
/// characters, so `!room:server`, `$event` and `@user:server` survive.
pub fn seg(segment: &str) -> String {
    let mut encoded = String::with_capacity(segment.len());
    for byte in segment.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(char::from(byte));
        } else {
            let _ = write!(encoded, "%{byte:02X}"); // writing to a String cannot fail
        }
    }
    encoded
}

#[cfg(test)]
mod tests;
