use serde_json::json;

use super::*;

const ME: &str = "@bot:matrix.test";

fn response(value: Value) -> SyncResponse {
    serde_json::from_value(value).unwrap()
}

fn message(event_id: &str, sender: &str, body: &str) -> Value {
    json!({ "type": "m.room.message", "event_id": event_id, "sender": sender, "origin_server_ts": 7,
            "content": { "msgtype": "m.text", "body": body } })
}

fn state(event_type: &str, state_key: &str, content: &Value) -> Value {
    json!({ "type": event_type, "state_key": state_key, "event_id": format!("${event_type}"),
            "sender": "@alice:matrix.test", "content": content })
}

#[test]
fn joined_room_state_fills_the_room_row() {
    let batch = plan(
        response(
            json!({ "next_batch": "s1", "rooms": { "join": { "!r:matrix.test": {
            "summary": { "m.joined_member_count": 3 },
            "state": { "events": [
                state("m.room.name", "", &json!({ "name": "Ops" })),
                state("m.room.encryption", "", &json!({ "algorithm": "m.megolm.v1.aes-sha2" })),
                state("m.room.create", "", &json!({ "type": "m.space" })),
            ] },
            "timeline": { "events": [state("m.room.topic", "", &json!({ "topic": "deploys" }))] },
        } } } }),
        ),
        ME,
        true,
    );

    assert_eq!(batch.next_batch, "s1");
    let room = &batch.rooms[0];
    assert_eq!(room.membership, "join");
    assert_eq!(room.name.as_deref(), Some("Ops"));
    assert_eq!(room.topic.as_deref(), Some("deploys"));
    assert_eq!(room.encrypted, Some(true));
    assert_eq!(room.room_type.as_deref(), Some("m.space"));
    assert_eq!(room.joined_member_count, Some(3));
    assert_eq!(batch.state.len(), 4);
}

#[test]
fn the_last_state_event_for_a_key_wins() {
    let batch = plan(
        response(
            json!({ "next_batch": "s1", "rooms": { "join": { "!r:matrix.test": {
            "state": { "events": [state("m.room.name", "", &json!({ "name": "Old" }))] },
            "timeline": { "events": [state("m.room.name", "", &json!({ "name": "New" }))] },
        } } } }),
        ),
        ME,
        true,
    );

    assert_eq!(batch.state.len(), 1);
    assert_eq!(batch.state[0].content["name"], "New");
    assert_eq!(batch.rooms[0].name.as_deref(), Some("New"));
}

#[test]
fn timeline_events_are_delivered_except_the_agents_own() {
    let batch = plan(
        response(
            json!({ "next_batch": "s2", "rooms": { "join": { "!r:matrix.test": {
            "timeline": { "events": [
                message("$1", "@alice:matrix.test", "!ping"),
                message("$2", ME, "pong"),
                message("$3", "@bob:matrix.test", "hi"),
            ] },
        } } } }),
        ),
        ME,
        true,
    );

    let delivered: Vec<(&str, usize)> = batch
        .inbox
        .iter()
        .map(|row| (row.event_id.as_str(), row.seq))
        .collect();
    assert_eq!(delivered, [("$1", 0), ("$3", 1)]);
    assert_eq!(batch.inbox[0].content["body"], "!ping");
    assert_eq!(batch.inbox[0].origin_server_ts, Some(7));
}

#[test]
fn the_first_sync_mirrors_state_but_replays_nothing() {
    let batch = plan(
        response(
            json!({ "next_batch": "s1", "rooms": { "join": { "!r:matrix.test": {
            "state": { "events": [state("m.room.name", "", &json!({ "name": "Ops" }))] },
            "timeline": { "events": [message("$1", "@alice:matrix.test", "old history")] },
        } } } }),
        ),
        ME,
        false,
    );

    assert_eq!(batch.inbox, []);
    assert_eq!(batch.rooms[0].name.as_deref(), Some("Ops"));
}

#[test]
fn members_are_mirrored_and_the_agents_own_membership_sets_the_room() {
    let batch = plan(
        response(
            json!({ "next_batch": "s1", "rooms": { "leave": { "!r:matrix.test": {
            "timeline": { "events": [
                state("m.room.member", "@alice:matrix.test", &json!({ "membership": "join", "displayname": "Alice" })),
                state("m.room.member", ME, &json!({ "membership": "ban" })),
            ] },
        } } } }),
        ),
        ME,
        true,
    );

    assert_eq!(batch.rooms[0].membership, "ban");
    let alice = batch
        .members
        .iter()
        .find(|m| m.user_id == "@alice:matrix.test")
        .unwrap();
    assert_eq!(alice.display_name.as_deref(), Some("Alice"));
    assert_eq!(batch.inbox, [], "left rooms are not delivered");
}

#[test]
fn invites_are_delivered_even_on_the_first_sync_with_a_stable_id() {
    let invite = json!({ "next_batch": "s1", "rooms": { "invite": { "!r:matrix.test": { "invite_state": { "events": [
        { "type": "m.room.name", "state_key": "", "sender": "@alice:matrix.test", "content": { "name": "Ops" } },
        { "type": "m.room.member", "state_key": ME, "sender": "@alice:matrix.test",
          "content": { "membership": "invite" } },
    ] } } } } });

    let first = plan(response(invite.clone()), ME, false);
    let again = plan(response(invite), ME, true);

    let row = &first.inbox[0];
    assert_eq!(row.kind, "invite");
    assert_eq!(row.sender, "@alice:matrix.test");
    assert!(
        row.event_id.starts_with("invite:!r:matrix.test:"),
        "{}",
        row.event_id
    );
    assert_eq!(
        row.event_id, again.inbox[0].event_id,
        "the same invite gets the same id"
    );
    assert_eq!(first.rooms[0].membership, "invite");
    assert_eq!(first.rooms[0].name.as_deref(), Some("Ops"));
}

#[test]
fn m_direct_lists_the_direct_rooms() {
    let batch = plan(
        response(
            json!({ "next_batch": "s1", "account_data": { "events": [{ "type": "m.direct", "content": {
            "@alice:matrix.test": ["!dm1:matrix.test", "!dm2:matrix.test"],
            "@bob:matrix.test": ["!dm1:matrix.test"],
        } }] } }),
        ),
        ME,
        true,
    );

    assert_eq!(
        batch.direct_rooms,
        Some(vec![
            "!dm1:matrix.test".to_owned(),
            "!dm2:matrix.test".to_owned()
        ])
    );
}

#[test]
fn malformed_events_are_skipped() {
    let batch = plan(
        response(
            json!({ "next_batch": "s1", "rooms": { "join": { "!r:matrix.test": {
            "timeline": { "events": [{ "type": "m.room.message" }, "not an object", message("$1", "@a:m", "ok")] },
        } } } }),
        ),
        ME,
        true,
    );

    assert_eq!(batch.inbox.len(), 1);
}
