//! The Matrix client against the fake homeserver, over real HTTP.

// A test-only crate: a panic is a failed test, which is what unwrap is for.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::time::Duration;

use activematrix_fakehs::{FakeHomeserver, Fault, batch};
use activematrixd::crypto::AccessToken;
use activematrixd::matrix::{self, Client, Homeserver, MatrixError, sync};
use serde_json::json;

const BOT: &str = "@bot:matrix.test";
const ROOM: &str = "!room:matrix.test";

fn client(server: &FakeHomeserver) -> (Client, String) {
    let token = server.add_user("bot", Some("hunter2"));
    let client = Client::new(
        Homeserver::new(&server.url()),
        AccessToken::new(token.clone()),
        BOT.into(),
    );
    (client, token)
}

#[tokio::test]
async fn logs_in_and_knows_who_it_is() {
    let server = FakeHomeserver::start().await.unwrap();
    server.add_user("bot", Some("hunter2"));
    let homeserver = Homeserver::new(&server.url());

    let login = matrix::login(&homeserver, "bot", "hunter2", "activematrixd")
        .await
        .unwrap();
    let whoami = Client::new(
        homeserver.clone(),
        login.access_token,
        login.user_id.clone(),
    )
    .whoami()
    .await
    .unwrap();

    assert_eq!(login.user_id, BOT);
    assert_eq!(whoami.device_id.as_deref(), Some(login.device_id.as_str()));
    assert!(matches!(
        matrix::login(&homeserver, "bot", "wrong", "x").await,
        Err(MatrixError::Rejected { status: 403, .. })
    ));
}

#[tokio::test]
async fn sync_long_polls_until_a_batch_arrives() {
    let server = FakeHomeserver::start().await.unwrap();
    let (client, _) = client(&server);

    let first = client
        .sync(None, Duration::ZERO, sync::FIRST_SYNC_FILTER)
        .await
        .unwrap();
    let pending = tokio::spawn({
        let client = client.clone();
        let since = first.next_batch.clone();
        async move {
            client
                .sync(Some(&since), Duration::from_secs(5), sync::FILTER)
                .await
        }
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    server.push_sync(
        BOT,
        batch::message(ROOM, "@alice:matrix.test", "$1", "!ping"),
    );

    let response = pending.await.unwrap().unwrap();
    let events = &response.rooms.join[ROOM].timeline.events;

    assert_eq!(events[0]["content"]["body"], "!ping");
    assert_eq!(server.last_since(BOT), Some(first.next_batch));
}

#[tokio::test]
async fn a_repeated_transaction_id_sends_once() {
    let server = FakeHomeserver::start().await.unwrap();
    let (client, _) = client(&server);
    let content = json!({ "msgtype": "m.text", "body": "pong" });

    let first = client
        .send_event(ROOM, "m.room.message", "txn-1", &content)
        .await
        .unwrap();
    let again = client
        .send_event(ROOM, "m.room.message", "txn-1", &content)
        .await
        .unwrap();

    assert_eq!(first, again);
    let sent = server.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].room_id, ROOM, "the room id survives path encoding");
}

#[tokio::test]
async fn rate_limits_carry_retry_after() {
    let server = FakeHomeserver::start().await.unwrap();
    let (client, _) = client(&server);
    server.inject(
        Some("PUT"),
        "/_matrix/client/v3/rooms/",
        Fault::rate_limited(2),
    );

    let error = client
        .send_event(ROOM, "m.room.message", "t", &json!({}))
        .await
        .unwrap_err();

    assert_eq!(error, MatrixError::RateLimited(Duration::from_secs(2)));
    assert!(
        client
            .send_event(ROOM, "m.room.message", "t", &json!({}))
            .await
            .is_ok(),
        "fault is one-shot"
    );
}

#[tokio::test]
async fn a_revoked_token_is_unknown() {
    let server = FakeHomeserver::start().await.unwrap();
    let (client, token) = client(&server);
    server.revoke(&token);

    assert_eq!(
        client.whoami().await.unwrap_err(),
        MatrixError::UnknownToken
    );
}

#[tokio::test]
async fn an_unreachable_homeserver_is_a_retryable_transport_error() {
    let client = Client::new(
        Homeserver::new("http://127.0.0.1:9"),
        AccessToken::new("t".into()),
        BOT.into(),
    );

    let error = client.whoami().await.unwrap_err();

    assert!(error.is_retryable(), "{error:?}");
}

#[tokio::test]
async fn room_operations_reach_the_homeserver() {
    let server = FakeHomeserver::start().await.unwrap();
    let (client, _) = client(&server);

    assert_eq!(client.join(ROOM).await.unwrap(), ROOM);
    client
        .membership(ROOM, "invite", Some("@carol:matrix.test"), None)
        .await
        .unwrap();
    client
        .put_state(ROOM, "m.room.topic", "", &json!({ "topic": "ops" }))
        .await
        .unwrap();
    client
        .typing(ROOM, true, Duration::from_secs(5))
        .await
        .unwrap();
    client.receipt(ROOM, "$1", "m.read").await.unwrap();
    let created = client
        .create_room(&json!({ "preset": "private_chat" }))
        .await
        .unwrap();
    let mxc = client
        .upload("image/png", Some("a.png"), vec![1, 2, 3])
        .await
        .unwrap();

    assert!(created.starts_with('!'));
    assert!(mxc.starts_with("mxc://"));
    let paths: Vec<String> = server
        .requests()
        .into_iter()
        .map(|r| format!("{} {}", r.method, r.path))
        .collect();
    assert!(
        paths.contains(&"POST /_matrix/client/v3/rooms/%21room%3Amatrix.test/invite".to_owned()),
        "{paths:#?}"
    );
    assert_eq!(server.sent()[0].event_type, "m.room.topic");
}
