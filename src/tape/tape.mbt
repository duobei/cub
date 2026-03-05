///|
/// Tape instance bound to a store.
pub struct Tape {
  name : String
  store : FileTapeStore
  compact_enabled : Bool
}

///|
/// Create a new Tape.
pub fn Tape::new(
  name : String,
  store : FileTapeStore,
  compact_enabled? : Bool = true,
) -> Tape {
  { name, store, compact_enabled }
}

///|
/// Read all entries from this tape.
pub async fn Tape::read_entries(self : Tape) -> Array[TapeEntry] {
  self.store.read(self.name)
}

///|
/// Read messages (entries converted to LLM message format).
pub async fn Tape::read_messages(self : Tape) -> Array[Json] {
  let entries = self.read_entries()
  select_messages(entries)
}

///|
/// Append an entry to this tape.
pub async fn Tape::append(self : Tape, entry : TapeEntry) -> Unit {
  self.store.append(self.name, entry)
}

///|
/// Perform a handoff: create an anchor, compact old entries, return current entries.
pub async fn Tape::handoff(
  self : Tape,
  name : String,
  state? : Map[String, Json]? = None,
) -> Array[TapeEntry] {
  // Record source entry range in state for citation
  let final_state = match state {
    Some(s) => {
      let entries = self.read_entries()
      if entries.length() > 0 {
        s["source_from_id"] = entries[0].id.to_json()
        s["source_to_id"] = entries[entries.length() - 1].id.to_json()
      }
      Some(s)
    }
    None => None
  }
  let anchor = TapeEntry::anchor(name, state=final_state)
  self.append(anchor)
  // Compact: discard entries before the last anchor to keep tape size bounded.
  // Skipped when compact_enabled is false (e.g. during fork — compact would
  // destroy the fork tape and break merge).
  if self.compact_enabled {
    ignore(self.store.compact(self.name))
  }
  self.read_entries()
}

///|
/// Compact this tape (discard entries before last anchor).
pub async fn Tape::compact(self : Tape) -> Int {
  self.store.compact(self.name)
}

///|
/// Reset this tape.
pub async fn Tape::reset(self : Tape) -> Unit {
  self.store.reset(self.name)
}
