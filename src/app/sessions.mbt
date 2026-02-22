/// Session persistence: save and load active sessions for resume on restart.

///|
/// Save active session state to disk for resume on restart.
pub async fn AppRuntime::save_active_session(
  self : AppRuntime,
  session_id : String,
  channel : String,
  channel_id : String,
) -> Unit {
  let home = self.settings.resolve_home()
  let path = "\{home}/active_sessions.json"
  // Read existing sessions
  let content = read_file_sync(path)
  let parsed : Json = @json.parse(content) catch { _ => Json::object({}) }
  let sessions : Map[String, Json] = match parsed {
    Object(obj) => obj
    _ => {}
  }
  // Update this session
  let entry : Map[String, Json] = {}
  entry["channel"] = channel.to_json()
  entry["channel_id"] = channel_id.to_json()
  entry["last_active_ms"] = @async.now().to_double().to_json()
  sessions[session_id] = Json::object(entry)
  // Write back
  ignore(write_file_sync(path, Json::object(sessions).stringify()))
}

///|
/// Load active sessions from disk. Returns sessions active within the last 24h.
pub async fn AppRuntime::load_active_sessions(
  self : AppRuntime,
) -> Array[(String, String, String)] {
  let home = self.settings.resolve_home()
  let path = "\{home}/active_sessions.json"
  let content = read_file_sync(path)
  if content.is_empty() {
    return []
  }
  let parsed : Json = @json.parse(content) catch { _ => return [] }
  let sessions = match parsed {
    Object(obj) => obj
    _ => return []
  }
  let now = @async.now()
  let day_ms = 24L * 60L * 60L * 1000L
  let result : Array[(String, String, String)] = []
  for session_id, entry in sessions {
    let last_active = match entry {
      { "last_active_ms": Number(n, ..), .. } => n.to_int64()
      _ => 0L
    }
    if now - last_active < day_ms {
      let channel = match entry {
        { "channel": String(c), .. } => c
        _ => continue
      }
      let channel_id = match entry {
        { "channel_id": String(cid), .. } => cid
        _ => continue
      }
      result.push((session_id, channel, channel_id))
    }
  }
  result
}
