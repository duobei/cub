/// Handoff summarization for the LLM module.

///|
/// Summarize chat messages into a compact handoff state.
pub fn summarize_messages_for_handoff(
  messages : Array[Json],
) -> Map[String, Json] {
  let state : Map[String, Json] = {}
  // Collect user task descriptions (first and last user messages)
  let user_msgs : Array[String] = []
  let tool_names : Array[String] = []
  let mut last_assistant = ""
  for msg in messages {
    match msg {
      { "role": String("user"), "content": String(c), .. } => user_msgs.push(c)
      { "role": String("assistant"), "content": String(c), .. } =>
        if c.length() > 0 {
          last_assistant = c
        }
      { "role": String("tool"), "name": String(n), .. } =>
        if not(tool_names.contains(n)) {
          tool_names.push(n)
        }
      _ => ()
    }
  }
  // Task: first user message (the original request)
  if user_msgs.length() > 0 {
    let task = user_msgs[0]
    let max_task = 500
    let task_text = if task.length() > max_task {
      "\{task[:max_task]}" catch {
        _ => task
      }
    } else {
      task
    }
    state["task"] = task_text.to_json()
  }
  // Summary: last assistant response (current state)
  if last_assistant.length() > 0 {
    let max_summary = 1000
    let summary = if last_assistant.length() > max_summary {
      "\{last_assistant[:max_summary]}" catch {
        _ => last_assistant
      }
    } else {
      last_assistant
    }
    state["summary"] = summary.to_json()
  }
  // Tools used
  if tool_names.length() > 0 {
    state["tools_used"] = tool_names.join(", ").to_json()
  }
  // Context: last user message if different from first
  if user_msgs.length() > 1 {
    let last_user = user_msgs[user_msgs.length() - 1]
    let max_ctx = 300
    let ctx = if last_user.length() > max_ctx {
      "\{last_user[:max_ctx]}" catch {
        _ => last_user
      }
    } else {
      last_user
    }
    state["context"] = ctx.to_json()
  }
  state
}

///|
/// Summarize chat messages for handoff using an LLM call.
/// Falls back to heuristic summarize_messages_for_handoff on failure.
pub async fn LLMClient::summarize_for_handoff(
  self : LLMClient,
  messages : Array[Json],
) -> Map[String, Json] {
  // Take last 20 messages, truncate each to 500 chars
  let start = if messages.length() > 20 { messages.length() - 20 } else { 0 }
  let buf = StringBuilder::new()
  for i = start; i < messages.length(); i = i + 1 {
    let msg = messages[i]
    let role = match msg {
      { "role": String(r), .. } => r
      _ => "unknown"
    }
    let content = match msg {
      { "content": String(c), .. } => c
      _ => continue
    }
    let truncated = if content.length() > 500 {
      content[:500].to_string() catch {
        _ => content
      }
    } else {
      content
    }
    buf.write_string(role)
    buf.write_string(": ")
    buf.write_string(truncated)
    buf.write_string("\n")
  }
  let sys =
    #|Summarize this conversation for handoff to a fresh context.
    #|Output ONLY valid JSON with these keys:
    #|{"task": "original user request", "summary": "what was accomplished", "decisions": "key decisions made", "pending": "what remains to do"}
    #|Be concise. No markdown, no explanation.
  let user_msg : Map[String, Json] = {}
  user_msg["role"] = "user".to_json()
  user_msg["content"] = buf.to_string().to_json()
  let resp = self.chat(
    [Json::object(user_msg)],
    max_tokens=500,
    system_prompt=Some(sys),
  ) catch {
    _ => return summarize_messages_for_handoff(messages)
  }
  match resp.error {
    Some(_) => return summarize_messages_for_handoff(messages)
    None => ()
  }
  if resp.text.is_empty() {
    return summarize_messages_for_handoff(messages)
  }
  // Parse the JSON response
  let json = @json.parse(resp.text) catch {
    _ => return summarize_messages_for_handoff(messages)
  }
  let state : Map[String, Json] = {}
  match json {
    { "task": String(t), .. } => state["task"] = t.to_json()
    _ => ()
  }
  match json {
    { "summary": String(s), .. } => state["summary"] = s.to_json()
    _ => ()
  }
  match json {
    { "decisions": String(d), .. } => state["context"] = d.to_json()
    _ => ()
  }
  match json {
    { "pending": String(p), .. } => state["next_steps"] = p.to_json()
    _ => ()
  }
  // If we got nothing useful, fall back
  if state.is_empty() {
    return summarize_messages_for_handoff(messages)
  }
  state
}
