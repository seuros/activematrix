use activematrixd::cli::{Activematrixd, Context};
use usage_rs::RunWith;

fn main() -> anyhow::Result<()> {
    let cli = Activematrixd::parse();
    let context = Context {
        config_path: cli.config,
    };
    cli.command.run_with(&context)
}
