/// Telegram Bot API — HTTP long polling.

///|
/// Telegram API base URL.
let telegram_api_base : String = "https://api.telegram.org"

///|
/// Telegram message chunk limit.
let telegram_message_limit : Int = 4096

///|
/// Telegram channel implementation.
pub struct TelegramChannel {
  token : String
  allow_from : Array[String]
  allow_chats : Array[String]
  mut last_update_id : Int
}

///|
/// Create a new TelegramChannel.
pub fn TelegramChannel::new(
  token : String,
  allow_from? : Array[String] = [],
  allow_chats? : Array[String] = [],
) -> TelegramChannel {
  { token, allow_from, allow_chats, last_update_id: 0 }
}

///|
/// Get channel name.
pub fn TelegramChannel::name(_self : TelegramChannel) -> String {
  "telegram"
}

///|
/// Start the Telegram channel with long polling.
pub async fn TelegramChannel::start(
  self : TelegramChannel,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  if self.token.is_empty() {
    @log.error("telegram", "token is empty")
    return
  }
  @log.info("telegram", "starting long polling...")
  // Poll loop
  for {
    let updates = self.get_updates()
    for update in updates {
      self.handle_update(update, handler)
    }
    // Small delay between polls if no updates
    if updates.is_empty() {
      @async.sleep(500)
    }
  }
}

///|
/// Fetch updates from Telegram API with long polling.
async fn TelegramChannel::get_updates(self : TelegramChannel) -> Array[Json] {
  let url = "\{telegram_api_base}/bot\{self.token}/getUpdates?timeout=30&offset=\{self.last_update_id}"
  let headers : Map[String, String] = {}
  headers["Content-Type"] = "application/json"
  let (response, response_data) = @http.get(url, headers~) catch {
    e => {
      @log.error("telegram", "poll error: \{e}")
      @async.sleep(5000)
      return []
    }
  }
  if response.code != 200 {
    let text = response_data.text() catch { _ => "HTTP \{response.code}" }
    @log.error("telegram", "API error (\{response.code}): \{text}")
    @async.sleep(5000)
    return []
  }
  let text = response_data.text() catch { _ => return [] }
  let json = @json.parse(text) catch { _ => return [] }
  match json {
    { "ok": True, "result": Array(results), .. } => results
    _ => []
  }
}

///|
/// Handle a single update.
async fn TelegramChannel::handle_update(
  self : TelegramChannel,
  update : Json,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  // Extract update_id and advance offset
  let update_id = match update {
    { "update_id": Number(n, ..), .. } => n.to_int()
    _ => return
  }
  self.last_update_id = update_id + 1
  // Extract message
  let message = match update {
    { "message": Object(_), .. } =>
      match update {
        { "message": msg, .. } => msg
        _ => return
      }
    _ => return
  }
  // Extract text
  let text = match message {
    { "text": String(t), .. } => t
    _ => return
  }
  // Extract chat_id and from_id
  let chat_id = match message {
    { "chat": { "id": Number(n, ..), .. }, .. } => n.to_int().to_string()
    _ => return
  }
  let from_id = match message {
    { "from": { "id": Number(n, ..), .. }, .. } => n.to_int().to_string()
    _ => ""
  }
  let from_name = match message {
    { "from": { "first_name": String(n), .. }, .. } => n
    _ => "unknown"
  }
  // Access control
  if not(self.allow_from.is_empty()) && not(self.allow_from.contains(from_id)) {
    @log.debug(
      "telegram",
      "ignoring message from \{from_id} (not in allow_from)",
    )
    return
  }
  if not(self.allow_chats.is_empty()) && not(self.allow_chats.contains(chat_id)) {
    @log.debug(
      "telegram",
      "ignoring message in chat \{chat_id} (not in allow_chats)",
    )
    return
  }
  @log.info(
    "telegram",
    "message from \{from_name} (\{from_id}) in chat \{chat_id}",
  )
  // Build channel message
  let session_id = "telegram:\{chat_id}"
  let metadata : Map[String, Json] = {}
  metadata["from_id"] = from_id.to_json()
  metadata["from_name"] = from_name.to_json()
  metadata["chat_id"] = chat_id.to_json()
  let msg = ChannelMessage::{
    channel: "telegram",
    session_id,
    prompt: text,
    metadata: Json::object(metadata),
  }
  handler(msg)
}

///|
/// Escape text for Telegram HTML parse mode.
fn escape_html(text : String) -> String {
  text
  .replace(old="&", new="&amp;")
  .replace(old="<", new="&lt;")
  .replace(old=">", new="&gt;")
}

///|
/// Send a message to a Telegram chat with HTML formatting.
pub async fn TelegramChannel::send_message(
  self : TelegramChannel,
  chat_id : String,
  text : String,
) -> Unit {
  let escaped = escape_html(text)
  // Chunk if too long
  let chunks = chunk_message(escaped, telegram_message_limit)
  for chunk in chunks {
    let body : Map[String, Json] = {}
    body["chat_id"] = chat_id.to_json()
    body["text"] = chunk.to_json()
    body["parse_mode"] = "HTML".to_json()
    let url = "\{telegram_api_base}/bot\{self.token}/sendMessage"
    let headers : Map[String, String] = {}
    headers["Content-Type"] = "application/json"
    let body_str = Json::object(body).stringify()
    let (response, _) = @http.post(url, body_str, headers~) catch {
      e => {
        @log.error("telegram", "send error: \{e}")
        return
      }
    }
    if response.code != 200 {
      @log.error("telegram", "send failed: HTTP \{response.code}")
    }
  }
}
