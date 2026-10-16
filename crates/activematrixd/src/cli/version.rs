use usage_rs::{Args, Run};

/// Print the daemon version
#[derive(Args, Debug)]
pub struct Version {}

impl Run for Version {
    type Output = anyhow::Result<()>;

    fn run(self) -> Self::Output {
        println!("activematrixd {}", env!("CARGO_PKG_VERSION"));
        Ok(())
    }
}
