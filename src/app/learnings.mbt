/// Self-evolution system: learning extraction, persistence, decay, and skill crystallization.

///|
/// Read learnings from genome/pending.json (fallback: learnings.json).
pub async fn read_learnings(home : String) -> Array[Json] {
  let genome_path = "\{home}/genome/pending.json"
  let content = read_file_sync(genome_path)
  if not(content.is_empty()) {
    let parsed : Json = @json.parse(content) catch { _ => return [] }
    match parsed {
      Json::Array(arr) => return arr
      _ => return []
    }
  }
  // Fallback to legacy path
  let content = read_file_sync("\{home}/learnings.json")
  if content.is_empty() {
    return []
  }
  let parsed : Json = @json.parse(content) catch { _ => return [] }
  match parsed {
    Json::Array(arr) => arr
    _ => []
  }
}

///|
/// Render learnings as a prompt section for system prompt injection.
/// Only includes learnings with confidence >= 0.3, sorted by confidence desc.
pub async fn render_learnings(home : String) -> String {
  let learnings = read_learnings(home)
  if learnings.is_empty() {
    return ""
  }
  // Filter and sort by confidence
  let items : Array[(Double, String, String)] = []
  for entry in learnings {
    let confidence = match entry {
      { "confidence": Json::Number(c, ..), .. } => c
      _ => 0.0
    }
    if confidence < 0.3 {
      continue
    }
    let type_ = match entry {
      { "type": Json::String(t), .. } => t
      _ => "unknown"
    }
    let content = match entry {
      { "content": Json::String(c), .. } => c
      _ => continue
    }
    items.push((confidence, type_, content))
  }
  if items.is_empty() {
    return ""
  }
  // Sort by confidence descending
  items.sort_by(fn(a, b) { b.0.compare(a.0) })
  // Render
  let lines : Array[String] = ["# Learnings from past tasks"]
  for item in items {
    let tag = match item.1 {
      "anti_pattern" => "[avoid]"
      "heuristic" => "[effective]"
      "preference" => "[pattern]"
      _ => "[note]"
    }
    lines.push("- \{tag} \{item.2}")
  }
  lines.join("\n")
}

///|
/// Write learnings to genome/pending.json.
pub async fn write_learnings(home : String, learnings : Array[Json]) -> Bool {
  let path = "\{home}/genome/pending.json"
  let json_str = Json::array(learnings).stringify()
  write_file_sync(path, json_str)
}

///|
/// Check if two learning contents are similar (substring containment or word overlap).
pub fn learnings_similar(a : String, b : String) -> Bool {
  if a.is_empty() || b.is_empty() {
    return false
  }
  let a_lower = a.to_lower()
  let b_lower = b.to_lower()
  // Substring containment (only for strings longer than 10 chars)
  if a_lower.length() > 10 && b_lower.length() > 10 {
    if a_lower.contains(b_lower) || b_lower.contains(a_lower) {
      return true
    }
  }
  // Word overlap: Jaccard >= 0.6
  let a_words = split_words(a_lower)
  let b_words = split_words(b_lower)
  if a_words.is_empty() || b_words.is_empty() {
    return false
  }
  let mut intersection = 0
  for w in a_words {
    for bw in b_words {
      if w == bw {
        intersection += 1
        break
      }
    }
  }
  let union = a_words.length() + b_words.length() - intersection
  if union == 0 {
    return false
  }
  // Jaccard similarity >= 0.6
  intersection * 10 >= union * 6
}

///|
/// Split a string into words (simple whitespace + punctuation split).
fn split_words(s : String) -> Array[String] {
  let words : Array[String] = []
  let buf = StringBuilder::new()
  for ch in s {
    if ch == ' ' ||
      ch == ',' ||
      ch == '.' ||
      ch == ':' ||
      ch == ';' ||
      ch == '(' ||
      ch == ')' ||
      ch == '[' ||
      ch == ']' {
      let word = buf.to_string().trim().to_string()
      if not(word.is_empty()) {
        words.push(word)
      }
      buf.reset()
    } else {
      buf.write_char(ch)
    }
  }
  let last = buf.to_string().trim().to_string()
  if not(last.is_empty()) {
    words.push(last)
  }
  words
}

///|
/// Add a learning with dedup-as-reinforcement.
/// Returns the proposed skill name if a learning was reinforced enough for crystallization.
pub async fn add_learning(
  home : String,
  type_ : String,
  content : String,
  now_ms : Int64,
) -> String? {
  let learnings = read_learnings(home)
  // Check for similar existing learning
  for i, entry in learnings {
    match entry {
      {
        "content": Json::String(existing),
        "reinforced": Json::Number(r, ..),
        ..
      } =>
        if learnings_similar(content, existing) {
          // Reinforce: increment reinforced, update last_used
          let new_reinforced = r.to_int() + 1
          let updated : Map[String, Json] = {}
          updated["type"] = match entry {
            { "type": t, .. } => t
            _ => type_.to_json()
          }
          updated["content"] = existing.to_json()
          updated["confidence"] = match entry {
            { "confidence": c, .. } => c
            _ => 0.7.to_json()
          }
          updated["reinforced"] = new_reinforced.to_json()
          updated["last_used"] = now_ms.to_double().to_json()
          updated["created_at"] = match entry {
            { "created_at": c, .. } => c
            _ => now_ms.to_double().to_json()
          }
          learnings[i] = Json::object(updated)
          ignore(write_learnings(home, learnings))
          // Check if crystallization threshold reached
          if new_reinforced >= 3 {
            return Some(existing)
          }
          return None
        }
      _ => ()
    }
  }
  // New learning
  let entry : Map[String, Json] = {}
  entry["type"] = type_.to_json()
  entry["content"] = content.to_json()
  entry["confidence"] = 0.7.to_json()
  entry["reinforced"] = (1).to_json()
  entry["last_used"] = now_ms.to_double().to_json()
  entry["created_at"] = now_ms.to_double().to_json()
  learnings.push(Json::object(entry))
  ignore(write_learnings(home, learnings))
  None
}

///|
/// Decay learnings confidence based on time since last use.
/// Prunes entries with confidence < 0.1.
pub async fn decay_learnings(home : String, now_ms : Int64) -> Unit {
  let learnings = read_learnings(home)
  if learnings.is_empty() {
    return
  }
  let ms_per_week : Int64 = 7L * 24L * 60L * 60L * 1000L
  let surviving : Array[Json] = []
  for entry in learnings {
    match entry {
      {
        "confidence": Json::Number(conf, ..),
        "last_used": Json::Number(lu, ..),
        ..
      } => {
        let last_used_ms = lu.to_int64()
        let elapsed_ms = now_ms - last_used_ms
        let weeks = if elapsed_ms > 0L {
          (elapsed_ms / ms_per_week).to_int()
        } else {
          0
        }
        // Apply decay: confidence *= 0.905^weeks (approximation of e^(-0.1*weeks))
        let mut new_conf = conf
        for _ in 0..<weeks {
          new_conf = new_conf * 0.905
        }
        if new_conf >= 0.1 {
          let updated : Map[String, Json] = {}
          // Copy all fields, update confidence
          match entry {
            { "type": t, .. } => updated["type"] = t
            _ => ()
          }
          match entry {
            { "content": c, .. } => updated["content"] = c
            _ => ()
          }
          updated["confidence"] = new_conf.to_json()
          match entry {
            { "reinforced": r, .. } => updated["reinforced"] = r
            _ => ()
          }
          match entry {
            { "last_used": l, .. } => updated["last_used"] = l
            _ => ()
          }
          match entry {
            { "created_at": c, .. } => updated["created_at"] = c
            _ => ()
          }
          surviving.push(Json::object(updated))
        }
      }
      _ => surviving.push(entry)
    }
  }
  // Always write back — confidence values may have been updated even if no entries pruned
  ignore(write_learnings(home, surviving))
}

///|
/// Refine a raw learning into a structured skill description using an LLM.
/// Returns the refined content, or the original on failure.
pub async fn refine_learning_to_skill(
  llm : @llm.LLMClient,
  type_ : String,
  raw_content : String,
) -> String {
  let sys = "You are a skill writer. Convert the raw learning below into a structured skill instruction. Output ONLY the instruction with these sections: ## When to use, ## What to do, ## What to avoid. Keep it under 200 words. No preamble."
  let user_msg : Map[String, Json] = {}
  user_msg["role"] = "user".to_json()
  user_msg["content"] = "Type: \{type_}\nLearning: \{raw_content}".to_json()
  let resp = llm.chat(
    [Json::object(user_msg)],
    max_tokens=300,
    system_prompt=Some(sys),
  ) catch {
    _ => return raw_content
  }
  match resp.error {
    Some(_) => raw_content
    None => if resp.text.is_empty() { raw_content } else { resp.text }
  }
}

///|
/// Extract learnings from tape after task completion (zero-token, no LLM).
pub async fn extract_learnings_from_tape(
  entries : Array[@tape.TapeEntry],
  steps : Int,
  error : String?,
  home : String,
  now_ms : Int64,
  workspace? : String = "",
  llm? : @llm.LLMClient? = None,
) -> Unit {
  // Collect tool calls since last anchor
  let tool_names : Array[String] = []
  let mut last_anchor_idx = -1
  for i, entry in entries {
    if entry.kind == "anchor" {
      last_anchor_idx = i
    }
  }
  let start_idx = if last_anchor_idx >= 0 { last_anchor_idx + 1 } else { 0 }
  for i = start_idx; i < entries.length(); i = i + 1 {
    let entry = entries[i]
    if entry.kind == "tool_call" {
      match entry.payload {
        { "calls": Json::Array(calls), .. } =>
          for call in calls {
            match call {
              { "function": { "name": Json::String(n), .. }, .. } =>
                tool_names.push(n)
              _ => ()
            }
          }
        _ => ()
      }
    }
  }
  if tool_names.is_empty() {
    return
  }
  // Build optional refine callback from LLM
  let refine_fn : (async (String, String) -> String)? = match llm {
    Some(l) =>
      Some(async fn(type_ : String, raw : String) -> String {
        refine_learning_to_skill(l, type_, raw)
      })
    None => None
  }
  // Detect patterns
  match error {
    Some(err) => {
      // Task failed — record anti-pattern with truncated tool list
      let unique_tools : Array[String] = []
      for name in tool_names {
        if not(unique_tools.contains(name)) {
          unique_tools.push(name)
        }
      }
      let tools_display = if unique_tools.length() > 5 {
        let first5 = unique_tools[:5].to_array()
        first5.join(", ") + " (+\{unique_tools.length() - 5} more)"
      } else {
        unique_tools.join(", ")
      }
      // Truncate error message
      let err_short = if err.length() > 100 {
        let truncated = err[:100].to_string() catch { _ => err }
        truncated + "..."
      } else {
        err
      }
      let content = "Task failed after \{steps} steps using [\{tools_display}]: \{err_short}"
      match add_learning(home, "anti_pattern", content, now_ms) {
        Some(c) =>
          if not(workspace.is_empty()) {
            ignore(
              crystallize_skill(workspace, "anti_pattern", c, refine_fn~, home~),
            )
          }
        None => ()
      }
    }
    None => {
      // Task succeeded
      if steps <= 3 && tool_names.length() > 0 {
        // Efficient completion — deduplicate and cap at 5 unique tools
        let unique_tools : Array[String] = []
        for name in tool_names {
          if not(unique_tools.contains(name)) {
            unique_tools.push(name)
          }
        }
        let display = if unique_tools.length() > 5 {
          let first5 = unique_tools[:5].to_array()
          first5.join(", ") + " (+\{unique_tools.length() - 5} more)"
        } else {
          unique_tools.join(", ")
        }
        let content = "Efficient: completed in \{steps} steps via \{display}"
        match add_learning(home, "heuristic", content, now_ms) {
          Some(c) =>
            if not(workspace.is_empty()) {
              ignore(
                crystallize_skill(workspace, "heuristic", c, refine_fn~, home~),
              )
            }
          None => ()
        }
      }
      // Detect repeated consecutive tool usage (5+ same tool in a row)
      // Skip generic tools (bash, fs_read) — they're too common to be useful
      let generic_tools = ["bash", "fs_read", "fs.read", "grep"]
      let mut run_start = 0
      for i = 1; i <= tool_names.length(); i = i + 1 {
        if i == tool_names.length() || tool_names[i] != tool_names[run_start] {
          let run_len = i - run_start
          let tool = tool_names[run_start]
          if run_len >= 5 && not(generic_tools.contains(tool)) {
            let content = "Pattern: \{tool} called \{run_len} times consecutively"
            match add_learning(home, "preference", content, now_ms) {
              Some(c) =>
                if not(workspace.is_empty()) {
                  ignore(
                    crystallize_skill(
                      workspace,
                      "preference",
                      c,
                      refine_fn~,
                      home~,
                    ),
                  )
                }
              None => ()
            }
          }
          run_start = i
        }
      }
    }
  }
}

///|
/// Read skill stats from genome/skill_stats.json (fallback: skill_stats.json).
pub async fn read_skill_stats(home : String) -> Map[String, Json] {
  let genome_path = "\{home}/genome/skill_stats.json"
  let content = read_file_sync(genome_path)
  if not(content.is_empty()) {
    let parsed : Json = @json.parse(content) catch { _ => return {} }
    match parsed {
      Json::Object(obj) => return obj
      _ => return {}
    }
  }
  // Fallback to legacy path
  let content = read_file_sync("\{home}/skill_stats.json")
  if content.is_empty() {
    return {}
  }
  let parsed : Json = @json.parse(content) catch { _ => return {} }
  match parsed {
    Json::Object(obj) => obj
    _ => {}
  }
}

///|
/// Write skill stats to genome/skill_stats.json.
pub async fn write_skill_stats(
  home : String,
  stats : Map[String, Json],
) -> Bool {
  let path = "\{home}/genome/skill_stats.json"
  let json_str = Json::object(stats).stringify()
  write_file_sync(path, json_str)
}

///|
/// Update skill stats after a task completes.
/// Records usage count, success/failure, and average steps.
pub async fn update_skill_stats(
  home : String,
  expanded_skills : Map[String, String],
  steps : Int,
  error : String?,
) -> Unit {
  if expanded_skills.is_empty() {
    return
  }
  let stats = read_skill_stats(home)
  for name, _ in expanded_skills {
    let entry = match stats.get(name) {
      Some(Json::Object(obj)) => obj
      _ => {
        let m : Map[String, Json] = {}
        m["uses"] = (0).to_json()
        m["successes"] = (0).to_json()
        m["failures"] = (0).to_json()
        m["total_steps"] = (0).to_json()
        m
      }
    }
    // Increment counts
    let uses = match entry.get("uses") {
      Some(Json::Number(n, ..)) => n.to_int() + 1
      _ => 1
    }
    entry["uses"] = uses.to_json()
    match error {
      None => {
        let s = match entry.get("successes") {
          Some(Json::Number(n, ..)) => n.to_int() + 1
          _ => 1
        }
        entry["successes"] = s.to_json()
      }
      Some(_) => {
        let f = match entry.get("failures") {
          Some(Json::Number(n, ..)) => n.to_int() + 1
          _ => 1
        }
        entry["failures"] = f.to_json()
      }
    }
    let total = match entry.get("total_steps") {
      Some(Json::Number(n, ..)) => n.to_int() + steps
      _ => steps
    }
    entry["total_steps"] = total.to_json()
    stats[name] = Json::object(entry)
  }
  write_skill_stats(home, stats) |> ignore
}

///|
/// Generate a skill name from learning content.
pub fn skill_name_from_content(content : String) -> String {
  let words = split_words(content.to_lower())
  // Take up to 3 meaningful words, skip common ones
  let skip = [
    "the", "a", "an", "in", "via", "to", "is", "of", "and", "or", "for",
  ]
  let parts : Array[String] = []
  for word in words {
    if parts.length() >= 3 {
      break
    }
    if word.length() > 2 && not(skip.contains(word)) {
      parts.push(word)
    }
  }
  if parts.is_empty() {
    return "auto-skill"
  }
  let joined = parts.join("-")
  "auto-\{joined}"
}

///|
/// Crystallize a learning into a skill file.
/// Creates .agent/skills/auto-{name}/SKILL.md from a reinforced learning.
/// If refine_fn is provided, uses it to transform raw content into structured skill instructions.
pub async fn crystallize_skill(
  workspace : String,
  type_ : String,
  content : String,
  refine_fn? : (async (String, String) -> String)? = None,
  home? : String = "",
) -> String? {
  let name = skill_name_from_content(content)
  match @tools.sanitize_name(name) {
    None => return None
    Some(_) => ()
  }
  // Prefer genome/skills/ if home is provided, fallback to workspace/.agent/skills/
  let skill_dir = if home.is_empty() {
    "\{workspace}/.agent/skills/\{name}"
  } else {
    "\{home}/genome/skills/\{name}"
  }
  let skill_path = "\{skill_dir}/SKILL.md"
  // Don't overwrite existing skills
  let existing = read_file_sync(skill_path)
  if not(existing.is_empty()) {
    return None
  }
  let tag = match type_ {
    "anti_pattern" => "Avoid this pattern"
    "heuristic" => "Effective approach"
    "preference" => "Preferred pattern"
    _ => "Learned pattern"
  }
  // Optionally refine the content via LLM
  let refined = match refine_fn {
    Some(rfn) => {
      let result = rfn(type_, content) catch { _ => content }
      if result.is_empty() {
        content
      } else {
        result
      }
    }
    None => content
  }
  let body = "---\nname: \{name}\ndescription: \{tag} - crystallized from repeated experience\n---\n\n\{refined}\n\nThis skill was auto-crystallized from repeated task patterns.\n"
  if write_file_sync(skill_path, body) {
    Some(name)
  } else {
    None
  }
}
