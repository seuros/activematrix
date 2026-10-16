use activematrixd::cli::Cli;

fn main() -> anyhow::Result<()> {
    activematrixd::cli::run(&Cli::parse())
}
