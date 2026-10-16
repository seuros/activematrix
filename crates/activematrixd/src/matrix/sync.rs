//! The slice of a `/sync` response the daemon reads. Events stay raw JSON:
//! they are mirrored and delivered as the homeserver sent them.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Default, Deserialize)]
pub struct SyncResponse {
    pub next_batch: String,
    #[serde(default)]
    pub rooms: Rooms,
    #[serde(default)]
    pub account_data: Events,
}

#[derive(Debug, Default, Deserialize)]
pub struct Rooms {
    #[serde(default)]
    pub join: BTreeMap<String, JoinedRoom>,
    #[serde(default)]
    pub invite: BTreeMap<String, InvitedRoom>,
    #[serde(default)]
    pub leave: BTreeMap<String, LeftRoom>,
}

#[derive(Debug, Default, Deserialize)]
pub struct JoinedRoom {
    #[serde(default)]
    pub summary: Summary,
    #[serde(default)]
    pub state: Events,
    #[serde(default)]
    pub timeline: Timeline,
}

#[derive(Debug, Default, Deserialize)]
pub struct InvitedRoom {
    #[serde(default)]
    pub invite_state: Events,
}

#[derive(Debug, Default, Deserialize)]
pub struct LeftRoom {
    #[serde(default)]
    pub state: Events,
    #[serde(default)]
    pub timeline: Timeline,
}

#[derive(Debug, Default, Deserialize)]
pub struct Summary {
    #[serde(rename = "m.joined_member_count")]
    pub joined_member_count: Option<u64>,
    #[serde(rename = "m.invited_member_count")]
    pub invited_member_count: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
pub struct Timeline {
    #[serde(default)]
    pub events: Vec<Value>,
    #[serde(default)]
    pub limited: bool,
}

#[derive(Debug, Default, Deserialize)]
pub struct Events {
    #[serde(default)]
    pub events: Vec<Value>,
}

/// The filter the daemon syncs with: members lazy-loaded, no presence.
pub const FILTER: &str = concat!(
    r#"{"room":{"state":{"lazy_load_members":true},"timeline":{"limit":50}},"#,
    r#""presence":{"types":[]}}"#
);

/// For the first sync: state only, so history is not replayed into the bots.
pub const FIRST_SYNC_FILTER: &str = concat!(
    r#"{"room":{"state":{"lazy_load_members":true},"timeline":{"limit":0}},"#,
    r#""presence":{"types":[]}}"#
);
