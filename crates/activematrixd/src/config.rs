//! Daemon configuration: `config/activematrixd.toml` for settings, the
//! environment for secrets and overrides.
//!
//! Secrets (database URL, master key, delivery secret) are read from the
//! environment only, so the file can be committed. Each command asks for what
//! it needs, so `keygen` runs with nothing set and `check` can report every
//! missing piece at once.

use std::fmt;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;

use crate::crypto::MasterKey;

pub const DEFAULT_PATH: &str = "config/activematrixd.toml";

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("reading {path}: {source}")]
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("parsing {path}: {source}")]
    Parse {
        path: PathBuf,
        source: Box<toml::de::Error>,
    },
    #[error("{0} is not set")]
    Missing(&'static str),
    #[error("{name} is invalid: {reason}")]
    Invalid { name: &'static str, reason: String },
}

/// Settings that may live in the TOML file. Every one has a default.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    delivery_url: Option<String>,
    probe_bind: Option<String>,
    node_id: Option<String>,
    max_agents: Option<u32>,
    lease_ttl_secs: Option<u64>,
    heartbeat_secs: Option<u64>,
    shutdown_timeout_secs: Option<u64>,
}

pub struct Config {
    database_url: Option<String>,
    master_key: Option<String>,
    master_key_previous: Option<String>,
    delivery_url: Option<String>,
    delivery_secret: Option<String>,
    pub probe_bind: SocketAddr,
    pub node_id: String,
    pub max_agents: u32,
    pub lease_ttl: Duration,
    pub heartbeat: Duration,
    pub shutdown_timeout: Duration,
}

/// Where the daemon pushes `(agent, room)` pairs, and the HMAC secret.
#[derive(Clone)]
pub struct Delivery {
    pub url: String,
    pub secret: String,
}

impl fmt::Debug for Delivery {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Delivery")
            .field("url", &self.url)
            .finish_non_exhaustive()
    }
}

impl Config {
    /// Loads `path`, else `ACTIVEMATRIX_CONFIG`, else `config/activematrixd.toml`
    /// if it exists. `env` reads a variable; production passes `std::env::var`.
    pub fn load(
        path: Option<&Path>,
        env: impl Fn(&str) -> Option<String>,
    ) -> Result<Self, ConfigError> {
        let explicit = path
            .map(Path::to_path_buf)
            .or_else(|| env("ACTIVEMATRIX_CONFIG").map(PathBuf::from));
        let file = match explicit {
            Some(path) => read(&path)?,
            None if Path::new(DEFAULT_PATH).exists() => read(Path::new(DEFAULT_PATH))?,
            None => File::default(),
        };
        Self::build(file, &env)
    }

    fn build(file: File, env: &impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let probe_bind = env("ACTIVEMATRIX_PROBE_BIND")
            .or(file.probe_bind)
            .unwrap_or_else(|| "127.0.0.1:3042".into());
        let probe_bind = probe_bind.parse().map_err(|_| ConfigError::Invalid {
            name: "probe_bind",
            reason: format!("{probe_bind:?} is not ip:port"),
        })?;
        let seconds =
            |var: &'static str, value: Option<u64>, default| -> Result<Duration, ConfigError> {
                let secs = match env(var) {
                    Some(raw) => raw.parse().map_err(|_| ConfigError::Invalid {
                        name: var,
                        reason: format!("{raw:?}"),
                    })?,
                    None => value.unwrap_or(default),
                };
                Ok(Duration::from_secs(secs))
            };
        let config = Self {
            database_url: env("ACTIVEMATRIX_DATABASE_URL").or_else(|| env("DATABASE_URL")),
            master_key: env("ACTIVEMATRIX_MASTER_KEY"),
            master_key_previous: env("ACTIVEMATRIX_MASTER_KEY_PREVIOUS"),
            delivery_url: env("ACTIVEMATRIX_DELIVERY_URL").or(file.delivery_url),
            delivery_secret: env("ACTIVEMATRIX_DELIVERY_SECRET"),
            probe_bind,
            node_id: env("ACTIVEMATRIX_NODE_ID")
                .or(file.node_id)
                .unwrap_or_else(default_node_id),
            max_agents: match env("ACTIVEMATRIX_MAX_AGENTS") {
                Some(raw) => raw.parse().map_err(|_| ConfigError::Invalid {
                    name: "ACTIVEMATRIX_MAX_AGENTS",
                    reason: format!("{raw:?}"),
                })?,
                None => file.max_agents.unwrap_or(100),
            },
            lease_ttl: seconds("ACTIVEMATRIX_LEASE_TTL_SECS", file.lease_ttl_secs, 30)?,
            heartbeat: seconds("ACTIVEMATRIX_HEARTBEAT_SECS", file.heartbeat_secs, 10)?,
            shutdown_timeout: seconds(
                "ACTIVEMATRIX_SHUTDOWN_TIMEOUT_SECS",
                file.shutdown_timeout_secs,
                30,
            )?,
        };
        config.validate_timing()?;
        Ok(config)
    }

    /// A lease must outlive two missed heartbeats, or a busy daemon loses its
    /// agents to another one.
    fn validate_timing(&self) -> Result<(), ConfigError> {
        (self.heartbeat.as_secs() > 0 && self.lease_ttl >= self.heartbeat * 3)
            .then_some(())
            .ok_or_else(|| ConfigError::Invalid {
                name: "lease_ttl_secs",
                reason: format!(
                    "must be at least 3x heartbeat_secs ({}s), got {}s",
                    self.heartbeat.as_secs(),
                    self.lease_ttl.as_secs()
                ),
            })
    }

    pub fn database_url(&self) -> Result<&str, ConfigError> {
        self.database_url.as_deref().ok_or(ConfigError::Missing(
            "ACTIVEMATRIX_DATABASE_URL (or DATABASE_URL)",
        ))
    }

    pub fn master_key(&self) -> Result<MasterKey, ConfigError> {
        let current = self
            .master_key
            .as_deref()
            .ok_or(ConfigError::Missing("ACTIVEMATRIX_MASTER_KEY"))?;
        MasterKey::from_base64(current, self.master_key_previous.as_deref()).map_err(|error| {
            ConfigError::Invalid {
                name: "ACTIVEMATRIX_MASTER_KEY",
                reason: error.to_string(),
            }
        })
    }

    pub fn delivery(&self) -> Result<Delivery, ConfigError> {
        let url = self
            .delivery_url
            .clone()
            .ok_or(ConfigError::Missing("ACTIVEMATRIX_DELIVERY_URL"))?;
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err(ConfigError::Invalid {
                name: "ACTIVEMATRIX_DELIVERY_URL",
                reason: format!("{url:?} is not http(s)"),
            });
        }
        let secret = self
            .delivery_secret
            .clone()
            .ok_or(ConfigError::Missing("ACTIVEMATRIX_DELIVERY_SECRET"))?;
        if secret.len() < 32 {
            return Err(ConfigError::Invalid {
                name: "ACTIVEMATRIX_DELIVERY_SECRET",
                reason: "must be at least 32 characters".into(),
            });
        }
        Ok(Delivery { url, secret })
    }

    /// Everything `start` needs that is missing or wrong, at once.
    pub fn problems(&self) -> Vec<ConfigError> {
        [
            self.database_url().err(),
            self.master_key().err(),
            self.delivery().err(),
        ]
        .into_iter()
        .flatten()
        .collect()
    }
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("delivery_url", &self.delivery_url)
            .field("probe_bind", &self.probe_bind)
            .field("node_id", &self.node_id)
            .field("max_agents", &self.max_agents)
            .field("lease_ttl", &self.lease_ttl)
            .field("heartbeat", &self.heartbeat)
            .field("shutdown_timeout", &self.shutdown_timeout)
            .finish_non_exhaustive()
    }
}

fn read(path: &Path) -> Result<File, ConfigError> {
    let text = std::fs::read_to_string(path).map_err(|source| ConfigError::Read {
        path: path.into(),
        source,
    })?;
    toml::from_str(&text).map_err(|source| ConfigError::Parse {
        path: path.into(),
        source: Box::new(source),
    })
}

fn default_node_id() -> String {
    format!(
        "{}:{}",
        gethostname::gethostname().to_string_lossy(),
        std::process::id()
    )
}

#[cfg(test)]
mod tests;
