/// Due schedule checking and startup instructions.

///|
/// Read .agent/startup.md from workspace, returns empty string if not found.
async fn read_startup_md(workspace : String) -> String {
  let path = "\{workspace}/.agent/startup.md"
  let text = read_file_sync(path)
  if text.is_empty() {
    return ""
  }
  "<startup_instructions>\n\{text}\n</startup_instructions>"
}

///|
/// Check and execute due scheduled tasks. Returns (session_id, message) pairs.
/// For interval triggers, checks if enough time has elapsed since created_at_ms.
/// For date triggers, checks if the date has passed.
pub async fn AppRuntime::check_due_schedules(
  self : AppRuntime,
) -> Array[(String, String)] {
  let home = self.settings.resolve_home()
  let path = "\{home}/schedules.json"
  let content = read_file_sync(path)
  if content.trim().to_string().is_empty() {
    return []
  }
  let parsed : Json = @json.parse(content) catch { _ => return [] }
  let schedules = match parsed {
    Array(items) => items
    _ => return []
  }
  let now_ms = @async.now()
  let due_messages : Array[(String, String)] = []
  let remaining : Array[Json] = []
  let mut changed = false
  for s in schedules {
    let enabled = match s {
      { "enabled": True, .. } => true
      _ => false
    }
    if not(enabled) {
      remaining.push(s)
      continue
    }
    let trigger = match s {
      { "trigger": String(t), .. } => t
      _ => {
        remaining.push(s)
        continue
      }
    }
    let message = match s {
      { "message": String(m), .. } => m
      _ => {
        remaining.push(s)
        continue
      }
    }
    let sched_session_id = match s {
      { "session_id": String(sid), .. } => sid
      _ => "schedule"
    }
    let created_at_ms : Int64 = match s {
      { "created_at_ms": Number(n, ..), .. } => n.to_int64()
      { "created_at_ms": String(str), .. } =>
        parse_int64_simple(str)
      _ => 0L
    }
    // Check interval triggers
    if trigger.has_prefix("interval:") {
      let interval_str = trigger[9:].to_string() catch {
        _ => {
          remaining.push(s)
          continue
        }
      }
      let interval_secs = @tools.parse_interval_seconds(interval_str)
      if interval_secs > 0 {
        let interval_ms = interval_secs.to_int64() * 1000L
        if now_ms - created_at_ms >= interval_ms {
          due_messages.push((sched_session_id, message))
          changed = true
          // Update created_at_ms for next interval
          let updated : Map[String, Json] = Map::new()
          match s {
            { "id": String(id), .. } => updated["id"] = id.to_json()
            _ => ()
          }
          updated["message"] = message.to_json()
          updated["trigger"] = trigger.to_json()
          match s {
            { "session_id": String(sid), .. } =>
              updated["session_id"] = sid.to_json()
            _ => ()
          }
          updated["created_at_ms"] = now_ms.to_json()
          updated["enabled"] = true.to_json()
          remaining.push(Json::object(updated))
        } else {
          remaining.push(s)
        }
      } else {
        remaining.push(s)
      }
      continue
    }
    // Check cron triggers
    if trigger.has_prefix("cron:") {
      let cron_str = trigger[5:].to_string() catch {
        _ => {
          remaining.push(s)
          continue
        }
      }
      let cron_expr = @tools.parse_cron(cron_str)
      match cron_expr {
        Some(expr) => {
          let dt = @tools.unix_ms_to_datetime(now_ms)
          if @tools.cron_matches(expr, dt) {
            // Only fire if >60s since last fire to prevent double-firing
            if now_ms - created_at_ms > 60000L {
              due_messages.push((sched_session_id, message))
              changed = true
              // Update created_at_ms to prevent re-firing this minute
              let updated : Map[String, Json] = Map::new()
              match s {
                { "id": String(id), .. } => updated["id"] = id.to_json()
                _ => ()
              }
              updated["message"] = message.to_json()
              updated["trigger"] = trigger.to_json()
              match s {
                { "session_id": String(sid), .. } =>
                  updated["session_id"] = sid.to_json()
                _ => ()
              }
              updated["created_at_ms"] = now_ms.to_json()
              updated["enabled"] = true.to_json()
              remaining.push(Json::object(updated))
            } else {
              remaining.push(s)
            }
          } else {
            remaining.push(s)
          }
        }
        None => remaining.push(s) // invalid cron expression, keep but skip
      }
      continue
    }
    // For date triggers: keep for now (not yet fully implemented)
    remaining.push(s)
  }
  // Write back if changed
  if changed {
    let json_str = Json::array(remaining).stringify()
    ignore(write_file_sync(path, json_str))
  }
  due_messages
}

///|
/// Parse a simple non-negative integer string to Int64.
fn parse_int64_simple(s : String) -> Int64 {
  let mut result = 0L
  for ch in s {
    let code = ch.to_int()
    if code >= 48 && code <= 57 {
      result = result * 10L + (code - 48).to_int64()
    } else {
      return 0L
    }
  }
  result
}
