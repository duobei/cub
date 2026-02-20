/// Channel base types.

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
