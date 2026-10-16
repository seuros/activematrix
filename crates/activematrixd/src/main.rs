use activematrixd::cli::{Activematrixd, Context};
use tracing_subscriber::EnvFilter;
use usage_rs::RunAsyncWith;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();
    let cli = Activematrixd::parse();
    let context = Context {
        config_path: cli.config,
    };
    cli.command.run_async_with(&context).await
}
