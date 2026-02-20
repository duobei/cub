/// Tape context: convert tape entries to LLM chat messages.

/// Convert tape entries to chat messages for the LLM.
/// Handles orphan tool_calls (no matching tool_result) by buffering
/// the assistant message and only emitting it when a tool_result follows.
pub fn select_messages(entries : Array[TapeEntry]) -> Array[Json] {
  let messages : Array[Json] = []
  let mut pending_calls : Array[Json] = []
  let mut pending_assistant_msg : Json? = None
  for entry in entries {
    if entry.kind == "message" {
      // If there's a buffered tool_call without a result, drop it
      if pending_assistant_msg is Some(_) {
        pending_assistant_msg = None
        pending_calls = []
      }
      append_message_entry(messages, entry)
      continue
    }
    if entry.kind == "tool_call" {
      // If there's already a buffered tool_call without a result, drop it
      if pending_assistant_msg is Some(_) {
        pending_assistant_msg = None
      }
      // Buffer the assistant message instead of emitting immediately
      let (msg, calls) = build_tool_call_message(entry)
      pending_calls = calls
      pending_assistant_msg = msg
      continue
    }
    if entry.kind == "tool_result" {
      // Emit the buffered assistant message now that we have the result
      match pending_assistant_msg {
        Some(msg) => messages.push(msg)
        None => ()
      }
      pending_assistant_msg = None
      append_tool_result_entry(messages, pending_calls, entry)
      pending_calls = []
      continue
    }
    // event, anchor → skip
  }
  // If there's a trailing orphan tool_call, drop it
  messages
}

/// Append a message entry directly as a chat message.
fn append_message_entry(messages : Array[Json], entry : TapeEntry) -> Unit {
  match entry.payload {
    Object(_) => messages.push(entry.payload)
    _ => ()
  }
}

/// Build a tool_call assistant message (without appending).
/// Returns (message_json, normalized_calls).
fn build_tool_call_message(entry : TapeEntry) -> (Json?, Array[Json]) {
  let calls = normalize_tool_calls(entry.payload)
  if calls.length() > 0 {
    let msg : Map[String, Json] = {}
    msg["role"] = "assistant".to_json()
    msg["content"] = "".to_json()
    msg["tool_calls"] = Json::array(calls.copy())
    (Some(Json::object(msg)), calls)
  } else {
    (None, calls)
  }
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
