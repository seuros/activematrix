//! Executing what Rails wrote to the outbox.
//!
//! The row id is the Matrix transaction id, so a command retried after a
//! crash or a timeout reaches the room once. Each agent's commands run one
//! at a time in creation order, which keeps per-room order.
//!
//! Payloads, by kind (`room_id` is the row's column):
//! - `send`: `{event_type, content}` → `{event_id}`
//! - `state`: `{event_type, state_key?, content}` → `{event_id}`
//! - `redact`: `{event_id, reason?}` → `{event_id}`
//! - `join`: `{room?}` (an alias, else `room_id`) → `{room_id}`
//! - `leave`: `{}`; `invite`, `kick`, `ban`, `unban`: `{user_id, reason?}`
//! - `create_room`: a `/createRoom` body → `{room_id}`
//! - `typing`: `{typing, timeout_ms?}`; `receipt`: `{event_id, receipt_type?}`
//! - `profile`: `{displayname?, avatar_url?}`
//! - `upload`: `{content_type, filename?}` with the bytes in `blob` → `{content_uri}`

use std::time::Duration;

use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use crate::matrix::{Client, MatrixError};

/// A failure the daemon gives up on after this many attempts.
pub const MAX_ATTEMPTS: i32 = 8;

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct Command {
    pub id: Uuid,
    pub kind: String,
    pub room_id: Option<String>,
    pub payload: Value,
    pub blob: Option<Vec<u8>>,
    pub attempts: i32,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum CommandError {
    #[error("invalid {kind} command: {reason}")]
    Invalid { kind: String, reason: String },
    #[error(transparent)]
    Matrix(#[from] MatrixError),
}

impl CommandError {
    pub const fn is_retryable(&self) -> bool {
        match self {
            Self::Invalid { .. } => false,
            Self::Matrix(error) => error.is_retryable(),
        }
    }
}

/// Runs one command against the homeserver and returns its result.
pub async fn execute(client: &Client, command: &Command) -> Result<Value, CommandError> {
    let txn = command.id.to_string();
    let invalid = |reason: &str| CommandError::Invalid {
        kind: command.kind.clone(),
        reason: reason.to_owned(),
    };
    let field = |name: &str| command.payload.get(name).and_then(Value::as_str);
    let require = |name: &str| field(name).ok_or_else(|| invalid(&format!("{name} is required")));
    let content = || {
        command
            .payload
            .get("content")
            .ok_or_else(|| invalid("content is required"))
    };
    let room = || {
        command
            .room_id
            .as_deref()
            .ok_or_else(|| invalid("room_id is required"))
    };

    let result = match command.kind.as_str() {
        "send" => {
            let event_type = require("event_type")?;
            let content = content()?;
            json!({ "event_id": client.send_event(room()?, event_type, &txn, content).await? })
        }
        "state" => {
            let event_type = require("event_type")?;
            let content = content()?;
            let state_key = field("state_key").unwrap_or_default();
            json!({ "event_id": client.put_state(room()?, event_type, state_key, content).await? })
        }
        "redact" => {
            let event_id = require("event_id")?;
            json!({ "event_id": client.redact(room()?, event_id, &txn, field("reason")).await? })
        }
        "join" => {
            let target = field("room").map_or_else(room, Ok)?;
            json!({ "room_id": client.join(target).await? })
        }
        "leave" => {
            client
                .membership(room()?, "leave", None, field("reason"))
                .await?;
            json!({})
        }
        "invite" | "kick" | "ban" | "unban" => {
            let user_id = require("user_id")?;
            client
                .membership(room()?, &command.kind, Some(user_id), field("reason"))
                .await?;
            json!({})
        }
        "create_room" => json!({ "room_id": client.create_room(&command.payload).await? }),
        "typing" => {
            let typing = command
                .payload
                .get("typing")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            let timeout = command
                .payload
                .get("timeout_ms")
                .and_then(Value::as_u64)
                .unwrap_or(30_000);
            client
                .typing(room()?, typing, Duration::from_millis(timeout))
                .await?;
            json!({})
        }
        "receipt" => {
            let event_id = require("event_id")?;
            client
                .receipt(room()?, event_id, field("receipt_type").unwrap_or("m.read"))
                .await?;
            json!({})
        }
        "profile" => {
            for name in ["displayname", "avatar_url"] {
                if let Some(value) = field(name) {
                    client.set_profile(name, value).await?;
                }
            }
            json!({})
        }
        "upload" => {
            let content_type = require("content_type")?;
            let bytes = command
                .blob
                .clone()
                .ok_or_else(|| invalid("blob is required"))?;
            json!({ "content_uri": client.upload(content_type, field("filename"), bytes).await? })
        }
        other => return Err(invalid(&format!("unknown kind {other:?}"))),
    };
    Ok(result)
}

/// Rows a previous run of this agent left mid-send go back to pending. Safe:
/// their transaction ids make a resend a no-op on the homeserver.
pub async fn recover(pool: &PgPool, node: &str, agent_id: Uuid) -> Result<u64, sqlx::Error> {
    sqlx::query(
        "UPDATE active_matrix_outbox o SET status = 'pending', updated_at = now()
         FROM active_matrix_agents a
         WHERE o.agent_id = $1 AND o.status = 'sending' AND a.id = o.agent_id AND a.claimed_by = $2",
    )
    .bind(agent_id)
    .bind(node)
    .execute(pool)
    .await
    .map(|done| done.rows_affected())
}

/// Takes up to `limit` pending commands of an agent this node holds, oldest
/// first, and marks them sending.
pub async fn claim(
    pool: &PgPool,
    node: &str,
    agent_id: Uuid,
    limit: i64,
) -> Result<Vec<Command>, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let ids: Vec<Uuid> = sqlx::query_scalar(
        "SELECT o.id FROM active_matrix_outbox o JOIN active_matrix_agents a ON a.id = o.agent_id
         WHERE o.agent_id = $1 AND a.claimed_by = $2 AND o.status = 'pending'
         ORDER BY o.created_at, o.id LIMIT $3
         FOR UPDATE OF o SKIP LOCKED",
    )
    .bind(agent_id)
    .bind(node)
    .bind(limit)
    .fetch_all(&mut *tx)
    .await?;
    if ids.is_empty() {
        tx.rollback().await?;
        return Ok(Vec::new());
    }
    let mut commands: Vec<Command> = sqlx::query_as(
        "UPDATE active_matrix_outbox SET status = 'sending', attempts = attempts + 1, updated_at = now()
         WHERE id = ANY ($1) RETURNING id, kind, room_id, payload, blob, attempts",
    )
    .bind(&ids)
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;
    commands.sort_by_key(|command| ids.iter().position(|id| *id == command.id));
    Ok(commands)
}

/// Puts claimed commands back untried, so they keep their place in line.
pub async fn unclaim(pool: &PgPool, ids: &[Uuid]) -> Result<(), sqlx::Error> {
    if ids.is_empty() {
        return Ok(());
    }
    sqlx::query(
        "UPDATE active_matrix_outbox SET status = 'pending', attempts = greatest(attempts - 1, 0), updated_at = now()
         WHERE id = ANY ($1) AND status = 'sending'",
    )
    .bind(ids)
    .execute(pool)
    .await
    .map(drop)
}

/// What happened to a command, written back for Rails.
#[derive(Debug)]
pub enum Outcome {
    Sent(Value),
    Failed(String),
    Retry(String),
}

pub async fn complete(pool: &PgPool, id: Uuid, outcome: &Outcome) -> Result<(), sqlx::Error> {
    let mut tx = pool.begin().await?;
    match outcome {
        Outcome::Sent(result) => {
            sqlx::query(
                "UPDATE active_matrix_outbox SET status = 'sent', result = $2, last_error = NULL, sent_at = now(),
                 updated_at = now() WHERE id = $1",
            )
            .bind(id)
            .bind(sqlx::types::Json(result))
            .execute(&mut *tx)
            .await?;
        }
        Outcome::Failed(error) | Outcome::Retry(error) => {
            let status = if matches!(outcome, Outcome::Failed(_)) {
                "failed"
            } else {
                "pending"
            };
            sqlx::query("UPDATE active_matrix_outbox SET status = $2, last_error = $3, updated_at = now() WHERE id = $1")
                .bind(id)
                .bind(status)
                .bind(error)
                .execute(&mut *tx)
                .await?;
        }
    }
    if !matches!(outcome, Outcome::Retry(_)) {
        sqlx::query("SELECT pg_notify('active_matrix_outbox_done', $1)")
            .bind(id.to_string())
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await
}

/// Decides a command's outcome from an execution result.
pub fn outcome(command: &Command, result: Result<Value, CommandError>) -> Outcome {
    match result {
        Ok(result) => Outcome::Sent(result),
        Err(error) if error.is_retryable() && command.attempts < MAX_ATTEMPTS => {
            Outcome::Retry(error.to_string())
        }
        Err(error) => Outcome::Failed(error.to_string()),
    }
}

#[cfg(test)]
mod tests;
