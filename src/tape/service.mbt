///|
/// High-level tape service with fork/merge for atomic writes.
pub struct TapeService {
  store : FileTapeStore
  mut current_tape_name : String
  base_tape_name : String
  done_requested : Bool
  mut fork_active : Bool
}

///|
/// Create a new TapeService.
pub fn TapeService::new(
  tape_name : String,
  store : FileTapeStore,
) -> TapeService {
  {
    store,
    current_tape_name: tape_name,
    base_tape_name: tape_name,
    done_requested: false,
    fork_active: false,
  }
}

///|
/// Get the current tape.
/// During fork, compact is disabled so handoff won't destroy the fork tape.
pub fn TapeService::tape(self : TapeService) -> Tape {
  Tape::new(
    self.current_tape_name,
    self.store,
    compact_enabled=not(self.fork_active),
  )
}

///|
/// Fork the tape for atomic writes. All subsequent writes go to the fork.
pub async fn TapeService::fork(self : TapeService) -> Unit {
  if self.fork_active {
    return
  }
  let fork_name = self.store.fork(self.base_tape_name)
  self.current_tape_name = fork_name
  self.fork_active = true
}

///|
/// Merge the fork back into the base tape. New entries are appended atomically.
pub async fn TapeService::merge(self : TapeService) -> Unit {
  if not(self.fork_active) {
    return
  }
  let fork_name = self.current_tape_name
  self.store.merge(fork_name, self.base_tape_name)
  self.current_tape_name = self.base_tape_name
  self.fork_active = false
}

///|
/// Discard the fork. The base tape remains unchanged.
pub async fn TapeService::discard_fork(self : TapeService) -> Unit {
  if not(self.fork_active) {
    return
  }
  let fork_name = self.current_tape_name
  self.store.delete_tape(fork_name)
  self.current_tape_name = self.base_tape_name
  self.fork_active = false
}

///|
/// Ensure a bootstrap anchor exists.
/// Uses direct append instead of handoff to avoid compact truncating old data.
pub async fn TapeService::ensure_bootstrap_anchor(self : TapeService) -> Unit {
  let entries = self.read_entries()
  let has_anchor = entries.iter().any(fn(e) { e.kind == "anchor" })
  if not(has_anchor) {
    let state : Map[String, Json] = {}
    state["owner"] = "human".to_json()
    self.tape().append(TapeEntry::anchor("session/start", state=Some(state)))
  }
}

///|
/// Read all entries from the current tape.
pub async fn TapeService::read_entries(self : TapeService) -> Array[TapeEntry] {
  self.tape().read_entries()
}

///|
/// Perform a handoff. Delegates to Tape::handoff which respects compact_enabled.
pub async fn TapeService::handoff(
  self : TapeService,
  name : String,
  state? : Map[String, Json]? = None,
) -> Array[TapeEntry] {
  self.tape().handoff(name, state~)
}

///|
/// Append an event entry.
pub async fn TapeService::append_event(
  self : TapeService,
  name : String,
  data : Json,
) -> Unit {
  self.tape().append(TapeEntry::event(name, data~))
}

///|
/// Append a system message.
pub async fn TapeService::append_system(
  self : TapeService,
  content : String,
) -> Unit {
  self.tape().append(TapeEntry::system(content))
}

///|
/// Get tape info summary.
pub async fn TapeService::info(self : TapeService) -> TapeInfo {
  let entries = self.tape().read_entries()
  let anchors : Array[TapeEntry] = []
  for e in entries {
    if e.kind == "anchor" {
      anchors.push(e)
    }
  }
  let last_anchor : String? = if anchors.length() > 0 {
    let last = anchors[anchors.length() - 1]
    match last.payload {
      { "name": String(n), .. } => Some(n)
      _ => None
    }
  } else {
    None
  }
  let entries_since = if anchors.length() > 0 {
    let last_id = anchors[anchors.length() - 1].id
    let mut count = 0
    for e in entries {
      if e.id > last_id {
        count += 1
      }
    }
    count
  } else {
    entries.length()
  }
  {
    name: self.current_tape_name,
    entries: entries.length(),
    anchors: anchors.length(),
    last_anchor,
    entries_since_last_anchor: entries_since,
  }
}

///|
/// Reset the tape, optionally archiving first.
/// Preserves a summary of the last few messages so the next session has context.
pub async fn TapeService::reset(
  self : TapeService,
  archive? : Bool = false,
) -> String {
  // Extract recent context before reset
  let recent_summary = extract_recent_summary(self.read_entries())
  let archive_path : String? = if archive {
    self.store.archive(self.base_tape_name)
  } else {
    None
  }
  self.tape().reset()
  let state : Map[String, Json] = {}
  state["owner"] = "human".to_json()
  if not(recent_summary.is_empty()) {
    state["context"] = recent_summary.to_json()
  }
  match archive_path {
    Some(p) => state["archived"] = p.to_json()
    None => ()
  }
  ignore(self.handoff("session/start", state=Some(state)))
  match archive_path {
    Some(p) => "Archived: \{p}"
    None => "ok"
  }
}

///|
/// Get anchors summary.
pub async fn TapeService::anchors(
  self : TapeService,
  limit? : Int = 20,
) -> Array[AnchorSummary] {
  let entries = self.tape().read_entries()
  let anchor_entries : Array[TapeEntry] = []
  for e in entries {
    if e.kind == "anchor" {
      anchor_entries.push(e)
    }
  }
  let results : Array[AnchorSummary] = []
  let start = if anchor_entries.length() > limit {
    anchor_entries.length() - limit
  } else {
    0
  }
  for i in start..<anchor_entries.length() {
    let e = anchor_entries[i]
    let name = match e.payload {
      { "name": String(n), .. } => n
      _ => "-"
    }
    let state : Map[String, Json] = match e.payload {
      { "state": Object(s), .. } => s
      _ => {}
    }
    results.push({ name, state })
  }
  results
}

///|
/// Read entries by ID range (inclusive).
pub async fn TapeService::read_range(
  self : TapeService,
  start_id : Int,
  end_id : Int,
) -> Array[TapeEntry] {
  let entries = self.tape().read_entries()
  entries.filter(fn(e) { e.id >= start_id && e.id <= end_id })
}

///|
/// Read entries after a named anchor (most recent match).
pub async fn TapeService::entries_since_anchor(
  self : TapeService,
  anchor_name : String,
) -> Array[TapeEntry] {
  let entries = self.tape().read_entries()
  let mut anchor_idx = -1
  for i in 0..<entries.length() {
    if entries[i].kind == "anchor" {
      match entries[i].payload {
        { "name": String(n), .. } => if n == anchor_name { anchor_idx = i }
        _ => ()
      }
    }
  }
  if anchor_idx < 0 {
    return []
  }
  let result : Array[TapeEntry] = []
  for i in (anchor_idx + 1)..<entries.length() {
    result.push(entries[i])
  }
  result
}

///|
/// Get detailed anchor info including summary, timestamp, and entry counts.
pub async fn TapeService::anchors_detailed(
  self : TapeService,
  limit? : Int = 20,
) -> Array[Json] {
  let entries = self.tape().read_entries()
  // Collect anchor indices
  let anchor_indices : Array[Int] = []
  for i in 0..<entries.length() {
    if entries[i].kind == "anchor" {
      anchor_indices.push(i)
    }
  }
  let start = if anchor_indices.length() > limit {
    anchor_indices.length() - limit
  } else {
    0
  }
  let results : Array[Json] = []
  for i in start..<anchor_indices.length() {
    let idx = anchor_indices[i]
    let e = entries[idx]
    let name = match e.payload {
      { "name": String(n), .. } => n
      _ => "-"
    }
    let summary = match e.payload {
      { "state": { "summary": String(s), .. }, .. } => s
      _ => ""
    }
    let task = match e.payload {
      { "state": { "task": String(t), .. }, .. } => t
      _ => ""
    }
    let ts = match e.meta {
      { "ts": Number(t, ..), .. } => t.to_int64()
      _ => 0L
    }
    // Count entries until next anchor or end
    let next_anchor_idx = if i + 1 < anchor_indices.length() {
      anchor_indices[i + 1]
    } else {
      entries.length()
    }
    let entry_count = next_anchor_idx - idx - 1
    let obj : Map[String, Json] = {}
    obj["id"] = e.id.to_json()
    obj["name"] = name.to_json()
    obj["ts"] = ts.to_json()
    obj["entries_after"] = entry_count.to_json()
    if summary.length() > 0 {
      obj["summary"] = summary.to_json()
    }
    if task.length() > 0 {
      obj["task"] = task.to_json()
    }
    results.push(Json::object(obj))
  }
  results
}

///|
/// Search tape entries by substring match (current tape only).
/// Optional kind filter and offset for pagination.
pub async fn TapeService::search(
  self : TapeService,
  query : String,
  limit? : Int = 20,
  kind? : String = "",
  offset? : Int = 0,
) -> Array[TapeEntry] {
  let normalized = ascii_to_lower(query)
  if normalized.is_empty() {
    return []
  }
  let entries = self.tape().read_entries()
  let results : Array[TapeEntry] = []
  let mut skipped = 0
  let mut i = entries.length() - 1
  while i >= 0 && results.length() < limit {
    let entry = entries[i]
    // Kind filter
    if kind.length() > 0 && entry.kind != kind {
      i -= 1
      continue
    }
    let payload_text = ascii_to_lower(entry.payload.stringify())
    if payload_text.contains(normalized) {
      if skipped < offset {
        skipped += 1
      } else {
        results.push(entry)
      }
    }
    i -= 1
  }
  results
}

///|
/// Search across all tapes in this workspace.
pub async fn TapeService::search_all(
  self : TapeService,
  query : String,
  limit? : Int = 20,
  kind? : String = "",
) -> Array[(String, TapeEntry)] {
  self.store.search_all(query, limit~, kind~)
}

///|
/// Extract a brief summary of recent user/assistant messages from tape entries.
/// Used to carry forward context across tape resets.
fn extract_recent_summary(entries : Array[TapeEntry]) -> String {
  let recent : Array[String] = []
  let max_msgs = 10
  // Walk backwards to find last N user/assistant messages
  let mut i = entries.length() - 1
  while i >= 0 && recent.length() < max_msgs {
    let entry = entries[i]
    if entry.kind == "message" {
      match entry.payload {
        { "role": String(role), "content": String(content), .. } =>
          if role == "user" || role == "assistant" {
            let truncated = if content.length() > 300 {
              content[:300].to_string() catch {
                _ => content
              }
            } else {
              content
            }
            recent.push("\{role}: \{truncated}")
          }
        _ => ()
      }
    }
    i -= 1
  }
  if recent.is_empty() {
    return ""
  }
  recent.rev().join("\n")
}
