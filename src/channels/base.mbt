/// Channel base types.

///|
/// A non-image file attachment.
pub struct Attachment {
  url : String
  filename : String
  content_type : String
} derive(Show)

///|
/// A message from a channel.
pub struct ChannelMessage {
  channel : String
  session_id : String
  prompt : String
  metadata : Json
  attachments : Array[String]
  documents : Array[Attachment]
} derive(Show)
