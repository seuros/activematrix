use super::*;

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
    let rate_limited =
        || Err(CommandError::Matrix(MatrixError::RateLimited(Duration::from_secs(1))));

    assert!(matches!(outcome(&command(1), rate_limited()), Outcome::Retry(_)));
    assert!(matches!(outcome(&command(MAX_ATTEMPTS), rate_limited()), Outcome::Failed(_)));
}

#[test]
fn rejected_and_invalid_commands_fail_at_once() {
    let rejected = CommandError::Matrix(MatrixError::Rejected {
        status: 403,
        errcode: "M_FORBIDDEN".into(),
        message: "not in room".into(),
    });
    let invalid =
        CommandError::Invalid { kind: "send".into(), reason: "event_type is required".into() };

    assert!(matches!(outcome(&command(1), Err(rejected)),
                 Outcome::Failed(e) if e.contains("M_FORBIDDEN")));
    assert!(
        matches!(outcome(&command(1), Err(invalid)), Outcome::Failed(e) if e.contains("event_type"))
    );
    assert!(matches!(outcome(&command(1), Ok(json!({ "event_id": "$1" }))), Outcome::Sent(_)));
}
