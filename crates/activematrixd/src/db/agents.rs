//! Agent rows: credentials, leases, runtime state.
//!
//! Every write after a claim is fenced on `claimed_by = node`, so a daemon
//! that lost its lease (another one took over after a missed heartbeat)
//! cannot overwrite the new owner's state.

use std::time::Duration;

use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct Agent {
    pub id: Uuid,
    pub name: String,
    pub homeserver_url: String,
    pub user_id: Option<String>,
    pub device_id: Option<String>,
    pub access_token_ciphertext: Option<Vec<u8>>,
    pub sync_token: Option<String>,
    pub enabled: bool,
    pub settings: Value,
}

const COLUMNS: &str = concat!(
    "id, name, homeserver_url, user_id, device_id, access_token_ciphertext, sync_token, ",
    "enabled, settings"
);

/// Runtime states, as the `active_matrix_agents_state` constraint allows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Offline,
    Starting,
    Online,
    Reconnecting,
    Failed,
}

impl State {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Offline => "offline",
            Self::Starting => "starting",
            Self::Online => "online",
            Self::Reconnecting => "reconnecting",
            Self::Failed => "failed",
        }
    }
}

pub async fn find_by_name(pool: &PgPool, name: &str) -> Result<Option<Agent>, sqlx::Error> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {COLUMNS} FROM active_matrix_agents WHERE name = $1"
    )))
    .bind(name)
    .fetch_optional(pool)
    .await
}

pub async fn store_credentials(
    pool: &PgPool,
    id: Uuid,
    user_id: &str,
    device_id: &str,
    ciphertext: &[u8],
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE active_matrix_agents SET user_id = $2, device_id = $3, access_token_ciphertext = $4,
         state = CASE WHEN state = 'failed' THEN 'offline' ELSE state END, last_error = NULL,
         updated_at = now()
         WHERE id = $1",
    )
    .bind(id)
    .bind(user_id)
    .bind(device_id)
    .bind(ciphertext)
    .execute(pool)
    .await
    .map(drop)
}

/// A token opened with the previous master key, sealed again with the
/// current one. Fenced: only the owner reseals.
pub async fn reseal(
    pool: &PgPool,
    node: &str,
    id: Uuid,
    ciphertext: &[u8],
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE active_matrix_agents SET access_token_ciphertext = $3
         WHERE id = $1 AND claimed_by = $2",
    )
    .bind(id)
    .bind(node)
    .bind(ciphertext)
    .execute(pool)
    .await
    .map(drop)
}

/// Claims up to `limit` runnable agents nobody holds (or whose lease
/// expired). Two daemons claiming at once never get the same agent. Failed
/// agents wait for `activematrix login`, which resets them.
pub async fn claim(
    pool: &PgPool,
    node: &str,
    ttl: Duration,
    limit: i64,
) -> Result<Vec<Agent>, sqlx::Error> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE active_matrix_agents SET claimed_by = $1,
           lease_expires_at = now() + make_interval(secs => $2), heartbeat_at = now(),
           state = 'starting', last_error = NULL, updated_at = now()
         WHERE id IN (
           SELECT id FROM active_matrix_agents
           WHERE enabled AND access_token_ciphertext IS NOT NULL AND state <> 'failed'
             AND (claimed_by IS NULL OR lease_expires_at < now())
           ORDER BY id LIMIT $3 FOR UPDATE SKIP LOCKED)
         RETURNING {COLUMNS}"
    )))
    .bind(node)
    .bind(ttl.as_secs_f64())
    .bind(limit)
    .fetch_all(pool)
    .await
}

/// Extends the leases this node holds on `ids`. Returns (id, enabled) for
/// each lease still held; an id missing from the answer was lost.
pub async fn renew(
    pool: &PgPool,
    node: &str,
    ttl: Duration,
    ids: &[Uuid],
) -> Result<Vec<(Uuid, bool)>, sqlx::Error> {
    sqlx::query_as(
        "UPDATE active_matrix_agents SET lease_expires_at = now() + make_interval(secs => $3),
         heartbeat_at = now()
         WHERE id = ANY ($1) AND claimed_by = $2
         RETURNING id, enabled",
    )
    .bind(ids)
    .bind(node)
    .bind(ttl.as_secs_f64())
    .fetch_all(pool)
    .await
}

/// Gives the leases back. The agents are left offline for the next claimer,
/// or failed, which `claim` skips until they log in again.
pub async fn release(
    pool: &PgPool,
    node: &str,
    ids: &[Uuid],
    failed: bool,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE active_matrix_agents SET claimed_by = NULL, lease_expires_at = NULL,
         state = CASE WHEN $3 THEN 'failed' ELSE 'offline' END, updated_at = now()
         WHERE id = ANY ($1) AND claimed_by = $2",
    )
    .bind(ids)
    .bind(node)
    .bind(failed)
    .execute(pool)
    .await
    .map(drop)
}

/// Records a runtime state change. `error` is kept with `failed` and
/// `reconnecting`, cleared otherwise.
pub async fn set_state(
    pool: &PgPool,
    node: &str,
    id: Uuid,
    state: State,
    error: Option<&str>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE active_matrix_agents SET state = $3, last_error = $4,
         last_error_at = CASE WHEN $4::text IS NULL THEN last_error_at ELSE now() END,
         updated_at = now()
         WHERE id = $1 AND claimed_by = $2",
    )
    .bind(id)
    .bind(node)
    .bind(state.as_str())
    .bind(error)
    .execute(pool)
    .await
    .map(drop)
}
