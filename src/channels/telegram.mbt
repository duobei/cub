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
  // Extract photo URLs
  let image_urls : Array[String] = []
  match message {
    { "photo": Array(photos), .. } =>
      if photos.length() > 0 {
        // Take the largest photo (last in array)
        let largest = photos[photos.length() - 1]
        match largest {
          { "file_id": String(fid), .. } => {
            let photo_url = self.get_file_url(fid)
            if photo_url.length() > 0 {
              image_urls.push(photo_url)
            }
          }
          _ => ()
        }
      }
    _ => ()
  }
  // Extract document attachment
  let documents : Array[Attachment] = []
  match message {
    { "document": { "file_id": String(fid), .. }, .. } => {
      let filename = match message {
        { "document": { "file_name": String(f), .. }, .. } => f
        _ => "document"
      }
      let mime = match message {
        { "document": { "mime_type": String(m), .. }, .. } => m
        _ => "application/octet-stream"
      }
      let doc_url = self.get_file_url(fid)
      if doc_url.length() > 0 {
        documents.push({ url: doc_url, filename, content_type: mime })
      }
    }
    _ => ()
  }
  // Extract text (or caption for photo messages)
  let text = match message {
    { "text": String(t), .. } => t
    { "caption": String(c), .. } => c
    _ => ""
  }
  // Skip empty messages (no text, no images, no documents)
  if text.is_empty() && image_urls.is_empty() && documents.is_empty() {
    return
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
    attachments: image_urls,
    documents,
  }
  handler(msg)
}

///|
/// Get file URL from Telegram file_id via getFile API.
async fn TelegramChannel::get_file_url(
  self : TelegramChannel,
  file_id : String,
) -> String {
  let url = "\{telegram_api_base}/bot\{self.token}/getFile?file_id=\{file_id}"
  let headers : Map[String, String] = {}
  headers["Content-Type"] = "application/json"
  let (response, response_data) = @http.get(url, headers~) catch {
    e => {
      @log.error("telegram", "getFile error: \{e}")
      return ""
    }
  }
  if response.code != 200 {
    @log.error("telegram", "getFile failed: HTTP \{response.code}")
    return ""
  }
  let text = response_data.text() catch { _ => return "" }
  let json = @json.parse(text) catch { _ => return "" }
  match json {
    { "ok": True, "result": { "file_path": String(fp), .. }, .. } =>
      "\{telegram_api_base}/file/bot\{self.token}/\{fp}"
    _ => ""
  }
}

///|
/// Send typing indicator to a Telegram chat.
pub async fn TelegramChannel::send_typing(
  self : TelegramChannel,
  chat_id : String,
) -> Unit {
  let body : Map[String, Json] = {}
  body["chat_id"] = chat_id.to_json()
  body["action"] = "typing".to_json()
  let url = "\{telegram_api_base}/bot\{self.token}/sendChatAction"
  let headers : Map[String, String] = {}
  headers["Content-Type"] = "application/json"
  let body_str = Json::object(body).stringify()
  try {
    let _ = @http.post(url, body_str, headers~)
  } catch {
    e => @log.debug("telegram", "typing indicator error: \{e}")
  }
}

///|
/// Escape text for Telegram HTML parse mode.
pub fn escape_html(text : String) -> String {
  let buf = StringBuilder::new()
  for ch in text {
    match ch {
      '&' => buf.write_string("&amp;")
      '<' => buf.write_string("&lt;")
      '>' => buf.write_string("&gt;")
      '"' => buf.write_string("&quot;")
      _ => buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
/// Convert Markdown text to Telegram-compatible HTML.
/// Three-pass approach: 1) extract code blocks 2) convert markdown 3) restore code blocks.
pub fn markdown_to_html(text : String) -> String {
  // Pass 1: Extract fenced code blocks and inline code into placeholders
  let placeholders : Array[String] = []
  let buf1 = StringBuilder::new()
  let len = text.length()
  let mut i = 0
  while i < len {
    // Check for fenced code block: ```
    if i + 2 < len &&
      text[i] == '`'.to_int().to_uint16() &&
      text[i + 1] == '`'.to_int().to_uint16() &&
      text[i + 2] == '`'.to_int().to_uint16() {
      i += 3
      // Extract optional language
      let lang_buf = StringBuilder::new()
      while i < len && text[i] != '\n'.to_int().to_uint16() {
        lang_buf.write_char(text[i].to_int().unsafe_to_char())
        i += 1
      }
      if i < len {
        i += 1 // skip newline
      }
      let lang = lang_buf.to_string().trim().to_string()
      // Find closing ```
      let code_buf = StringBuilder::new()
      let mut found_close = false
      while i < len {
        if i + 2 < len &&
          text[i] == '`'.to_int().to_uint16() &&
          text[i + 1] == '`'.to_int().to_uint16() &&
          text[i + 2] == '`'.to_int().to_uint16() {
          i += 3
          found_close = true
          break
        }
        code_buf.write_char(text[i].to_int().unsafe_to_char())
        i += 1
      }
      ignore(found_close)
      let escaped_code = escape_html(code_buf.to_string())
      let html = if lang.length() > 0 {
        let escaped_lang = escape_html(lang)
        "<pre><code class=\"language-\{escaped_lang}\">\{escaped_code}</code></pre>"
      } else {
        "<pre><code>\{escaped_code}</code></pre>"
      }
      let idx = placeholders.length()
      placeholders.push(html)
      buf1.write_string("\u0000PH\{idx}\u0000")
      continue
    }
    // Check for inline code: `code`
    if text[i] == '`'.to_int().to_uint16() {
      i += 1
      let code_buf = StringBuilder::new()
      let mut found_close = false
      while i < len {
        if text[i] == '`'.to_int().to_uint16() {
          i += 1
          found_close = true
          break
        }
        code_buf.write_char(text[i].to_int().unsafe_to_char())
        i += 1
      }
      if found_close {
        let escaped_code = escape_html(code_buf.to_string())
        let html = "<code>\{escaped_code}</code>"
        let idx = placeholders.length()
        placeholders.push(html)
        buf1.write_string("\u0000PH\{idx}\u0000")
      } else {
        buf1.write_char('`')
        buf1.write_string(code_buf.to_string())
      }
      continue
    }
    buf1.write_char(text[i].to_int().unsafe_to_char())
    i += 1
  }
  let pass1 = buf1.to_string()
  // Pass 2: Escape HTML in remaining text, then convert markdown markers
  // First escape the non-placeholder text
  let buf2 = StringBuilder::new()
  let p1_len = pass1.length()
  i = 0
  while i < p1_len {
    if pass1[i] == '\u0000'.to_int().to_uint16() {
      // Copy placeholder verbatim
      buf2.write_char('\u0000')
      i += 1
      while i < p1_len && pass1[i] != '\u0000'.to_int().to_uint16() {
        buf2.write_char(pass1[i].to_int().unsafe_to_char())
        i += 1
      }
      if i < p1_len {
        buf2.write_char('\u0000')
        i += 1
      }
    } else {
      let ch = pass1[i].to_int().unsafe_to_char()
      match ch {
        '&' => buf2.write_string("&amp;")
        '<' => buf2.write_string("&lt;")
        '>' => buf2.write_string("&gt;")
        _ => buf2.write_char(ch)
      }
      i += 1
    }
  }
  let escaped_pass = buf2.to_string()
  // Now convert markdown markers: **bold**, *italic*, ~~strike~~, [text](url)
  let buf3 = StringBuilder::new()
  let ep_len = escaped_pass.length()
  i = 0
  while i < ep_len {
    // Skip placeholders
    if escaped_pass[i] == '\u0000'.to_int().to_uint16() {
      buf3.write_char('\u0000')
      i += 1
      while i < ep_len && escaped_pass[i] != '\u0000'.to_int().to_uint16() {
        buf3.write_char(escaped_pass[i].to_int().unsafe_to_char())
        i += 1
      }
      if i < ep_len {
        buf3.write_char('\u0000')
        i += 1
      }
      continue
    }
    // Check for **bold**
    if i + 1 < ep_len &&
      escaped_pass[i] == '*'.to_int().to_uint16() &&
      escaped_pass[i + 1] == '*'.to_int().to_uint16() {
      i += 2
      let inner = StringBuilder::new()
      let mut found = false
      while i + 1 < ep_len {
        if escaped_pass[i] == '*'.to_int().to_uint16() &&
          escaped_pass[i + 1] == '*'.to_int().to_uint16() {
          i += 2
          found = true
          break
        }
        inner.write_char(escaped_pass[i].to_int().unsafe_to_char())
        i += 1
      }
      if found {
        buf3.write_string("<b>")
        buf3.write_string(inner.to_string())
        buf3.write_string("</b>")
      } else {
        buf3.write_string("**")
        buf3.write_string(inner.to_string())
      }
      continue
    }
    // Check for ~~strikethrough~~
    if i + 1 < ep_len &&
      escaped_pass[i] == '~'.to_int().to_uint16() &&
      escaped_pass[i + 1] == '~'.to_int().to_uint16() {
      i += 2
      let inner = StringBuilder::new()
      let mut found = false
      while i + 1 < ep_len {
        if escaped_pass[i] == '~'.to_int().to_uint16() &&
          escaped_pass[i + 1] == '~'.to_int().to_uint16() {
          i += 2
          found = true
          break
        }
        inner.write_char(escaped_pass[i].to_int().unsafe_to_char())
        i += 1
      }
      if found {
        buf3.write_string("<s>")
        buf3.write_string(inner.to_string())
        buf3.write_string("</s>")
      } else {
        buf3.write_string("~~")
        buf3.write_string(inner.to_string())
      }
      continue
    }
    // Check for *italic* (single asterisk, not followed by another *)
    if escaped_pass[i] == '*'.to_int().to_uint16() {
      if i + 1 < ep_len && escaped_pass[i + 1] != '*'.to_int().to_uint16() {
        i += 1
        let inner = StringBuilder::new()
        let mut found = false
        while i < ep_len {
          if escaped_pass[i] == '*'.to_int().to_uint16() {
            i += 1
            found = true
            break
          }
          inner.write_char(escaped_pass[i].to_int().unsafe_to_char())
          i += 1
        }
        if found {
          buf3.write_string("<i>")
          buf3.write_string(inner.to_string())
          buf3.write_string("</i>")
        } else {
          buf3.write_char('*')
          buf3.write_string(inner.to_string())
        }
        continue
      }
    }
    // Check for [text](url)
    if escaped_pass[i] == '['.to_int().to_uint16() {
      let start_i = i
      i += 1
      let link_text = StringBuilder::new()
      let mut found_bracket = false
      while i < ep_len {
        if escaped_pass[i] == ']'.to_int().to_uint16() {
          found_bracket = true
          i += 1
          break
        }
        link_text.write_char(escaped_pass[i].to_int().unsafe_to_char())
        i += 1
      }
      if found_bracket &&
        i < ep_len &&
        escaped_pass[i] == '('.to_int().to_uint16() {
        i += 1
        let url_buf = StringBuilder::new()
        let mut found_paren = false
        while i < ep_len {
          if escaped_pass[i] == ')'.to_int().to_uint16() {
            found_paren = true
            i += 1
            break
          }
          url_buf.write_char(escaped_pass[i].to_int().unsafe_to_char())
          i += 1
        }
        if found_paren {
          let link_text_str = link_text.to_string()
          let url_str = url_buf.to_string()
          buf3.write_string("<a href=\"\{url_str}\">\{link_text_str}</a>")
        } else {
          buf3.write_char('[')
          buf3.write_string(link_text.to_string())
          buf3.write_string("](")
          buf3.write_string(url_buf.to_string())
        }
      } else {
        // Not a link, output as-is
        i = start_i + 1
        buf3.write_char('[')
      }
      continue
    }
    buf3.write_char(escaped_pass[i].to_int().unsafe_to_char())
    i += 1
  }
  let pass3 = buf3.to_string()
  // Pass 3: Restore placeholders
  let result = StringBuilder::new()
  let p3_len = pass3.length()
  i = 0
  while i < p3_len {
    if pass3[i] == '\u0000'.to_int().to_uint16() {
      i += 1
      // Read "PH{idx}"
      let idx_buf = StringBuilder::new()
      while i < p3_len && pass3[i] != '\u0000'.to_int().to_uint16() {
        idx_buf.write_char(pass3[i].to_int().unsafe_to_char())
        i += 1
      }
      if i < p3_len {
        i += 1 // skip closing \u0000
      }
      let idx_str = idx_buf.to_string()
      // Parse "PH{n}" to get index
      if idx_str.has_prefix("PH") {
        let num_str = idx_str[2:].to_string() catch { _ => "" }
        let idx = parse_placeholder_idx(num_str)
        if idx >= 0 && idx < placeholders.length() {
          result.write_string(placeholders[idx])
        }
      }
    } else {
      result.write_char(pass3[i].to_int().unsafe_to_char())
      i += 1
    }
  }
  result.to_string()
}

///|
/// Parse a placeholder index string to int.
fn parse_placeholder_idx(s : String) -> Int {
  let mut result = 0
  let mut valid = false
  for i = 0; i < s.length(); i = i + 1 {
    let ch = s[i].to_int()
    if ch >= 48 && ch <= 57 {
      result = result * 10 + (ch - 48)
      valid = true
    } else {
      return -1
    }
  }
  if valid {
    result
  } else {
    -1
  }
}

///|
/// Send a message to a Telegram chat with HTML formatting.
pub async fn TelegramChannel::send_message(
  self : TelegramChannel,
  chat_id : String,
  text : String,
) -> Unit {
  let escaped = markdown_to_html(text)
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
