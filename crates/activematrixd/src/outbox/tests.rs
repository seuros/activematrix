use super::*;
use rama_x_ruma::client::ClientError;
use ruma::api::error::{FromHttpResponseError, StandardErrorBody};

fn command(attempts: i32) -> Command {
    Command {
        id: Uuid::now_v7(),
        kind: "send".into(),
        room_id: None,
        payload: json!({}),
        blob: None,
        attempts,
    }
}

#[test]
fn transient_errors_retry_until_the_attempts_run_out() {
    for (status, errcode) in [(429, "M_LIMIT_EXCEEDED"), (500, "M_UNKNOWN"), (502, "M_UNKNOWN")] {
        assert!(matches!(outcome(&command(1), Err(rejected(status, errcode))), Outcome::Retry(_)));
        assert!(matches!(
            outcome(&command(MAX_ATTEMPTS), Err(rejected(status, errcode))),
            Outcome::Failed(_)
        ));
    }
}

#[test]
fn rejected_and_invalid_commands_fail_at_once() {
    let invalid =
        CommandError::Invalid { kind: "send".into(), reason: "event_type is required".into() };

    for (status, errcode) in
        [(403, "M_FORBIDDEN"), (401, "M_UNKNOWN_TOKEN"), (500, "M_UNKNOWN_TOKEN")]
    {
        assert!(matches!(outcome(&command(1), Err(rejected(status, errcode))),
                 Outcome::Failed(e) if e.contains(errcode)));
    }
    assert!(
        matches!(outcome(&command(1), Err(invalid)), Outcome::Failed(e) if e.contains("event_type"))
    );
    assert!(matches!(outcome(&command(1), Ok(json!({ "event_id": "$1" }))), Outcome::Sent(_)));
}

fn rejected(status: u16, errcode: &str) -> CommandError {
    let status = status.to_string().parse().unwrap();
    let body: StandardErrorBody = serde_json::from_value(json!({
        "errcode": errcode, "error": "not in room", "retry_after_ms": 1000,
    }))
    .unwrap();
    let body = ruma::api::error::ErrorBody::Standard(body);
    CommandError::Matrix(matrix::Error::Request(ClientError::Response {
        status,
        error: FromHttpResponseError::Server(body.into_error(status)),
    }))
}
