//! The built binary, end to end.

// A test-only crate: a panic is a failed test, which is what unwrap is for.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::process::Command;

#[test]
fn keygen_prints_a_usable_master_key() {
    let out = usage_rs::test::command!("activematrixd", "keygen").assert_success();
    let key = out.stdout_text().trim();

    assert!(activematrixd::crypto::MasterKey::from_base64(key, None).is_ok(), "{key}");
}

#[test]
fn check_lists_every_missing_secret() {
    // A clean environment and a directory without config/activematrixd.toml.
    let dir = tempfile::tempdir().unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_activematrixd"))
        .arg("check")
        .env_clear()
        .current_dir(dir.path())
        .output()
        .unwrap();
    let stdout = String::from_utf8(out.stdout).unwrap();

    assert!(!out.status.success());
    for name in ["DATABASE_URL", "ACTIVEMATRIX_MASTER_KEY", "ACTIVEMATRIX_DELIVERY_URL"] {
        assert!(stdout.contains(name), "{name} missing from:\n{stdout}");
    }
}
