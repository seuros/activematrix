use usage_rs::{Args, RunAsyncWith};

use super::Context;
use crate::runtime;

/// Run the daemon
///
/// Claims agents, syncs them, delivers their events to Rails and sends their
/// outbox, until SIGTERM or SIGINT. The first signal drains: agents stop and
/// their leases are released. A second signal exits at once.
#[derive(Args, Debug)]
pub struct Start {}

impl RunAsyncWith<&Context> for Start {
    type Output = anyhow::Result<()>;

    async fn run_async_with(self, context: &Context) -> Self::Output {
        let config = context.config()?;
        let (stop, stopped) = tokio::sync::watch::channel(false);
        let running = runtime::start(&config, stopped).await?;
        tokio::spawn(async move {
            signal().await;
            tracing::info!("shutting down; a second signal exits at once");
            let _ = stop.send(true); // the daemon may already be gone
            signal().await;
            std::process::exit(130);
        });
        running.task.await?;
        Ok(())
    }
}

async fn signal() {
    let mut terminate =
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(terminate) => terminate,
            Err(error) => {
                tracing::warn!(%error, "cannot watch SIGTERM; only SIGINT stops the daemon");
                let _ = tokio::signal::ctrl_c().await;
                return;
            }
        };
    tokio::select! {
        _ = terminate.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
}
