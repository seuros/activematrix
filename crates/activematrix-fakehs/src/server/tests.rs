use serde_json::Value;

use super::*;
use crate::state::Batch;

const ROOM: &str = "%21room%3Amatrix.test";

struct Fixture {
    shared: Arc<Shared>,
    token: String,
}

impl Fixture {
    fn new() -> Self {
        let shared = Arc::new(Shared::default());
        let token = shared.add_user("bot", None);
        Self { shared, token }
    }

    async fn call(&self, method: &str, path: &str, body: &str) -> (u16, Value) {
        let request = Request::builder()
            .method(method)
            .uri(path)
            .header("authorization", format!("Bearer {}", self.token))
            .header("content-type", "application/json")
            .body(Body::from(body.to_owned()))
            .unwrap();
        let response = app(Arc::clone(&self.shared)).serve(request).await.unwrap();
        let status = response.status().as_u16();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
    }
}

#[tokio::test]
async fn a_conforming_send_is_accepted_and_recorded() {
    let fx = Fixture::new();
    let path = format!("/_matrix/client/v3/rooms/{ROOM}/send/m.room.message/t1");

    let (status, body) = fx.call("PUT", &path, r#"{"msgtype":"m.text","body":"hi"}"#).await;

    assert_eq!(status, 200, "{body}");
    let sent = fx.shared.sent();
    assert_eq!(sent[0].room_id, "!room:matrix.test");
    assert_eq!(sent[0].txn_id.as_deref(), Some("t1"));
    assert_eq!(body["event_id"], sent[0].event_id);
    assert_eq!(fx.shared.requests()[0].user_id.as_deref(), Some("@bot:matrix.test"));
}

#[tokio::test]
async fn a_malformed_room_id_is_rejected_by_the_spec() {
    let fx = Fixture::new();
    let path = "/_matrix/client/v3/rooms/not-a-room/send/m.room.message/t1";

    let (status, body) = fx.call("PUT", path, "{}").await;

    assert_eq!(status, 400, "{body}");
    assert_eq!(fx.shared.sent(), []);
}

#[tokio::test]
async fn a_body_that_is_not_json_is_rejected() {
    let fx = Fixture::new();
    let path = format!("/_matrix/client/v3/rooms/{ROOM}/typing/%40bot%3Amatrix.test");

    let (status, body) = fx.call("PUT", &path, "typing").await;

    assert_eq!(status, 400, "{body}");
}

#[tokio::test]
async fn typing_as_someone_else_is_forbidden() {
    let fx = Fixture::new();
    let path = format!("/_matrix/client/v3/rooms/{ROOM}/typing/%40carol%3Amatrix.test");

    let (status, body) = fx.call("PUT", &path, r#"{"typing":false}"#).await;

    assert_eq!((status, body["errcode"].as_str()), (403, Some("M_FORBIDDEN")));
}

#[tokio::test]
async fn tokens_missing_or_revoked_are_spec_errors() {
    let fx = Fixture::new();
    let whoami = "/_matrix/client/v3/account/whoami";
    let request = Request::builder().uri(whoami).body(Body::empty()).unwrap();
    let response = app(Arc::clone(&fx.shared)).serve(request).await.unwrap();
    assert_eq!(response.status().as_u16(), 401);

    fx.shared.revoke(&fx.token);
    let (status, body) = fx.call("GET", whoami, "").await;

    assert_eq!((status, body["errcode"].as_str()), (401, Some("M_UNKNOWN_TOKEN")));
}

#[tokio::test]
async fn an_unknown_endpoint_is_unrecognized() {
    let (status, body) = Fixture::new().call("GET", "/_matrix/client/v3/nope", "").await;

    assert_eq!((status, body["errcode"].as_str()), (404, Some("M_UNRECOGNIZED")));
}

#[tokio::test]
async fn an_empty_state_key_may_end_in_a_slash() {
    let fx = Fixture::new();
    for path in [
        format!("/_matrix/client/v3/rooms/{ROOM}/state/m.room.topic/"),
        format!("/_matrix/client/v3/rooms/{ROOM}/state/m.room.topic"),
    ] {
        let (status, body) = fx.call("PUT", &path, r#"{"topic":"ops"}"#).await;
        assert_eq!(status, 200, "{path}: {body}");
    }

    assert!(fx.shared.sent().iter().all(|sent| sent.state_key.as_deref() == Some("")));
}

#[tokio::test]
async fn a_fault_answers_before_the_request_is_parsed() {
    let fx = Fixture::new();
    fx.shared.inject(Some("PUT"), "/_matrix/client/v3/rooms/", Fault::rate_limited(2));
    let path = "/_matrix/client/v3/rooms/not-a-room/send/m.room.message/t1";

    let (status, body) = fx.call("PUT", path, "{}").await;

    assert_eq!((status, body["retry_after_ms"].as_u64()), (429, Some(2000)));
    assert_eq!(fx.shared.requests().len(), 1);
}

#[tokio::test]
async fn uploads_get_a_fresh_mxc_uri() {
    let fx = Fixture::new();

    let (status, body) = fx.call("POST", "/_matrix/media/v3/upload?filename=a.png", "png").await;

    assert_eq!(status, 200, "{body}");
    assert!(body["content_uri"].as_str().unwrap().starts_with("mxc://matrix.test/"));
    assert_eq!(fx.shared.requests()[0].body, serde_json::json!({ "bytes": 3 }));
}

#[tokio::test]
async fn sync_answers_a_queued_batch_then_times_out_empty() {
    let fx = Fixture::new();
    let batch = crate::batch::message("!room:matrix.test", "@a:matrix.test", "$1", "hi");
    fx.shared.push_sync("@bot:matrix.test", Batch::parse(batch).unwrap());

    let (_, first) = fx.call("GET", "/_matrix/client/v3/sync?timeout=0", "").await;
    let since = first["next_batch"].as_str().unwrap().to_owned();
    let (_, second) = fx.call("GET", &format!("/_matrix/client/v3/sync?since={since}"), "").await;

    let timeline = &first["rooms"]["join"]["!room:matrix.test"]["timeline"]["events"];
    assert_eq!(timeline[0]["content"]["body"], "hi");
    assert!(second["rooms"].is_null() && second["next_batch"].is_string(), "{second}");
    assert_eq!(fx.shared.last_since("@bot:matrix.test"), Some(since));
}

#[tokio::test]
async fn a_batch_with_unknown_fields_is_refused() {
    let fx = Fixture::new();

    let (status, _) = fx.call("POST", "/_fake/sync/%40bot%3Amatrix.test", r#"{"room":{}}"#).await;

    assert_eq!(status, 400);
}
