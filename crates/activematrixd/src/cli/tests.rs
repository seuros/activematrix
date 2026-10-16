use std::assert_matches;

use usage_rs::test::{self as harness};

use super::*;

fn parse(words: &[&str]) -> Result<Activematrixd, String> {
    let argv = harness::argv(words.iter().copied());
    harness::parse(Activematrixd::spec(), &argv.words(), Activematrixd::parse_from)
}

#[test]
fn spec_round_trips() {
    let _spec: usage_parser::Spec = Activematrixd::to_kdl().parse().unwrap();
}

#[test]
fn parses_each_command() {
    assert_matches!(parse(&["version"]).unwrap().command, Commands::Version(_));
    assert_matches!(parse(&["keygen"]).unwrap().command, Commands::Keygen(_));
    assert_matches!(parse(&["check"]).unwrap().command, Commands::Check(_));
    assert_matches!(parse(&["start"]).unwrap().command, Commands::Start(_));
    assert_matches!(
        parse(&["login", "captain", "--token-stdin"]).unwrap().command,
        Commands::Login(Login { token_stdin: true, .. })
    );
}

#[test]
fn config_is_global() {
    let cli = parse(&["check", "--config", "/etc/am.toml"]).unwrap();

    assert_eq!(cli.config.as_deref(), Some(std::path::Path::new("/etc/am.toml")));
}

#[test]
fn unknown_flags_are_rejected() {
    let message = parse(&["version", "--bogus"]).unwrap_err();

    assert!(message.contains("--bogus"), "{message}");
}
