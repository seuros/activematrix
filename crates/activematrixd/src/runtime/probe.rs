//! Probes for orchestrators and people.
//!
//! - `/livez`: the heartbeat ran recently (the process is not wedged).
//! - `/readyz`: live and not draining; 503 while draining, so traffic and
//!   rollouts move on before the leases are released.
//! - `/status`: JSON with every agent and its state.
//! - `/metrics`: Prometheus text.
//!
//! No database queries: probes are answered from memory, so a database
//! outage does not restart every daemon.

use std::collections::BTreeMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use rama::graceful::Shutdown;
use rama::http::server::HttpServer;
use rama::http::{Body, Request, Response, StatusCode};
use rama::rt::Executor;
use rama::service::service_fn;
use rama::tcp::server::TcpListener;
use serde_json::json;
use tokio::sync::watch;

use super::{Shared, metrics};

pub async fn serve(
    addr: SocketAddr,
    shared: Arc<Shared>,
    mut shutdown: watch::Receiver<bool>,
) -> Result<SocketAddr, rama::error::BoxError> {
    let graceful = Shutdown::new(async move {
        let _ = shutdown.changed().await;
    });
    let executor = Executor::graceful(graceful.guard());
    let listener = TcpListener::bind_address(addr, executor.clone()).await?;
    let bound = listener.local_addr()?;
    let app = service_fn(move |request: Request| {
        std::future::ready(Ok::<_, Infallible>(answer(&shared, &request)))
    });
    tokio::spawn(async move {
        listener.serve(HttpServer::auto(executor).service(app)).await;
    });
    tokio::spawn(async move {
        let _ = graceful.shutdown_with_limit(std::time::Duration::from_secs(5)).await;
    });
    Ok(bound)
}

fn answer(shared: &Shared, request: &Request) -> Response {
    let path = request.uri().path().map(|p| p.as_encoded_str().into_owned()).unwrap_or_default();
    let draining = shared.draining.load(Ordering::Relaxed);
    match path.as_str() {
        "/livez" => status_text(shared.healthy(), "ok", "heartbeat stalled"),
        "/readyz" => status_text(
            shared.healthy() && !draining,
            "ready",
            if draining { "draining" } else { "not ready" },
        ),
        "/status" => {
            let agents: Vec<_> = shared
                .reports()
                .into_iter()
                .map(|(id, report)| {
                    json!({
                        "id": id, "name": report.name,
                        "state": report.state.as_str(), "error": report.error,
                    })
                })
                .collect();
            let body = json!({
                "node": shared.node,
                "draining": draining,
                "uptime_secs": shared.started.elapsed().as_secs(),
                "agents": agents,
            });
            respond(StatusCode::OK, "application/json", body.to_string())
        }
        "/metrics" => {
            let mut by_state: BTreeMap<&str, usize> = BTreeMap::new();
            for (_, report) in shared.reports() {
                *by_state.entry(report.state.as_str()).or_default() += 1;
            }
            let by_state: Vec<(&str, usize)> = by_state.into_iter().collect();
            respond(StatusCode::OK, "text/plain; version=0.0.4", metrics::render(&by_state))
        }
        _ => respond(StatusCode::NOT_FOUND, "text/plain", "not found\n".into()),
    }
}

fn status_text(ok: bool, yes: &str, no: &str) -> Response {
    if ok {
        respond(StatusCode::OK, "text/plain", format!("{yes}\n"))
    } else {
        respond(StatusCode::SERVICE_UNAVAILABLE, "text/plain", format!("{no}\n"))
    }
}

fn respond(status: StatusCode, content_type: &str, body: String) -> Response {
    Response::builder()
        .status(status)
        .header("content-type", content_type)
        .body(Body::from(body.clone()))
        .unwrap_or_else(|_| Response::new(Body::from(body)))
}
