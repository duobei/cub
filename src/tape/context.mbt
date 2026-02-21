/// Tape context: convert tape entries to LLM chat messages.

///|
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

///|
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

///|
/// Append a message entry directly as a chat message.
fn append_message_entry(messages : Array[Json], entry : TapeEntry) -> Unit {
  match entry.payload {
    Object(_) => messages.push(entry.payload)
    _ => ()
  }
}

///|
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

///|
/// Append tool_result entries, correlating with pending tool calls.
fn append_tool_result_entry(
  messages : Array[Json],
  pending_calls : Array[Json],
  entry : TapeEntry,
) -> Unit {
  let results = match entry.payload {
    { "results": Array(rs), .. } => rs
    _ => return
  }
  for index, result in results {
    messages.push(build_tool_result_message(result, pending_calls, index))
  }
}

///|
/// Build a single tool result message.
fn build_tool_result_message(
  result : Json,
  pending_calls : Array[Json],
  index : Int,
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

///|
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

///|
/// Validate a tool call JSON: must have id, function.name, and parseable arguments.
pub fn validate_tool_call(call : Json) -> Bool {
  match call {
    {
      "id": String(id),
      "function": { "name": String(name), "arguments": String(args), .. },
      ..
    } => {
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

///|
/// Max lines to keep in a tool result when it appears in history.
let tool_result_max_lines : Int = 80

///|
/// Render a tool result to string, truncating if too long.
fn render_tool_result(result : Json) -> String {
  let tool_name = match result {
    { "name": String(n), .. } => n
    _ => ""
  }
  let text = match result {
    { "content": String(s), .. } => s
    String(s) => s
    _ => result.stringify()
  }
  smart_truncate(text, tool_name)
}

///|
/// Smart truncation based on tool type and content.
pub fn smart_truncate(text : String, tool_name : String) -> String {
  let lines : Array[String] = []
  for line in text.split("\n") {
    lines.push(line.to_string())
  }
  let count = lines.length()
  if count <= tool_result_max_lines {
    return text
  }
  // Determine truncation strategy based on tool name
  let (head, tail) = if tool_name.contains("fs_read") ||
    tool_name.contains("fs.read") {
    // Code files: keep head + tail for context
    (40, 20)
  } else if tool_name.contains("bash") {
    // Logs/errors: errors usually at the end
    (10, 30)
  } else if tool_name.contains("grep") ||
    tool_name.contains("fs_list") ||
    tool_name.contains("fs.list") ||
    tool_name.contains("fs_glob") ||
    tool_name.contains("fs.glob") {
    // Search/listing results: keep more from the top
    (60, 10)
  } else {
    // Default: keep first N lines
    (tool_result_max_lines, 0)
  }
  if tail > 0 && count > head + tail {
    let head_lines : Array[String] = []
    for i = 0; i < head; i = i + 1 {
      head_lines.push(lines[i])
    }
    let tail_lines : Array[String] = []
    for i = count - tail; i < count; i = i + 1 {
      tail_lines.push(lines[i])
    }
    let omitted = count - head - tail
    let head_text = head_lines.join("\n")
    let tail_text = tail_lines.join("\n")
    "\{head_text}\n[...\{omitted} lines omitted...]\n\{tail_text}\n[\{count} lines total]"
  } else {
    let kept : Array[String] = []
    for i = 0; i < head && i < count; i = i + 1 {
      kept.push(lines[i])
    }
    let kept_text = kept.join("\n")
    "\{kept_text}\n[...truncated, \{count} lines total]"
  }
}
