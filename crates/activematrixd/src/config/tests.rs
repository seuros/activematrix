use std::collections::HashMap;
use std::io::Write as _;

use super::*;

fn env(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> + use<> {
    let vars: HashMap<String, String> = vars
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect();
    move |name| vars.get(name).cloned()
}

fn secret() -> String {
    "s".repeat(32)
}

#[test]
fn defaults_need_nothing_set() {
    let config = Config::build(File::default(), &env(&[])).unwrap();

    assert_eq!(
        config.probe_bind,
        "127.0.0.1:3042".parse::<SocketAddr>().unwrap()
    );
    assert_eq!(config.lease_ttl, Duration::from_secs(30));
    assert_eq!(config.heartbeat, Duration::from_secs(10));
    assert_eq!(config.max_agents, 100);
    assert!(config.node_id.contains(':'));
}

#[test]
fn the_environment_overrides_the_file() {
    let file: File = toml::from_str(
        "probe_bind = \"0.0.0.0:9000\"\nlease_ttl_secs = 60\nnode_id = \"from-file\"",
    )
    .unwrap();
    let config = Config::build(file, &env(&[("ACTIVEMATRIX_NODE_ID", "from-env")])).unwrap();

    assert_eq!(
        config.probe_bind,
        "0.0.0.0:9000".parse::<SocketAddr>().unwrap()
    );
    assert_eq!(config.lease_ttl, Duration::from_secs(60));
    assert_eq!(config.node_id, "from-env");
}

#[test]
fn secrets_cannot_come_from_the_file() {
    let error = toml::from_str::<File>("master_key = \"abc\"").unwrap_err();

    assert!(error.to_string().contains("unknown field"), "{error}");
}

#[test]
fn every_missing_secret_is_reported_at_once() {
    let config = Config::build(File::default(), &env(&[])).unwrap();
    let problems: Vec<String> = config.problems().iter().map(ToString::to_string).collect();

    assert_eq!(problems.len(), 3, "{problems:?}");
    assert!(
        problems
            .iter()
            .any(|p| p.contains("ACTIVEMATRIX_MASTER_KEY"))
    );
    assert!(
        problems
            .iter()
            .any(|p| p.contains("ACTIVEMATRIX_DELIVERY_URL"))
    );
}

#[test]
fn a_complete_environment_has_no_problems() {
    let key = MasterKey::generate();
    let secret = secret();
    let config = Config::build(
        File::default(),
        &env(&[
            ("DATABASE_URL", "postgres://localhost/app"),
            ("ACTIVEMATRIX_MASTER_KEY", &key),
            (
                "ACTIVEMATRIX_DELIVERY_URL",
                "http://web:3000/active_matrix/deliveries",
            ),
            ("ACTIVEMATRIX_DELIVERY_SECRET", &secret),
        ]),
    )
    .unwrap();

    assert!(config.problems().is_empty());
    assert_eq!(config.database_url().unwrap(), "postgres://localhost/app");
}

#[test]
fn rejects_bad_values() {
    let invalid = [
        ("ACTIVEMATRIX_PROBE_BIND", "localhost"),
        ("ACTIVEMATRIX_LEASE_TTL_SECS", "soon"),
        ("ACTIVEMATRIX_LEASE_TTL_SECS", "15"),
        ("ACTIVEMATRIX_HEARTBEAT_SECS", "0"),
    ];
    for (name, value) in invalid {
        assert!(
            Config::build(File::default(), &env(&[(name, value)])).is_err(),
            "{name}={value}"
        );
    }

    let config = Config::build(
        File::default(),
        &env(&[
            ("ACTIVEMATRIX_DELIVERY_URL", "web:3000"),
            ("ACTIVEMATRIX_DELIVERY_SECRET", "short"),
        ]),
    )
    .unwrap();
    assert!(config.delivery().is_err());
}

#[test]
fn debug_hides_secrets() {
    let secret = secret();
    let config = Config::build(
        File::default(),
        &env(&[
            ("DATABASE_URL", "postgres://user:hunter2@db/app"),
            ("ACTIVEMATRIX_DELIVERY_SECRET", &secret),
        ]),
    )
    .unwrap();
    let shown = format!("{config:?}");

    assert!(!shown.contains("hunter2"), "{shown}");
    assert!(!shown.contains(&secret), "{shown}");
}

#[test]
fn loads_an_explicit_file() {
    let mut file = tempfile::NamedTempFile::new().unwrap();
    writeln!(file, "max_agents = 5").unwrap();

    let config = Config::load(Some(file.path()), env(&[])).unwrap();
    assert_eq!(config.max_agents, 5);

    assert!(matches!(
        Config::load(Some(Path::new("/nonexistent.toml")), env(&[])),
        Err(ConfigError::Read { .. })
    ));
}

/// The file the Rails install generator writes must be one the daemon reads.
#[test]
fn the_generated_config_file_parses() {
    const GENERATED: &str = include_str!(
        "../../../../lib/generators/active_matrix/install/templates/activematrixd.toml.tt"
    );

    let file: File = toml::from_str(GENERATED).unwrap();
    let config = Config::build(file, &env(&[])).unwrap();

    assert_eq!(config.lease_ttl, Duration::from_secs(30));
    assert_eq!(
        config.probe_bind,
        "127.0.0.1:3042".parse::<SocketAddr>().unwrap()
    );
}
