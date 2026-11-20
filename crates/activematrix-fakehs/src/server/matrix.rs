//! The Matrix endpoints activematrixd uses, one typed ruma handler each.
//! ruma parses every request against the spec, so a non-conforming client
//! request is rejected here as a real homeserver would.

use std::sync::Arc;
use std::time::Duration;

use rama::http::service::web::Router;
use rama_x_ruma::{Matrix, MatrixRejection, MatrixResponse, MatrixResult, MatrixRouterExt};
use ruma::api::IncomingRequest;
use ruma::api::client::account::whoami::v3 as whoami;
use ruma::api::client::discovery::get_supported_versions as versions;
use ruma::api::client::media::create_content::v3 as upload;
use ruma::api::client::membership::{
    ban_user::v3 as ban, forget_room::v3 as forget, invite_user::v3 as invite,
    join_room_by_id_or_alias::v3 as join, kick_user::v3 as kick, leave_room::v3 as leave,
    unban_user::v3 as unban,
};
use ruma::api::client::message::send_message_event::v3 as send;
use ruma::api::client::profile::set_profile_field::v3 as profile;
use ruma::api::client::receipt::create_receipt::v3 as receipt;
use ruma::api::client::redact::redact_event::v3 as redact;
use ruma::api::client::room::create_room::v3 as create_room;
use ruma::api::client::session::login::v3 as login;
use ruma::api::client::state::send_state_event::v3 as state;
use ruma::api::client::sync::sync_events::v3 as sync;
use ruma::api::client::typing::create_typing_event::v3 as typing;
use ruma::api::client::uiaa::UserIdentifier;
use ruma::serde::Raw;
use ruma::{OwnedDeviceId, OwnedEventId, OwnedMxcUri, OwnedRoomId, OwnedUserId, RoomId, UserId};
use serde_json::{Value, json};

use crate::SERVER_NAME;
use crate::state::{NewEvent, Shared};

/// Long-polls are capped so a test never hangs on a client that asked for
/// minutes.
const MAX_SYNC_WAIT: Duration = Duration::from_secs(30);

type Req<T> = Matrix<T, Shared>;

pub fn routes(router: Router) -> Router {
    router
        .with_matrix_endpoint::<versions::Request, _, _>(supported_versions)
        .with_matrix_endpoint::<login::Request, _, _>(log_in)
        .with_matrix_endpoint::<whoami::Request, _, _>(who_am_i)
        .with_matrix_endpoint::<sync::Request, _, _>(sync_events)
        .with_matrix_endpoint::<send::Request, _, _>(send_message)
        .with_matrix_endpoint::<state::Request, _, _>(send_state)
        .with_matrix_endpoint::<redact::Request, _, _>(redact_event)
        .with_matrix_endpoint::<join::Request, _, _>(join_room)
        .with_matrix_endpoint::<create_room::Request, _, _>(new_room)
        .with_matrix_endpoint::<typing::Request, _, _>(set_typing)
        .with_matrix_endpoint::<profile::Request, _, _>(set_profile)
        .with_matrix_endpoint::<upload::Request, _, _>(upload_media)
        .with_matrix_endpoint::<receipt::Request, _, _>(accept::<receipt::Request>)
        .with_matrix_endpoint::<leave::Request, _, _>(accept::<leave::Request>)
        .with_matrix_endpoint::<forget::Request, _, _>(accept::<forget::Request>)
        .with_matrix_endpoint::<invite::Request, _, _>(accept::<invite::Request>)
        .with_matrix_endpoint::<kick::Request, _, _>(accept::<kick::Request>)
        .with_matrix_endpoint::<ban::Request, _, _>(accept::<ban::Request>)
        .with_matrix_endpoint::<unban::Request, _, _>(accept::<unban::Request>)
}

async fn supported_versions(_: Req<versions::Request>) -> MatrixResult<versions::Response> {
    let versions = ["v1.1", "v1.11", "v1.12"].map(str::to_owned).to_vec();
    Ok(MatrixResponse::new(versions::Response::new(versions)))
}

async fn log_in(req: Req<login::Request>) -> MatrixResult<login::Response> {
    let forbidden = || MatrixRejection::forbidden("invalid username or password");
    let login::LoginInfo::Password(password) = &req.login_info else {
        return Err(MatrixRejection::Unrecognized("only m.login.password is supported".into()));
    };
    let Some(UserIdentifier::Matrix(identifier)) = &password.identifier else {
        return Err(forbidden());
    };
    let (user_id, token, device_id) =
        state(&req)?.login(&identifier.user, &password.password).ok_or_else(forbidden)?;
    let user_id = OwnedUserId::try_from(user_id).map_err(|_| forbidden())?;
    let response = login::Response::new(user_id, token, OwnedDeviceId::from(device_id));
    Ok(MatrixResponse::new(response))
}

async fn who_am_i(req: Req<whoami::Request>) -> MatrixResult<whoami::Response> {
    let mut response = whoami::Response::new(sender(&req)?.to_owned(), false);
    response.device_id.clone_from(&req.sender_device);
    Ok(MatrixResponse::new(response))
}

/// Answers a queued batch at once, else waits for one up to the client's
/// timeout, else answers an empty batch.
async fn sync_events(req: Req<sync::Request>) -> MatrixResult<sync::Response> {
    let shared = state(&req)?;
    let user_id = sender(&req)?.as_str();
    shared.note_since(user_id, req.since.as_deref());
    let wait = req.timeout.unwrap_or_default().min(MAX_SYNC_WAIT);
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        // Registered before checking, so a push between the check and the
        // wait is not missed.
        let notified = shared.sync_wake.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if let Some(batch) = shared.take_sync(user_id) {
            return Ok(MatrixResponse::new(batch));
        }
        tokio::select! {
            () = notified => {}
            () = tokio::time::sleep_until(deadline) => {
                return Ok(MatrixResponse::new(shared.empty_sync()));
            }
        }
    }
}

async fn send_message(req: Req<send::Request>) -> MatrixResult<send::Response> {
    let event =
        new_event(&req, &req.room_id, req.event_type.to_string(), json_of(&req.body.body)?)?;
    let event = NewEvent { txn_id: Some(req.txn_id.to_string()), ..event };
    Ok(MatrixResponse::new(send::Response::new(accept_event(&req, event)?)))
}

async fn send_state(req: Req<state::Request>) -> MatrixResult<state::Response> {
    let event =
        new_event(&req, &req.room_id, req.event_type.to_string(), json_of(&req.body.body)?)?;
    let event = NewEvent { state_key: Some(req.state_key.clone()), ..event };
    Ok(MatrixResponse::new(state::Response::new(accept_event(&req, event)?)))
}

async fn redact_event(req: Req<redact::Request>) -> MatrixResult<redact::Response> {
    let mut content = json!({ "redacts": req.event_id });
    if let Some(reason) = &req.reason {
        content["reason"] = json!(reason);
    }
    let event = new_event(&req, &req.room_id, "m.room.redaction".into(), content)?;
    let event = NewEvent { txn_id: Some(req.txn_id.to_string()), ..event };
    Ok(MatrixResponse::new(redact::Response::new(accept_event(&req, event)?)))
}

/// Joining a room id lands in it; an alias resolves to a fresh room.
async fn join_room(req: Req<join::Request>) -> MatrixResult<join::Response> {
    let room_id = match OwnedRoomId::try_from(req.room_id_or_alias.clone()) {
        Ok(room_id) => room_id,
        Err(_) => new_room_id(state(&req)?, "joined")?,
    };
    Ok(MatrixResponse::new(join::Response::new(room_id)))
}

async fn new_room(req: Req<create_room::Request>) -> MatrixResult<create_room::Response> {
    Ok(MatrixResponse::new(create_room::Response::new(new_room_id(state(&req)?, "created")?)))
}

async fn set_typing(req: Req<typing::Request>) -> MatrixResult<typing::Response> {
    own(&req, &req.user_id)?;
    Ok(MatrixResponse::new(typing::Response::new()))
}

async fn set_profile(req: Req<profile::Request>) -> MatrixResult<profile::Response> {
    own(&req, &req.user_id)?;
    Ok(MatrixResponse::new(profile::Response::new()))
}

async fn upload_media(req: Req<upload::Request>) -> MatrixResult<upload::Response> {
    let media_id = state(&req)?.new_local("media");
    let uri = OwnedMxcUri::from(format!("mxc://{SERVER_NAME}/{media_id}"));
    Ok(MatrixResponse::new(upload::Response::new(uri)))
}

/// Endpoints whose effect the fake does not model: parsed, then accepted.
async fn accept<T>(_: Req<T>) -> MatrixResult<T::OutgoingResponse>
where
    T: IncomingRequest,
    T::OutgoingResponse: Default,
{
    Ok(MatrixResponse::new(T::OutgoingResponse::default()))
}

fn state<T: IncomingRequest>(req: &Req<T>) -> Result<&Arc<Shared>, MatrixRejection> {
    req.try_app_state().ok_or_else(|| MatrixRejection::internal_error("state missing"))
}

fn sender<T: IncomingRequest>(req: &Req<T>) -> Result<&UserId, MatrixRejection> {
    req.sender_user.as_deref().ok_or_else(|| MatrixRejection::internal_error("no sender"))
}

/// Users may only set their own typing state and profile.
fn own<T: IncomingRequest>(req: &Req<T>, user_id: &UserId) -> Result<(), MatrixRejection> {
    if sender(req)? == user_id {
        Ok(())
    } else {
        Err(MatrixRejection::forbidden(format!("cannot act as {user_id}")))
    }
}

fn new_event<T: IncomingRequest>(
    req: &Req<T>,
    room_id: &RoomId,
    event_type: String,
    content: Value,
) -> Result<NewEvent, MatrixRejection> {
    let device_id = req.sender_device.as_ref().map(ToString::to_string).unwrap_or_default();
    Ok(NewEvent {
        user_id: sender(req)?.to_string(),
        device_id,
        room_id: room_id.to_string(),
        event_type,
        state_key: None,
        txn_id: None,
        content,
    })
}

fn accept_event<T: IncomingRequest>(
    req: &Req<T>,
    event: NewEvent,
) -> Result<OwnedEventId, MatrixRejection> {
    OwnedEventId::try_from(state(req)?.send(event))
        .map_err(|e| MatrixRejection::internal_error(e.to_string()))
}

fn json_of<T>(raw: &Raw<T>) -> Result<Value, MatrixRejection> {
    serde_json::from_str(raw.json().get()).map_err(|e| MatrixRejection::bad_json(e.to_string()))
}

fn new_room_id(shared: &Shared, prefix: &str) -> Result<OwnedRoomId, MatrixRejection> {
    let room_id = format!("!{}:{SERVER_NAME}", shared.new_local(prefix));
    OwnedRoomId::try_from(room_id).map_err(|e| MatrixRejection::internal_error(e.to_string()))
}
