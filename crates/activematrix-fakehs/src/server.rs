//! Request handling: one function, explicit path matching, so faults and
//! recording see every request the same way.

use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;

use rama::http::body::util::BodyExt;
use rama::http::{Body, Request, Response, StatusCode};
use serde_json::{Value, json};

use crate::state::{AuthError, Fault, NewEvent, Recorded, Session, Shared};

/// Long-polls are capped so a test never hangs on a client that asked for
/// minutes.
const MAX_SYNC_WAIT: Duration = Duration::from_secs(30);

pub async fn handle(shared: Arc<Shared>, request: Request) -> Result<Response, Infallible> {
    let method = request.method().as_str().to_owned();
    // Encoded forms: segments are decoded one by one, so an encoded `/`
    // inside a room id cannot split it.
    let path = request
        .uri()
        .path()
        .map_or_else(|| "/".to_owned(), |p| p.as_encoded_str().into_owned());
    let query = request
        .uri()
        .query()
        .map(|q| q.as_encoded_str().into_owned())
        .unwrap_or_default();
    let token = request
        .headers()
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::to_owned);
    let Ok(collected) = request.into_body().collect().await else {
        return Ok(error(
            StatusCode::BAD_REQUEST,
            "M_BAD_JSON",
            "unreadable body",
        ));
    };
    let bytes = collected.to_bytes();
    let is_upload = path.starts_with("/_matrix/media/");
    let body = if is_upload {
        json!({ "bytes": bytes.len() })
    } else if bytes.is_empty() {
        Value::Null
    } else {
        match serde_json::from_slice(&bytes) {
            Ok(body) => body,
            Err(_) => {
                return Ok(error(
                    StatusCode::BAD_REQUEST,
                    "M_NOT_JSON",
                    "body is not JSON",
                ));
            }
        }
    };

    let session = shared.session(token.as_deref()).ok();
    if !path.starts_with("/_fake/") {
        shared.record(Recorded {
            method: method.clone(),
            path: path.clone(),
            user_id: session.as_ref().map(|s| s.user_id.clone()),
            body: body.clone(),
        });
        if let Some(fault) = shared.take_fault(&method, &path) {
            return Ok(fault_response(&fault));
        }
    }

    let segments: Vec<String> = path
        .trim_start_matches('/')
        .split('/')
        .map(percent_decode)
        .collect();
    let segments: Vec<&str> = segments.iter().map(String::as_str).collect();
    let params = Query::parse(&query);

    let response = match (method.as_str(), segments.as_slice()) {
        ("GET", ["_matrix", "client", "versions"]) => {
            ok(&json!({ "versions": ["v1.1", "v1.11", "v1.12"], "unstable_features": {} }))
        }
        ("POST", ["_matrix", "client", "v3", "login"]) => login(&shared, &body),
        (_, ["_fake", rest @ ..]) => admin(&shared, &method, rest, body),
        (_, ["_matrix", ..]) => match shared.session(token.as_deref()) {
            Err(AuthError::Missing) => error(
                StatusCode::UNAUTHORIZED,
                "M_MISSING_TOKEN",
                "missing access token",
            ),
            Err(AuthError::Unknown) => error(
                StatusCode::UNAUTHORIZED,
                "M_UNKNOWN_TOKEN",
                "unknown access token",
            ),
            Ok(session) => {
                let token = token.unwrap_or_default();
                authenticated(&shared, &token, &session, &method, &segments, &params, body).await
            }
        },
        _ => not_found(),
    };
    Ok(response)
}

async fn authenticated(
    shared: &Shared,
    token: &str,
    session: &Session,
    method: &str,
    segments: &[&str],
    params: &Query,
    body: Value,
) -> Response {
    let send = |room: &str,
                event_type: &str,
                state_key: Option<&str>,
                txn: Option<&str>,
                content: Value| {
        let event = NewEvent {
            room_id: room,
            event_type,
            state_key,
            txn_id: txn,
            content,
        };
        ok(&json!({ "event_id": shared.send(token, session, event) }))
    };
    match (method, segments) {
        ("GET", [_, "client", "v3", "account", "whoami"]) => ok(
            &json!({ "user_id": session.user_id, "device_id": session.device_id, "is_guest": false }),
        ),
        ("GET", [_, "client", "v3", "sync"]) => sync(shared, session, params).await,
        ("PUT", [_, "client", "v3", "rooms", room, "send", event_type, txn]) => {
            send(room, event_type, None, Some(txn), body)
        }
        ("PUT", [_, "client", "v3", "rooms", room, "state", event_type]) => {
            send(room, event_type, Some(""), None, body)
        }
        (
            "PUT",
            [
                _,
                "client",
                "v3",
                "rooms",
                room,
                "state",
                event_type,
                state_key,
            ],
        ) => send(room, event_type, Some(state_key), None, body),
        ("PUT", [_, "client", "v3", "rooms", room, "redact", event_id, txn]) => {
            let mut content = body;
            if let Value::Object(fields) = &mut content {
                fields.insert("redacts".into(), Value::String((*event_id).to_owned()));
            }
            send(room, "m.room.redaction", None, Some(txn), content)
        }
        ("POST", [_, "client", "v3", "join", room]) => {
            let room_id = if room.starts_with('!') {
                (*room).to_owned()
            } else {
                shared.new_id("!joined")
            };
            ok(&json!({ "room_id": room_id }))
        }
        (
            "POST",
            [
                _,
                "client",
                "v3",
                "rooms",
                _,
                "leave" | "forget" | "invite" | "kick" | "ban" | "unban",
            ]
            | [_, "client", "v3", "rooms", _, "receipt", _, _],
        )
        | (
            "PUT",
            [_, "client", "v3", "rooms", _, "typing", _] | [_, "client", "v3", "profile", _, _],
        ) => ok(&json!({})),
        ("POST", [_, "client", "v3", "createRoom"]) => {
            ok(&json!({ "room_id": shared.new_id("!created") }))
        }
        ("POST", ["_matrix", "media", "v3", "upload"]) => ok(
            &json!({ "content_uri": format!("mxc://{}", shared.new_id("media").replace(':', "/")) }),
        ),
        _ => not_found(),
    }
}

/// Answers a queued batch at once, else waits for one up to the client's
/// timeout, else answers an empty batch.
async fn sync(shared: &Shared, session: &Session, params: &Query) -> Response {
    shared.note_since(&session.user_id, params.get("since"));
    let wait = params
        .get("timeout")
        .and_then(|ms| ms.parse().ok())
        .map_or(Duration::ZERO, Duration::from_millis)
        .min(MAX_SYNC_WAIT);
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        // Registered before checking, so a push between the check and the
        // wait is not missed.
        let notified = shared.sync_wake.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if let Some(batch) = shared.take_sync(&session.user_id) {
            return ok(&batch);
        }
        tokio::select! {
            () = notified => {}
            () = tokio::time::sleep_until(deadline) => return ok(&shared.empty_sync()),
        }
    }
}

fn login(shared: &Shared, body: &Value) -> Response {
    let user = body
        .pointer("/identifier/user")
        .or_else(|| body.get("user"))
        .and_then(Value::as_str);
    let password = body.get("password").and_then(Value::as_str);
    match user
        .zip(password)
        .and_then(|(user, password)| shared.login(user, password))
    {
        Some((user_id, access_token, device_id)) => {
            ok(&json!({ "user_id": user_id, "access_token": access_token, "device_id": device_id }))
        }
        None => error(
            StatusCode::FORBIDDEN,
            "M_FORBIDDEN",
            "invalid username or password",
        ),
    }
}

/// The admin API for tests written in other languages.
fn admin(shared: &Shared, method: &str, segments: &[&str], body: Value) -> Response {
    match (method, segments) {
        ("POST", ["users"]) => {
            let Some(localpart) = body.get("localpart").and_then(Value::as_str) else {
                return error(StatusCode::BAD_REQUEST, "M_MISSING_PARAM", "localpart");
            };
            let token = shared.add_user(localpart, body.get("password").and_then(Value::as_str));
            ok(
                &json!({ "user_id": format!("@{localpart}:{}", crate::SERVER_NAME), "access_token": token }),
            )
        }
        ("POST", ["sync", user_id]) => {
            shared.push_sync(user_id, body);
            ok(&json!({}))
        }
        ("GET", ["sent"]) => ok(&serde_json::to_value(shared.sent()).unwrap_or_default()),
        ("GET", ["requests"]) => ok(&serde_json::to_value(shared.requests()).unwrap_or_default()),
        ("GET", ["since", user_id]) => ok(&json!({ "since": shared.last_since(user_id) })),
        ("POST", ["faults"]) => {
            let method = body
                .get("method")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let prefix = body
                .get("path_prefix")
                .and_then(Value::as_str)
                .unwrap_or("/")
                .to_owned();
            match serde_json::from_value::<Fault>(body) {
                Ok(fault) => {
                    shared.inject(method.as_deref(), &prefix, fault);
                    ok(&json!({}))
                }
                Err(e) => error(StatusCode::BAD_REQUEST, "M_BAD_JSON", &e.to_string()),
            }
        }
        ("POST", ["revoke"]) => {
            if let Some(token) = body.get("token").and_then(Value::as_str) {
                shared.revoke(token);
            }
            ok(&json!({}))
        }
        _ => not_found(),
    }
}

fn ok(body: &Value) -> Response {
    respond(StatusCode::OK, body, None)
}

fn not_found() -> Response {
    error(
        StatusCode::NOT_FOUND,
        "M_UNRECOGNIZED",
        "unrecognized request",
    )
}

fn error(status: StatusCode, errcode: &str, message: &str) -> Response {
    respond(
        status,
        &json!({ "errcode": errcode, "error": message }),
        None,
    )
}

fn fault_response(fault: &Fault) -> Response {
    let status = StatusCode::from_u16(fault.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut body = json!({ "error": "injected fault" });
    if let Some(errcode) = &fault.errcode {
        body["errcode"] = Value::String(errcode.clone());
    }
    if let Some(ms) = fault.retry_after_ms {
        body["retry_after_ms"] = json!(ms);
    }
    respond(status, &body, fault.retry_after_secs)
}

fn respond(status: StatusCode, body: &Value, retry_after_secs: Option<u64>) -> Response {
    let mut builder = Response::builder()
        .status(status)
        .header("content-type", "application/json");
    if let Some(secs) = retry_after_secs {
        builder = builder.header("retry-after", secs.to_string());
    }
    builder
        .body(Body::from(body.to_string()))
        .unwrap_or_else(|_| Response::new(Body::from(body.to_string())))
}

/// Query parameters, percent-decoded.
pub struct Query(Vec<(String, String)>);

impl Query {
    fn parse(query: &str) -> Self {
        Self(
            query
                .split('&')
                .filter(|pair| !pair.is_empty())
                .map(|pair| {
                    let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
                    (
                        percent_decode(&key.replace('+', " ")),
                        percent_decode(&value.replace('+', " ")),
                    )
                })
                .collect(),
        )
    }

    fn get(&self, key: &str) -> Option<&str> {
        self.0
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(hex) = input.get(i + 1..i + 3)
            && let Ok(byte) = u8::from_str_radix(hex, 16)
        {
            out.push(byte);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}
