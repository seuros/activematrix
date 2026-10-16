//! Turning one `/sync` response into the rows to write.
//!
//! Pure: no database, so every rule here is unit-tested. Rows are
//! de-duplicated by their keys with the last event winning, the way state
//! resolves within a batch, because one upsert statement cannot touch a
//! row twice.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::matrix::sync::{Events, SyncResponse};

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Batch {
    pub next_batch: String,
    pub rooms: Vec<RoomRow>,
    pub state: Vec<StateRow>,
    pub members: Vec<MemberRow>,
    pub inbox: Vec<InboxRow>,
    /// Every room `m.direct` lists, when this batch carried `m.direct`.
    pub direct_rooms: Option<Vec<String>>,
}

/// A room's summary fields. `None` means "unchanged by this batch".
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize)]
pub struct RoomRow {
    pub room_id: String,
    pub membership: String,
    pub name: Option<String>,
    pub topic: Option<String>,
    pub canonical_alias: Option<String>,
    pub avatar_url: Option<String>,
    pub room_type: Option<String>,
    pub encrypted: Option<bool>,
    pub joined_member_count: Option<u64>,
    pub invited_member_count: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StateRow {
    pub room_id: String,
    pub event_type: String,
    pub state_key: String,
    pub event_id: Option<String>,
    pub sender: Option<String>,
    pub content: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MemberRow {
    pub room_id: String,
    pub user_id: String,
    pub membership: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InboxRow {
    /// Order within the batch; inbox ids are assigned in this order.
    pub seq: usize,
    pub room_id: String,
    pub event_id: String,
    pub kind: &'static str,
    pub event_type: String,
    pub sender: String,
    pub state_key: Option<String>,
    pub content: Value,
    pub raw: Value,
    pub origin_server_ts: Option<i64>,
}

/// Plans the rows for one sync response.
///
/// `me` is the agent's user id: its own events are not delivered back to it.
/// `deliver_timeline` is false for the first sync, so history is mirrored
/// but never replayed into the bots; invites are delivered regardless.
pub fn plan(response: SyncResponse, me: &str, deliver_timeline: bool) -> Batch {
    let mut planner = Planner::default();

    for (room_id, joined) in response.rooms.join {
        let mut room = RoomRow {
            room_id: room_id.clone(),
            membership: "join".into(),
            joined_member_count: joined.summary.joined_member_count,
            invited_member_count: joined.summary.invited_member_count,
            ..RoomRow::default()
        };
        for event in joined.state.events.iter().chain(&joined.timeline.events) {
            planner.state(&mut room, event, me);
        }
        if deliver_timeline {
            for event in &joined.timeline.events {
                planner.timeline(&room_id, event, me);
            }
        }
        // Joined at the end of the batch, whatever the timeline went through.
        room.membership = "join".into();
        planner.rooms.insert(room_id, room);
    }

    for (room_id, invited) in response.rooms.invite {
        let mut room =
            RoomRow { room_id: room_id.clone(), membership: "invite".into(), ..RoomRow::default() };
        for event in &invited.invite_state.events {
            planner.state(&mut room, event, me);
        }
        planner.invite(&room_id, &invited.invite_state, me);
        room.membership = "invite".into();
        planner.rooms.insert(room_id, room);
    }

    for (room_id, left) in response.rooms.leave {
        let mut room =
            RoomRow { room_id: room_id.clone(), membership: "leave".into(), ..RoomRow::default() };
        for event in left.state.events.iter().chain(&left.timeline.events) {
            planner.state(&mut room, event, me);
        }
        if room.membership == "join" || room.membership == "invite" {
            room.membership = "leave".into();
        }
        planner.rooms.insert(room_id, room);
    }

    let direct_rooms = response
        .account_data
        .events
        .iter()
        .find(|event| str_at(event, "type") == Some("m.direct"))
        .map(|event| direct_room_ids(&event["content"]));

    Batch {
        next_batch: response.next_batch,
        rooms: planner.rooms.into_values().collect(),
        state: planner.state.into_values().collect(),
        members: planner.members.into_values().collect(),
        inbox: planner.inbox,
        direct_rooms,
    }
}

#[derive(Default)]
struct Planner {
    rooms: BTreeMap<String, RoomRow>,
    state: BTreeMap<(String, String, String), StateRow>,
    members: BTreeMap<(String, String), MemberRow>,
    inbox: Vec<InboxRow>,
}

impl Planner {
    /// Records a state event (one with a `state_key`) and what it says about
    /// the room. Anything else is ignored.
    fn state(&mut self, room: &mut RoomRow, event: &Value, me: &str) {
        let (Some(event_type), Some(state_key)) =
            (str_at(event, "type"), str_at(event, "state_key"))
        else {
            return;
        };
        let content = event.get("content").cloned().unwrap_or_else(|| json!({}));
        let text = |field: &str| content.get(field).and_then(Value::as_str).map(str::to_owned);
        match event_type {
            "m.room.name" => room.name = Some(text("name").unwrap_or_default()),
            "m.room.topic" => room.topic = Some(text("topic").unwrap_or_default()),
            "m.room.canonical_alias" => room.canonical_alias = text("alias"),
            "m.room.avatar" => room.avatar_url = text("url"),
            "m.room.encryption" => room.encrypted = Some(true),
            "m.room.create" => room.room_type = text("type"),
            "m.room.member" => {
                let membership = text("membership").unwrap_or_else(|| "leave".into());
                if state_key == me {
                    room.membership.clone_from(&membership);
                }
                self.members.insert(
                    (room.room_id.clone(), state_key.to_owned()),
                    MemberRow {
                        room_id: room.room_id.clone(),
                        user_id: state_key.to_owned(),
                        membership,
                        display_name: text("displayname"),
                        avatar_url: text("avatar_url"),
                    },
                );
            }
            _ => {}
        }
        self.state.insert(
            (room.room_id.clone(), event_type.to_owned(), state_key.to_owned()),
            StateRow {
                room_id: room.room_id.clone(),
                event_type: event_type.to_owned(),
                state_key: state_key.to_owned(),
                event_id: str_at(event, "event_id").map(str::to_owned),
                sender: str_at(event, "sender").map(str::to_owned),
                content,
            },
        );
    }

    /// Queues a timeline event for the bots, unless it is the agent's own.
    fn timeline(&mut self, room_id: &str, event: &Value, me: &str) {
        let (Some(event_id), Some(event_type), Some(sender)) =
            (str_at(event, "event_id"), str_at(event, "type"), str_at(event, "sender"))
        else {
            return;
        };
        if sender == me {
            return;
        }
        self.push(InboxRow {
            seq: 0,
            room_id: room_id.to_owned(),
            event_id: event_id.to_owned(),
            kind: "timeline",
            event_type: event_type.to_owned(),
            sender: sender.to_owned(),
            state_key: str_at(event, "state_key").map(str::to_owned),
            content: event.get("content").cloned().unwrap_or_else(|| json!({})),
            raw: event.clone(),
            origin_server_ts: event.get("origin_server_ts").and_then(Value::as_i64),
        });
    }

    /// An invite is the agent's own stripped `m.room.member` event. Stripped
    /// events have no id, so one is derived from the invite state: the same
    /// invite synced twice is ingested once, and a later re-invite (different
    /// state) is a new event.
    fn invite(&mut self, room_id: &str, invite_state: &Events, me: &str) {
        let Some(member) = invite_state.events.iter().find(|event| {
            str_at(event, "type") == Some("m.room.member") && str_at(event, "state_key") == Some(me)
        }) else {
            return;
        };
        let raw = json!({ "invite_state": invite_state.events });
        let digest = Sha256::digest(raw.to_string().as_bytes());
        let mut event_id = format!("invite:{room_id}:");
        for byte in &digest[..8] {
            let _ = write!(event_id, "{byte:02x}"); // writing to a String cannot fail
        }
        self.push(InboxRow {
            seq: 0,
            room_id: room_id.to_owned(),
            event_id,
            kind: "invite",
            event_type: "m.room.member".into(),
            sender: str_at(member, "sender").unwrap_or_default().to_owned(),
            state_key: Some(me.to_owned()),
            content: member.get("content").cloned().unwrap_or_else(|| json!({})),
            raw,
            origin_server_ts: None,
        });
    }

    fn push(&mut self, mut row: InboxRow) {
        if self.inbox.iter().any(|queued| queued.event_id == row.event_id) {
            return;
        }
        row.seq = self.inbox.len();
        self.inbox.push(row);
    }
}

fn str_at<'a>(event: &'a Value, field: &str) -> Option<&'a str> {
    event.get(field).and_then(Value::as_str)
}

fn direct_room_ids(content: &Value) -> Vec<String> {
    let mut rooms: Vec<String> = content
        .as_object()
        .into_iter()
        .flat_map(|users| users.values())
        .filter_map(Value::as_array)
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    rooms.sort();
    rooms.dedup();
    rooms
}

#[cfg(test)]
mod tests;
