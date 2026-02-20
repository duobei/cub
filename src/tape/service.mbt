/// High-level tape service (no fork/merge — handoff + anchors only).

pub struct TapeService {
  store : FileTapeStore
  current_tape_name : String
  base_tape_name : String
  done_requested : Bool
}

/// Create a new TapeService.
pub fn TapeService::new(tape_name : String, store : FileTapeStore) -> TapeService {
  {
    store,
    current_tape_name: tape_name,
    base_tape_name: tape_name,
    done_requested: false,
  }
}

/// Get the current tape.
pub fn TapeService::tape(self : TapeService) -> Tape {
  Tape::new(self.current_tape_name, self.store)
}

/// Ensure a bootstrap anchor exists.
pub async fn TapeService::ensure_bootstrap_anchor(self : TapeService) -> Unit {
  let entries = self.read_entries()
  let has_anchor = entries.iter().any(fn(e) { e.kind == "anchor" })
  if not(has_anchor) {
    let state : Map[String, Json] = {}
    state["owner"] = "human".to_json()
    ignore(self.handoff("session/start", state=Some(state)))
  }
}

/// Read all entries from the current tape.
pub async fn TapeService::read_entries(self : TapeService) -> Array[TapeEntry] {
  self.tape().read_entries()
}

/// Perform a handoff.
pub async fn TapeService::handoff(
  self : TapeService,
  name : String,
  state~ : Map[String, Json]? = None
) -> Array[TapeEntry] {
  self.tape().handoff(name, state~)
}

/// Append an event entry.
pub async fn TapeService::append_event(
  self : TapeService,
  name : String,
  data : Json
) -> Unit {
  self.tape().append(TapeEntry::event(name, data~))
}

/// Append a system message.
pub async fn TapeService::append_system(
  self : TapeService,
  content : String
) -> Unit {
  self.tape().append(TapeEntry::system(content))
}

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

/// Reset the tape, optionally archiving first.
pub async fn TapeService::reset(
  self : TapeService,
  archive~ : Bool = false
) -> String {
  let archive_path : String? = if archive {
    self.store.archive(self.base_tape_name)
  } else {
    None
  }
  self.tape().reset()
  let state : Map[String, Json] = {}
  state["owner"] = "human".to_json()
  match archive_path {
    Some(p) => state["archived"] = p.to_json()
    None => ()
  }
  ignore(self.handoff("session/start", state=Some(state)))
  match archive_path {
    Some(p) => "Archived: " + p
    None => "ok"
  }
}

/// Get anchors summary.
pub async fn TapeService::anchors(
  self : TapeService,
  limit~ : Int = 20
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
  for i = start; i < anchor_entries.length(); i = i + 1 {
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

/// Search tape entries by substring match.
pub async fn TapeService::search(
  self : TapeService,
  query : String,
  limit~ : Int = 20
) -> Array[TapeEntry] {
  let normalized = query.to_lower()
  if normalized.length() == 0 {
    return []
  }
  let entries = self.tape().read_entries()
  let results : Array[TapeEntry] = []
  let mut i = entries.length() - 1
  while i >= 0 && results.length() < limit {
    let entry = entries[i]
    let payload_text = entry.payload.stringify().to_lower()
    if payload_text.contains(normalized) {
      results.push(entry)
    }
    i -= 1
  }
  results
}
