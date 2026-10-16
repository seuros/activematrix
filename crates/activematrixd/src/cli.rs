//! Command line. Parsing lives here so tests and `main` share it.

#[derive(usage_rs::Cli, Debug)]
#[usage(
    bin = "activematrixd",
    version = env!("CARGO_PKG_VERSION"),
    about = "The Matrix daemon for ActiveMatrix",
    unknown_flags = "error"
)]
pub struct Cli {
    #[usage(subcommand)]
    pub command: Command,
}

#[derive(usage_rs::Subcommands, Debug, PartialEq, Eq)]
pub enum Command {
    /// Print the daemon version
    Version,
}

/// Runs a parsed command line.
///
/// # Errors
///
/// Returns the error of the command that failed.
pub fn run(cli: &Cli) -> anyhow::Result<()> {
    match cli.command {
        Command::Version => println!("activematrixd {}", env!("CARGO_PKG_VERSION")),
    }
    Ok(())
}

#[cfg(test)]
mod tests;
