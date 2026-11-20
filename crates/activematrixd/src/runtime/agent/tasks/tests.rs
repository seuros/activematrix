use rama::http::convert::hyperium::TryIntoHyperiumHttp;
use ruma::api::{EndpointError, error::FromHttpResponseError};
use serde_json::json;

use super::*;

#[test]
fn rate_limits_use_server_hints_or_the_daemons_one_second_default() {
    let cases = [
        (429, "M_LIMIT_EXCEEDED", Some("3"), Some(1500), Some(3000)),
        (429, "M_LIMIT_EXCEEDED", None, Some(1500), Some(1500)),
        (429, "M_LIMIT_EXCEEDED", None, None, Some(1000)),
        (429, "M_UNKNOWN", None, None, Some(1000)),
        (400, "M_LIMIT_EXCEEDED", None, Some(7), Some(7)),
        (503, "M_UNKNOWN", None, None, None),
        (401, "M_UNKNOWN_TOKEN", None, None, None),
    ];
    for (status, errcode, header, millis, expected) in cases {
        let mut body = json!({ "errcode": errcode, "error": "try later" });
        if let Some(millis) = millis {
            body["retry_after_ms"] = json!(millis);
        }
        let bytes = body.to_string().into_bytes();
        let mut response = rama::http::Response::builder().status(status);
        if let Some(header) = header {
            response = response.header("retry-after", header);
        }
        let response = response.body(bytes.as_slice()).unwrap().try_into_hyperium_http().unwrap();
        let status = response.status();
        let error = ruma::api::error::Error::from_http_response(response);
        let error = ClientError::Response { status, error: FromHttpResponseError::Server(error) };
        assert_eq!(rate_limit_delay(&error), expected.map(Duration::from_millis), "{errcode}");
    }
}
