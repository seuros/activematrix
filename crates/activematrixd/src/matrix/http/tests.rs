use rama::http::HeaderValue;

use super::*;

fn headers(retry_after: Option<&str>) -> HeaderMap {
    let mut headers = HeaderMap::new();
    if let Some(value) = retry_after {
        headers.insert("retry-after", HeaderValue::from_str(value).unwrap());
    }
    headers
}

#[test]
fn success_is_json() {
    assert_eq!(
        interpret(200, &headers(None), br#"{"a":1}"#).unwrap(),
        serde_json::json!({ "a": 1 })
    );
    assert!(matches!(
        interpret(200, &headers(None), b"<html>"),
        Err(MatrixError::Decode(_))
    ));
}

#[test]
fn errors_follow_the_matrix_conventions() {
    let cases: &[(u16, Option<&str>, &[u8], MatrixError)] = &[
        (
            429,
            Some("3"),
            br#"{"errcode":"M_LIMIT_EXCEEDED","retry_after_ms":9000}"#,
            MatrixError::RateLimited(Duration::from_secs(3)),
        ),
        (
            429,
            None,
            br#"{"errcode":"M_LIMIT_EXCEEDED","retry_after_ms":1500}"#,
            MatrixError::RateLimited(Duration::from_millis(1500)),
        ),
        (
            429,
            None,
            b"",
            MatrixError::RateLimited(Duration::from_secs(1)),
        ),
        (
            401,
            None,
            br#"{"errcode":"M_UNKNOWN_TOKEN","error":"gone"}"#,
            MatrixError::UnknownToken,
        ),
        (
            502,
            None,
            b"<html>bad gateway</html>",
            MatrixError::Server(502),
        ),
        (
            403,
            None,
            br#"{"errcode":"M_FORBIDDEN","error":"not in room"}"#,
            MatrixError::Rejected {
                status: 403,
                errcode: "M_FORBIDDEN".into(),
                message: "not in room".into(),
            },
        ),
    ];
    for (status, retry_after, body, expected) in cases {
        assert_eq!(
            interpret(*status, &headers(*retry_after), body).unwrap_err(),
            *expected,
            "HTTP {status}"
        );
    }
}

#[test]
fn only_transient_errors_are_retryable() {
    assert!(MatrixError::Timeout.is_retryable());
    assert!(MatrixError::Server(503).is_retryable());
    assert!(MatrixError::RateLimited(Duration::ZERO).is_retryable());
    assert!(!MatrixError::UnknownToken.is_retryable());
    assert!(
        !MatrixError::Rejected {
            status: 400,
            errcode: String::new(),
            message: String::new()
        }
        .is_retryable()
    );
}
