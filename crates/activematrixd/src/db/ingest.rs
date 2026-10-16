//! Writing one planned sync batch, exactly once.
//!
//! One transaction holds the mirror upserts, the inbox inserts and the new
//! sync token. If it commits, the batch is in and the next sync starts after
//! it; if it does not, nothing changed and the same batch is fetched again.
//! The inbox insert ignores event ids it already has, so a batch applied
//! twice delivers nothing twice.
//!
//! The transaction first locks the agent row and checks the lease: a daemon
//! that lost the agent to another one cannot move its sync position.

use sqlx::types::Json;
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::ingest::Batch;

#[derive(Debug, thiserror::Error)]
pub enum IngestError {
    #[error("the lease on this agent was lost")]
    LeaseLost,
    #[error(transparent)]
    Database(#[from] sqlx::Error),
}

/// Applies `batch` and returns the rooms that got new inbox events.
pub async fn apply(
    pool: &PgPool,
    node: &str,
    agent_id: Uuid,
    batch: &Batch,
) -> Result<Vec<String>, IngestError> {
    let mut tx = pool.begin().await?;

    let held: Option<i32> = sqlx::query_scalar(
        "SELECT 1 FROM active_matrix_agents WHERE id = $1 AND claimed_by = $2 FOR UPDATE",
    )
    .bind(agent_id)
    .bind(node)
    .fetch_optional(&mut *tx)
    .await?;
    if held.is_none() {
        return Err(IngestError::LeaseLost);
    }

    upsert_rooms(&mut tx, agent_id, batch).await?;
    upsert_state(&mut tx, agent_id, batch).await?;
    upsert_members(&mut tx, agent_id, batch).await?;
    if let Some(direct) = &batch.direct_rooms {
        sqlx::query(
            "UPDATE active_matrix_rooms SET direct = (room_id = ANY ($2)) WHERE agent_id = $1",
        )
        .bind(agent_id)
        .bind(direct)
        .execute(&mut *tx)
        .await?;
    }
    let mut touched = insert_inbox(&mut tx, agent_id, batch).await?;

    sqlx::query("UPDATE active_matrix_agents SET sync_token = $3, updated_at = now() WHERE id = $1 AND claimed_by = $2")
        .bind(agent_id)
        .bind(node)
        .bind(&batch.next_batch)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    touched.sort();
    touched.dedup();
    Ok(touched)
}

/// New rooms are inserted with defaults, then every room in the batch takes
/// the fields the batch changed. Two steps, because NOT NULL columns cannot
/// carry "unchanged" through an upsert.
async fn upsert_rooms(
    tx: &mut Transaction<'_, Postgres>,
    agent_id: Uuid,
    batch: &Batch,
) -> sqlx::Result<()> {
    if batch.rooms.is_empty() {
        return Ok(());
    }
    let rooms = Json(&batch.rooms);
    sqlx::query(
        "INSERT INTO active_matrix_rooms (agent_id, room_id, membership)
         SELECT $1, r.room_id, r.membership FROM jsonb_to_recordset($2::jsonb) AS r(room_id text, membership text)
         ON CONFLICT (agent_id, room_id) DO NOTHING",
    )
    .bind(agent_id)
    .bind(rooms)
    .execute(&mut **tx)
    .await?;
    sqlx::query(
        "UPDATE active_matrix_rooms AS room SET
           membership = r.membership,
           name = COALESCE(r.name, room.name),
           topic = COALESCE(r.topic, room.topic),
           canonical_alias = COALESCE(r.canonical_alias, room.canonical_alias),
           avatar_url = COALESCE(r.avatar_url, room.avatar_url),
           room_type = COALESCE(r.room_type, room.room_type),
           encrypted = COALESCE(r.encrypted, room.encrypted),
           joined_member_count = COALESCE(r.joined_member_count, room.joined_member_count),
           invited_member_count = COALESCE(r.invited_member_count, room.invited_member_count),
           updated_at = now()
         FROM jsonb_to_recordset($2::jsonb) AS r(
           room_id text, membership text, name text, topic text, canonical_alias text, avatar_url text,
           room_type text, encrypted boolean, joined_member_count integer, invited_member_count integer)
         WHERE room.agent_id = $1 AND room.room_id = r.room_id",
    )
    .bind(agent_id)
    .bind(rooms)
    .execute(&mut **tx)
    .await
    .map(drop)
}

async fn upsert_state(
    tx: &mut Transaction<'_, Postgres>,
    agent_id: Uuid,
    batch: &Batch,
) -> sqlx::Result<()> {
    if batch.state.is_empty() {
        return Ok(());
    }
    sqlx::query(
        "INSERT INTO active_matrix_room_state (agent_id, room_id, event_type, state_key, event_id, sender, content)
         SELECT $1, s.room_id, s.event_type, s.state_key, s.event_id, s.sender, s.content
         FROM jsonb_to_recordset($2::jsonb) AS s(
           room_id text, event_type text, state_key text, event_id text, sender text, content jsonb)
         ON CONFLICT (agent_id, room_id, event_type, state_key) DO UPDATE SET
           event_id = EXCLUDED.event_id, sender = EXCLUDED.sender, content = EXCLUDED.content, updated_at = now()",
    )
    .bind(agent_id)
    .bind(Json(&batch.state))
    .execute(&mut **tx)
    .await
    .map(drop)
}

async fn upsert_members(
    tx: &mut Transaction<'_, Postgres>,
    agent_id: Uuid,
    batch: &Batch,
) -> sqlx::Result<()> {
    if batch.members.is_empty() {
        return Ok(());
    }
    sqlx::query(
        "INSERT INTO active_matrix_room_members (agent_id, room_id, user_id, membership, display_name, avatar_url)
         SELECT $1, m.room_id, m.user_id, m.membership, m.display_name, m.avatar_url
         FROM jsonb_to_recordset($2::jsonb) AS m(
           room_id text, user_id text, membership text, display_name text, avatar_url text)
         ON CONFLICT (agent_id, room_id, user_id) DO UPDATE SET
           membership = EXCLUDED.membership, display_name = EXCLUDED.display_name,
           avatar_url = EXCLUDED.avatar_url, updated_at = now()",
    )
    .bind(agent_id)
    .bind(Json(&batch.members))
    .execute(&mut **tx)
    .await
    .map(drop)
}

/// Inserts in `seq` order, so inbox ids follow the order the events came in.
async fn insert_inbox(
    tx: &mut Transaction<'_, Postgres>,
    agent_id: Uuid,
    batch: &Batch,
) -> sqlx::Result<Vec<String>> {
    if batch.inbox.is_empty() {
        return Ok(Vec::new());
    }
    sqlx::query_scalar(
        "INSERT INTO active_matrix_inbox
           (agent_id, room_id, event_id, kind, event_type, sender, state_key, content, raw, origin_server_ts)
         SELECT $1, i.room_id, i.event_id, i.kind, i.event_type, i.sender, i.state_key, i.content, i.raw,
                i.origin_server_ts
         FROM jsonb_to_recordset($2::jsonb) AS i(
           seq integer, room_id text, event_id text, kind text, event_type text, sender text, state_key text,
           content jsonb, raw jsonb, origin_server_ts bigint)
         ORDER BY i.seq
         ON CONFLICT (agent_id, event_id) DO NOTHING
         RETURNING room_id",
    )
    .bind(agent_id)
    .bind(Json(&batch.inbox))
    .fetch_all(&mut **tx)
    .await
}
