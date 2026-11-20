//! The HTTP side: a gate that records every request and plays injected
//! faults, in front of a router with one typed ruma handler per Matrix
//! endpoint and the plain `/_fake/` admin routes.

mod admin;
mod matrix;

use std::convert::Infallible;
use std::sync::Arc;

use rama::http::body::util::BodyExt;
use rama::http::layer::error_handling::ErrorHandlerLayer;
use rama::http::service::web::Router;
use rama::http::service::web::response::IntoResponse;
use rama::http::{Body, Request, Response, StatusCode};
use rama::{Layer, Service};
use rama_x_ruma::{MatrixRejection, StateLayer, extract_access_token};
use serde_json::{Value, json};

use crate::state::{Fault, Recorded, Shared};

/// The whole server: gate, state, router.
pub fn app(shared: Arc<Shared>) -> impl Service<Request, Output = Response, Error = Infallible> {
    let router = admin::routes(matrix::routes(Router::new())).with_not_found(not_found);
    let inner = StateLayer::new(Arc::clone(&shared))
        .into_layer(ErrorHandlerLayer::new().into_layer(router));
    Gate { shared, inner }
}

/// Records each request and answers it with a matching injected fault, if
/// any, before it reaches the router; `/_fake/` passes untouched.
struct Gate<S> {
    shared: Arc<Shared>,
    inner: S,
}

impl<S> Service<Request> for Gate<S>
where
    S: Service<Request, Output = Response, Error = Infallible>,
{
    type Output = Response;
    type Error = Infallible;

    async fn serve(&self, request: Request) -> Result<Response, Infallible> {
        let (mut parts, body) = request.into_parts();
        let bytes = match body.collect().await {
            Ok(collected) => collected.to_bytes(),
            Err(e) => return Ok(MatrixRejection::body_read_error(e.to_string()).into_response()),
        };
        // Encoded, as sent: fault prefixes and test assertions match on it.
        let path = parts.uri.path().map_or_else(|| "/".to_owned(), |p| p.as_encoded_str().into());
        if !path.starts_with("/_fake/") {
            let method = parts.method.as_str().to_owned();
            let body = if path.starts_with("/_matrix/media/") {
                json!({ "bytes": bytes.len() })
            } else {
                serde_json::from_slice(&bytes).unwrap_or(Value::Null)
            };
            self.shared.record(Recorded {
                method: method.clone(),
                query: parts.uri.query().map(|q| q.as_encoded_str().into()).unwrap_or_default(),
                user_id: extract_access_token(&parts).and_then(|t| self.shared.token_user(&t)),
                path: path.clone(),
                body,
            });
            if let Some(fault) = self.shared.take_fault(&method, &path) {
                return Ok(fault_response(&fault));
            }
        }
        // The spec allows `.../state/{type}/` for an empty state key, but
        // rama drops a route's trailing slash, so that spelling never routes.
        if path.contains("/state/") && path.ends_with('/') {
            parts.uri.path_mut().trim_trailing_slash();
        }
        self.inner.serve(Request::from_parts(parts, Body::from(bytes))).await
    }
}

async fn not_found() -> MatrixRejection {
    MatrixRejection::Unrecognized("unrecognized request".into())
}

fn fault_response(fault: &Fault) -> Response {
    let status = StatusCode::from_u16(fault.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut body = json!({ "error": "injected fault" });
    if let Some(errcode) = &fault.errcode {
        body["errcode"] = Value::String(errcode.clone());
    }
    if let Some(ms) = fault.retry_after_ms {
        body["retry_after_ms"] = json!(ms);
    }
    let mut builder = Response::builder().status(status).header("content-type", "application/json");
    if let Some(secs) = fault.retry_after_secs {
        builder = builder.header("retry-after", secs.to_string());
    }
    builder
        .body(Body::from(body.to_string()))
        .unwrap_or_else(|_| Response::new(Body::from(body.to_string())))
}

#[cfg(test)]
mod tests;
