/// Built-in tools: bash, fs.read, fs.write, done.

/// Default subprocess timeout in seconds.
let subprocess_timeout_seconds : Int = 30

/// Register all built-in tools.
pub fn register_builtin_tools(
  registry : ToolRegistry,
  ctx : ToolContext
) -> Unit {
  register_bash(registry, ctx)
  register_fs_read(registry, ctx)
  register_fs_write(registry, ctx)
  register_done(registry, ctx)
}

/// Build a JSON Schema object for tool parameters.
pub fn make_params(
  properties : Map[String, Json],
  required : Array[String]
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

/// Helper: create a string property schema.
pub fn string_prop(description : String) -> Json {
  let p : Map[String, Json] = Map::new()
  p["type"] = "string".to_json()
  p["description"] = description.to_json()
  Json::object(p)
}

/// Helper: create an integer property schema.
fn int_prop(description : String, default_val~ : Int? = None) -> Json {
  let p : Map[String, Json] = Map::new()
  p["type"] = "integer".to_json()
  p["description"] = description.to_json()
  match default_val {
    Some(d) => p["default"] = d.to_json()
    None => ()
  }
  Json::object(p)
}

/// Helper: resolve a path relative to workspace.
fn resolve_path(workspace : String, path : String) -> String {
  if path.length() > 0 && path[0] == '/'.to_int().to_uint16() {
    path // absolute
  } else {
    workspace + "/" + path
  }
}

/// Register bash tool.
fn register_bash(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["cmd"] = string_prop("Shell command to execute")
  props["cwd"] = string_prop("Working directory (default: workspace)")
  props["timeout_seconds"] = int_prop(
    "Maximum seconds to allow command to run",
    default_val=Some(subprocess_timeout_seconds),
  )
  let params = make_params(props, ["cmd"])
  registry.register(
    "bash",
    "Run shell command",
    detail="Execute a shell command using bash -lc. Returns stdout on success, stderr on failure.",
    parameters=params,
    handler=async fn(args) {
      let cmd = match args {
        { "cmd": String(c), .. } => c
        _ => fail("bash: missing 'cmd' argument")
      }
      let cwd = match args {
        { "cwd": String(c), .. } => c
        _ => workspace
      }
      let timeout = match args {
        { "timeout_seconds": Number(n), .. } => n.to_int()
        _ => subprocess_timeout_seconds
      }
      run_bash_command(cmd, cwd, timeout)
    },
  )
}

/// Execute a bash command.
async fn run_bash_command(cmd : String, cwd : String, timeout : Int) -> String {
  let (exit_code, stdout_data, stderr_data) = try {
    @async.with_timeout(
      timeout * 1000,
      async fn() {
        @process.collect_output("bash", ["-lc", cmd], cwd=cwd)
      },
    )
  } catch {
    e => fail("bash error: " + e.to_string())
  }
  let stdout_text = try { stdout_data.text() } catch { _ => "" }
  let stderr_text = try { stderr_data.text() } catch { _ => "" }
  if exit_code != 0 {
    let error_output = if stderr_text.length() > 0 {
      stderr_text
    } else {
      stdout_text
    }
    fail("exit=\{exit_code}: " + error_output)
  }
  if stdout_text.length() > 0 {
    stdout_text
  } else {
    "(no output)"
  }
}

/// Register fs.read tool.
fn register_fs_read(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["path"] = string_prop("File path (relative to workspace or absolute)")
  props["offset"] = int_prop("Line offset to start reading from", default_val=Some(0))
  props["limit"] = int_prop("Maximum number of lines to read")
  let params = make_params(props, ["path"])
  registry.register(
    "fs.read",
    "Read file content",
    detail="Read file content with optional line offset and limit.",
    parameters=params,
    handler=async fn(args) {
      let path = match args {
        { "path": String(p), .. } => resolve_path(workspace, p)
        _ => fail("fs.read: missing 'path' argument")
      }
      let offset = match args {
        { "offset": Number(n), .. } => n.to_int()
        _ => 0
      }
      let limit : Int? = match args {
        { "limit": Number(n), .. } => Some(n.to_int())
        _ => None
      }
      read_file_content(path, offset, limit)
    },
  )
}

/// Read file content with optional offset and limit.
async fn read_file_content(path : String, offset : Int, limit : Int?) -> String {
  let content = try {
    @fs.read_file(path).text()
  } catch {
    e => fail("fs.read: " + e.to_string())
  }
  let lines : Array[StringView] = []
  for line in content.split("\n") {
    lines.push(line)
  }
  let start = if offset < lines.length() { offset } else { lines.length() }
  let end = match limit {
    Some(l) => {
      let e = start + l
      if e < lines.length() { e } else { lines.length() }
    }
    None => lines.length()
  }
  let result = StringBuilder::new()
  for i = start; i < end; i = i + 1 {
    if i > start {
      result.write_char('\n')
    }
    result.write_string(lines[i].to_string())
  }
  result.to_string()
}

/// Register fs.write tool.
fn register_fs_write(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["path"] = string_prop("File path (relative to workspace or absolute)")
  props["content"] = string_prop("File content to write")
  let params = make_params(props, ["path", "content"])
  registry.register(
    "fs.write",
    "Write file content",
    detail="Write content to a file. Creates parent directories if needed.",
    parameters=params,
    handler=async fn(args) {
      let path = match args {
        { "path": String(p), .. } => resolve_path(workspace, p)
        _ => fail("fs.write: missing 'path' argument")
      }
      let content = match args {
        { "content": String(c), .. } => c
        _ => fail("fs.write: missing 'content' argument")
      }
      write_file_content(path, content)
    },
  )
}

/// Write content to a file, creating parent directories as needed.
async fn write_file_content(path : String, content : String) -> String {
  // Create parent directory
  let parent = get_parent_dir(path)
  if parent.length() > 0 {
    try {
      @fs.mkdir(parent, permission=0o755, recursive=true)
    } catch {
      _ => ()
    }
  }
  try {
    @fs.write_file(path, content)
  } catch {
    e => fail("fs.write: " + e.to_string())
  }
  "wrote: " + path
}

/// Get parent directory from a path.
fn get_parent_dir(path : String) -> String {
  let mut last_slash = -1
  for i, ch in path {
    if ch == '/' {
      last_slash = i
    }
  }
  if last_slash <= 0 {
    ""
  } else {
    path.substring(end=last_slash)
  }
}

/// Register done tool.
fn register_done(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  ignore(ctx)
  let params = make_params(Map::new(), [])
  registry.register(
    "done",
    "Signal task completion",
    detail="Call this tool when the task is complete. Stops the agent loop.",
    parameters=params,
    handler=async fn(_args) { "done" },
  )
}
