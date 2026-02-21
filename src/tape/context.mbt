/// Tape context: convert tape entries to LLM chat messages.

/// Convert tape entries to chat messages for the LLM.
/// Only processes entries AFTER the last anchor (anchor-aware context selection).
/// If the last anchor has state, injects it as the first system message.
/// Handles orphan tool_calls (no matching tool_result) by buffering
/// the assistant message and only emitting it when a tool_result follows.
pub fn select_messages(entries : Array[TapeEntry]) -> Array[Json] {
  // Find the last anchor position
  let mut last_anchor_idx = -1
  let mut last_anchor_state : Json = Json::null()
  for i, entry in entries {
    if entry.kind == "anchor" {
      last_anchor_idx = i
      last_anchor_state = entry.payload
    }
  }
  let messages : Array[Json] = []
  // Inject anchor state as context if present
  let state_text = extract_anchor_context(last_anchor_state)
  if not(state_text.is_empty()) {
    let ctx_msg : Map[String, Json] = {}
    ctx_msg["role"] = "system".to_json()
    ctx_msg["content"] = "<handoff_context>\n\{state_text}\n</handoff_context>".to_json()
    messages.push(Json::object(ctx_msg))
  }
  // Process only entries after the last anchor
  let mut pending_calls : Array[Json] = []
  let mut pending_assistant_msg : Json? = None
  for i, entry in entries {
    if i <= last_anchor_idx {
      continue
    }
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

/// Extract human-readable context from anchor state payload.
pub fn extract_anchor_context(payload : Json) -> String {
  let parts : Array[String] = []
  match payload {
    { "state": Object(state), .. } => {
      // Extract meaningful state fields
      match state.get("summary") {
        Some(String(s)) => parts.push("Summary: \{s}")
        _ => ()
      }
      match state.get("context") {
        Some(String(c)) => parts.push("Context: \{c}")
        _ => ()
      }
      match state.get("next_steps") {
        Some(String(ns)) => parts.push("Next steps: \{ns}")
        _ => ()
      }
      match state.get("task") {
        Some(String(t)) => parts.push("Current task: \{t}")
        _ => ()
      }
    }
    _ => ()
  }
  parts.join("\n")
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

/// Normalize tool calls from a payload, skipping calls with invalid arguments.
fn normalize_tool_calls(payload : Json) -> Array[Json] {
  match payload {
    { "calls": Array(items), .. } => {
      let calls : Array[Json] = []
      for item in items {
        if validate_tool_call(item) {
          calls.push(item)
        }
      }
      calls
    }
    _ => []
  }
}

/// Validate a tool call JSON: must have id, function.name, and parseable arguments.
pub fn validate_tool_call(call : Json) -> Bool {
  match call {
    { "id": String(id), "function": { "name": String(name), "arguments": String(args), .. }, .. } => {
      if id.is_empty() || name.is_empty() {
        return false
      }
      // Arguments must be valid JSON
      let valid = try {
        ignore(@json.parse(args))
        true
      } catch {
        _ => false
      }
      valid
    }
    _ => false
  }
}

/// Max lines to keep in a tool result when it appears in history.
let tool_result_max_lines : Int = 80

/// Render a tool result to string, truncating if too long.
fn render_tool_result(result : Json) -> String {
  let text = match result {
    String(s) => s
    _ => result.stringify()
  }
  truncate_tool_output(text)
}

/// Truncate tool output to max lines, appending a note if truncated.
pub fn truncate_tool_output(text : String) -> String {
  let lines = text.split("\n")
  let mut count = 0
  for _line in lines {
    count += 1
  }
  if count <= tool_result_max_lines {
    return text
  }
  // Keep first N lines
  let kept : Array[String] = []
  let mut i = 0
  for line in text.split("\n") {
    if i >= tool_result_max_lines {
      break
    }
    kept.push(line.to_string())
    i += 1
  }
  let joined = kept.join("\n")
  "\{joined}\n[...truncated, \{count} lines total]"
}
