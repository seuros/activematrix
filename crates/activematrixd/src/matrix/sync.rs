//! Sync request types and the daemon's filters.

pub use ruma::api::client::sync::sync_events::v3::{Filter, Request, Response};

/// Members lazy-loaded, no presence, at most 50 timeline events.
pub const FILTER: &str = concat!(
    r#"{"room":{"state":{"lazy_load_members":true},"timeline":{"limit":50}},"#,
    r#""presence":{"types":[]}}"#
);

/// First sync mirrors state without replaying history into bots.
pub const FIRST_SYNC_FILTER: &str = concat!(
    r#"{"room":{"state":{"lazy_load_members":true},"timeline":{"limit":0}},"#,
    r#""presence":{"types":[]}}"#
);
