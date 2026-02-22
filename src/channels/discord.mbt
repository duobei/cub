/// Discord Gateway WebSocket + REST.

///|
/// Discord Gateway URL.
let discord_gateway_url : String = "wss://gateway.discord.gg/?v=10&encoding=json"

///|
/// Discord REST API base URL.
let discord_api_base : String = "https://discord.com/api/v10"

///|
/// Discord message chunk limit.
let discord_message_limit : Int = 2000

///|
/// Discord Gateway opcodes.
let op_dispatch : Int = 0

///|
let op_heartbeat : Int = 1

///|
let op_identify : Int = 2

///|
let _op_hello : Int = 10

///|
let op_heartbeat_ack : Int = 11

///|
/// Discord Gateway intents.
let intent_guilds : Int = 1 << 9 // 512

///|
let intent_message_content : Int = 1 << 15 // 32768

///|
/// Discord channel implementation.
pub struct DiscordChannel {
  token : String
  allow_from : Array[String]
  allow_channels : Array[String]
  mut sequence : Int?
  mut session_id : String
  mut bot_user_id : String
  seen_messages : Map[String, Bool]
  mut heartbeat_acked : Bool
}

///|
/// Create a new DiscordChannel.
pub fn DiscordChannel::new(
  token : String,
  allow_from? : Array[String] = [],
  allow_channels? : Array[String] = [],
) -> DiscordChannel {
  {
    token,
    allow_from,
    allow_channels,
    sequence: None,
    session_id: "",
    bot_user_id: "",
    seen_messages: {},
    heartbeat_acked: true,
  }
}

///|
/// Get channel name.
pub fn DiscordChannel::name(_self : DiscordChannel) -> String {
  "discord"
}

///|
/// Maximum reconnect delay in milliseconds.
let max_reconnect_delay_ms : Int = 60000

///|
/// Initial reconnect delay in milliseconds.
let initial_reconnect_delay_ms : Int = 2000

///|
/// Start the Discord channel with automatic reconnection.
pub async fn DiscordChannel::start(
  self : DiscordChannel,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  if self.token.is_empty() {
    @log.error("discord", "token is empty")
    return
  }
  let mut delay = initial_reconnect_delay_ms
  for {
    let ok = self.connect_and_run(handler)
    // Reset delay on successful long-lived connections
    if ok {
      delay = initial_reconnect_delay_ms
    } else {
      // Exponential backoff on quick failures
      delay = if delay * 2 < max_reconnect_delay_ms {
        delay * 2
      } else {
        max_reconnect_delay_ms
      }
    }
    @log.info("discord", "reconnecting in \{delay / 1000}s...")
    @async.sleep(delay)
  }
}

///|
/// Connect to Gateway, run event loop. Returns true if session lasted > 30s.
async fn DiscordChannel::connect_and_run(
  self : DiscordChannel,
  handler : async (ChannelMessage) -> Unit,
) -> Bool {
  @log.info("discord", "connecting to gateway...")
  let conn = @websocket.connect(discord_gateway_url) catch {
    e => {
      @log.error("discord", "gateway connection failed: \{e}")
      return false
    }
  }
  // Read Hello (op 10)
  let hello_text = read_text_message(conn) catch {
    e => {
      @log.error("discord", "failed to read hello: \{e}")
      conn.close()
      return false
    }
  }
  let hello_json = @json.parse(hello_text) catch {
    _ => {
      @log.error("discord", "invalid hello message")
      conn.close()
      return false
    }
  }
  let heartbeat_interval = match hello_json {
    {
      "op": Number(_),
      "d": { "heartbeat_interval": Number(interval, ..), .. },
      ..
    } => interval.to_int()
    _ => {
      @log.error("discord", "unexpected hello format")
      conn.close()
      return false
    }
  }
  @log.info(
    "discord",
    "hello received, heartbeat interval: \{heartbeat_interval}ms",
  )
  // Send Identify
  self.send_identify(conn)
  // Track connection start time (approximate via heartbeat count)
  let heartbeat_count : Ref[Int] = { val: 0 }
  // Run heartbeat and event loop concurrently using task group
  @async.with_task_group(async fn(group) {
    group.spawn_bg(
      async fn() {
        self.heartbeat_loop(conn, heartbeat_interval, counter=heartbeat_count)
      },
      allow_failure=true,
    )
    self.event_loop(conn, handler)
    conn.close()
    @log.info("discord", "disconnected")
  })
  // If we got at least a few heartbeats, connection was healthy
  heartbeat_count.val > 0
}

///|
/// Send Identify payload.
async fn DiscordChannel::send_identify(
  self : DiscordChannel,
  conn : @websocket.Conn,
) -> Unit {
  let intents = intent_guilds + intent_message_content
  let payload : Map[String, Json] = Map::new()
  payload["op"] = op_identify.to_json()
  let d : Map[String, Json] = Map::new()
  d["token"] = self.token.to_json()
  d["intents"] = intents.to_json()
  let properties : Map[String, Json] = Map::new()
  properties["os"] = "linux".to_json()
  properties["browser"] = "cub".to_json()
  properties["device"] = "cub".to_json()
  d["properties"] = Json::object(properties)
  payload["d"] = Json::object(d)
  let text = Json::object(payload).stringify()
  conn.send_text(text) catch {
    e => @log.error("discord", "identify send error: \{e}")
  }
}

///|
/// Heartbeat loop: send heartbeat at the given interval.
async fn DiscordChannel::heartbeat_loop(
  self : DiscordChannel,
  conn : @websocket.Conn,
  interval_ms : Int,
  counter? : Ref[Int] = { val: 0 },
) -> Unit {
  for {
    @async.sleep(interval_ms)
    // Check if previous heartbeat was acknowledged
    if not(self.heartbeat_acked) {
      @log.warn("discord", "heartbeat ACK not received, reconnecting")
      break
    }
    self.heartbeat_acked = false
    let payload : Map[String, Json] = Map::new()
    payload["op"] = op_heartbeat.to_json()
    match self.sequence {
      Some(s) => payload["d"] = s.to_json()
      None => payload["d"] = Json::null()
    }
    try {
      conn.send_text(Json::object(payload).stringify())
      counter.val += 1
    } catch {
      _ => break
    }
  }
}

///|
/// Event loop: receive and dispatch Gateway events.
async fn DiscordChannel::event_loop(
  self : DiscordChannel,
  conn : @websocket.Conn,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  for {
    let text = read_text_message(conn) catch { _ => break }
    let json = @json.parse(text) catch { _ => continue }
    let op = match json {
      { "op": Number(n, ..), .. } => n.to_int()
      _ => continue
    }
    // Update sequence
    match json {
      { "s": Number(s, ..), .. } => self.sequence = Some(s.to_int())
      _ => ()
    }
    match op {
      _ if op == op_dispatch => self.handle_dispatch(json, handler)
      _ if op == op_heartbeat_ack => self.heartbeat_acked = true
      _ if op == op_heartbeat
      // Server requesting heartbeat
      => {
        let payload : Map[String, Json] = Map::new()
        payload["op"] = op_heartbeat.to_json()
        match self.sequence {
          Some(s) => payload["d"] = s.to_json()
          None => payload["d"] = Json::null()
        }
        conn.send_text(Json::object(payload).stringify()) catch {
          _ => break
        }
      }
      _ => ()
    }
  }
}

///|
/// Handle a DISPATCH event.
async fn DiscordChannel::handle_dispatch(
  self : DiscordChannel,
  json : Json,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  let event_name = match json {
    { "t": String(t), .. } => t
    _ => return
  }
  let data = match json {
    { "d": Object(_), .. } =>
      match json {
        { "d": d, .. } => d
        _ => return
      }
    _ => return
  }
  match event_name {
    "READY" => {
      match data {
        { "session_id": String(sid), .. } => self.session_id = sid
        _ => ()
      }
      match data {
        { "user": { "id": String(uid), .. }, .. } => {
          self.bot_user_id = uid
          @log.info("discord", "ready, bot user id: \{uid}")
        }
        _ => @log.info("discord", "ready")
      }
    }
    "MESSAGE_CREATE" => self.handle_message_create(data, handler)
    _ => ()
  }
}

///|
/// Handle a MESSAGE_CREATE event.
async fn DiscordChannel::handle_message_create(
  self : DiscordChannel,
  data : Json,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  // Deduplicate by message ID
  let msg_id = match data {
    { "id": String(mid), .. } => mid
    _ => ""
  }
  if msg_id.length() > 0 {
    if self.seen_messages.contains(msg_id) {
      return
    }
    self.seen_messages[msg_id] = true
    // Keep seen_messages bounded — evict oldest half when full
    if self.seen_messages.length() > 1000 {
      let keys = self.seen_messages.keys().collect()
      let half = keys.length() / 2
      for i = 0; i < half; i = i + 1 {
        self.seen_messages.remove(keys[i])
      }
    }
  }
  // Skip bot messages
  let is_bot = match data {
    { "author": { "bot": True, .. }, .. } => true
    _ => false
  }
  let content = match data {
    { "content": String(c), .. } => c
    _ => ""
  }
  if is_bot {
    return
  }
  // Extract image attachment URLs
  let image_urls : Array[String] = []
  match data {
    { "attachments": Array(attachments), .. } =>
      for att in attachments {
        let url = match att {
          { "url": String(u), .. } => u
          _ => continue
        }
        let content_type = match att {
          { "content_type": String(ct), .. } => ct
          _ => ""
        }
        if content_type.has_prefix("image/") {
          image_urls.push(url)
        }
      }
    _ => ()
  }
  // Allow messages with images but no text
  if content.trim().to_string().is_empty() && image_urls.is_empty() {
    return
  }
  // Get channel_id
  let channel_id = match data {
    { "channel_id": String(cid), .. } => cid
    _ => return
  }
  // Get author info
  let author_id = match data {
    { "author": { "id": String(uid), .. }, .. } => uid
    _ => ""
  }
  let author_name = match data {
    { "author": { "username": String(uname), .. }, .. } => uname
    _ => ""
  }
  // Permission check
  let perm = self.check_permission(channel_id, author_id, author_name, content)
  if perm == "denied" {
    self.send_message(
      channel_id, "Access denied. Please deploy your own instance of Cub.",
    )
    return
  }
  if perm != "ok" {
    return // "ignored" — wrong channel, silently skip
  }
  @log.info(
    "discord",
    "message from \{author_name} in \{channel_id}: \{truncate(content, 100)}",
  )
  // Build ChannelMessage
  let session_id = "discord:\{channel_id}"
  let metadata : Map[String, Json] = Map::new()
  metadata["channel"] = "discord".to_json()
  metadata["channel_id"] = channel_id.to_json()
  metadata["sender_id"] = author_id.to_json()
  metadata["username"] = author_name.to_json()
  match data {
    { "id": String(mid), .. } => metadata["message_id"] = mid.to_json()
    _ => ()
  }
  let msg : ChannelMessage = {
    channel: "discord",
    session_id,
    prompt: content,
    metadata: Json::object(metadata),
    attachments: image_urls,
  }
  handler(msg)
}

///|
/// Check permission for a message. Returns "ok", "denied", or "ignored".
pub fn DiscordChannel::check_permission(
  self : DiscordChannel,
  channel_id : String,
  author_id : String,
  author_name : String,
  content : String,
) -> String {
  // Check channel filter — wrong channel is silently ignored
  if self.allow_channels.length() > 0 &&
    not(self.allow_channels.contains(channel_id)) {
    return "ignored"
  }
  // Check sender filter — unauthorized user gets denied message
  if self.allow_from.length() > 0 {
    let allowed = self.allow_from.contains(author_id) ||
      self.allow_from.contains(author_name)
    if not(allowed) {
      return "denied"
    }
  }
  // If no channels configured, ignore all messages
  if self.allow_channels.is_empty() {
    return "ignored"
  }
  // Check if message mentions cub or is a command
  if content.trim().to_string().length() > 0 &&
    content[0] == ','.to_int().to_uint16() {
    return "ok"
  }
  if content.to_lower().contains("cub") {
    return "ok"
  }
  // Channel is in allowed list, accept all messages in it
  "ok"
}

///|
/// Send a message to a Discord channel via REST API.
pub async fn DiscordChannel::send_message(
  self : DiscordChannel,
  channel_id : String,
  text : String,
) -> Unit {
  let chunks = chunk_message(text, discord_message_limit)
  for chunk in chunks {
    let url = "\{discord_api_base}/channels/\{channel_id}/messages"
    let body : Map[String, Json] = Map::new()
    body["content"] = chunk.to_json()
    let body_str = Json::object(body).stringify()
    let headers : Map[String, String] = Map::new()
    headers["Content-Type"] = "application/json"
    headers["Authorization"] = "Bot \{self.token}"
    headers["User-Agent"] = "DiscordBot (cub, 0.1.0)"
    try {
      let (response, _data) = @http.post(url, body_str, headers~)
      if response.code != 200 && response.code != 204 {
        @log.warn("discord", "send_message failed: HTTP \{response.code}")
      }
    } catch {
      e => @log.error("discord", "send_message error: \{e}")
    }
  }
}

///|
/// Read a text message from a WebSocket connection.
async fn read_text_message(conn : @websocket.Conn) -> String {
  let msg = conn.recv()
  let buf = @buffer.new()
  let tmp = FixedArray::make(4096, b'\x00')
  for {
    let n = msg.read(tmp)
    if n == 0 {
      break
    }
    buf.write_bytesview(tmp.unsafe_reinterpret_as_bytes()[:n])
  }
  @utf8.decode_lossy(buf.contents())
}

///|
/// Chunk a message to fit within Discord's message limit.
pub fn chunk_message(text : String, limit : Int) -> Array[String] {
  if text.length() <= limit {
    return [text]
  }
  let chunks : Array[String] = []
  let mut remaining = text
  let mut safety = 0
  while remaining.length() > 0 {
    safety = safety + 1
    if safety > 100 {
      chunks.push(remaining)
      break
    }
    if remaining.length() <= limit {
      chunks.push(remaining)
      break
    }
    // Try to split at newline
    let mut split_at = -1
    for i = limit - 1; i > 0; i = i - 1 {
      if remaining[i] == '\n'.to_int().to_uint16() {
        split_at = i
        break
      }
    }
    if split_at <= 0 {
      split_at = limit
    }
    let chunk = remaining[:split_at].to_string() catch { _ => remaining }
    chunks.push(chunk.trim().to_string())
    remaining = remaining[split_at:].to_string().trim().to_string() catch {
        _ => ""
      }
  }
  chunks
}

///|
/// Truncate a string to max length.
fn truncate(s : String, max_len : Int) -> String {
  if s.length() <= max_len {
    s
  } else {
    try s[:max_len].to_string() + "..." catch {
      _ => s
    }
  }
}
