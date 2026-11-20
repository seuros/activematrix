use ruma::api::client::membership::{
    ban_user::v3 as ban, forget_room::v3 as forget, invite_user::v3 as invite,
    join_room_by_id_or_alias::v3 as join, kick_user::v3 as kick, leave_room::v3 as leave,
    unban_user::v3 as unban,
};

use super::{Client, Error};

impl Client {
    /// Joins a room by id or alias, returning the room id.
    pub async fn join(&self, room: &str) -> Result<String, Error> {
        let request = join::Request::new(room.try_into()?);
        Ok(self.matrix.send(request).await?.room_id.to_string())
    }

    /// Changes this session's membership or another user's membership.
    pub async fn membership(
        &self,
        room_id: &str,
        action: &str,
        user_id: Option<&str>,
        reason: Option<&str>,
    ) -> Result<(), Error> {
        let room_id = room_id.try_into()?;
        let user = || {
            user_id
                .ok_or_else(|| Error::Invalid("user_id is required".into()))?
                .try_into()
                .map_err(Error::from)
        };
        match action {
            "leave" => {
                let mut request = leave::Request::new(room_id);
                request.reason = reason.map(str::to_owned);
                self.matrix.send(request).await?;
            }
            "forget" => {
                self.matrix.send(forget::Request::new(room_id)).await?;
            }
            "invite" => {
                let mut recipient = invite::InviteUserId::new(user()?);
                recipient.reason = reason.map(str::to_owned);
                let request = invite::Request::new(room_id, recipient.into());
                self.matrix.send(request).await?;
            }
            "kick" => {
                let mut request = kick::Request::new(room_id, user()?);
                request.reason = reason.map(str::to_owned);
                self.matrix.send(request).await?;
            }
            "ban" => {
                let mut request = ban::Request::new(room_id, user()?);
                request.reason = reason.map(str::to_owned);
                self.matrix.send(request).await?;
            }
            "unban" => {
                let mut request = unban::Request::new(room_id, user()?);
                request.reason = reason.map(str::to_owned);
                self.matrix.send(request).await?;
            }
            _ => return Err(Error::Invalid(format!("membership action {action}"))),
        }
        Ok(())
    }
}
