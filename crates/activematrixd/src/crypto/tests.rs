use super::*;

fn key() -> MasterKey {
    MasterKey::from_base64(&MasterKey::generate(), None).unwrap()
}

fn token() -> AccessToken {
    AccessToken::new("syt_secret_token".to_owned())
}

#[test]
fn seals_and_opens() {
    let key = key();
    let agent = Uuid::now_v7();

    let opened = key
        .open(agent, &key.seal(agent, &token()).unwrap())
        .unwrap();

    assert_eq!(opened.token, token());
    assert!(!opened.stale);
}

#[test]
fn each_seal_uses_a_fresh_nonce() {
    let key = key();
    let agent = Uuid::now_v7();

    assert_ne!(
        key.seal(agent, &token()).unwrap(),
        key.seal(agent, &token()).unwrap()
    );
}

#[test]
fn a_token_does_not_open_for_another_agent() {
    let key = key();
    let sealed = key.seal(Uuid::now_v7(), &token()).unwrap();

    assert_eq!(
        key.open(Uuid::now_v7(), &sealed).unwrap_err(),
        CryptoError::Unauthentic
    );
}

#[test]
fn rotation_opens_with_the_previous_key_and_says_so() {
    let old = MasterKey::generate();
    let agent = Uuid::now_v7();
    let sealed = MasterKey::from_base64(&old, None)
        .unwrap()
        .seal(agent, &token())
        .unwrap();
    let rotated = MasterKey::from_base64(&MasterKey::generate(), Some(&old)).unwrap();

    let opened = rotated.open(agent, &sealed).unwrap();

    assert_eq!(opened.token, token());
    assert!(opened.stale);
}

#[test]
fn rejects_bad_keys_and_tampered_tokens() {
    assert_eq!(
        MasterKey::from_base64("not base64!", None).unwrap_err(),
        CryptoError::KeyEncoding
    );
    assert_eq!(
        MasterKey::from_base64(&STANDARD.encode([0u8; 16]), None).unwrap_err(),
        CryptoError::KeyLength(16)
    );

    let key = key();
    let agent = Uuid::now_v7();
    let mut sealed = key.seal(agent, &token()).unwrap();
    *sealed.last_mut().unwrap() ^= 1;

    assert_eq!(
        key.open(agent, &sealed).unwrap_err(),
        CryptoError::Unauthentic
    );
    assert_eq!(
        key.open(agent, &[FORMAT_V1, 1, 2]).unwrap_err(),
        CryptoError::Malformed
    );
    assert_eq!(key.open(agent, &[]).unwrap_err(), CryptoError::Malformed);
}

#[test]
fn debug_never_shows_secrets() {
    let key = key();

    assert_eq!(format!("{:?}", token()), "AccessToken(<16 bytes>)");
    assert!(!format!("{key:?}").contains("cipher"));
}
