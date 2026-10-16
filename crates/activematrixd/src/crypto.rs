//! Access tokens at rest.
//!
//! Sealed with XChaCha20-Poly1305 under the master key, which only the daemon
//! holds: a database dump or a compromised web process yields ciphertext.
//! The agent id is bound in as associated data, so a sealed token copied onto
//! another agent's row does not open.
//!
//! Layout: `version (1) || nonce (24) || ciphertext || tag (16)`.

use std::fmt;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use chacha20poly1305::aead::{Aead, Generate, Payload};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce};
use uuid::Uuid;

const FORMAT_V1: u8 = 1;
const NONCE_LEN: usize = 24;
const KEY_LEN: usize = 32;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum CryptoError {
    #[error("master key is not valid base64")]
    KeyEncoding,
    #[error("master key must decode to {KEY_LEN} bytes, got {0}")]
    KeyLength(usize),
    #[error("sealed token is malformed")]
    Malformed,
    #[error("sealed token does not open with the master key or the previous one")]
    Unauthentic,
    #[error("sealing failed")]
    Seal,
}

/// An access token. Never printed: Debug shows its length only.
#[derive(Clone, PartialEq, Eq)]
pub struct AccessToken(String);

impl AccessToken {
    pub const fn new(token: String) -> Self {
        Self(token)
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for AccessToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AccessToken(<{} bytes>)", self.0.len())
    }
}

/// A token opened with the previous key should be sealed again with the
/// current one; `stale` says so.
#[derive(Debug)]
pub struct Opened {
    pub token: AccessToken,
    pub stale: bool,
}

/// The master key, and during rotation the one it replaces.
pub struct MasterKey {
    current: XChaCha20Poly1305,
    previous: Option<XChaCha20Poly1305>,
}

impl MasterKey {
    /// Parses base64 keys, as `activematrixd keygen` prints them.
    pub fn from_base64(current: &str, previous: Option<&str>) -> Result<Self, CryptoError> {
        Ok(Self { current: cipher(current)?, previous: previous.map(cipher).transpose()? })
    }

    /// A fresh random key, base64.
    pub fn generate() -> String {
        STANDARD.encode(chacha20poly1305::Key::generate())
    }

    pub fn seal(&self, agent_id: Uuid, token: &AccessToken) -> Result<Vec<u8>, CryptoError> {
        let nonce = XNonce::generate();
        let payload = Payload { msg: token.expose().as_bytes(), aad: agent_id.as_bytes() };
        let ciphertext = self.current.encrypt(&nonce, payload).map_err(|_| CryptoError::Seal)?;

        let mut sealed = Vec::with_capacity(1 + NONCE_LEN + ciphertext.len());
        sealed.push(FORMAT_V1);
        sealed.extend_from_slice(&nonce);
        sealed.extend_from_slice(&ciphertext);
        Ok(sealed)
    }

    pub fn open(&self, agent_id: Uuid, sealed: &[u8]) -> Result<Opened, CryptoError> {
        let Some((&FORMAT_V1, rest)) = sealed.split_first() else {
            return Err(CryptoError::Malformed);
        };
        let (nonce, ciphertext) = rest.split_at_checked(NONCE_LEN).ok_or(CryptoError::Malformed)?;
        let nonce = XNonce::try_from(nonce).map_err(|_| CryptoError::Malformed)?;

        let open = |cipher: &XChaCha20Poly1305| {
            cipher.decrypt(&nonce, Payload { msg: ciphertext, aad: agent_id.as_bytes() }).ok()
        };
        let (plaintext, stale) = match open(&self.current) {
            Some(plaintext) => (plaintext, false),
            None => (self.previous.as_ref().and_then(open).ok_or(CryptoError::Unauthentic)?, true),
        };
        let token = String::from_utf8(plaintext).map_err(|_| CryptoError::Malformed)?;
        Ok(Opened { token: AccessToken::new(token), stale })
    }
}

impl fmt::Debug for MasterKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MasterKey")
            .field("rotating", &self.previous.is_some())
            .finish_non_exhaustive()
    }
}

fn cipher(encoded: &str) -> Result<XChaCha20Poly1305, CryptoError> {
    let bytes = STANDARD.decode(encoded.trim()).map_err(|_| CryptoError::KeyEncoding)?;
    XChaCha20Poly1305::new_from_slice(&bytes).map_err(|_| CryptoError::KeyLength(bytes.len()))
}

#[cfg(test)]
mod tests;
