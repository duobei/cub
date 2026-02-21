///|
/// Tape instance bound to a store.
pub struct Tape {
  name : String
  store : FileTapeStore
}

///|
/// Create a new Tape.
pub fn Tape::new(name : String, store : FileTapeStore) -> Tape {
  { name, store }
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
/// Perform a handoff: create an anchor and return entries after it.
pub async fn Tape::handoff(
  self : Tape,
  name : String,
  state? : Map[String, Json]? = None,
) -> Array[TapeEntry] {
  let anchor = TapeEntry::anchor(name, state~)
  self.append(anchor)
  self.read_entries()
}

///|
/// Reset this tape.
pub async fn Tape::reset(self : Tape) -> Unit {
  self.store.reset(self.name)
}
