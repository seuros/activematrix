use usage_rs::{Args, RunWith};

use super::Context;

/// Check the configuration before starting
///
/// Reports every missing or invalid setting at once and exits non-zero if
/// there is any.
#[derive(Args, Debug)]
pub struct Check {}

impl RunWith<&Context> for Check {
    type Output = anyhow::Result<()>;

    fn run_with(self, context: &Context) -> Self::Output {
        let config = context.config()?;
        let problems = config.problems();
        for problem in &problems {
            println!("✗ {problem}");
        }
        anyhow::ensure!(problems.is_empty(), "{} problem(s) found", problems.len());
        println!("✓ configuration complete ({config:?})");
        Ok(())
    }
}
