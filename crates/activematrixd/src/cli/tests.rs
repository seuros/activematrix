use std::ffi::OsStr;

use super::*;

#[test]
fn parses_version_subcommand() {
    let cli = Cli::parse_from(&[OsStr::new("version")]).expect("version parses");

    assert_eq!(cli.command, Command::Version);
}

#[test]
fn rejects_unknown_flags() {
    assert!(Cli::parse_from(&[OsStr::new("version"), OsStr::new("--bogus")]).is_err());
}
