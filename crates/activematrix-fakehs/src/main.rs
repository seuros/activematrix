//! Serves the fake homeserver and prints `{"url": ...}` on stdout once it is
//! listening, for test harnesses in other languages. Drive it through the
//! admin API under /_fake/. Runs until stdin closes or SIGTERM/SIGINT.

use std::net::SocketAddr;

use activematrix_fakehs::FakeHomeserver;
use tokio::io::AsyncReadExt;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let addr: SocketAddr = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "127.0.0.1:0".into())
        .parse()?;
    let server = FakeHomeserver::start_on(addr).await?;
    println!("{}", serde_json::json!({ "url": server.url() }));

    let mut stdin = tokio::io::stdin();
    let mut sink = Vec::new();
    tokio::select! {
        _ = stdin.read_to_end(&mut sink) => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    drop(server);
    Ok(())
}
