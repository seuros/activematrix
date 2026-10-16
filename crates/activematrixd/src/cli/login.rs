use anyhow::Context as _;
use tokio::io::AsyncReadExt;
use usage_rs::{Args, RunAsyncWith};

use super::Context;
use crate::crypto::AccessToken;
use crate::db::{Db, agents};
use crate::matrix::{self, Client, Homeserver};

/// Log an agent in and store its sealed access token
///
/// Logs in with a password (prompted, or read from stdin), or stores an
/// existing access token read from stdin. The token is sealed with the
/// master key; only the daemon can open it. Logging in again replaces the
/// token and clears a failed state.
#[derive(Args, Debug)]
#[usage(effect = "write")]
pub struct Login {
    /// The agent's name, as created in Rails
    #[usage(arg, value_name = "AGENT")]
    pub agent: String,
    /// Read an existing access token from stdin instead of logging in
    #[usage(long)]
    pub token_stdin: bool,
    /// Read the password from stdin instead of prompting
    #[usage(long)]
    pub password_stdin: bool,
    /// User to log in as [default: the agent's user id, else its name]
    #[usage(long, value_name = "USER")]
    pub user: Option<String>,
    /// Device name shown in the account's session list
    #[usage(long, value_name = "NAME", default = "activematrixd")]
    pub device_name: String,
}

impl RunAsyncWith<&Context> for Login {
    type Output = anyhow::Result<()>;

    async fn run_async_with(self, context: &Context) -> Self::Output {
        let config = context.config()?;
        let key = config.master_key()?;
        let db =
            Db::connect(config.database_url()?, 2).await.context("connecting to the database")?;
        let agent = agents::find_by_name(db.pool(), &self.agent).await?.with_context(|| {
            format!("no agent named {:?}; create it in Rails first", self.agent)
        })?;
        let homeserver = Homeserver::new(&agent.homeserver_url);

        let (user_id, device_id, token) = if self.token_stdin {
            let token = AccessToken::new(read_stdin().await?);
            let whoami = Client::new(homeserver, token.clone(), String::new()).whoami().await?;
            let device_id = whoami
                .device_id
                .context("the homeserver did not say which device this token is")?;
            (whoami.user_id, device_id, token)
        } else {
            let user = self
                .user
                .clone()
                .or_else(|| agent.user_id.clone())
                .unwrap_or_else(|| agent.name.clone());
            let password = if self.password_stdin {
                read_stdin().await?
            } else {
                let prompt = format!("Password for {user}: ");
                tokio::task::spawn_blocking(move || rpassword::prompt_password(prompt)).await??
            };
            let login = matrix::login(&homeserver, &user, &password, &self.device_name).await?;
            (login.user_id, login.device_id, login.access_token)
        };

        let sealed = key.seal(agent.id, &token)?;
        agents::store_credentials(db.pool(), agent.id, &user_id, &device_id, &sealed).await?;
        println!("✓ {} is logged in as {user_id} (device {device_id})", agent.name);
        Ok(())
    }
}

async fn read_stdin() -> anyhow::Result<String> {
    let mut input = String::new();
    tokio::io::stdin().read_to_string(&mut input).await?;
    let input = input.trim().to_owned();
    anyhow::ensure!(!input.is_empty(), "nothing on stdin");
    Ok(input)
}
