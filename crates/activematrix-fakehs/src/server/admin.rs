//! The admin API under `/_fake/`, for tests written in other languages.
//! Plain routes: these are not Matrix endpoints.

use rama::http::StatusCode;
use rama::http::service::web::Router;
use rama::http::service::web::extract::{Json, Path};
use rama_x_ruma::ExtState;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::state::{Batch, Fault, Shared};

#[derive(Deserialize)]
struct NewUser {
    localpart: String,
    password: Option<String>,
}

#[derive(Deserialize)]
struct NewFault {
    method: Option<String>,
    #[serde(default = "root")]
    path_prefix: String,
    #[serde(flatten)]
    fault: Fault,
}

#[derive(Deserialize)]
struct Revoke {
    token: Option<String>,
}

#[derive(Deserialize)]
struct UserPath {
    user_id: String,
}

pub fn routes(router: Router) -> Router {
    router
        .with_post("/_fake/users", add_user)
        .with_post("/_fake/sync/{user_id}", push_sync)
        .with_get("/_fake/sent", sent)
        .with_get("/_fake/requests", requests)
        .with_get("/_fake/since/{user_id}", since)
        .with_post("/_fake/faults", inject)
        .with_post("/_fake/revoke", revoke)
}

async fn add_user(ExtState(shared): ExtState<Shared>, Json(user): Json<NewUser>) -> Json<Value> {
    let token = shared.add_user(&user.localpart, user.password.as_deref());
    Json(json!({
        "user_id": format!("@{}:{}", user.localpart, crate::SERVER_NAME),
        "access_token": token,
    }))
}

/// The batch must parse as the scripted part of a `/sync` response.
async fn push_sync(
    ExtState(shared): ExtState<Shared>,
    Path(path): Path<UserPath>,
    Json(batch): Json<Value>,
) -> (StatusCode, Json<Value>) {
    match Batch::parse(batch) {
        Ok(batch) => {
            shared.push_sync(&path.user_id, batch);
            (StatusCode::OK, Json(json!({})))
        }
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "errcode": "M_BAD_JSON", "error": e.to_string() })),
        ),
    }
}

async fn sent(ExtState(shared): ExtState<Shared>) -> Json<Value> {
    Json(serde_json::to_value(shared.sent()).unwrap_or_default())
}

async fn requests(ExtState(shared): ExtState<Shared>) -> Json<Value> {
    Json(serde_json::to_value(shared.requests()).unwrap_or_default())
}

async fn since(ExtState(shared): ExtState<Shared>, Path(path): Path<UserPath>) -> Json<Value> {
    Json(json!({ "since": shared.last_since(&path.user_id) }))
}

async fn inject(ExtState(shared): ExtState<Shared>, Json(new): Json<NewFault>) -> Json<Value> {
    shared.inject(new.method.as_deref(), &new.path_prefix, new.fault);
    Json(json!({}))
}

async fn revoke(ExtState(shared): ExtState<Shared>, Json(revoke): Json<Revoke>) -> Json<Value> {
    if let Some(token) = revoke.token {
        shared.revoke(&token);
    }
    Json(json!({}))
}

fn root() -> String {
    "/".into()
}
