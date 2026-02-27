/// Genome directory management: manifest read/write, migration, export/import.

///|
/// FNV-1a hash for generating unique IDs.
fn fnv1a_hash(input : String) -> String {
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
/// Format milliseconds since epoch as ISO 8601 string (simplified UTC).
pub fn format_iso8601(ms : Int64) -> String {
  let secs = ms / 1000L
  let mut days = secs / 86400L
  let day_secs = secs % 86400L
  let hour = day_secs / 3600L
  let minute = day_secs % 3600L / 60L
  let second = day_secs % 60L
  let mut year = 1970L
  while true {
    let leap = if year % 4L == 0L && (year % 100L != 0L || year % 400L == 0L) {
      1L
    } else {
      0L
    }
    let year_days = 365L + leap
    if days < year_days {
      break
    }
    days = days - year_days
    year = year + 1L
  }
  let leap = if year % 4L == 0L && (year % 100L != 0L || year % 400L == 0L) {
    1
  } else {
    0
  }
  let month_days = [31, 28 + leap, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  let mut month = 1L
  for md in month_days {
    if days < md.to_int64() {
      break
    }
    days = days - md.to_int64()
    month = month + 1L
  }
  let day = days + 1L
  let pad2 = fn(n : Int64) -> String { if n < 10L { "0\{n}" } else { "\{n}" } }
  "\{year}-\{pad2(month)}-\{pad2(day)}T\{pad2(hour)}:\{pad2(minute)}:\{pad2(second)}Z"
}

///|
/// Read file content, returns empty string on failure.
async fn read_file(path : String) -> String {
  @platform.read_file_text(path) catch {
    _ => ""
  }
}

///|
/// Write file content, creating parent dirs. Returns true on success.
async fn write_file(path : String, content : String) -> Bool {
  // Create parent directory
  let mut last_slash = -1
  for i, ch in path {
    if ch == '/' {
      last_slash = i
    }
  }
  if last_slash > 0 {
    let parent = path[:last_slash].to_string() catch { _ => "" }
    if not(parent.is_empty()) {
      @platform.mkdir(parent, permission=0o755, recursive=true) catch {
        _ => ()
      }
    }
  }
  @platform.write_file(path, content, create=0o644) catch {
    _ => return false
  }
  true
}

///|
/// List directory entries, returns empty on failure.
async fn list_dir(path : String) -> Array[String] {
  @platform.readdir(path) catch {
    _ => []
  }
}

///|
/// Generate a new manifest ID from workspace and current time.
pub fn generate_id(workspace : String, now_ms : Int64) -> String {
  fnv1a_hash("\{workspace}:\{now_ms}")
}

///|
/// Ensure genome directory structure exists under home.
pub async fn ensure_genome_dir(home : String) -> Unit {
  let genome = "\{home}/genome"
  @platform.mkdir(genome, permission=0o755, recursive=true) catch {
    _ => ()
  }
  let skills = "\{genome}/skills"
  @platform.mkdir(skills, permission=0o755, recursive=true) catch {
    _ => ()
  }
}

///|
/// Read manifest from {home}/genome/manifest.json.
/// Returns None if file doesn't exist or is invalid.
pub async fn read_manifest(home : String) -> Manifest? {
  let content = read_file("\{home}/genome/manifest.json")
  if content.is_empty() {
    return None
  }
  let json : Json = @json.parse(content) catch { _ => return None }
  Manifest::from_json(json)
}

///|
/// Write manifest to {home}/genome/manifest.json.
pub async fn write_manifest(home : String, manifest : Manifest) -> Bool {
  write_file("\{home}/genome/manifest.json", manifest.to_json().stringify())
}

///|
/// Migrate existing cub data into genome/ directory.
/// Idempotent: only runs if manifest.json doesn't exist yet.
/// - {home}/learnings.json → {home}/genome/pending.json
/// - {home}/skill_stats.json → {home}/genome/skill_stats.json
/// - {workspace}/AGENTS.md → {home}/genome/identity.md
/// - {workspace}/.agent/skills/ → {home}/genome/skills/ (copies SKILL.md files)
pub async fn migrate_to_genome(home : String, workspace : String) -> Manifest? {
  // Check if already migrated
  let existing = read_manifest(home)
  match existing {
    Some(_) => return existing
    None => ()
  }
  // Ensure directory exists
  ensure_genome_dir(home)
  // Migrate learnings.json → genome/pending.json
  let learnings_content = read_file("\{home}/learnings.json")
  if not(learnings_content.is_empty()) {
    ignore(write_file("\{home}/genome/pending.json", learnings_content))
  }
  // Migrate skill_stats.json → genome/skill_stats.json
  let stats_content = read_file("\{home}/skill_stats.json")
  if not(stats_content.is_empty()) {
    ignore(write_file("\{home}/genome/skill_stats.json", stats_content))
  }
  // Migrate AGENTS.md → genome/identity.md
  let agents_content = read_file("\{workspace}/AGENTS.md")
  if not(agents_content.is_empty()) {
    ignore(write_file("\{home}/genome/identity.md", agents_content))
  }
  // Migrate workspace skills → genome/skills/
  let ws_skills_dir = "\{workspace}/.agent/skills"
  let entries = list_dir(ws_skills_dir)
  for entry in entries {
    let skill_content = read_file("\{ws_skills_dir}/\{entry}/SKILL.md")
    if not(skill_content.is_empty()) {
      ignore(
        write_file("\{home}/genome/skills/\{entry}/SKILL.md", skill_content),
      )
    }
  }
  // Generate manifest
  let now_ms = @async.now()
  let id = generate_id(workspace, now_ms)
  let manifest : Manifest = {
    id,
    generation: 0,
    parents: [],
    born: format_iso8601(now_ms),
    lineage: [],
  }
  ignore(write_manifest(home, manifest))
  Some(manifest)
}

///|
/// Export genome directory as a single JSON object for migration/split.
pub async fn export_genome(home : String) -> Json {
  let result : Map[String, Json] = {}
  // Manifest
  match read_manifest(home) {
    Some(m) => result["manifest"] = m.to_json()
    None => ()
  }
  // Pending learnings
  let pending_content = read_file("\{home}/genome/pending.json")
  if not(pending_content.is_empty()) {
    try {
      result["pending"] = @json.parse(pending_content)
    } catch {
      _ => ()
    }
  }
  // Skill stats
  let stats_content = read_file("\{home}/genome/skill_stats.json")
  if not(stats_content.is_empty()) {
    try {
      result["skill_stats"] = @json.parse(stats_content)
    } catch {
      _ => ()
    }
  }
  // Identity
  let identity_content = read_file("\{home}/genome/identity.md")
  if not(identity_content.is_empty()) {
    result["identity"] = identity_content.to_json()
  }
  // Skills
  let skill_entries = list_dir("\{home}/genome/skills")
  let skills : Map[String, Json] = {}
  for entry in skill_entries {
    let content = read_file("\{home}/genome/skills/\{entry}/SKILL.md")
    if not(content.is_empty()) {
      skills[entry] = content.to_json()
    }
  }
  if not(skills.is_empty()) {
    result["skills"] = Json::object(skills)
  }
  Json::object(result)
}

///|
/// Import genome from a JSON export. Overwrites existing data.
pub async fn import_genome(home : String, data : Json) -> Bool {
  ensure_genome_dir(home)
  // Import manifest
  match data {
    { "manifest": manifest, .. } =>
      match Manifest::from_json(manifest) {
        Some(m) => ignore(write_manifest(home, m))
        None => ()
      }
    _ => ()
  }
  // Import pending learnings
  match data {
    { "pending": pending, .. } =>
      ignore(write_file("\{home}/genome/pending.json", pending.stringify()))
    _ => ()
  }
  // Import skill stats
  match data {
    { "skill_stats": stats, .. } =>
      ignore(write_file("\{home}/genome/skill_stats.json", stats.stringify()))
    _ => ()
  }
  // Import identity
  match data {
    { "identity": String(identity), .. } =>
      ignore(write_file("\{home}/genome/identity.md", identity))
    _ => ()
  }
  // Import skills
  match data {
    { "skills": Object(skills), .. } =>
      for name, content in skills {
        match content {
          String(body) =>
            ignore(write_file("\{home}/genome/skills/\{name}/SKILL.md", body))
          _ => ()
        }
      }
    _ => ()
  }
  true
}

///|
/// Genome directory path helper.
pub fn genome_dir(home : String) -> String {
  "\{home}/genome"
}

///|
/// Path to pending learnings in genome.
pub fn pending_path(home : String) -> String {
  "\{home}/genome/pending.json"
}

///|
/// Path to skill stats in genome.
pub fn skill_stats_path(home : String) -> String {
  "\{home}/genome/skill_stats.json"
}

///|
/// Path to identity in genome.
pub fn identity_path(home : String) -> String {
  "\{home}/genome/identity.md"
}

///|
/// Path to genome skills directory.
pub fn skills_dir(home : String) -> String {
  "\{home}/genome/skills"
}
