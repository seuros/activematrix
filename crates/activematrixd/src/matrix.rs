//! The daemon's Matrix operations, sent as typed ruma requests.

mod membership;
pub mod sync;

use std::sync::Once;
use std::time::Duration;

use rama::http::client::DefaultHttpWebClient;
use rama_x_ruma::MatrixClient;
use rama_x_ruma::client::ClientError;
use ruma::api::client::{
    account::whoami::v3 as whoami, media::create_content::v3 as upload,
    message::send_message_event::v3 as send, profile, receipt::create_receipt::v3 as receipt,
    redact::redact_event::v3 as redact, room::create_room::v3 as create_room,
    session::login::v3 as login, state::send_state_event::v3 as state,
    typing::create_typing_event::v3 as typing, uiaa::MatrixUserIdentifier,
};
use ruma::profile::ProfileFieldValue;
use ruma::serde::Raw;
use serde_json::Value;

use crate::crypto::AccessToken;

/// Requests other than `/sync` give up after this long.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Local command validation or a failed Matrix exchange.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Request(#[from] ClientError),
    #[error("invalid Matrix identifier: {0}")]
    Identifier(#[from] ruma::IdParseError),
    #[error("invalid Matrix request: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid Matrix operation: {0}")]
    Invalid(String),
}

#[derive(Debug)]
pub struct Login {
    pub user_id: String,
    pub device_id: String,
    pub access_token: AccessToken,
}

/// `user` is a localpart or a full user id.
pub async fn login(
    homeserver: &str,
    user: &str,
    password: &str,
    device_name: &str,
) -> Result<Login, ClientError> {
    let password =
        login::Password::new(MatrixUserIdentifier::new(user.into()).into(), password.into());
    let mut request = login::Request::new(login::LoginInfo::Password(password));
    request.initial_device_display_name = Some(device_name.into());
    let response = transport(homeserver).send(request).await?;
    Ok(Login {
        user_id: response.user_id.to_string(),
        device_id: response.device_id.to_string(),
        access_token: AccessToken::new(response.access_token),
    })
}

/// An authenticated session on a homeserver.
#[derive(Clone)]
pub struct Client {
    matrix: MatrixClient<DefaultHttpWebClient>,
    user_id: String,
}

impl Client {
    pub fn new(homeserver: &str, token: &AccessToken, user_id: String) -> Self {
        Self { matrix: transport(homeserver).with_access_token(token.expose()), user_id }
    }

    pub fn user_id(&self) -> &str {
        &self.user_id
    }

    #[must_use]
    pub fn with_user_id(mut self, user_id: String) -> Self {
        self.user_id = user_id;
        self
    }

    pub async fn whoami(&self) -> Result<whoami::Response, ClientError> {
        self.matrix.send(whoami::Request::new()).await
    }

    /// Long-polls `/sync`, allowing the server's timeout plus transport slack.
    pub async fn sync(
        &self,
        since: Option<&str>,
        timeout: Duration,
        filter: &str,
    ) -> Result<sync::Response, Error> {
        let mut request = sync::Request::new();
        request.since = since.map(str::to_owned);
        request.timeout = Some(timeout);
        request.filter = Some(sync::Filter::FilterDefinition(serde_json::from_str(filter)?));
        Ok(self.matrix.send_with_timeout(request, timeout + REQUEST_TIMEOUT).await?)
    }

    /// Repeating a transaction id returns the original event id.
    pub async fn send_event(
        &self,
        room_id: &str,
        event_type: &str,
        txn_id: &str,
        content: &Value,
    ) -> Result<String, Error> {
        let request = send::Request::new_raw(
            room_id.try_into()?,
            txn_id.into(),
            event_type.into(),
            Raw::from_json(serde_json::value::to_raw_value(content)?),
        );
        Ok(self.matrix.send(request).await?.event_id.to_string())
    }

    pub async fn put_state(
        &self,
        room_id: &str,
        event_type: &str,
        state_key: &str,
        content: &Value,
    ) -> Result<String, Error> {
        let request = state::Request::new_raw(
            room_id.try_into()?,
            event_type.into(),
            state_key.into(),
            Raw::from_json(serde_json::value::to_raw_value(content)?),
        );
        Ok(self.matrix.send(request).await?.event_id.to_string())
    }

    pub async fn redact(
        &self,
        room_id: &str,
        event_id: &str,
        txn_id: &str,
        reason: Option<&str>,
    ) -> Result<String, Error> {
        let mut request =
            redact::Request::new(room_id.try_into()?, event_id.try_into()?, txn_id.into());
        request.reason = reason.map(str::to_owned);
        Ok(self.matrix.send(request).await?.event_id.to_string())
    }

    /// `body` follows the `/createRoom` schema.
    pub async fn create_room(&self, body: &Value) -> Result<String, Error> {
        let request = create_room_request(body)?;
        Ok(self.matrix.send(request).await?.room_id.to_string())
    }

    pub async fn typing(
        &self,
        room_id: &str,
        typing: bool,
        timeout: Duration,
    ) -> Result<(), Error> {
        let state = if typing {
            typing::Typing::Yes(typing::TypingInfo::new(timeout))
        } else {
            typing::Typing::No
        };
        let request =
            typing::Request::new(self.user_id.as_str().try_into()?, room_id.try_into()?, state);
        self.matrix.send(request).await?;
        Ok(())
    }

    pub async fn receipt(
        &self,
        room_id: &str,
        event_id: &str,
        receipt_type: &str,
    ) -> Result<(), Error> {
        let request =
            receipt::Request::new(room_id.try_into()?, receipt_type.into(), event_id.try_into()?);
        self.matrix.send(request).await?;
        Ok(())
    }

    /// `field` is `displayname` or `avatar_url`.
    pub async fn set_profile(&self, field: &str, value: &str) -> Result<(), Error> {
        let value = match field {
            "displayname" => ProfileFieldValue::DisplayName(value.into()),
            "avatar_url" => ProfileFieldValue::AvatarUrl(value.into()),
            _ => return Err(Error::Invalid(format!("profile field {field}"))),
        };
        let request =
            profile::set_profile_field::v3::Request::new(self.user_id.as_str().try_into()?, value);
        self.matrix.send(request).await?;
        Ok(())
    }

    /// Uploads media through `/media/v3/upload`, returning its MXC URI.
    pub async fn upload(
        &self,
        content_type: &str,
        filename: Option<&str>,
        bytes: Vec<u8>,
    ) -> Result<String, Error> {
        let mut request = upload::Request::new(bytes);
        request.content_type = Some(content_type.into());
        request.filename = filename.map(str::to_owned);
        Ok(self.matrix.send(request).await?.content_uri.to_string())
    }
}

/// Installs the rustls crypto provider once per process, before any TLS.
pub fn install_crypto_provider() {
    static INSTALL: Once = Once::new();
    INSTALL.call_once(|| {
        use rama::tls::rustls::dep::rustls::crypto::{CryptoProvider, ring};
        if CryptoProvider::get_default().is_none() {
            // Another installer may win the race.
            let _ = ring::default_provider().install_default();
        }
    });
}

fn transport(homeserver: &str) -> MatrixClient<DefaultHttpWebClient> {
    install_crypto_provider();
    MatrixClient::new(DefaultHttpWebClient::default(), homeserver)
        .with_timeout(REQUEST_TIMEOUT)
        // Preserve the daemon's unbounded sync batches.
        .with_max_response_body(usize::MAX)
}

fn field<T: serde::de::DeserializeOwned>(
    body: &Value,
    name: &str,
) -> serde_json::Result<Option<T>> {
    body.get(name)
        .filter(|value| !value.is_null())
        .map(|value| serde_json::from_value(value.clone()))
        .transpose()
}

fn create_room_request(body: &Value) -> Result<create_room::Request, Error> {
    if !body.is_object() {
        return Err(Error::Invalid("createRoom body must be an object".into()));
    }
    let mut request = create_room::Request::new();
    request.creation_content = field(body, "creation_content")?;
    request.initial_state = field(body, "initial_state")?.unwrap_or_default();
    request.invite = field(body, "invite")?.unwrap_or_default();
    request.invite_3pid = field(body, "invite_3pid")?.unwrap_or_default();
    request.is_direct = field(body, "is_direct")?.unwrap_or_default();
    request.name = field(body, "name")?;
    request.power_level_content_override = field(body, "power_level_content_override")?;
    request.preset = field(body, "preset")?;
    request.room_alias_name = field(body, "room_alias_name")?;
    request.room_version = field(body, "room_version")?;
    request.topic = field(body, "topic")?;
    request.visibility = field(body, "visibility")?.unwrap_or_default();
    Ok(request)
}

#[cfg(test)]
mod tests;
