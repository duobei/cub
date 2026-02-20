/// Channel base trait and types stub.

/// A message from a channel.
pub struct ChannelMessage {
  channel : String
  session_id : String
  prompt : String
  metadata : Json
} derive(Show)

/// Result to send back to a channel.
pub struct ChannelOutput {
  text : String
  metadata : Json
} derive(Show)

/// Channel trait: all channels implement this.
pub(open) trait Channel {
  name(Self) -> String
  start(Self, async (ChannelMessage) -> ChannelOutput!Error) -> Unit!Error
}
