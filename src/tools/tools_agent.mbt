/// Agent spawn tool: launch sub-agent processes.

///|
/// Register agent.spawn tool.
fn register_agent_spawn(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["task"] = string_prop("Task description for the sub-agent to execute")
  props["session_id"] = string_prop(
    "Session ID for the sub-agent (optional, auto-generated if omitted)",
  )
  props["timeout_seconds"] = int_prop(
    "Maximum seconds for sub-agent to run",
    default_val=Some(300),
  )
  let params = make_params(props, ["task"])
  registry.register(
    "agent.spawn",
    "Spawn a sub-agent to handle a task",
    detail="Launch a sub-agent process that runs independently with its own session. The sub-agent inherits the workspace but has its own tape. Returns the sub-agent's final output.",
    parameters=params,
    requires_confirmation=true,
    handler=async fn(args) {
      let task = match args {
        { "task": String(t), .. } => t
        _ => fail("agent.spawn: missing 'task' argument")
      }
      let child_session = match args {
        { "session_id": String(s), .. } => s
        _ => "child_\{generate_job_id()}"
      }
      let timeout = match args {
        { "timeout_seconds": Number(n, ..), .. } => n.to_int()
        _ => 300
      }
      spawn_sub_agent(workspace, child_session, task, timeout)
    },
  )
}

///|
/// Spawn a sub-agent as a subprocess.
async fn spawn_sub_agent(
  workspace : String,
  _session_id : String,
  task : String,
  timeout : Int,
) -> String {
  // Find the cub binary
  let cub_bin = match @config.getenv("CUB_BIN") {
    Some(b) => b
    None => {
      // Try common locations
      let candidates = [
        "\{workspace}/_build/native/debug/build/main/main.exe",
        "/usr/local/bin/cub",
      ]
      let mut found = ""
      for c in candidates {
        let data = @fs.read_file(c) catch { _ => continue }
        if data.binary().length() > 0 {
          found = c
          break
        }
      }
      if found.is_empty() {
        fail("agent.spawn: cannot find cub binary (set CUB_BIN)")
      }
      found
    }
  }
  let (exit_code, stdout_data, stderr_data) = @async.with_timeout(
    timeout * 1000,
    async fn() {
      @process.collect_output(cub_bin, ["run", "--workspace", workspace, task])
    },
  ) catch {
    _ => fail("agent.spawn: timeout after \{timeout}s")
  }
  let stdout_text = stdout_data.text() catch { _ => "" }
  let stderr_text = stderr_data.text() catch { _ => "" }
  if exit_code != 0 {
    let error_output = if stderr_text.length() > 0 {
      stderr_text
    } else {
      stdout_text
    }
    fail("agent.spawn: exit=\{exit_code}: \{error_output}")
  }
  if stdout_text.trim().to_string().is_empty() {
    "(sub-agent produced no output)"
  } else {
    stdout_text
  }
}
