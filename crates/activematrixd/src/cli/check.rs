use usage_rs::{Args, RunAsyncWith};

use super::Context;
use crate::db::Db;

/// Check the configuration and the database before starting
///
/// Reports every missing or invalid setting at once, then connects to the
/// database and checks that the ActiveMatrix tables are migrated. Exits
/// non-zero if anything is wrong.
#[derive(Args, Debug)]
pub struct Check {}

impl RunAsyncWith<&Context> for Check {
    type Output = anyhow::Result<()>;

    async fn run_async_with(self, context: &Context) -> Self::Output {
        let config = context.config()?;
        let problems = config.problems();
        for problem in &problems {
            println!("✗ {problem}");
        }
        anyhow::ensure!(problems.is_empty(), "{} problem(s) found", problems.len());
        println!("✓ configuration complete ({config:?})");

        let db = Db::connect(config.database_url()?, 1).await;
        let db = match db {
            Ok(db) => db,
            Err(error) => anyhow::bail!("✗ cannot connect to the database: {error}"),
        };
        if let Err(error) = db.verify_schema().await {
            anyhow::bail!("✗ {error}");
        }
        println!("✓ database reachable and migrated");
        Ok(())
    }
}
