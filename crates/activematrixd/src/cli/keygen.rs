use usage_rs::{Args, Run};

use crate::crypto::MasterKey;

/// Print a new master key for ACTIVEMATRIX_MASTER_KEY
///
/// The master key seals agents' access tokens. Keep it with your other
/// secrets; losing it means logging every agent in again. To rotate, move the
/// current key to ACTIVEMATRIX_MASTER_KEY_PREVIOUS and set a new one: tokens
/// are resealed as agents start.
#[derive(Args, Debug)]
pub struct Keygen {}

impl Run for Keygen {
    type Output = anyhow::Result<()>;

    fn run(self) -> Self::Output {
        println!("{}", MasterKey::generate());
        Ok(())
    }
}
