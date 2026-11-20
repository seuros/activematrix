use std::borrow::Cow;
use std::collections::BTreeSet;

use ruma::api::{
    MatrixVersion, OutgoingRequestExt, SupportedVersions, auth_scheme::SendAccessToken,
};
use serde_json::json;

use super::*;

#[test]
fn create_room_keeps_every_spec_field_and_opaque_event_content() {
    let payload = json!({
        "creation_content": { "m.federate": false, "org.example.extra": [1, 2] },
        "initial_state": [{
            "type": "org.example.state", "state_key": "",
            "content": { "opaque": { "nested": true } },
        }],
        "invite": ["@alice:matrix.test"],
        "invite_3pid": [{
            "id_server": "identity.test", "id_access_token": "identity-token",
            "medium": "email", "address": "alice@example.org",
        }],
        "is_direct": true, "name": "Ops",
        "power_level_content_override": { "users_default": 3, "org.example.extra": 7 },
        "preset": "private_chat", "room_alias_name": "ops", "room_version": "10",
        "topic": "Deploys", "visibility": "public",
    });
    let versions =
        SupportedVersions { versions: [MatrixVersion::V1_1].into(), features: BTreeSet::new() };
    let request = create_room_request(&payload)
        .unwrap()
        .try_into_http_request::<Vec<u8>>(
            "https://matrix.test",
            SendAccessToken::IfRequired("token"),
            Cow::Owned(versions),
        )
        .unwrap();
    assert_eq!(request.uri().path(), "/_matrix/client/v3/createRoom");
    assert_eq!(serde_json::from_slice::<Value>(request.body()).unwrap(), payload);
}
