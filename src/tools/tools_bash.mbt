/// Bash tool: shell command execution.

///|
/// Register bash tool.
fn register_bash(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let session_id = ctx.session_id
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
    requires_confirmation=true,
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
        { "timeout_seconds": Number(n, ..), .. } => n.to_int()
        _ => subprocess_timeout_seconds
      }
      if is_ext_cmd(cmd) {
        return "ERROR: Do not manually create files under .agent/plugins/ or .agent/tools/. Use tool.create instead — it handles scaffolding, build, and hot-registration in one call."
      }
      run_bash_command(cmd, cwd, timeout, workspace, session_id)
    },
  )
}

///|
/// Execute a bash command.
async fn run_bash_command(
  cmd : String,
  cwd : String,
  timeout : Int,
  workspace : String,
  session_id : String,
) -> String {
  // Load workspace .env into extra environment
  let extra_env : Map[String, String] = {}
  let env_path = "\{workspace}/.env"
  let env_content = try {
    let data = @fs.read_file(env_path)
    data.text()
  } catch {
    _ => ""
  }
  if env_content.length() > 0 {
    let dotenv = @config.parse_dotenv(env_content)
    for k, v in dotenv {
      extra_env[k] = v
    }
  }
  extra_env["CUB_SESSION_ID"] = session_id
  let (exit_code, stdout_data, stderr_data) = @async.with_timeout(
    timeout * 1000,
    async fn() {
      @process.collect_output("bash", ["-lc", cmd], cwd~, extra_env~)
    },
  ) catch {
    e => fail("bash error: \{e}")
  }
  let stdout_text = stdout_data.text() catch { _ => "" }
  let stderr_text = stderr_data.text() catch { _ => "" }
  if exit_code != 0 {
    let error_output = if stderr_text.length() > 0 {
      stderr_text
    } else {
      stdout_text
    }
    fail("exit=\{exit_code}: \{error_output}")
  }
  if stdout_text.length() > 0 {
    stdout_text
  } else {
    "(no output)"
  }
}
