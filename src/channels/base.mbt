/// Channel base types.

///|
/// A message from a channel.
pub struct ChannelMessage {
  channel : String
  session_id : String
  prompt : String
  metadata : Json
  attachments : Array[String]
} derive(Show)
