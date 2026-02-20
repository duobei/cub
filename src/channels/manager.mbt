/// Channel manager stub.

/// Manages multiple channels.
pub struct ChannelManager {
  channels : Array[DiscordChannel]
}

/// Create a new ChannelManager.
pub fn ChannelManager::new() -> ChannelManager {
  { channels: [] }
}

/// Add a Discord channel.
pub fn ChannelManager::add_discord(
  self : ChannelManager,
  channel : DiscordChannel
) -> Unit {
  self.channels.push(channel)
}

/// Run all channels concurrently.
pub async fn ChannelManager::run(
  self : ChannelManager,
  handler : async (ChannelMessage) -> ChannelOutput!Error
) -> Unit!Error {
  ignore(self)
  ignore(handler)
  abort("ChannelManager::run not implemented")
}
