/// Cost tracking: persistent token usage accounting per session.

///|
/// Read cost balance from genome/cost.json.
pub async fn read_cost(home : String) -> Json {
  let content = read_file("\{home}/genome/cost.json")
  if content.is_empty() {
    let empty : Map[String, Json] = {}
    empty["total_prompt_tokens"] = (0).to_json()
    empty["total_completion_tokens"] = (0).to_json()
    empty["total_requests"] = (0).to_json()
    empty["sessions"] = Json::object({})
    return Json::object(empty)
  }
  @json.parse(content) catch {
    _ => {
      let empty : Map[String, Json] = {}
      empty["total_prompt_tokens"] = (0).to_json()
      empty["total_completion_tokens"] = (0).to_json()
      empty["total_requests"] = (0).to_json()
      empty["sessions"] = Json::object({})
      Json::object(empty)
    }
  }
}

///|
/// Record token usage from an API call.
pub async fn record_usage(
  home : String,
  session_id : String,
  prompt_tokens : Int,
  completion_tokens : Int,
) -> Unit {
  let cost = read_cost(home)
  // Update totals
  let total_pt = match cost {
    { "total_prompt_tokens": Number(n, ..), .. } => n.to_int() + prompt_tokens
    _ => prompt_tokens
  }
  let total_ct = match cost {
    { "total_completion_tokens": Number(n, ..), .. } =>
      n.to_int() + completion_tokens
    _ => completion_tokens
  }
  let total_req = match cost {
    { "total_requests": Number(n, ..), .. } => n.to_int() + 1
    _ => 1
  }
  // Update session
  let sessions : Map[String, Json] = match cost {
    { "sessions": Object(s), .. } => s
    _ => {}
  }
  let session_entry : Map[String, Json] = match sessions.get(session_id) {
    Some(Object(obj)) => obj
    _ => {
      let m : Map[String, Json] = {}
      m["prompt_tokens"] = (0).to_json()
      m["completion_tokens"] = (0).to_json()
      m["requests"] = (0).to_json()
      m
    }
  }
  let s_pt = match session_entry.get("prompt_tokens") {
    Some(Number(n, ..)) => n.to_int() + prompt_tokens
    _ => prompt_tokens
  }
  let s_ct = match session_entry.get("completion_tokens") {
    Some(Number(n, ..)) => n.to_int() + completion_tokens
    _ => completion_tokens
  }
  let s_req = match session_entry.get("requests") {
    Some(Number(n, ..)) => n.to_int() + 1
    _ => 1
  }
  session_entry["prompt_tokens"] = s_pt.to_json()
  session_entry["completion_tokens"] = s_ct.to_json()
  session_entry["requests"] = s_req.to_json()
  session_entry["total_tokens"] = (s_pt + s_ct).to_json()
  sessions[session_id] = Json::object(session_entry)
  // Write back
  let result : Map[String, Json] = {}
  result["total_prompt_tokens"] = total_pt.to_json()
  result["total_completion_tokens"] = total_ct.to_json()
  result["total_tokens"] = (total_pt + total_ct).to_json()
  result["total_requests"] = total_req.to_json()
  result["sessions"] = Json::object(sessions)
  // Keep only last 50 sessions to avoid unbounded growth
  if sessions.length() > 50 {
    let keys : Array[String] = []
    for k, _ in sessions {
      keys.push(k)
    }
    // Remove oldest (first in iteration order)
    let to_remove = keys.length() - 50
    for i in 0..<to_remove {
      sessions.remove(keys[i])
    }
  }
  ignore(
    write_file("\{home}/genome/cost.json", Json::object(result).stringify()),
  )
}

///|
/// Format cost balance as a human-readable string.
pub async fn format_balance(home : String) -> String {
  let cost = read_cost(home)
  let total_pt = match cost {
    { "total_prompt_tokens": Number(n, ..), .. } => n.to_int()
    _ => 0
  }
  let total_ct = match cost {
    { "total_completion_tokens": Number(n, ..), .. } => n.to_int()
    _ => 0
  }
  let total_req = match cost {
    { "total_requests": Number(n, ..), .. } => n.to_int()
    _ => 0
  }
  let total = total_pt + total_ct
  let buf = StringBuilder::new()
  buf.write_string("# Cost Balance\n\n")
  buf.write_string("| Metric | Value |\n|--------|-------|\n")
  buf.write_string("| Total requests | \{total_req} |\n")
  buf.write_string("| Prompt tokens | \{total_pt} |\n")
  buf.write_string("| Completion tokens | \{total_ct} |\n")
  buf.write_string("| Total tokens | \{total} |\n")
  buf.to_string()
}
