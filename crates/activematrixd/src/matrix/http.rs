//! One request path for every endpoint: build, send, bound by a timeout,
//! and turn the answer into JSON or a [`MatrixError`].

use std::sync::{Arc, Once};
use std::time::Duration;

use rama::http::body::util::BodyExt;
use rama::http::client::DefaultHttpWebClient;
use rama::http::service::client::HttpClientExt;
use rama::http::{HeaderMap, Method};
use serde::de::DeserializeOwned;
use serde_json::Value;

use super::seg;
use crate::crypto::AccessToken;

/// Why a request failed, and whether trying again can help.
#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum MatrixError {
    #[error("homeserver unreachable: {0}")]
    Transport(String),
    #[error("request timed out")]
    Timeout,
    #[error("rate limited; retry after {0:?}")]
    RateLimited(Duration),
    #[error("access token rejected (M_UNKNOWN_TOKEN)")]
    UnknownToken,
    #[error("homeserver error (HTTP {0})")]
    Server(u16),
    #[error("HTTP {status} {errcode}: {message}")]
    Rejected { status: u16, errcode: String, message: String },
    #[error("unexpected response: {0}")]
    Decode(String),
}

impl MatrixError {
    /// Transport trouble, timeouts, rate limits and 5xx can pass; a rejected
    /// request or a revoked token will fail the same way again.
    pub const fn is_retryable(&self) -> bool {
        matches!(self, Self::Transport(_) | Self::Timeout | Self::RateLimited(_) | Self::Server(_))
    }

    pub const fn retry_after(&self) -> Option<Duration> {
        match self {
            Self::RateLimited(after) => Some(*after),
            _ => None,
        }
    }
}

/// A homeserver base URL and a pooled HTTPS client. Cheap to clone.
#[derive(Clone)]
pub struct Homeserver {
    base: Arc<str>,
    http: DefaultHttpWebClient,
}

impl Homeserver {
    pub fn new(base_url: &str) -> Self {
        install_crypto_provider();
        Self { base: base_url.trim_end_matches('/').into(), http: DefaultHttpWebClient::default() }
    }

    pub fn url(&self) -> &str {
        &self.base
    }

    pub(super) async fn json<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, &str)],
        token: Option<&AccessToken>,
        body: Option<&Value>,
        timeout: Duration,
    ) -> Result<T, MatrixError> {
        let body = body.map(|body| (b"application/json".as_slice(), body.to_string().into_bytes()));
        let value = self.send(method, path, query, token, body, timeout).await?;
        serde_json::from_value(value).map_err(|e| MatrixError::Decode(e.to_string()))
    }

    pub(super) async fn upload(
        &self,
        path: &str,
        query: &[(&str, &str)],
        token: &AccessToken,
        content_type: &str,
        bytes: Vec<u8>,
        timeout: Duration,
    ) -> Result<Value, MatrixError> {
        self.send(
            Method::POST,
            path,
            query,
            Some(token),
            Some((content_type.as_bytes(), bytes)),
            timeout,
        )
        .await
    }

    async fn send(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, &str)],
        token: Option<&AccessToken>,
        body: Option<(&[u8], Vec<u8>)>,
        timeout: Duration,
    ) -> Result<Value, MatrixError> {
        let mut url = format!("{}{path}", self.base);
        for (i, (key, value)) in query.iter().enumerate() {
            url.push(if i == 0 { '?' } else { '&' });
            url.push_str(&seg(key));
            url.push('=');
            url.push_str(&seg(value));
        }
        let exchange = async {
            let mut request = self.http.request(method, url);
            if let Some(token) = token {
                request = request.header("authorization", format!("Bearer {}", token.expose()));
            }
            if let Some((content_type, bytes)) = body {
                request = request
                    .header("content-type", String::from_utf8_lossy(content_type).into_owned())
                    .body(bytes);
            }
            let response =
                request.send().await.map_err(|e| MatrixError::Transport(e.to_string()))?;
            let status = response.status().as_u16();
            let headers = response.headers().clone();
            let bytes = response
                .into_body()
                .collect()
                .await
                .map_err(|e| MatrixError::Transport(e.to_string()))?
                .to_bytes();
            Ok::<_, MatrixError>((status, headers, bytes))
        };
        let (status, headers, bytes) =
            tokio::time::timeout(timeout, exchange).await.map_err(|_| MatrixError::Timeout)??;
        interpret(status, &headers, &bytes)
    }
}

/// Maps a response to JSON or an error, by the Matrix error conventions.
fn interpret(status: u16, headers: &HeaderMap, bytes: &[u8]) -> Result<Value, MatrixError> {
    let body: Option<Value> = serde_json::from_slice(bytes).ok();
    if (200..300).contains(&status) {
        return body.ok_or_else(|| {
            MatrixError::Decode(format!("HTTP {status} with a body that is not JSON"))
        });
    }
    let field = |name: &str| {
        body.as_ref().and_then(|b| b.get(name)).and_then(Value::as_str).map(str::to_owned)
    };
    let errcode = field("errcode").unwrap_or_default();
    if status == 429 || errcode == "M_LIMIT_EXCEEDED" {
        // The header is what Matrix 1.10 prefers; retry_after_ms is older.
        let header = headers
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.trim().parse::<u64>().ok())
            .map(Duration::from_secs);
        let body_ms = body
            .as_ref()
            .and_then(|b| b.get("retry_after_ms"))
            .and_then(Value::as_u64)
            .map(Duration::from_millis);
        return Err(MatrixError::RateLimited(header.or(body_ms).unwrap_or(Duration::from_secs(1))));
    }
    if errcode == "M_UNKNOWN_TOKEN" {
        return Err(MatrixError::UnknownToken);
    }
    if status >= 500 {
        return Err(MatrixError::Server(status));
    }
    Err(MatrixError::Rejected { status, errcode, message: field("error").unwrap_or_default() })
}

/// Installs the rustls crypto provider once per process, before any TLS.
pub fn install_crypto_provider() {
    static INSTALL: Once = Once::new();
    INSTALL.call_once(|| {
        use rama::tls::rustls::dep::rustls::crypto::{CryptoProvider, ring};
        if CryptoProvider::get_default().is_none() {
            // Losing a race to another installer is fine: one is installed.
            let _ = ring::default_provider().install_default();
        }
    });
}

#[cfg(test)]
mod tests;
