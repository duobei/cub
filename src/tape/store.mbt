/// Persistent tape store implementation (JSONL-based, append-only).

/// Helper for one tape file.
pub struct TapeFile {
  path : String
  mut read_entries : Array[TapeEntry]
  mut read_offset : Int
}

/// Create a new TapeFile.
pub fn TapeFile::new(path : String) -> TapeFile {
  { path, read_entries: [], read_offset: 0 }
}

/// Get the next entry ID.
fn TapeFile::next_id(self : TapeFile) -> Int {
  if self.read_entries.length() > 0 {
    self.read_entries[self.read_entries.length() - 1].id + 1
  } else {
    1
  }
}

/// Reset internal state.
fn TapeFile::reset_state(self : TapeFile) -> Unit {
  self.read_entries = []
  self.read_offset = 0
}

/// Reset the tape file (delete and reset state).
pub async fn TapeFile::reset(self : TapeFile) -> Unit {
  try {
    @fs.remove(self.path)
  } catch {
    _ => ()
  }
  self.reset_state()
}

/// Read all entries from the JSONL file.
pub async fn TapeFile::read(self : TapeFile) -> Array[TapeEntry] {
  let content = try {
    @fs.read_file(self.path).text()
  } catch {
    _ => {
      self.reset_state()
      return []
    }
  }
  if content.length() == 0 {
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
    if trimmed.length() == 0 {
      continue
    }
    let parsed = try {
      @json.parse(trimmed.to_string())
    } catch {
      _ => continue
    }
    let entry : TapeEntry = try {
      @json.from_json(parsed)
    } catch {
      _ => continue
    }
    self.read_entries.push(entry)
  }
  self.read_offset = content.length()
  self.read_entries.copy()
}

/// Append a single entry.
pub async fn TapeFile::append(self : TapeFile, entry : TapeEntry) -> Unit {
  self.append_many([entry])
}

/// Append multiple entries with auto-incrementing IDs.
pub async fn TapeFile::append_many(self : TapeFile, entries : Array[TapeEntry]) -> Unit {
  if entries.length() == 0 {
    return
  }
  // Ensure we have current state
  let _ = self.read()
  let buf = StringBuilder::new()
  let mut next = self.next_id()
  for entry in entries {
    let stored : TapeEntry = {
      id: next,
      kind: entry.kind,
      payload: entry.payload,
      meta: entry.meta,
    }
    buf.write_string(stored.to_json().stringify())
    buf.write_char('\n')
    self.read_entries.push(stored)
    next += 1
  }
  let text = buf.to_string()
  try {
    // Append to file
    @fs.write_file(self.path, text, append=true)
  } catch {
    _ => ()
  }
  self.read_offset += text.length()
}

/// Archive the tape file with a .bak suffix.
pub async fn TapeFile::archive(self : TapeFile) -> String? {
  let content = try {
    @fs.read_file(self.path).text()
  } catch {
    _ => return None
  }
  if content.length() == 0 {
    return None
  }
  let archive_path = self.path + ".bak"
  try {
    @fs.write_file(archive_path, content)
  } catch {
    _ => return None
  }
  try {
    @fs.remove(self.path)
  } catch {
    _ => ()
  }
  Some(archive_path)
}

/// FNV-1a hash for workspace isolation.
pub fn fnv1a_hash(input : String) -> String {
  let mut hash : UInt64 = 14695981039346656037UL
  let prime : UInt64 = 1099511628211UL
  for ch in input {
    hash = hash.lxor(ch.to_uint().to_uint64())
    hash = hash * prime
  }
  let hex_chars = "0123456789abcdef"
  let buf = StringBuilder::new()
  for i = 0; i < 16; i = i + 1 {
    let shift = (15 - i) * 4
    let nibble = ((hash >> shift) & 0xFUL).to_int()
    buf.write_char(hex_chars[nibble].to_int().unsafe_to_char())
  }
  buf.to_string()
}

/// URL-encode a string for tape file names.
fn url_encode(s : String) -> String {
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

/// Append-only JSONL tape store.
pub struct FileTapeStore {
  home : String
  tape_root : String
  workspace_hash : String
  tape_files : Map[String, TapeFile]
}

/// Create a new FileTapeStore.
pub async fn FileTapeStore::new(
  home : String,
  workspace_path : String
) -> FileTapeStore {
  let workspace_hash = fnv1a_hash(workspace_path)
  let tape_root = home + "/tapes"
  try {
    @fs.mkdir(tape_root, permission=0o755, recursive=true)
  } catch {
    _ => ()
  }
  { home, tape_root, workspace_hash, tape_files: {} }
}

/// Get or create a TapeFile for a tape name.
fn FileTapeStore::tape_file(self : FileTapeStore, name : String) -> TapeFile {
  match self.tape_files.get(name) {
    Some(tf) => tf
    None => {
      let encoded = url_encode(name)
      let path = self.tape_root +
        "/" +
        self.workspace_hash +
        "__" +
        encoded +
        ".jsonl"
      let tf = TapeFile::new(path)
      self.tape_files[name] = tf
      tf
    }
  }
}

/// Reset a tape.
pub async fn FileTapeStore::reset(self : FileTapeStore, name : String) -> Unit {
  self.tape_file(name).reset()
}

/// Read entries from a tape.
pub async fn FileTapeStore::read(
  self : FileTapeStore,
  name : String
) -> Array[TapeEntry] {
  self.tape_file(name).read()
}

/// Append an entry to a tape.
pub async fn FileTapeStore::append(
  self : FileTapeStore,
  name : String,
  entry : TapeEntry
) -> Unit {
  self.tape_file(name).append(entry)
}

/// Archive a tape.
pub async fn FileTapeStore::archive(
  self : FileTapeStore,
  name : String
) -> String? {
  self.tape_file(name).archive()
}

/// List all known tape names.
pub fn FileTapeStore::list_tapes(self : FileTapeStore) -> Array[String] {
  let names : Array[String] = []
  for name, _ in self.tape_files {
    names.push(name)
  }
  names
}
