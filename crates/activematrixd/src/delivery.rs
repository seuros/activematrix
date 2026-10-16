//! Pushing `(agent, room)` pairs to the Rails app, which enqueues the jobs
//! that run the bots.
//!
//! A push is a hint, not the data: Rails reads the events from the inbox.
//! So pushes are coalesced, retried until Rails accepts them, and repeated
//! for anything left unprocessed (a lost push, a crashed job), which makes
//! delivery at-least-once while the inbox keeps handling exactly-once.

pub mod signature;

use std::collections::BTreeSet;
use std::time::Duration;

use rama::http::body::util::BodyExt;
use rama::http::client::DefaultHttpWebClient;
use rama::http::service::client::HttpClientExt;
use serde_json::json;
use sqlx::PgPool;
use tokio::sync::{mpsc, watch};
use uuid::Uuid;

use crate::config::Delivery;

pub type Pair = (Uuid, String);

#[derive(Debug, thiserror::Error)]
pub enum PushError {
    #[error("delivery endpoint unreachable: {0}")]
    Transport(String),
    #[error("delivery endpoint answered HTTP {0}")]
    Status(u16),
}

/// Signs and POSTs pushes.
#[derive(Clone)]
pub struct Pusher {
    target: Delivery,
    http: DefaultHttpWebClient,
}

impl Pusher {
    pub fn new(target: Delivery) -> Self {
        crate::matrix::install_crypto_provider();
        Self { target, http: DefaultHttpWebClient::default() }
    }

    pub async fn push(&self, pairs: &BTreeSet<Pair>) -> Result<(), PushError> {
        let rooms: Vec<_> = pairs
            .iter()
            .map(|(agent_id, room_id)| json!({ "agent_id": agent_id, "room_id": room_id }))
            .collect();
        let body = json!({ "rooms": rooms }).to_string();
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| i64::try_from(since.as_secs()).unwrap_or(i64::MAX));
        let signature = signature::sign(&self.target.secret, timestamp, body.as_bytes());

        let exchange = async {
            let response = self
                .http
                .post(self.target.url.as_str())
                .header("content-type", "application/json")
                .header(signature::TIMESTAMP_HEADER, timestamp.to_string())
                .header(signature::SIGNATURE_HEADER, signature)
                .body(body)
                .send()
                .await
                .map_err(|e| PushError::Transport(e.to_string()))?;
            let status = response.status().as_u16();
            // Drain the body so the pooled connection can be reused.
            let _ = response.into_body().collect().await;
            Ok::<_, PushError>(status)
        };
        let status = tokio::time::timeout(Duration::from_secs(10), exchange)
            .await
            .map_err(|_| PushError::Transport("timed out".into()))??;
        if (200..300).contains(&status) { Ok(()) } else { Err(PushError::Status(status)) }
    }
}

/// Inbox rows this node's agents ingested more than `older_than` ago that
/// Rails has not processed.
pub async fn unprocessed(
    pool: &PgPool,
    node: &str,
    older_than: Duration,
) -> Result<Vec<Pair>, sqlx::Error> {
    sqlx::query_as(
        "SELECT DISTINCT i.agent_id, i.room_id FROM active_matrix_inbox i
         JOIN active_matrix_agents a ON a.id = i.agent_id
         WHERE i.processed_at IS NULL AND a.claimed_by = $1
           AND i.created_at < now() - make_interval(secs => $2)",
    )
    .bind(node)
    .bind(older_than.as_secs_f64())
    .fetch_all(pool)
    .await
}

/// The delivery loop: coalesces queued pairs, pushes them, retries with
/// backoff, and sweeps for unprocessed rows every `sweep`.
pub async fn run(
    pusher: Pusher,
    pool: PgPool,
    node: String,
    mut queue: mpsc::UnboundedReceiver<Pair>,
    sweep: Duration,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut pending = BTreeSet::new();
    let mut failures: u8 = 0;
    let mut sweep_timer = tokio::time::interval(sweep);
    sweep_timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            pair = queue.recv() => match pair {
                Some(pair) => { pending.insert(pair); }
                None => break,
            },
            _ = sweep_timer.tick() => match unprocessed(&pool, &node, sweep).await {
                Ok(pairs) => pending.extend(pairs),
                Err(error) => tracing::warn!(%error, "delivery sweep failed"),
            },
            _ = shutdown.changed() => break,
        }
        while let Ok(pair) = queue.try_recv() {
            pending.insert(pair);
        }
        if pending.is_empty() {
            continue;
        }
        match pusher.push(&pending).await {
            Ok(()) => {
                tracing::debug!(rooms = pending.len(), "delivered");
                crate::runtime::metrics::DELIVERIES.add(1);
                pending.clear();
                failures = 0;
            }
            Err(error) => {
                crate::runtime::metrics::DELIVERY_FAILURES.add(1);
                failures = failures.saturating_add(1);
                let delay = crate::runtime::backoff(failures);
                tracing::warn!(%error, ?delay, rooms = pending.len(), "delivery failed; retrying");
                tokio::select! {
                    () = tokio::time::sleep(delay) => {}
                    _ = shutdown.changed() => break,
                }
            }
        }
    }
}
