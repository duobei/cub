/// Persistent tape store implementation (JSONL-based, append-only).

///|
/// Helper for one tape file.
pub struct TapeFile {
  path : String
  mut read_entries : Array[TapeEntry]
  mut read_offset : Int
}

///|
/// Create a new TapeFile.
pub fn TapeFile::new(path : String) -> TapeFile {
  { path, read_entries: [], read_offset: 0 }
}

///|
/// Get the next entry ID.
fn TapeFile::next_id(self : TapeFile) -> Int {
  if self.read_entries.length() > 0 {
    self.read_entries[self.read_entries.length() - 1].id + 1
  } else {
    1
  }
}

///|
/// Reset internal state.
fn TapeFile::reset_state(self : TapeFile) -> Unit {
  self.read_entries = []
  self.read_offset = 0
}

///|
/// Reset the tape file (delete and reset state).
pub async fn TapeFile::reset(self : TapeFile) -> Unit {
  @fs.remove(self.path) catch {
    _ => ()
  }
  self.reset_state()
}

///|
/// Read all entries from the JSONL file.
pub async fn TapeFile::read(self : TapeFile) -> Array[TapeEntry] {
  let content = @fs.read_file(self.path).text() catch {
    _ => {
      self.reset_state()
      return []
    }
  }
  if content.is_empty() {
    self.reset_state()
    return []
  }
  // Only parse new content past read_offset
  let lines = content.split("\n")
  let mut line_offset = 0
  let mut char_offset = 0
  for line in lines {
    if char_offset >= self.read_offset {
      break
    }
    char_offset += line.length() + 1 // +1 for newline
    line_offset += 1
  }
  let mut idx = 0
  for line in lines {
    if idx < line_offset {
      idx += 1
      continue
    }
    idx += 1
    let trimmed = line.trim(chars=" \t\r")
    if trimmed.is_empty() {
      continue
    }
    let parsed = @json.parse(trimmed.to_string()) catch { _ => continue }
    let entry : TapeEntry = @json.from_json(parsed) catch { _ => continue }
    self.read_entries.push(entry)
  }
  self.read_offset = content.length()
  self.read_entries.copy()
}

///|
/// Append a single entry.
pub async fn TapeFile::append(self : TapeFile, entry : TapeEntry) -> Unit {
  self.append_many([entry])
}

///|
/// Append multiple entries with auto-incrementing IDs.
pub async fn TapeFile::append_many(
  self : TapeFile,
  entries : Array[TapeEntry],
) -> Unit {
  if entries.is_empty() {
    return
  }
  // Ensure we have current state
  let _ = self.read()
  let buf = StringBuilder::new()
  let mut next = self.next_id()
  let now = @async.now()
  for entry in entries {
    // Inject timestamp into meta
    let meta = match entry.meta {
      Object(m) => {
        m["ts"] = now.to_json()
        Json::object(m)
      }
      _ => {
        let m : Map[String, Json] = {}
        m["ts"] = now.to_json()
        Json::object(m)
      }
    }
    let stored : TapeEntry = {
      id: next,
      kind: entry.kind,
      payload: entry.payload,
      meta,
    }
    buf.write_string(stored.to_json().stringify())
    buf.write_char('\n')
    self.read_entries.push(stored)
    next += 1
  }
  let text = buf.to_string()
  @fs.write_file(self.path, text, append=true, create=0o644, truncate=false) catch {
    _ => ()
  }
  self.read_offset += text.length()
}

///|
/// Compact the tape file: keep only the last anchor and entries after it.
/// Returns the number of entries removed, or 0 if no compaction needed.
pub async fn TapeFile::compact(self : TapeFile) -> Int {
  let entries = self.read()
  if entries.length() <= 1 {
    return 0
  }
  // Find last anchor
  let mut last_anchor_idx = -1
  for i in 0..<entries.length() {
    if entries[i].kind == "anchor" {
      last_anchor_idx = i
    }
  }
  // No anchor or anchor is first entry — nothing to compact
  if last_anchor_idx <= 0 {
    return 0
  }
  // Keep entries from last anchor onward
  let kept : Array[TapeEntry] = []
  for i in last_anchor_idx..<entries.length() {
    kept.push(entries[i])
  }
  let removed = entries.length() - kept.length()
  if removed == 0 {
    return 0
  }
  // Rewrite the file with kept entries (re-numbered from 1)
  let buf = StringBuilder::new()
  let mut next_id = 1
  for entry in kept {
    let renumbered : TapeEntry = {
      id: next_id,
      kind: entry.kind,
      payload: entry.payload,
      meta: entry.meta,
    }
    buf.write_string(renumbered.to_json().stringify())
    buf.write_char('\n')
    next_id += 1
  }
  @fs.write_file(self.path, buf.to_string(), create=0o644) catch {
    _ => return 0
  }
  // Reset internal state so next read picks up the new file
  self.reset_state()
  removed
}

///|
/// Archive the tape file with a .bak suffix.
pub async fn TapeFile::archive(self : TapeFile) -> String? {
  let content = @fs.read_file(self.path).text() catch { _ => return None }
  if content.is_empty() {
    return None
  }
  let archive_path = "\{self.path}.bak"
  @fs.write_file(archive_path, content, create=0o644) catch {
    _ => return None
  }
  // Verify archive was written before removing original
  let verify = @fs.read_file(archive_path).text() catch { _ => return None }
  if verify.length() != content.length() {
    return None
  }
  @fs.remove(self.path) catch {
    _ => ()
  }
  Some(archive_path)
}

///|
/// FNV-1a hash for workspace isolation.
pub fn fnv1a_hash(input : String) -> String {
  let mut hash : UInt64 = 14695981039346656037UL
  let prime : UInt64 = 1099511628211UL
  for ch in input {
    hash = hash ^ ch.to_uint().to_uint64()
    hash = hash * prime
  }
  let hex_chars = "0123456789abcdef"
  let buf = StringBuilder::new()
  for i in 0..<16 {
    let shift = (15 - i) * 4
    let nibble = ((hash >> shift) & 0xFUL).to_int()
    buf.write_char(hex_chars[nibble].to_int().unsafe_to_char())
  }
  buf.to_string()
}

///|
/// URL-encode a string for tape file names.
pub fn url_encode(s : String) -> String {
  let buf = StringBuilder::new()
  for ch in s {
    if (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '-' ||
      ch == '_' ||
      ch == '.' {
      buf.write_char(ch)
    } else {
      let code = ch.to_int()
      let hex = "0123456789ABCDEF"
      buf.write_char('%')
      buf.write_char(hex[code / 16].to_int().unsafe_to_char())
      buf.write_char(hex[code % 16].to_int().unsafe_to_char())
    }
  }
  buf.to_string()
}

///|
/// Append-only JSONL tape store.
pub struct FileTapeStore {
  home : String
  tape_root : String
  workspace_hash : String
  tape_files : Map[String, TapeFile]
}

///|
/// Create a new FileTapeStore. Scans disk for existing tape files.
pub async fn FileTapeStore::new(
  home : String,
  workspace_path : String,
) -> FileTapeStore {
  let workspace_hash = fnv1a_hash(workspace_path)
  let tape_root = "\{home}/tapes"
  @fs.mkdir(tape_root, permission=0o755, recursive=true) catch {
    _ => ()
  }
  let store : FileTapeStore = {
    home,
    tape_root,
    workspace_hash,
    tape_files: {},
  }
  store.scan_existing()
  store
}

///|
/// Scan the tape directory for existing .jsonl files matching this workspace.
/// Registers them in the in-memory map so they are discoverable.
async fn FileTapeStore::scan_existing(self : FileTapeStore) -> Unit {
  let entries = @fs.readdir(self.tape_root) catch { _ => return }
  let prefix = "\{self.workspace_hash}__"
  let suffix = ".jsonl"
  for entry in entries {
    if not(entry.has_prefix(prefix)) || not(entry.has_suffix(suffix)) {
      continue
    }
    // Skip .bak archives
    if entry.has_suffix(".jsonl.bak") {
      continue
    }
    // Extract encoded tape name: {hash}__{encoded}.jsonl
    let encoded = entry[prefix.length():entry.length() - suffix.length()].to_string() catch {
      _ => continue
    }
    let name = url_decode(encoded)
    if not(self.tape_files.contains(name)) {
      let path = "\{self.tape_root}/\{entry}"
      self.tape_files[name] = TapeFile::new(path)
    }
  }
}

///|
/// Simple URL percent-decode.
pub fn url_decode(s : String) -> String {
  let buf = StringBuilder::new()
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '%' && i + 2 < chars.length() {
      let hi = hex_val(chars[i + 1])
      let lo = hex_val(chars[i + 2])
      if hi >= 0 && lo >= 0 {
        buf.write_char((hi * 16 + lo).unsafe_to_char())
        i += 3
        continue
      }
    }
    buf.write_char(chars[i])
    i += 1
  }
  buf.to_string()
}

///|
/// Parse a single hex digit character to its value, or -1.
fn hex_val(ch : Char) -> Int {
  if ch >= '0' && ch <= '9' {
    ch.to_int() - '0'.to_int()
  } else if ch >= 'a' && ch <= 'f' {
    ch.to_int() - 'a'.to_int() + 10
  } else if ch >= 'A' && ch <= 'F' {
    ch.to_int() - 'A'.to_int() + 10
  } else {
    -1
  }
}

///|
/// Get or create a TapeFile for a tape name.
fn FileTapeStore::tape_file(self : FileTapeStore, name : String) -> TapeFile {
  match self.tape_files.get(name) {
    Some(tf) => tf
    None => {
      let encoded = url_encode(name)
      let path = "\{self.tape_root}/\{self.workspace_hash}__\{encoded}.jsonl"
      let tf = TapeFile::new(path)
      self.tape_files[name] = tf
      tf
    }
  }
}

///|
/// Reset a tape.
pub async fn FileTapeStore::reset(self : FileTapeStore, name : String) -> Unit {
  self.tape_file(name).reset()
}

///|
/// Read entries from a tape.
pub async fn FileTapeStore::read(
  self : FileTapeStore,
  name : String,
) -> Array[TapeEntry] {
  self.tape_file(name).read()
}

///|
/// Append an entry to a tape.
pub async fn FileTapeStore::append(
  self : FileTapeStore,
  name : String,
  entry : TapeEntry,
) -> Unit {
  self.tape_file(name).append(entry)
}

///|
/// Archive a tape.
pub async fn FileTapeStore::archive(
  self : FileTapeStore,
  name : String,
) -> String? {
  self.tape_file(name).archive()
}

///|
/// Compact a tape (discard entries before last anchor).
pub async fn FileTapeStore::compact(self : FileTapeStore, name : String) -> Int {
  self.tape_file(name).compact()
}

///|
/// List all known tape names.
pub fn FileTapeStore::list_tapes(self : FileTapeStore) -> Array[String] {
  let names : Array[String] = []
  for name, _ in self.tape_files {
    names.push(name)
  }
  names
}

///|
/// Search across all known tapes by substring match.
/// Returns (tape_name, entry) pairs, most recent first.
pub async fn FileTapeStore::search_all(
  self : FileTapeStore,
  query : String,
  limit? : Int = 20,
) -> Array[(String, TapeEntry)] {
  let normalized = query.to_lower()
  if normalized.is_empty() {
    return []
  }
  let results : Array[(String, TapeEntry)] = []
  for name, tf in self.tape_files {
    if results.length() >= limit {
      break
    }
    let entries = tf.read()
    let mut i = entries.length() - 1
    while i >= 0 && results.length() < limit {
      let payload_text = entries[i].payload.stringify().to_lower()
      if payload_text.contains(normalized) {
        results.push((name, entries[i]))
      }
      i -= 1
    }
  }
  results
}
