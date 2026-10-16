//! Postgres: the only channel between the daemon and Rails.
//!
//! The tables belong to the Rails engine's migrations. The daemon checks at
//! boot that the columns it uses exist, so a missing migration fails with a
//! message rather than with an SQL error minutes later.

pub mod agents;
pub mod ingest;

use std::collections::BTreeSet;
use std::time::Duration;

use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;

/// The columns the daemon reads or writes, per table.
pub const REQUIRED: &[(&str, &[&str])] = &[
    (
        "active_matrix_agents",
        &[
            "id",
            "name",
            "homeserver_url",
            "user_id",
            "device_id",
            "access_token_ciphertext",
            "enabled",
            "state",
            "sync_token",
            "settings",
            "last_error",
            "last_error_at",
            "heartbeat_at",
            "claimed_by",
            "lease_expires_at",
        ],
    ),
    (
        "active_matrix_rooms",
        &[
            "agent_id",
            "room_id",
            "membership",
            "name",
            "topic",
            "canonical_alias",
            "avatar_url",
            "room_type",
            "encrypted",
            "direct",
            "joined_member_count",
            "invited_member_count",
            "updated_at",
        ],
    ),
    (
        "active_matrix_room_members",
        &["agent_id", "room_id", "user_id", "membership", "display_name", "avatar_url"],
    ),
    (
        "active_matrix_room_state",
        &["agent_id", "room_id", "event_type", "state_key", "event_id", "sender", "content"],
    ),
    (
        "active_matrix_inbox",
        &[
            "id",
            "agent_id",
            "room_id",
            "event_id",
            "kind",
            "event_type",
            "sender",
            "state_key",
            "content",
            "raw",
            "origin_server_ts",
            "processed_at",
            "created_at",
        ],
    ),
    (
        "active_matrix_outbox",
        &[
            "id",
            "agent_id",
            "kind",
            "room_id",
            "payload",
            "blob",
            "status",
            "attempts",
            "result",
            "last_error",
            "sent_at",
            "created_at",
            "updated_at",
        ],
    ),
];

#[derive(Debug, thiserror::Error)]
pub enum SchemaError {
    #[error(
        "the database is missing ActiveMatrix tables or columns ({0}); run \
         `bin/rails active_matrix:install:migrations db:migrate`"
    )]
    Missing(String),
    #[error(transparent)]
    Database(#[from] sqlx::Error),
}

#[derive(Clone)]
pub struct Db {
    pool: PgPool,
}

impl Db {
    pub async fn connect(url: &str, max_connections: u32) -> Result<Self, sqlx::Error> {
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .acquire_timeout(Duration::from_secs(10))
            .connect(url)
            .await?;
        Ok(Self { pool })
    }

    pub const fn from_pool(pool: PgPool) -> Self {
        Self { pool }
    }

    pub const fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Fails with every missing `table.column` listed.
    pub async fn verify_schema(&self) -> Result<(), SchemaError> {
        let tables: Vec<&str> = REQUIRED.iter().map(|(table, _)| *table).collect();
        let present: Vec<(String, String)> = sqlx::query_as(
            "SELECT table_name::text, column_name::text FROM information_schema.columns
             WHERE table_schema = ANY (current_schemas(false)) AND table_name = ANY ($1)",
        )
        .bind(&tables)
        .fetch_all(&self.pool)
        .await?;
        let present: BTreeSet<(String, String)> = present.into_iter().collect();

        let missing: Vec<String> = REQUIRED
            .iter()
            .flat_map(|(table, columns)| columns.iter().map(move |column| (*table, *column)))
            .filter(|(table, column)| {
                !present.contains(&((*table).to_owned(), (*column).to_owned()))
            })
            .map(|(table, column)| format!("{table}.{column}"))
            .collect();
        if missing.is_empty() { Ok(()) } else { Err(SchemaError::Missing(missing.join(", "))) }
    }
}
