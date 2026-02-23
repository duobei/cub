/// Built-in tools: orchestrator and shared helpers.

///|
/// Default subprocess timeout in seconds.
let subprocess_timeout_seconds : Int = 30

///|
/// Register all built-in tools.
pub fn register_builtin_tools(
  registry : ToolRegistry,
  ctx : ToolContext,
) -> Unit {
  register_bash(registry, ctx)
  register_fs_read(registry, ctx)
  register_fs_write(registry, ctx)
  register_fs_edit(registry, ctx)
  register_fs_list(registry, ctx)
  register_fs_glob(registry, ctx)
  register_grep(registry, ctx)
  register_web_fetch(registry, ctx)
  register_web_search(registry, ctx)
  register_skill_install(registry, ctx)
  register_schedule_add(registry, ctx)
  register_schedule_remove(registry, ctx)
  register_schedule_list(registry, ctx)
  register_agent_spawn(registry, ctx)
  register_done(registry, ctx)
}

///|
/// Build a JSON Schema object for tool parameters.
pub fn make_params(
  properties : Map[String, Json],
  required : Array[String],
) -> Json {
  let schema : Map[String, Json] = Map::new()
  schema["type"] = "object".to_json()
  schema["properties"] = Json::object(properties)
  if required.length() > 0 {
    let req_json : Array[Json] = []
    for r in required {
      req_json.push(r.to_json())
    }
    schema["required"] = Json::array(req_json)
  }
  Json::object(schema)
}

///|
/// Helper: create a string property schema.
pub fn string_prop(description : String) -> Json {
  let p : Map[String, Json] = Map::new()
  p["type"] = "string".to_json()
  p["description"] = description.to_json()
  Json::object(p)
}

///|
/// Helper: create an integer property schema.
fn int_prop(description : String, default_val? : Int? = None) -> Json {
  let p : Map[String, Json] = Map::new()
  p["type"] = "integer".to_json()
  p["description"] = description.to_json()
  match default_val {
    Some(d) => p["default"] = d.to_json()
    None => ()
  }
  Json::object(p)
}

///|
/// Helper: parse a simple non-negative integer from string.
fn parse_simple_int(s : String) -> Int {
  let mut result = 0
  for ch in s {
    if ch >= '0' && ch <= '9' {
      result = result * 10 + (ch.to_int() - '0'.to_int())
    } else {
      break
    }
  }
  result
}

///|
/// Helper: check if a URL points to a safe external host (not local/private).
pub fn is_safe_url(url : String) -> Bool {
  let lower = url.to_lower()
  // Must be https
  if not(lower.has_prefix("https://")) && not(lower.has_prefix("http://")) {
    return false
  }
  // Extract host portion
  let scheme_len = if lower.has_prefix("https://") { 8 } else { 7 }
  let after_scheme = lower[scheme_len:].to_string() catch { _ => return false }
  // Find end of host (before / or :, but handle [IPv6])
  let mut host_end = after_scheme.length()
  let in_bracket = after_scheme.length() > 0 &&
    after_scheme[0] == '['.to_int().to_uint16()
  for i in 0..<after_scheme.length() {
    let ch = after_scheme[i]
    if in_bracket {
      if ch == ']'.to_int().to_uint16() {
        host_end = i + 1
        break
      }
    } else if ch == '/'.to_int().to_uint16() || ch == ':'.to_int().to_uint16() {
      host_end = i
      break
    }
  }
  let host = after_scheme[:host_end].to_string() catch { _ => return false }
  // Block localhost and loopback
  let blocked_hosts = [
    "localhost", "[::1]", "169.254.169.254", "metadata.google.internal",
  ]
  for bh in blocked_hosts {
    if host == bh {
      return false
    }
  }
  // Block private IP prefixes
  let blocked_prefixes = ["127.", "10.", "192.168.", "0."]
  for bp in blocked_prefixes {
    if host.has_prefix(bp) {
      return false
    }
  }
  // Block 172.16-31.*
  if host.has_prefix("172.") {
    let parts = host.split(".")
    let second : Array[String] = []
    let mut count = 0
    for p in parts {
      if count == 1 {
        second.push(p.to_string())
      }
      count += 1
    }
    if second.length() > 0 {
      let n = parse_simple_int(second[0])
      if n >= 16 && n <= 31 {
        return false
      }
    }
  }
  true
}

///|
/// Helper: check if a path contains traversal sequences.
pub fn has_path_traversal(path : String) -> Bool {
  if path.contains("..") {
    return true
  }
  false
}

///|
/// Helper: sanitize a name for use in file paths (skill names, etc).
/// Rejects names containing path separators or traversal.
pub fn sanitize_name(name : String) -> String? {
  if name.is_empty() ||
    has_path_traversal(name) ||
    name.contains("/") ||
    name.contains("\\") {
    return None
  }
  Some(name)
}

///|
/// Helper: resolve a path relative to workspace.
fn resolve_path(workspace : String, path : String) -> String {
  if path.length() > 0 && path[0] == '/'.to_int().to_uint16() {
    path // absolute
  } else {
    "\{workspace}/\{path}"
  }
}

///|
/// Helper: resolve path with traversal check. Returns error string on failure.
fn safe_resolve_path(
  workspace : String,
  path : String,
) -> Result[String, String] {
  if has_path_traversal(path) {
    Err("rejected: path contains '..' traversal")
  } else {
    Ok(resolve_path(workspace, path))
  }
}

///|
/// Register done tool.
fn register_done(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  ignore(ctx)
  let params = make_params(Map::new(), [])
  registry.register(
    "done",
    "Signal task completion",
    detail="Call this tool when the task is complete. Stops the agent loop.",
    parameters=params,
    handler=fn(_args) { "done" },
  )
}

///|
/// Check if a resolved path targets extension directories.
fn is_ext_path(path : String) -> Bool {
  path.contains("/.agent/plugins/") || path.contains("/.agent/tools/")
}

///|
/// Check if a bash command writes to extension directories.
/// Allows read-only ops (ls, cat, find) and moon build/run.
fn is_ext_cmd(cmd : String) -> Bool {
  if not(cmd.contains(".agent/plugins/") || cmd.contains(".agent/tools/")) {
    return false
  }
  // Allow build/run commands
  if cmd.contains("moon build") || cmd.contains("moon run") {
    return false
  }
  // Block write operations
  cmd.contains("mkdir") ||
  cmd.contains("cp ") ||
  cmd.contains("mv ") ||
  cmd.contains("rm ") ||
  cmd.contains("touch ") ||
  cmd.contains("tee ") ||
  cmd.contains("echo ") ||
  cmd.contains("cat >") ||
  cmd.contains("cat >>")
}
