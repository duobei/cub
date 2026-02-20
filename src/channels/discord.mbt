/// Discord Gateway WebSocket + REST stub.

/// Discord channel implementation.
pub struct DiscordChannel {
  token : String
  allow_from : Array[String]
  allow_channels : Array[String]
}

/// Create a new DiscordChannel.
pub fn DiscordChannel::new(
  token : String,
  allow_from~ : Array[String] = [],
  allow_channels~ : Array[String] = []
) -> DiscordChannel {
  { token, allow_from, allow_channels }
}

/// Get channel name.
pub fn DiscordChannel::name(_self : DiscordChannel) -> String {
  "discord"
}

/// Start the Discord channel.
pub async fn DiscordChannel::start(
  self : DiscordChannel,
  handler : async (ChannelMessage) -> ChannelOutput!Error
) -> Unit!Error {
  ignore(self)
  ignore(handler)
  abort("DiscordChannel::start not implemented")
}

/// Send a message to a Discord channel.
pub async fn DiscordChannel::send_message(
  self : DiscordChannel,
  channel_id : String,
  text : String
) -> Unit!Error {
  ignore(self)
  ignore(channel_id)
  ignore(text)
  abort("DiscordChannel::send_message not implemented")
}
