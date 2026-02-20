/// Routing and command execution.

/// Command-aware router for user and model outputs.
pub struct InputRouter {
  registry : @tools.ToolRegistry
  tool_view : @tools.ProgressiveToolView
  tape : @tape.TapeService
  workspace : String
}

/// Create a new InputRouter.
pub fn InputRouter::new(
  registry : @tools.ToolRegistry,
  tool_view : @tools.ProgressiveToolView,
  tape : @tape.TapeService,
  workspace : String
) -> InputRouter {
  { registry, tool_view, tape, workspace }
}

/// Route user input.
pub async fn InputRouter::route_user(
  self : InputRouter,
  raw : String
) -> UserRouteResult {
  let stripped = raw.trim().to_string()
  if stripped.length() == 0 {
    return {
      enter_model: false,
      model_prompt: "",
      immediate_output: "",
      exit_requested: false,
    }
  }
  let command = self.parse_comma_command(stripped)
  match command {
    None => {
      // Check for $hints in the text and expand matching tools
      self.detect_hints(stripped)
      // Natural language → send to model
      {
        enter_model: true,
        model_prompt: stripped,
        immediate_output: "",
        exit_requested: false,
      }
    }
    Some(cmd) => {
      let result = self.execute_command(cmd, origin="human")
      if result.status == "ok" {
        if result.name == "quit" && result.output == "exit" {
          return {
            enter_model: false,
            model_prompt: "",
            immediate_output: "",
            exit_requested: true,
          }
        }
        return {
          enter_model: false,
          model_prompt: "",
          immediate_output: result.output,
          exit_requested: false,
        }
      }
      // Failed command falls back to model with context
      {
        enter_model: true,
        model_prompt: result.block(),
        immediate_output: result.output,
        exit_requested: false,
      }
    }
  }
}

/// Route assistant output: parse comma commands from text, execute them,
/// collect visible text and command result blocks.
pub async fn InputRouter::route_assistant(
  self : InputRouter,
  raw : String
) -> AssistantRouteResult {
  let visible_lines : Array[String] = []
  let command_blocks : Array[String] = []
  let mut exit_requested = false
  // Split lines and process
  for line in raw.split("\n") {
    let line_str = line.to_string()
    let stripped = line_str.trim().to_string()
    if stripped.length() == 0 {
      continue
    }
    let command = self.parse_comma_command(stripped)
    match command {
      None => visible_lines.push(line_str)
      Some(cmd) => {
        let result = self.execute_command(cmd, origin="assistant")
        command_blocks.push(result.block())
        if result.name == "quit" && result.status == "ok" && result.output == "exit" {
          exit_requested = true
        }
      }
    }
  }
  let visible_text = if command_blocks.length() > 0 {
    // Hide execution-phase chatter when commands were executed
    ""
  } else {
    join_lines(visible_lines)
  }
  let next_prompt = join_lines(command_blocks)
  { visible_text, next_prompt, exit_requested }
}

/// Detect $name hints in user input and expand matching tools.
fn InputRouter::detect_hints(self : InputRouter, text : String) -> Unit {
  let mut i = 0
  while i < text.length() {
    if text[i] == '$'.to_int().to_uint16() {
      // Extract the name after $
      let start = i + 1
      let mut end = start
      while end < text.length() {
        let ch = text[end].to_int()
        // Allow alphanumeric, dot, underscore, hyphen
        if (ch >= 97 && ch <= 122) ||  // a-z
           (ch >= 65 && ch <= 90) ||   // A-Z
           (ch >= 48 && ch <= 57) ||   // 0-9
           ch == 46 || ch == 95 || ch == 45 {  // . _ -
          end += 1
        } else {
          break
        }
      }
      if end > start {
        let hint = try { text[start:end].to_string() } catch { _ => "" }
        if hint.length() > 0 {
          ignore(self.tool_view.note_hint(hint))
        }
      }
      i = end
    } else {
      i += 1
    }
  }
}

/// Parse a comma-prefixed command from stripped text.
fn InputRouter::parse_comma_command(
  self : InputRouter,
  stripped : String
) -> DetectedCommand? {
  if stripped.length() == 0 || stripped[0] != ','.to_int().to_uint16() {
    return None
  }
  let body_start = 1
  let body = try {
    stripped[body_start:].to_string().trim().to_string()
  } catch {
    _ => return None
  }
  if body.length() == 0 {
    return None
  }
  // Try as internal command
  let (name, args_tokens) = parse_internal_command(stripped)
  if name.length() > 0 {
    let resolved = resolve_internal_name(name)
    if self.registry.has(resolved) {
      return Some(
        { kind: "internal", raw: stripped, name, args_tokens },
      )
    }
  }
  // Otherwise treat as shell command
  let words = parse_command_words(body)
  if words.length() == 0 {
    return None
  }
  Some({ kind: "shell", raw: body, name: words[0], args_tokens: words.copy() })
}

/// Execute a detected command.
async fn InputRouter::execute_command(
  self : InputRouter,
  command : DetectedCommand,
  origin~ : String
) -> CommandExecutionResult {
  if command.kind == "shell" {
    self.execute_shell(command, origin~)
  } else {
    self.execute_internal(command, origin~)
  }
}

/// Execute a shell command via the bash tool.
async fn InputRouter::execute_shell(
  self : InputRouter,
  command : DetectedCommand,
  origin~ : String
) -> CommandExecutionResult {
  let args : Map[String, Json] = Map::new()
  args["cmd"] = command.raw.to_json()
  args["cwd"] = self.workspace.to_json()
  let (status, text) = try {
    let output = self.registry.execute("bash", kwargs=Json::object(args))
    ("ok", output)
  } catch {
    e => ("error", e.to_string())
  }
  self.record_command(command, status, text, origin)
  { command: command.raw, name: "bash", status, output: text, elapsed_ms: 0 }
}

/// Execute an internal command.
async fn InputRouter::execute_internal(
  self : InputRouter,
  command : DetectedCommand,
  origin~ : String
) -> CommandExecutionResult {
  let name = resolve_internal_name(command.name)
  let parsed_args = parse_kv_arguments(command.args_tokens)
  // Handle tool.describe positional arg
  if name == "tool.describe" && parsed_args.positional.length() > 0 &&
    not(parsed_args.kwargs.contains("name")) {
    parsed_args.kwargs["name"] = parsed_args.positional[0]
  }
  // Handle skills.describe positional arg
  if name == "skills.describe" && parsed_args.positional.length() > 0 &&
    not(parsed_args.kwargs.contains("name")) {
    parsed_args.kwargs["name"] = parsed_args.positional[0]
  }
  // Handle tape.search positional arg
  if name == "tape.search" && parsed_args.positional.length() > 0 &&
    not(parsed_args.kwargs.contains("query")) {
    parsed_args.kwargs["query"] = parsed_args.positional.join(" ")
  }
  // Handle handoff default name
  if name == "handoff" && not(parsed_args.kwargs.contains("name")) {
    if parsed_args.positional.length() > 0 {
      parsed_args.kwargs["name"] = parsed_args.positional[0]
    } else {
      parsed_args.kwargs["name"] = "handoff"
    }
  }
  if not(self.registry.has(name)) {
    let text = "unknown internal command: " + command.name
    self.record_command(command, "error", text, origin)
    return {
      command: command.raw,
      name,
      status: "error",
      output: text,
      elapsed_ms: 0,
    }
  }
  // Convert kwargs to Json
  let kwargs_json : Map[String, Json] = Map::new()
  for k, v in parsed_args.kwargs {
    kwargs_json[k] = v.to_json()
  }
  let (status, text) = try {
    let output = self.registry.execute(name, kwargs=Json::object(kwargs_json))
    if name == "tool.describe" {
      match parsed_args.kwargs.get("name") {
        Some(described) => self.tool_view.note_selected(described)
        None => ()
      }
    } else if name != "help" && name != "tools" {
      self.tool_view.note_selected(name)
    }
    ("ok", output)
  } catch {
    e => ("error", e.to_string())
  }
  self.record_command(command, status, text, origin)
  { command: command.raw, name, status, output: text, elapsed_ms: 0 }
}

/// Resolve internal command name aliases.
fn resolve_internal_name(name : String) -> String {
  match name {
    "tool" => "tool.describe"
    "tape" => "tape.info"
    "skill" => "skills.describe"
    _ => name
  }
}

/// Record a command event on the tape.
async fn InputRouter::record_command(
  self : InputRouter,
  command : DetectedCommand,
  status : String,
  output : String,
  origin : String
) -> Unit {
  let data : Map[String, Json] = Map::new()
  data["origin"] = origin.to_json()
  data["kind"] = command.kind.to_json()
  data["raw"] = command.raw.to_json()
  data["name"] = command.name.to_json()
  data["status"] = status.to_json()
  data["output"] = output.to_json()
  self.tape.append_event("command", Json::object(data))
}

/// Join string array with newlines, trimming result.
fn join_lines(lines : Array[String]) -> String {
  let buf = StringBuilder::new()
  for i, line in lines {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string(line)
  }
  buf.to_string().trim().to_string()
}
