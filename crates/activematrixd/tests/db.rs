//! Leases and ingest against Postgres, in a schema loaded from the Rails
//! engine's snapshot.

// A test-only crate: a panic is a failed test, which is what unwrap is for.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::time::Duration;

use activematrixd::db::{Db, SchemaError, agents, ingest};
use activematrixd::ingest::plan;
use activematrixd::matrix::sync::SyncResponse;
use common::TestDb;
use serde_json::{Value, json};
use uuid::Uuid;

const NODE: &str = "node-a";
const ME: &str = "@bot:matrix.test";
const TTL: Duration = Duration::from_secs(30);

macro_rules! db {
    () => {
        match TestDb::new().await {
            Some(db) => db,
            None => return,
        }
    };
}

fn batch(value: Value, deliver: bool) -> activematrixd::ingest::Batch {
    plan(
        serde_json::from_value::<SyncResponse>(value).unwrap(),
        ME,
        deliver,
    )
}

fn messages(next_batch: &str, room: &str, ids: &[&str]) -> Value {
    let events: Vec<Value> = ids
        .iter()
        .map(|id| {
            json!({ "type": "m.room.message", "event_id": id, "sender": "@alice:matrix.test",
                          "content": { "msgtype": "m.text", "body": format!("body {id}") } })
        })
        .collect();
    json!({ "next_batch": next_batch, "rooms": { "join": { room: { "timeline": { "events": events } } } } })
}

async fn inbox_count(db: &TestDb) -> i64 {
    sqlx::query_scalar("SELECT count(*) FROM active_matrix_inbox")
        .fetch_one(&db.pool)
        .await
        .unwrap()
}

async fn claimed(db: &TestDb, name: &str) -> Uuid {
    let id = db.agent(name, "https://matrix.test", Some(b"sealed")).await;
    let claimed = agents::claim(&db.pool, NODE, TTL, 10).await.unwrap();
    assert!(claimed.iter().any(|agent| agent.id == id));
    id
}

#[tokio::test]
async fn the_snapshot_has_every_column_the_daemon_needs() {
    let db = db!();

    Db::from_pool(db.pool.clone())
        .verify_schema()
        .await
        .unwrap();
    sqlx::query("ALTER TABLE active_matrix_outbox DROP COLUMN attempts")
        .execute(&db.pool)
        .await
        .unwrap();
    let error = Db::from_pool(db.pool.clone())
        .verify_schema()
        .await
        .unwrap_err();

    assert!(
        matches!(&error, SchemaError::Missing(missing) if missing == "active_matrix_outbox.attempts"),
        "{error}"
    );
    db.drop_schema().await;
}

#[tokio::test]
async fn only_enabled_logged_in_unheld_agents_are_claimed() {
    let db = db!();
    let runnable = db
        .agent("runnable", "https://matrix.test", Some(b"sealed"))
        .await;
    db.agent("no-token", "https://matrix.test", None).await;
    let disabled = db
        .agent("disabled", "https://matrix.test", Some(b"sealed"))
        .await;
    sqlx::query("UPDATE active_matrix_agents SET enabled = false WHERE id = $1")
        .bind(disabled)
        .execute(&db.pool)
        .await
        .unwrap();

    let claimed = agents::claim(&db.pool, NODE, TTL, 10).await.unwrap();
    let again = agents::claim(&db.pool, "node-b", TTL, 10).await.unwrap();

    assert_eq!(claimed.iter().map(|a| a.id).collect::<Vec<_>>(), [runnable]);
    assert!(
        again.is_empty(),
        "a held lease is not claimed by another node"
    );
    let state: String = sqlx::query_scalar("SELECT state FROM active_matrix_agents WHERE id = $1")
        .bind(runnable)
        .fetch_one(&db.pool)
        .await
        .unwrap();
    assert_eq!(state, "starting");
    db.drop_schema().await;
}

#[tokio::test]
async fn concurrent_claims_never_share_an_agent() {
    let db = db!();
    for i in 0..20 {
        db.agent(
            &format!("agent-{i}"),
            "https://matrix.test",
            Some(b"sealed"),
        )
        .await;
    }

    let (a, b) = tokio::join!(
        agents::claim(&db.pool, "node-a", TTL, 15),
        agents::claim(&db.pool, "node-b", TTL, 15)
    );
    let (a, b) = (a.unwrap(), b.unwrap());

    assert_eq!(a.len() + b.len(), 20);
    assert!(a.iter().all(|x| b.iter().all(|y| x.id != y.id)));
    db.drop_schema().await;
}

#[tokio::test]
async fn an_expired_lease_is_claimable_and_renewal_reports_losses() {
    let db = db!();
    let id = claimed(&db, "bot").await;

    assert_eq!(
        agents::renew(&db.pool, NODE, TTL, &[id]).await.unwrap(),
        [(id, true)]
    );
    sqlx::query("UPDATE active_matrix_agents SET lease_expires_at = now() - interval '1 second'")
        .execute(&db.pool)
        .await
        .unwrap();
    let stolen = agents::claim(&db.pool, "node-b", TTL, 10).await.unwrap();

    assert_eq!(stolen.len(), 1);
    assert!(
        agents::renew(&db.pool, NODE, TTL, &[id])
            .await
            .unwrap()
            .is_empty(),
        "node-a lost it"
    );
    db.drop_schema().await;
}

#[tokio::test]
async fn release_leaves_the_agent_offline_and_claimable() {
    let db = db!();
    let id = claimed(&db, "bot").await;

    agents::release(&db.pool, NODE, &[id], false).await.unwrap();

    assert_eq!(
        agents::claim(&db.pool, "node-b", TTL, 10)
            .await
            .unwrap()
            .len(),
        1
    );
    db.drop_schema().await;
}

#[tokio::test]
async fn ingest_mirrors_the_room_and_queues_events_in_order() {
    let db = db!();
    let id = claimed(&db, "bot").await;
    let batch = batch(
        json!({ "next_batch": "s1", "rooms": { "join": { "!r:matrix.test": {
            "summary": { "m.joined_member_count": 2 },
            "state": { "events": [
                { "type": "m.room.name", "state_key": "", "event_id": "$n", "sender": "@alice:matrix.test",
                  "content": { "name": "Ops" } },
                { "type": "m.room.member", "state_key": "@alice:matrix.test", "event_id": "$m",
                  "sender": "@alice:matrix.test", "content": { "membership": "join", "displayname": "Alice" } },
            ] },
            "timeline": { "events": [
                { "type": "m.room.message", "event_id": "$2", "sender": "@alice:matrix.test", "content": { "body": "first" } },
                { "type": "m.room.message", "event_id": "$1", "sender": "@alice:matrix.test", "content": { "body": "second" } },
            ] },
        } } } }),
        true,
    );

    let touched = ingest::apply(&db.pool, NODE, id, &batch).await.unwrap();

    assert_eq!(touched, ["!r:matrix.test"]);
    let (name, members): (Option<String>, i32) = sqlx::query_as(
        "SELECT name, joined_member_count FROM active_matrix_rooms WHERE agent_id = $1",
    )
    .bind(id)
    .fetch_one(&db.pool)
    .await
    .unwrap();
    assert_eq!((name.as_deref(), members), (Some("Ops"), 2));
    let bodies: Vec<String> = sqlx::query_scalar(
        "SELECT content->>'body' FROM active_matrix_inbox WHERE agent_id = $1 ORDER BY id",
    )
    .bind(id)
    .fetch_all(&db.pool)
    .await
    .unwrap();
    assert_eq!(
        bodies,
        ["first", "second"],
        "inbox order is sync order, not event id order"
    );
    let display: Option<String> = sqlx::query_scalar(
        "SELECT display_name FROM active_matrix_room_members WHERE agent_id = $1 AND user_id = '@alice:matrix.test'",
    )
    .bind(id)
    .fetch_one(&db.pool)
    .await
    .unwrap();
    assert_eq!(display.as_deref(), Some("Alice"));
    let token: Option<String> =
        sqlx::query_scalar("SELECT sync_token FROM active_matrix_agents WHERE id = $1")
            .bind(id)
            .fetch_one(&db.pool)
            .await
            .unwrap();
    assert_eq!(token.as_deref(), Some("s1"));
    db.drop_schema().await;
}

#[tokio::test]
async fn applying_a_batch_twice_delivers_nothing_twice() {
    let db = db!();
    let id = claimed(&db, "bot").await;
    let batch = batch(messages("s1", "!r:matrix.test", &["$1", "$2"]), true);

    assert_eq!(
        ingest::apply(&db.pool, NODE, id, &batch)
            .await
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        ingest::apply(&db.pool, NODE, id, &batch).await.unwrap(),
        Vec::<String>::new()
    );

    let count = inbox_count(&db).await;
    assert_eq!(count, 2);
    db.drop_schema().await;
}

#[tokio::test]
async fn a_lost_lease_writes_nothing() {
    let db = db!();
    let id = claimed(&db, "bot").await;
    sqlx::query("UPDATE active_matrix_agents SET claimed_by = 'node-b'")
        .execute(&db.pool)
        .await
        .unwrap();

    let result = ingest::apply(
        &db.pool,
        NODE,
        id,
        &batch(messages("s9", "!r:matrix.test", &["$1"]), true),
    )
    .await;

    assert!(matches!(result, Err(ingest::IngestError::LeaseLost)));
    let count = inbox_count(&db).await;
    assert_eq!(count, 0);
    db.drop_schema().await;
}

#[tokio::test]
async fn later_batches_keep_fields_they_do_not_mention() {
    let db = db!();
    let id = claimed(&db, "bot").await;
    let named = batch(
        json!({ "next_batch": "s1", "rooms": { "join": { "!r:matrix.test": { "state": { "events": [
            { "type": "m.room.name", "state_key": "", "event_id": "$n", "sender": "@a:m", "content": { "name": "Ops" } },
        ] } } } } }),
        true,
    );
    ingest::apply(&db.pool, NODE, id, &named).await.unwrap();
    ingest::apply(
        &db.pool,
        NODE,
        id,
        &batch(messages("s2", "!r:matrix.test", &["$1"]), true),
    )
    .await
    .unwrap();

    let name: Option<String> =
        sqlx::query_scalar("SELECT name FROM active_matrix_rooms WHERE agent_id = $1")
            .bind(id)
            .fetch_one(&db.pool)
            .await
            .unwrap();
    assert_eq!(name.as_deref(), Some("Ops"));
    db.drop_schema().await;
}

#[tokio::test]
async fn m_direct_marks_direct_rooms() {
    let db = db!();
    let id = claimed(&db, "bot").await;
    ingest::apply(
        &db.pool,
        NODE,
        id,
        &batch(messages("s1", "!dm:matrix.test", &["$1"]), true),
    )
    .await
    .unwrap();
    ingest::apply(
        &db.pool,
        NODE,
        id,
        &batch(messages("s2", "!group:matrix.test", &["$2"]), true),
    )
    .await
    .unwrap();

    let direct = batch(
        json!({ "next_batch": "s3", "account_data": { "events": [
            { "type": "m.direct", "content": { "@alice:matrix.test": ["!dm:matrix.test"] } },
        ] } }),
        true,
    );
    ingest::apply(&db.pool, NODE, id, &direct).await.unwrap();

    let rows: Vec<(String, bool)> = sqlx::query_as(
        "SELECT room_id, direct FROM active_matrix_rooms WHERE agent_id = $1 ORDER BY room_id",
    )
    .bind(id)
    .fetch_all(&db.pool)
    .await
    .unwrap();
    assert_eq!(
        rows,
        [
            ("!dm:matrix.test".to_owned(), true),
            ("!group:matrix.test".to_owned(), false)
        ]
    );
    db.drop_schema().await;
}
