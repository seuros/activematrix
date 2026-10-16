use super::*;

/// The same vector is checked by the Rails verifier's tests, so the two
/// sides cannot drift apart.
#[test]
fn matches_the_shared_vector() {
    let body = concat!(
        r#"{"rooms":[{"agent_id":"0199e1a2-0000-7000-8000-000000000000","#,
        r#""room_id":"!room:matrix.test"}]}"#
    )
    .as_bytes();

    assert_eq!(
        sign(&"s".repeat(32), 1_760_000_000, body),
        "sha256=6c35f7a6837917d8ab0d029600626d9f7867b31fe2fc24b0886aa954370bbb7d"
    );
}

#[test]
fn the_timestamp_is_signed() {
    assert_ne!(sign("secret", 1, b"body"), sign("secret", 2, b"body"));
}
