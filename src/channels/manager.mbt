/// Channel manager: coordinate inbound routing and outbound dispatch.

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
  handler : async (ChannelMessage) -> Unit
) -> Unit {
  if self.channels.is_empty() {
    @log.warn("channels", "no channels configured")
    return
  }
  let names : Array[String] = []
  for ch in self.channels {
    names.push(ch.name())
  }
  let joined = names.join(", ")
  @log.info("channels", "starting: \{joined}")
  // Start all channels concurrently using task group
  @async.with_task_group(
    fn(group) {
      for ch in self.channels {
        group.spawn_bg(async fn() { ch.start(handler) }, allow_failure=true)
      }
    },
  )
}
