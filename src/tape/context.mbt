/// Tape context: convert tape entries to LLM chat messages.

/// Convert tape entries to chat messages for the LLM.
pub fn select_messages(entries : Array[TapeEntry]) -> Array[Json] {
  let messages : Array[Json] = []
  let mut pending_calls : Array[Json] = []
  for entry in entries {
    if entry.kind == "message" {
      append_message_entry(messages, entry)
      continue
    }
    if entry.kind == "tool_call" {
      pending_calls = append_tool_call_entry(messages, entry)
      continue
    }
    if entry.kind == "tool_result" {
      append_tool_result_entry(messages, pending_calls, entry)
      pending_calls = []
      continue
    }
    // event, anchor → skip
  }
  messages
}

/// Append a message entry directly as a chat message.
fn append_message_entry(messages : Array[Json], entry : TapeEntry) -> Unit {
  match entry.payload {
    Object(_) => messages.push(entry.payload)
    _ => ()
  }
}

/// Append a tool_call entry as an assistant message with tool_calls.
fn append_tool_call_entry(
  messages : Array[Json],
  entry : TapeEntry
) -> Array[Json] {
  let calls = normalize_tool_calls(entry.payload)
  if calls.length() > 0 {
    let msg : Map[String, Json] = {}
    msg["role"] = "assistant".to_json()
    msg["content"] = "".to_json()
    msg["tool_calls"] = Json::array(calls.copy())
    messages.push(Json::object(msg))
  }
  calls
}

/// Append tool_result entries, correlating with pending tool calls.
fn append_tool_result_entry(
  messages : Array[Json],
  pending_calls : Array[Json],
  entry : TapeEntry
) -> Unit {
  let results = match entry.payload {
    { "results": Array(rs), .. } => rs
    _ => return
  }
  for index, result in results {
    messages.push(build_tool_result_message(result, pending_calls, index))
  }
}

/// Build a single tool result message.
fn build_tool_result_message(
  result : Json,
  pending_calls : Array[Json],
  index : Int
) -> Json {
  let msg : Map[String, Json] = {}
  msg["role"] = "tool".to_json()
  msg["content"] = render_tool_result(result).to_json()
  if index < pending_calls.length() {
    let call = pending_calls[index]
    match call {
      { "id": String(call_id), .. } =>
        if call_id.length() > 0 {
          msg["tool_call_id"] = call_id.to_json()
        }
      _ => ()
    }
    match call {
      { "function": { "name": String(name), .. }, .. } =>
        if name.length() > 0 {
          msg["name"] = name.to_json()
        }
      _ => ()
    }
  }
  Json::object(msg)
}

/// Normalize tool calls from a payload.
fn normalize_tool_calls(payload : Json) -> Array[Json] {
  match payload {
    { "calls": Array(items), .. } => {
      let calls : Array[Json] = []
      for item in items {
        match item {
          Object(_) => calls.push(item)
          _ => ()
        }
      }
      calls
    }
    _ => []
  }
}

/// Render a tool result to string.
fn render_tool_result(result : Json) -> String {
  match result {
    String(s) => s
    _ => result.stringify()
  }
}
