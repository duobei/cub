/// Channel manager: coordinate inbound routing and outbound dispatch.

/// Manages multiple channels.
pub struct ChannelManager {
  discord_channels : Array[DiscordChannel]
  telegram_channels : Array[TelegramChannel]
}

/// Create a new ChannelManager.
pub fn ChannelManager::new() -> ChannelManager {
  { discord_channels: [], telegram_channels: [] }
}

/// Add a Discord channel.
pub fn ChannelManager::add_discord(
  self : ChannelManager,
  channel : DiscordChannel
) -> Unit {
  self.discord_channels.push(channel)
}

/// Add a Telegram channel.
pub fn ChannelManager::add_telegram(
  self : ChannelManager,
  channel : TelegramChannel
) -> Unit {
  self.telegram_channels.push(channel)
}

/// Run all channels concurrently.
pub async fn ChannelManager::run(
  self : ChannelManager,
  handler : async (ChannelMessage) -> Unit
) -> Unit {
  let total = self.discord_channels.length() + self.telegram_channels.length()
  if total == 0 {
    @log.warn("channels", "no channels configured")
    return
  }
  let names : Array[String] = []
  for ch in self.discord_channels {
    names.push(ch.name())
  }
  for ch in self.telegram_channels {
    names.push(ch.name())
  }
  let joined = names.join(", ")
  @log.info("channels", "starting: \{joined}")
  // Start all channels concurrently using task group
  @async.with_task_group(
    fn(group) {
      for ch in self.discord_channels {
        group.spawn_bg(async fn() { ch.start(handler) }, allow_failure=true)
      }
      for ch in self.telegram_channels {
        group.spawn_bg(async fn() { ch.start(handler) }, allow_failure=true)
      }
    },
  )
}
