//! The daemon end to end: a fake homeserver, Postgres, and a stand-in for
//! the Rails delivery endpoint.

// A test-only crate: a panic is a failed test, which is what unwrap is for.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::collections::HashMap;
use std::time::Duration;

use activematrix_fakehs::{FakeHomeserver, Fault, batch};
use activematrixd::config::Config;
use activematrixd::crypto::{AccessToken, MasterKey};
use activematrixd::delivery::signature;
use activematrixd::runtime::{self, Running};
use common::sink::Sink;
use common::{TestDb, eventually};
use serde_json::{Value, json};
use tokio::sync::watch;
use uuid::Uuid;

const BOT: &str = "@bot:matrix.test";
const ROOM: &str = "!room:matrix.test";
const SECRET: &str = "delivery-secret-of-at-least-32-chars";
const WAIT: Duration = Duration::from_secs(10);

struct Harness {
    db: TestDb,
    homeserver: FakeHomeserver,
    sink: Sink,
    key: String,
    agent: Uuid,
    token: String,
}

impl Harness {
    async fn new() -> Option<Self> {
        let db = TestDb::new().await?;
        let homeserver = FakeHomeserver::start().await.unwrap();
        let token = homeserver.add_user("bot", None);
        let key = MasterKey::generate();
        let agent = db.agent("bot", &homeserver.url(), None).await;
        let sealed = MasterKey::from_base64(&key, None)
            .unwrap()
            .seal(agent, &AccessToken::new(token.clone()))
            .unwrap();
        sqlx::query(
            "UPDATE active_matrix_agents SET access_token_ciphertext = $2, user_id = $3
             WHERE id = $1",
        )
        .bind(agent)
        .bind(sealed)
        .bind(BOT)
        .execute(&db.pool)
        .await
        .unwrap();
        Some(Self { db, homeserver, sink: Sink::start().await, key, agent, token })
    }

    fn config(&self) -> Config {
        let vars: HashMap<&str, String> = HashMap::from([
            ("ACTIVEMATRIX_DATABASE_URL", self.db.scoped_url()),
            ("ACTIVEMATRIX_MASTER_KEY", self.key.clone()),
            ("ACTIVEMATRIX_DELIVERY_URL", self.sink.url.clone()),
            ("ACTIVEMATRIX_DELIVERY_SECRET", SECRET.to_owned()),
            ("ACTIVEMATRIX_PROBE_BIND", "127.0.0.1:0".to_owned()),
            ("ACTIVEMATRIX_NODE_ID", "test-node".to_owned()),
            ("ACTIVEMATRIX_HEARTBEAT_SECS", "1".to_owned()),
            ("ACTIVEMATRIX_LEASE_TTL_SECS", "3".to_owned()),
            ("ACTIVEMATRIX_SHUTDOWN_TIMEOUT_SECS", "5".to_owned()),
        ]);
        Config::load(None, |name| vars.get(name).cloned()).unwrap()
    }

    async fn start(&self) -> Daemon {
        let (stop, stopped) = watch::channel(false);
        let running = runtime::start(&self.config(), stopped).await.unwrap();
        Daemon { stop, running }
    }

    async fn agent_column(&self, column: &str) -> Option<String> {
        sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
            "SELECT {column}::text FROM active_matrix_agents WHERE id = $1"
        )))
        .bind(self.agent)
        .fetch_one(&self.db.pool)
        .await
        .unwrap()
    }

    async fn wait_for_state(&self, state: &str) {
        eventually(&format!("agent {state}"), WAIT, || async {
            self.agent_column("state").await.as_deref() == Some(state)
        })
        .await;
    }

    async fn inbox_bodies(&self) -> Vec<String> {
        sqlx::query_scalar("SELECT content->>'body' FROM active_matrix_inbox ORDER BY id")
            .fetch_all(&self.db.pool)
            .await
            .unwrap()
    }

    /// What Rails does: an outbox row, then NOTIFY, in one transaction.
    async fn outbox(&self, kind: &str, payload: Value) -> Uuid {
        let mut tx = self.db.pool.begin().await.unwrap();
        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO active_matrix_outbox (agent_id, kind, room_id, payload, created_at,
             updated_at)
             VALUES ($1, $2, $3, $4, now(), now()) RETURNING id",
        )
        .bind(self.agent)
        .bind(kind)
        .bind(ROOM)
        .bind(sqlx::types::Json(payload))
        .fetch_one(&mut *tx)
        .await
        .unwrap();
        sqlx::query("SELECT pg_notify('active_matrix_outbox', $1)")
            .bind(id.to_string())
            .execute(&mut *tx)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        id
    }

    async fn outbox_row(&self, id: Uuid) -> (String, i32, Option<Value>) {
        sqlx::query_as("SELECT status, attempts, result FROM active_matrix_outbox WHERE id = $1")
            .bind(id)
            .fetch_one(&self.db.pool)
            .await
            .unwrap()
    }
}

struct Daemon {
    stop: watch::Sender<bool>,
    running: Running,
}

impl Daemon {
    async fn shutdown(self) {
        self.stop.send(true).unwrap();
        tokio::time::timeout(WAIT, self.running.task).await.expect("drained in time").unwrap();
    }

    async fn probe(&self, path: &str) -> (u16, String) {
        let url = format!("http://{}{path}", self.running.probe);
        let output = tokio::process::Command::new("curl")
            .args(["-s", "-w", "\n%{http_code}", &url])
            .output()
            .await
            .unwrap();
        let text = String::from_utf8(output.stdout).unwrap();
        let (body, code) = text.rsplit_once('\n').unwrap();
        (code.parse().unwrap(), body.to_owned())
    }
}

macro_rules! harness {
    () => {
        match Harness::new().await {
            Some(harness) => harness,
            None => return,
        }
    };
}

#[tokio::test(flavor = "multi_thread")]
async fn a_message_reaches_rails_and_the_reply_reaches_the_room() {
    let h = harness!();
    let daemon = h.start().await;
    h.wait_for_state("online").await;

    h.homeserver.push_sync(BOT, batch::message(ROOM, "@alice:matrix.test", "$ping", "!ping"));
    eventually("the event in the inbox", WAIT, || async { h.inbox_bodies().await == ["!ping"] })
        .await;
    eventually("a delivery push", WAIT, || async { !h.sink.pushes().is_empty() }).await;
    let push = h.sink.pushes().remove(0);
    let body: Value = serde_json::from_str(&push.body).unwrap();
    assert_eq!(body["rooms"][0]["room_id"], ROOM);
    assert_eq!(body["rooms"][0]["agent_id"], h.agent.to_string());
    let timestamp: i64 = push.timestamp.parse().unwrap();
    assert_eq!(push.signature, signature::sign(SECRET, timestamp, push.body.as_bytes()));

    let pong = json!({ "msgtype": "m.text", "body": "pong" });
    let command =
        h.outbox("send", json!({ "event_type": "m.room.message", "content": pong })).await;
    let sent = h.homeserver.wait_for_sent(WAIT, |sent| !sent.is_empty()).await;
    assert_eq!(sent[0].content["body"], "pong");
    assert_eq!(
        sent[0].txn_id.as_deref(),
        Some(command.to_string().as_str()),
        "the outbox id is the transaction id"
    );
    eventually("the command marked sent", WAIT, || async {
        h.outbox_row(command).await.0 == "sent"
    })
    .await;
    assert_eq!(h.outbox_row(command).await.2.unwrap()["event_id"], sent[0].event_id);

    daemon.shutdown().await;
    assert_eq!(h.agent_column("state").await.as_deref(), Some("offline"));
    assert_eq!(h.agent_column("claimed_by").await, None);
    h.db.drop_schema().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_restart_resumes_where_it_stopped_without_replaying() {
    let h = harness!();
    let daemon = h.start().await;
    h.wait_for_state("online").await;
    h.homeserver.push_sync(BOT, batch::message(ROOM, "@alice:matrix.test", "$1", "before"));
    eventually("the first event", WAIT, || async { h.inbox_bodies().await == ["before"] }).await;
    daemon.shutdown().await;
    let token = h.agent_column("sync_token").await.unwrap();

    let seen = h.homeserver.requests().len();
    let daemon = h.start().await;
    h.wait_for_state("online").await;
    let first_sync = h.homeserver.requests()[seen..]
        .iter()
        .find(|request| request.path == "/_matrix/client/v3/sync")
        .cloned()
        .expect("a sync after the restart");
    assert!(
        first_sync.query.contains(&format!("since={token}")),
        "resumed from {token}: {}",
        first_sync.query
    );
    h.homeserver.push_sync(BOT, batch::message(ROOM, "@alice:matrix.test", "$2", "after"));
    eventually("only the new event", WAIT, || async {
        h.inbox_bodies().await == ["before", "after"]
    })
    .await;

    daemon.shutdown().await;
    h.db.drop_schema().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn disabling_an_agent_in_rails_releases_it() {
    let h = harness!();
    let daemon = h.start().await;
    h.wait_for_state("online").await;

    sqlx::query("UPDATE active_matrix_agents SET enabled = false")
        .execute(&h.db.pool)
        .await
        .unwrap();

    h.wait_for_state("offline").await;
    eventually("the lease released", WAIT, || async {
        h.agent_column("claimed_by").await.is_none()
    })
    .await;
    daemon.shutdown().await;
    h.db.drop_schema().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rejected_token_fails_the_agent_until_it_logs_in_again() {
    let h = harness!();
    h.homeserver.revoke(&h.token);
    let daemon = h.start().await;

    h.wait_for_state("failed").await;
    assert!(h.agent_column("last_error").await.unwrap().contains("activematrix login"));
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(h.agent_column("claimed_by").await, None, "a failed agent is not claimed again");
    assert_eq!(h.agent_column("state").await.as_deref(), Some("failed"));

    daemon.shutdown().await;
    h.db.drop_schema().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rate_limited_send_is_retried_with_the_same_transaction_id() {
    let h = harness!();
    let daemon = h.start().await;
    h.wait_for_state("online").await;
    h.homeserver.inject(Some("PUT"), "/_matrix/client/v3/rooms/", Fault::rate_limited(1));

    let command = h
        .outbox(
            "send",
            json!({ "event_type": "m.room.message", "content": { "body": "eventually" } }),
        )
        .await;

    eventually("the command sent", WAIT, || async { h.outbox_row(command).await.0 == "sent" })
        .await;
    assert_eq!(h.outbox_row(command).await.1, 2, "one rate-limited attempt, one that went through");
    assert_eq!(h.homeserver.sent().len(), 1);
    daemon.shutdown().await;
    h.db.drop_schema().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_invalid_command_fails_without_blocking_the_next_one() {
    let h = harness!();
    let daemon = h.start().await;
    h.wait_for_state("online").await;

    let broken = h.outbox("send", json!({ "content": { "body": "no event type" } })).await;
    let fine = h
        .outbox("send", json!({ "event_type": "m.room.message", "content": { "body": "fine" } }))
        .await;

    eventually("both settled", WAIT, || async { h.outbox_row(fine).await.0 == "sent" }).await;
    assert_eq!(h.outbox_row(broken).await.0, "failed");
    daemon.shutdown().await;
    h.db.drop_schema().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_probes_answer_from_memory() {
    let h = harness!();
    let daemon = h.start().await;
    h.wait_for_state("online").await;

    eventually("live", WAIT, || async { daemon.probe("/livez").await.0 == 200 }).await;
    assert_eq!(daemon.probe("/readyz").await.0, 200);
    let (_, status) = daemon.probe("/status").await;
    let status: Value = serde_json::from_str(&status).unwrap();
    assert_eq!(status["agents"][0]["name"], "bot");
    eventually("the agent online in /status", WAIT, || async {
        let (_, status) = daemon.probe("/status").await;
        serde_json::from_str::<Value>(&status).unwrap()["agents"][0]["state"] == "online"
    })
    .await;
    let (_, metrics) = daemon.probe("/metrics").await;
    assert!(metrics.contains("activematrixd_sync_batches_total"), "{metrics}");
    assert!(metrics.contains("activematrixd_agents{state=\"online\"} 1"), "{metrics}");
    assert_eq!(daemon.probe("/nope").await.0, 404);

    daemon.shutdown().await;
    h.db.drop_schema().await;
}
