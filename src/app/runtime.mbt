/// Application runtime and session management.

/// Per-session runtime holding all components.
pub struct SessionRuntime {
  session_id : String
  agent_loop : @core.AgentLoop
  tape : @tape.TapeService
  model_runner : @core.ModelRunner
  tool_view : @tools.ProgressiveToolView
  registry : @tools.ToolRegistry
}

/// Handle input for a session.
pub async fn SessionRuntime::handle_input(
  self : SessionRuntime,
  text : String
) -> @core.LoopResult {
  self.agent_loop.handle_input(text)
}

/// Reset volatile in-memory context.
pub fn SessionRuntime::reset_context(self : SessionRuntime) -> Unit {
  self.model_runner.reset_context()
  self.tool_view.reset()
}

/// Application-level runtime managing sessions.
pub struct AppRuntime {
  settings : @config.Settings
  workspace : String
  sessions : Map[String, SessionRuntime]
  store : @tape.FileTapeStore
}

/// Create a new AppRuntime.
pub async fn AppRuntime::new(
  settings : @config.Settings,
  workspace : String
) -> AppRuntime {
  let home = match settings.home {
    Some(h) => h
    None => workspace + "/.cub"
  }
  let store = @tape.FileTapeStore::new(home, workspace)
  { settings, workspace, sessions: {}, store }
}

/// Get or create a session.
pub fn AppRuntime::get_session(
  self : AppRuntime,
  session_id : String
) -> SessionRuntime {
  match self.sessions.get(session_id) {
    Some(s) => s
    None => {
      let session = self.create_session(session_id)
      self.sessions[session_id] = session
      session
    }
  }
}

/// Resolve API key from settings priority chain.
fn resolve_api_key(settings : @config.Settings) -> String {
  match settings.api_key {
    Some(k) => k
    None =>
      match settings.openrouter_api_key {
        Some(k) => k
        None =>
          match settings.llm_api_key {
            Some(k) => k
            None => ""
          }
      }
  }
}

/// Create a new session with all components wired up.
fn AppRuntime::create_session(
  self : AppRuntime,
  session_id : String
) -> SessionRuntime {
  // Create tape service
  let tape_name = self.settings.tape_name + ":" + session_slug(session_id)
  let tape = @tape.TapeService::new(tape_name, self.store)
  // Create tool registry and register builtin tools
  let allowed = if self.settings.allowed_tools.length() > 0 {
    Some(self.settings.allowed_tools)
  } else {
    None
  }
  let registry = @tools.ToolRegistry::new(allowed_tools=allowed)
  let tool_ctx = @tools.ToolContext::new(tape, self.workspace)
  @tools.register_builtin_tools(registry, tool_ctx)
  // Register tape tools
  register_tape_tools(registry, tape, self.workspace, allowed_skills=self.settings.allowed_skills)
  // Create tool view
  let tool_view = @tools.ProgressiveToolView::new(registry)
  // Create LLM client
  let api_key = resolve_api_key(self.settings)
  let llm = @llm.LLMClient::new(
    self.settings.model,
    api_key,
    api_base=self.settings.api_base,
    max_tokens=self.settings.max_tokens,
  )
  // Create router
  let router = @core.InputRouter::new(registry, tool_view, tape, self.workspace)
  // Create model runner
  let ws = self.workspace
  let timeout : Int? = self.settings.model_timeout_seconds
  let model_runner = @core.ModelRunner::new(
    tape,
    router,
    tool_view,
    registry.model_tools(),
    fn() {
      let skills = @skills.discover_skills(ws)
      let allowed = self.settings.allowed_skills
      if allowed.length() == 0 {
        skills
      } else {
        let filtered : Array[@skills.SkillMetadata] = []
        for s in skills {
          if allowed.contains(s.name) {
            filtered.push(s)
          }
        }
        filtered
      }
    },
    fn(name) { @skills.load_skill_body(name, ws) },
    self.settings.model,
    self.settings.max_steps,
    self.settings.max_tokens,
    timeout,
    self.settings.system_prompt,
    fn() { read_agents_md(ws) },
    llm,
    registry,
  )
  // Create agent loop
  let agent_loop = @core.AgentLoop::new(router, model_runner, tape)
  {
    session_id,
    agent_loop,
    tape,
    model_runner,
    tool_view,
    registry,
  }
}

/// Handle input for a session.
pub async fn AppRuntime::handle_input(
  self : AppRuntime,
  session_id : String,
  text : String
) -> @core.LoopResult {
  let session = self.get_session(session_id)
  session.handle_input(text)
}

/// Reset session context.
pub fn AppRuntime::reset_session_context(
  self : AppRuntime,
  session_id : String
) -> Unit {
  match self.sessions.get(session_id) {
    Some(s) => s.reset_context()
    None => ()
  }
}

/// Discover skills for this workspace.
pub fn AppRuntime::discover_skills(
  self : AppRuntime
) -> Array[@skills.SkillMetadata] {
  @skills.discover_skills(self.workspace)
}

/// Load a skill body.
pub fn AppRuntime::load_skill_body(
  self : AppRuntime,
  name : String
) -> String? {
  @skills.load_skill_body(name, self.workspace)
}

/// Generate a short slug from session_id for tape file naming.
fn session_slug(session_id : String) -> String {
  let mut hash : UInt = 2166136261
  for i = 0; i < session_id.length(); i = i + 1 {
    hash = hash ^ session_id[i].to_uint()
    hash = hash * 16777619
  }
  uint_to_hex(hash)
}

/// Convert UInt to hex string.
fn uint_to_hex(n : UInt) -> String {
  let hex_chars = "0123456789abcdef"
  let buf = StringBuilder::new()
  for i = 0; i < 8; i = i + 1 {
    let nibble = ((n >> ((7 - i) * 4)) & 0xf).reinterpret_as_int()
    buf.write_char(hex_chars[nibble].to_int().unsafe_to_char())
  }
  buf.to_string()
}

/// Filter skills by allowed list (empty = allow all).
fn filter_skills(
  skills : Array[@skills.SkillMetadata],
  allowed : Array[String]
) -> Array[@skills.SkillMetadata] {
  if allowed.length() == 0 {
    return skills
  }
  let filtered : Array[@skills.SkillMetadata] = []
  for s in skills {
    if allowed.contains(s.name) {
      filtered.push(s)
    }
  }
  filtered
}

/// Read AGENTS.md from workspace root, returns empty string if not found.
fn read_agents_md(workspace : String) -> String {
  let path = workspace + "/AGENTS.md"
  let text = read_file_sync(path)
  if text.length() == 0 {
    return ""
  }
  "<workspace_instructions>\n" + text + "\n</workspace_instructions>"
}

/// Synchronous file read via C FFI two-pass pattern.
fn read_file_sync(path : String) -> String {
  let path_bytes = string_to_cstr(path)
  let len = cub_read_file(path_bytes, Bytes::new(0), 0)
  if len <= 0 {
    return ""
  }
  let buf = Bytes::new(len)
  let actual = cub_read_file(path_bytes, buf, len)
  if actual <= 0 {
    return ""
  }
  @utf8.decode_lossy(buf[:actual])
}

/// Convert a MoonBit String to a null-terminated UTF-8 byte array for C.
fn string_to_cstr(s : String) -> Bytes {
  let utf8 = @utf8.encode(s)
  let len = utf8.length()
  Bytes::makei(len + 1, fn(i) {
    if i < len { utf8[i] } else { b'\x00' }
  })
}

/// FFI: read file into buffer, returns size or -1 on error.
#borrow(path, buf)
extern "C" fn cub_read_file(path : Bytes, buf : Bytes, buf_size : Int) -> Int = "cub_read_file"

/// Register tape-related internal tools (help, tools, tape.info, etc.).
fn register_tape_tools(
  registry : @tools.ToolRegistry,
  tape : @tape.TapeService,
  workspace : String,
  allowed_skills~ : Array[String] = []
) -> Unit {
  // ,help
  registry.register(
    "help",
    "Show available commands",
    handler=fn(_args) {
      let rows = registry.compact_rows()
      let buf = StringBuilder::new()
      buf.write_string("Available commands:\n")
      for row in rows {
        buf.write_string("  ,")
        buf.write_string(row)
        buf.write_char('\n')
      }
      buf.to_string()
    },
  )
  // ,tools
  registry.register(
    "tools",
    "List available tools",
    handler=fn(_args) {
      let rows = registry.compact_rows()
      rows.join("\n")
    },
  )
  // ,tape.info
  registry.register(
    "tape.info",
    "Show tape status",
    handler=async fn(_args) {
      let info = tape.info()
      let buf = StringBuilder::new()
      buf.write_string("tape: ")
      buf.write_string(info.name)
      buf.write_string("\nentries: ")
      buf.write_string(info.entries.to_string())
      buf.write_string("\nanchors: ")
      buf.write_string(info.anchors.to_string())
      buf.write_string("\nlast_anchor: ")
      match info.last_anchor {
        Some(a) => buf.write_string(a)
        None => buf.write_string("-")
      }
      buf.write_string("\nentries_since_last_anchor: ")
      buf.write_string(info.entries_since_last_anchor.to_string())
      buf.to_string()
    },
  )
  // ,handoff
  let props : Map[String, Json] = Map::new()
  props["name"] = @tools.string_prop("Handoff name")
  props["summary"] = @tools.string_prop("Summary of current state")
  let handoff_params = @tools.make_params(props, ["name"])
  registry.register(
    "handoff",
    "Create a tape handoff (stage transition)",
    parameters=handoff_params,
    handler=async fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => "handoff"
      }
      let state : Map[String, Json] = Map::new()
      match args {
        { "summary": String(s), .. } => state["summary"] = s.to_json()
        _ => ()
      }
      ignore(tape.handoff(name, state=Some(state)))
      "handoff: " + name
    },
  )
  // ,anchors
  registry.register(
    "anchors",
    "List anchor points",
    handler=async fn(_args) {
      let anchors = tape.anchors()
      if anchors.length() == 0 {
        return "no anchors"
      }
      let buf = StringBuilder::new()
      for i, a in anchors {
        if i > 0 {
          buf.write_char('\n')
        }
        buf.write_string(a.name)
      }
      buf.to_string()
    },
  )
  // ,tape.search
  let search_props : Map[String, Json] = Map::new()
  search_props["query"] = @tools.string_prop("Search query")
  let search_params = @tools.make_params(search_props, ["query"])
  registry.register(
    "tape.search",
    "Search tape entries",
    parameters=search_params,
    handler=async fn(args) {
      let query = match args {
        { "query": String(q), .. } => q
        _ => return "tape.search: missing query"
      }
      let results = tape.search(query)
      if results.length() == 0 {
        return "no results"
      }
      let buf = StringBuilder::new()
      for i, entry in results {
        if i > 0 {
          buf.write_char('\n')
        }
        buf.write_string(entry.kind)
        buf.write_string(": ")
        buf.write_string(entry.payload.stringify())
      }
      buf.to_string()
    },
  )
  // ,tape.reset
  registry.register(
    "tape.reset",
    "Reset the tape",
    handler=async fn(args) {
      let archive = match args {
        { "archive": String(a), .. } => a == "true"
        _ => false
      }
      tape.reset(archive~)
    },
  )
  // ,skills.list
  let ws_for_skills = workspace
  let skill_filter = allowed_skills
  registry.register(
    "skills.list",
    "List available skills",
    handler=fn(_args) {
      let all_skills = @skills.discover_skills(ws_for_skills)
      let skills = filter_skills(all_skills, skill_filter)
      if skills.length() == 0 {
        return "no skills found"
      }
      let buf = StringBuilder::new()
      buf.write_string("Available skills:\n")
      for skill in skills {
        buf.write_string("  ")
        buf.write_string(skill.name)
        if skill.description.length() > 0 {
          buf.write_string(" — ")
          buf.write_string(skill.description)
        }
        buf.write_string(" [")
        buf.write_string(skill.source)
        buf.write_string("]\n")
      }
      buf.to_string()
    },
  )
  // ,skills.describe
  let ws_for_describe = workspace
  let describe_props : Map[String, Json] = Map::new()
  describe_props["name"] = @tools.string_prop("Skill name")
  let describe_params = @tools.make_params(describe_props, ["name"])
  registry.register(
    "skills.describe",
    "Show skill details",
    parameters=describe_params,
    handler=fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "skills.describe: missing name"
      }
      match @skills.load_skill_body(name, ws_for_describe) {
        Some(body) => "skill: " + name + "\n\n" + body
        None => "skill not found: " + name
      }
    },
  )
  // ,quit
  registry.register(
    "quit",
    "Exit the session",
    handler=fn(_args) { "exit" },
  )
}
