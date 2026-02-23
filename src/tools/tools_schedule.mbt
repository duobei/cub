/// Schedule tools: schedule.add, schedule.remove, schedule.list.

///|
/// Global counter for generating unique job IDs within a process.
let job_counter : Ref[Int] = { val: 0 }

///|
/// Generate a unique job ID using timestamp + counter.
fn generate_job_id() -> String {
  let ts = @async.now()
  job_counter.val = job_counter.val + 1
  let count = job_counter.val
  // FNV-1a hash mixing timestamp + counter
  let mut hash : UInt = 2166136261
  // Mix in timestamp bytes
  for i in 0..<8 {
    let byte = ((ts >> (i * 8)) & 0xFFL).to_int().reinterpret_as_uint()
    hash = hash ^ byte
    hash = hash * 16777619
  }
  // Mix in counter
  hash = hash ^ count.reinterpret_as_uint()
  hash = hash * 16777619
  let hex_chars = "0123456789abcdef"
  let buf = StringBuilder::new()
  buf.write_string("job_")
  for i in 0..<8 {
    let nibble = ((hash >> ((7 - i) * 4)) & 0xf).reinterpret_as_int()
    buf.write_char(hex_chars[nibble].to_int().unsafe_to_char())
  }
  buf.to_string()
}

///|
/// Register schedule.add tool.
fn register_schedule_add(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["message"] = string_prop("Message/task to execute when triggered")
  props["trigger"] = string_prop(
    "Trigger specification: 'cron:*/5 * * * *', 'date:2026-02-23T10:00:00', or 'interval:30m'",
  )
  props["session_id"] = string_prop(
    "Session ID to run the task in (optional, default: schedule)",
  )
  let params = make_params(props, ["message", "trigger"])
  registry.register(
    "schedule.add",
    "Add a scheduled task",
    detail="Schedule a task to run at a future time or on a recurring basis. Supports cron expressions, specific dates, and intervals (e.g. 30m, 1h, 2d).",
    parameters=params,
    handler=async fn(args) {
      let message = match args {
        { "message": String(m), .. } => m
        _ => fail("schedule.add: missing 'message' argument")
      }
      let trigger = match args {
        { "trigger": String(t), .. } => t
        _ => fail("schedule.add: missing 'trigger' argument")
      }
      let session_id = match args {
        { "session_id": String(s), .. } => s
        _ => "schedule"
      }
      // Validate trigger format
      if not(trigger.has_prefix("cron:")) &&
        not(trigger.has_prefix("date:")) &&
        not(trigger.has_prefix("interval:")) {
        fail(
          "schedule.add: trigger must start with 'cron:', 'date:', or 'interval:'",
        )
      }
      // Validate interval format if interval trigger
      if trigger.has_prefix("interval:") {
        let interval_str = trigger[9:].to_string() catch {
          _ => fail("schedule.add: invalid interval format")
        }
        if parse_interval_seconds(interval_str) <= 0 {
          fail(
            "schedule.add: invalid interval format (use e.g. '30m', '1h', '2d')",
          )
        }
      }
      let job_id = generate_job_id()
      // Build schedule entry
      let entry : Map[String, Json] = Map::new()
      entry["id"] = job_id.to_json()
      entry["message"] = message.to_json()
      entry["trigger"] = trigger.to_json()
      entry["session_id"] = session_id.to_json()
      let now_ms = @async.now()
      entry["created_at_ms"] = now_ms.to_json()
      entry["enabled"] = true.to_json()
      // Read existing schedules
      let schedules_path = resolve_schedules_path(workspace)
      let existing = read_schedules_file(schedules_path)
      existing.push(Json::object(entry))
      // Write back
      write_schedules_file(schedules_path, existing)
      "scheduled: \{job_id} (trigger: \{trigger})"
    },
  )
}

///|
/// Resolve the path to schedules.json.
fn resolve_schedules_path(_workspace : String) -> String {
  let home = @config.getenv("HOME").unwrap_or("/tmp")
  "\{home}/.cub/schedules.json"
}

///|
/// Read schedules from JSON file via async fs.
async fn read_schedules_file(path : String) -> Array[Json] {
  let content = @fs.read_file(path).text() catch { _ => return [] }
  if content.trim().to_string().is_empty() {
    return []
  }
  let parsed : Json = @json.parse(content) catch { _ => return [] }
  match parsed {
    Array(items) => items
    _ => []
  }
}

///|
/// Write schedules to JSON file. Raises on failure.
async fn write_schedules_file(path : String, schedules : Array[Json]) -> Unit {
  let json = Json::array(schedules)
  let content = json.stringify()
  // Create parent directory
  let parent = get_parent_dir(path)
  if parent.length() > 0 {
    @fs.mkdir(parent, permission=0o755, recursive=true) catch {
      _ => ()
    }
  }
  @fs.write_file(path, content, create=0o644) catch {
    e => fail("schedule: failed to write \{path}: \{e}")
  }
}

///|
/// Parse interval string like "30m", "1h", "2d" into seconds.
pub fn parse_interval_seconds(s : String) -> Int {
  let trimmed = s.trim().to_string()
  if trimmed.is_empty() {
    return -1
  }
  let last_char = trimmed[trimmed.length() - 1]
  let num_str = trimmed[:trimmed.length() - 1].to_string() catch {
    _ => return -1
  }
  let num = @strconv.parse_int(num_str) catch { _ => return -1 }
  if num <= 0 {
    return -1
  }
  let multiplier = if last_char == 's'.to_int().to_uint16() {
    1
  } else if last_char == 'm'.to_int().to_uint16() {
    60
  } else if last_char == 'h'.to_int().to_uint16() {
    3600
  } else if last_char == 'd'.to_int().to_uint16() {
    86400
  } else {
    return -1
  }
  num * multiplier
}

///|
/// Register schedule.remove tool.
fn register_schedule_remove(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["id"] = string_prop("Job ID to remove")
  let params = make_params(props, ["id"])
  registry.register(
    "schedule.remove",
    "Remove a scheduled task",
    detail="Remove a scheduled task by its job ID.",
    parameters=params,
    handler=async fn(args) {
      let id = match args {
        { "id": String(i), .. } => i
        _ => fail("schedule.remove: missing 'id' argument")
      }
      let path = resolve_schedules_path(workspace)
      let schedules = read_schedules_file(path)
      let filtered = schedules.filter(fn(s) {
        match s {
          { "id": String(sid), .. } => sid != id
          _ => true
        }
      })
      if filtered.length() == schedules.length() {
        fail("schedule.remove: job '\{id}' not found")
      }
      write_schedules_file(path, filtered)
      "removed: \{id}"
    },
  )
}

///|
/// Register schedule.list tool.
fn register_schedule_list(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let params = make_params(Map::new(), [])
  registry.register(
    "schedule.list",
    "List all scheduled tasks",
    detail="Show all pending scheduled tasks with their triggers and messages.",
    parameters=params,
    handler=async fn(_args) {
      let path = resolve_schedules_path(workspace)
      let schedules = read_schedules_file(path)
      if schedules.is_empty() {
        return "no scheduled tasks"
      }
      let lines : Array[String] = []
      for s in schedules {
        let id = match s {
          { "id": String(i), .. } => i
          _ => "?"
        }
        let msg = match s {
          { "message": String(m), .. } => m
          _ => ""
        }
        let trigger = match s {
          { "trigger": String(t), .. } => t
          _ => ""
        }
        let enabled = match s {
          { "enabled": True, .. } => "active"
          _ => "disabled"
        }
        // Truncate message for display
        let display_msg = if msg.length() > 60 {
          "\{msg[:60]}..." catch {
            _ => msg
          }
        } else {
          msg
        }
        lines.push("  \{id}  [\{trigger}]  \{display_msg}  (\{enabled})")
      }
      "Scheduled tasks:\n" + lines.join("\n")
    },
  )
}
