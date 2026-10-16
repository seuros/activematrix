//! `activematrixd login`, as a person runs it.

// A test-only crate: a panic is a failed test, which is what unwrap is for.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::io::Write as _;
use std::process::{Command, Stdio};

use activematrix_fakehs::FakeHomeserver;
use activematrixd::crypto::MasterKey;
use common::TestDb;
use uuid::Uuid;

fn login(db: &TestDb, key: &str, args: &[&str], stdin: &str) -> std::process::Output {
    let dir = tempfile::tempdir().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_activematrixd"))
        .arg("login")
        .args(args)
        .env_clear()
        .env("ACTIVEMATRIX_DATABASE_URL", db.scoped_url())
        .env("ACTIVEMATRIX_MASTER_KEY", key)
        .current_dir(dir.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

async fn credentials(
    db: &TestDb,
    agent: Uuid,
) -> (Option<String>, Option<String>, Option<Vec<u8>>) {
    sqlx::query_as("SELECT user_id, device_id, access_token_ciphertext FROM active_matrix_agents WHERE id = $1")
        .bind(agent)
        .fetch_one(&db.pool)
        .await
        .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_token_from_stdin_is_checked_and_sealed() {
    let Some(db) = TestDb::new().await else {
        return;
    };
    let homeserver = FakeHomeserver::start().await.unwrap();
    let token = homeserver.add_user("bot", None);
    let agent = db.agent("bot", &homeserver.url(), None).await;
    let key = MasterKey::generate();

    let out = login(&db, &key, &["bot", "--token-stdin"], &format!("{token}\n"));

    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(String::from_utf8_lossy(&out.stdout).contains("@bot:matrix.test"));
    let (user_id, device_id, sealed) = credentials(&db, agent).await;
    assert_eq!(user_id.as_deref(), Some("@bot:matrix.test"));
    assert!(device_id.is_some());
    let opened = MasterKey::from_base64(&key, None)
        .unwrap()
        .open(agent, &sealed.unwrap())
        .unwrap();
    assert_eq!(
        opened.token.expose(),
        token,
        "sealed for this agent with this key"
    );
    db.drop_schema().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_password_from_stdin_logs_in() {
    let Some(db) = TestDb::new().await else {
        return;
    };
    let homeserver = FakeHomeserver::start().await.unwrap();
    homeserver.add_user("bot", Some("hunter2"));
    let agent = db.agent("bot", &homeserver.url(), None).await;

    let out = login(
        &db,
        &MasterKey::generate(),
        &["bot", "--password-stdin"],
        "hunter2\n",
    );

    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(credentials(&db, agent).await.2.is_some());
    db.drop_schema().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn bad_credentials_and_unknown_agents_store_nothing() {
    let Some(db) = TestDb::new().await else {
        return;
    };
    let homeserver = FakeHomeserver::start().await.unwrap();
    homeserver.add_user("bot", Some("hunter2"));
    let agent = db.agent("bot", &homeserver.url(), None).await;
    let key = MasterKey::generate();

    let wrong = login(&db, &key, &["bot", "--password-stdin"], "wrong\n");
    let unknown = login(&db, &key, &["nobody", "--token-stdin"], "t\n");

    assert!(!wrong.status.success());
    assert!(String::from_utf8_lossy(&unknown.stderr).contains("no agent named"));
    assert_eq!(credentials(&db, agent).await.2, None);
    db.drop_schema().await;
}
