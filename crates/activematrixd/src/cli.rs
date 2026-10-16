//! Command line. Parsing lives in the library so tests and `main` share it.

// The derived async dispatch is generic over the context with no `Send`
// bound; clippy::nursery fires on the generated impl, and only a module-level
// allow reaches it.
#![allow(clippy::future_not_send)]

mod check;
mod keygen;
mod login;
mod start;
mod version;

use std::path::PathBuf;

use usage_rs::{Cli, Subcommands};

pub use check::Check;
pub use keygen::Keygen;
pub use login::Login;
pub use start::Start;
pub use version::Version;

use crate::config::Config;

/// The Matrix daemon for ActiveMatrix
#[derive(Cli, Debug)]
#[usage(bin = "activematrixd", version, unknown_flags = "error", args_override_self = false)]
pub struct Activematrixd {
    /// Config file [default: $ACTIVEMATRIX_CONFIG, else config/activematrixd.toml]
    #[usage(long, global, value_name = "PATH")]
    pub config: Option<PathBuf>,

    #[usage(subcommand)]
    pub command: Commands,
}

#[derive(Subcommands, Debug)]
#[usage(run_async_with)]
pub enum Commands {
    Start(Start),
    Login(Login),
    Check(Check),
    #[usage(no_ctx, run)]
    Keygen(Keygen),
    #[usage(no_ctx, run)]
    Version(Version),
}

/// What commands share: where the configuration comes from.
#[derive(Debug)]
pub struct Context {
    pub config_path: Option<PathBuf>,
}

impl Context {
    pub fn config(&self) -> anyhow::Result<Config> {
        Ok(Config::load(self.config_path.as_deref(), |name| std::env::var(name).ok())?)
    }
}

#[cfg(test)]
mod tests;
