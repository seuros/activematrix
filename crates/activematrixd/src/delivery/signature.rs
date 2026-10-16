//! Delivery request signatures.
//!
//! HMAC-SHA256 over `"{timestamp}.{body}"`, sent as `X-ActiveMatrix-Timestamp`
//! and `X-ActiveMatrix-Signature: sha256=<hex>`. The timestamp is signed so a
//! captured request cannot be replayed outside Rails' window.

use std::fmt::Write as _;

use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

pub const TIMESTAMP_HEADER: &str = "x-activematrix-timestamp";
pub const SIGNATURE_HEADER: &str = "x-activematrix-signature";

/// The `X-ActiveMatrix-Signature` value for `body` sent at `timestamp`
/// (Unix seconds).
pub fn sign(secret: &str, timestamp: i64, body: &[u8]) -> String {
    // HMAC accepts keys of any length, so this cannot fail.
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(secret.as_bytes()) else {
        unreachable!("HMAC takes keys of any length")
    };
    mac.update(timestamp.to_string().as_bytes());
    mac.update(b".");
    mac.update(body);

    let digest = mac.finalize().into_bytes();
    let mut signature = String::with_capacity(7 + digest.len() * 2);
    signature.push_str("sha256=");
    for byte in digest {
        let _ = write!(signature, "{byte:02x}"); // writing to a String cannot fail
    }
    signature
}

#[cfg(test)]
mod tests;
