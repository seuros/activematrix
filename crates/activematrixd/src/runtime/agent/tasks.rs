//! The tasks an agent runs: connecting, the sync loop, the outbox worker.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::sync::Notify;
use uuid::Uuid;

use super::{Env, Failure, SharedReport, report};
use crate::crypto::CryptoError;
use crate::db::agents::{self, Agent, State};
use crate::db::ingest::{self as db_ingest, IngestError};
use crate::matrix::sync::{FILTER, FIRST_SYNC_FILTER};
use crate::matrix::{Client, Homeserver, MatrixError};
use crate::runtime::{backoff, metrics};
use crate::{ingest, outbox};

/// How long a `/sync` long-poll waits for events.
const SYNC_TIMEOUT: Duration = Duration::from_secs(30);
const OUTBOX_IDLE: Duration = Duration::from_secs(5);

/// Opens the token and checks it against the homeserver.
pub(super) async fn connect(agent: &Agent, env: &Env) -> Result<Client, Failure> {
    let Some(ciphertext) = &agent.access_token_ciphertext else {
        return Err(Failure::Fatal("no access token; run `activematrix login`".into()));
    };
    let opened = env.key.open(agent.id, ciphertext).map_err(|error| match error {
        CryptoError::Unauthentic => Failure::Fatal(
            "the access token does not open with the master key; run `activematrix login`".into(),
        ),
        other => Failure::Fatal(other.to_string()),
    })?;
    if opened.stale {
        match env.key.seal(agent.id, &opened.token) {
            Ok(resealed) => {
                if let Err(error) = agents::reseal(&env.db, &env.node, agent.id, &resealed).await {
                    tracing::warn!(agent = %agent.name, %error, "could not reseal the token");
                }
            }
            Err(error) => tracing::warn!(agent = %agent.name, %error, "could not reseal the token"),
        }
    }

    let homeserver = Homeserver::new(&agent.homeserver_url);
    let provisional = Client::new(
        homeserver.clone(),
        opened.token.clone(),
        agent.user_id.clone().unwrap_or_default(),
    );
    let whoami = provisional.whoami().await.map_err(|error| match error {
        MatrixError::UnknownToken => Failure::Fatal(
            "the homeserver rejected the access token; run `activematrix login`".into(),
        ),
        other => Failure::Transient(other.to_string()),
    })?;
    if let Some(expected) = &agent.user_id
        && expected != &whoami.user_id
    {
        return Err(Failure::Fatal(format!(
            "the access token belongs to {}, not {expected}",
            whoami.user_id
        )));
    }
    Ok(Client::new(homeserver, opened.token, whoami.user_id))
}

/// Syncs until something goes wrong, committing every batch with its token.
pub(super) async fn sync_loop(
    client: Client,
    env: &Env,
    agent: &Agent,
    healthy: &AtomicBool,
    shared: &SharedReport,
) -> Failure {
    let mut since = agent.sync_token.clone();
    // The first request of a run returns at once, catching up, so the agent
    // is online as soon as it is current; long-polling starts after that.
    let mut online = false;
    loop {
        let first = since.is_none();
        let filter = if first { FIRST_SYNC_FILTER } else { FILTER };
        let timeout = if online { SYNC_TIMEOUT } else { Duration::ZERO };
        let response = match client.sync(since.as_deref(), timeout, filter).await {
            Ok(response) => response,
            Err(MatrixError::UnknownToken) => {
                return Failure::Fatal(
                    "the homeserver rejected the access token; run `activematrix login`".into(),
                );
            }
            Err(MatrixError::RateLimited(after)) => {
                tokio::time::sleep(after).await;
                continue;
            }
            Err(error) => return Failure::Transient(error.to_string()),
        };
        let batch = ingest::plan(response, client.user_id(), !first);
        let queued = batch.inbox.len() as u64;
        match db_ingest::apply(&env.db, &env.node, agent.id, &batch).await {
            Ok(touched) => {
                metrics::SYNC_BATCHES.add(1);
                metrics::INBOX_EVENTS.add(queued);
                for room_id in touched {
                    // The delivery loop only goes away at shutdown.
                    let _ = env.delivery.send((agent.id, room_id));
                }
                since = Some(batch.next_batch);
                healthy.store(true, Ordering::Relaxed);
                if !online {
                    online = true;
                    report(shared, State::Online, None);
                    if let Err(error) =
                        agents::set_state(&env.db, &env.node, agent.id, State::Online, None).await
                    {
                        tracing::warn!(agent = %agent.name, %error, "could not record state");
                    }
                    tracing::info!(agent = %agent.name, user = client.user_id(), "online");
                }
            }
            Err(IngestError::LeaseLost) => return Failure::LeaseLost,
            Err(IngestError::Database(error)) => {
                return Failure::Transient(format!("database: {error}"));
            }
        }
    }
}

/// Sends the agent's outbox, oldest first, one command at a time.
pub(super) async fn outbox_worker(client: Client, env: &Env, agent_id: Uuid, wake: &Notify) {
    if let Err(error) = outbox::recover(&env.db, &env.node, agent_id).await {
        tracing::warn!(%agent_id, %error, "could not recover interrupted sends");
    }
    loop {
        let commands = match outbox::claim(&env.db, &env.node, agent_id, 20).await {
            Ok(commands) => commands,
            Err(error) => {
                tracing::warn!(%agent_id, %error, "could not claim outbox commands");
                tokio::time::sleep(OUTBOX_IDLE).await;
                continue;
            }
        };
        if commands.is_empty() {
            tokio::select! {
                () = wake.notified() => {}
                () = tokio::time::sleep(OUTBOX_IDLE) => {}
            }
            continue;
        }
        for (index, command) in commands.iter().enumerate() {
            let result = outbox::execute(&client, command).await;
            let retry_after = result.as_ref().err().and_then(|error| match error {
                outbox::CommandError::Matrix(error) => error.retry_after(),
                outbox::CommandError::Invalid { .. } => None,
            });
            let outcome = outbox::outcome(command, result);
            match &outcome {
                outbox::Outcome::Sent(_) => metrics::OUTBOX_SENT.add(1),
                outbox::Outcome::Retry(_) => metrics::OUTBOX_RETRIED.add(1),
                outbox::Outcome::Failed(error) => {
                    metrics::OUTBOX_FAILED.add(1);
                    tracing::warn!(
                        %agent_id, command = %command.id, %error, "outbox command failed"
                    );
                }
            }
            if let Err(error) = outbox::complete(&env.db, command.id, &outcome).await {
                tracing::warn!(%agent_id, %error, "could not record an outbox result");
            }
            if matches!(outcome, outbox::Outcome::Retry(_)) {
                // Keep per-room order: everything after it waits too.
                let rest: Vec<Uuid> = commands[index + 1..].iter().map(|c| c.id).collect();
                if let Err(error) = outbox::unclaim(&env.db, &rest).await {
                    tracing::warn!(%agent_id, %error, "could not put commands back");
                }
                let attempts = u8::try_from(command.attempts).unwrap_or(u8::MAX);
                tokio::time::sleep(retry_after.unwrap_or_else(|| backoff(attempts))).await;
                break;
            }
        }
    }
}
