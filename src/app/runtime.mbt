/// Application runtime and session management.

///|
/// Per-session runtime holding all components.
pub struct SessionRuntime {
  session_id : String
  agent_loop : @core.AgentLoop
  tape : @tape.TapeService
  model_runner : @core.ModelRunner
  tool_view : @tools.ProgressiveToolView
  registry : @tools.ToolRegistry
}

///|
/// Handle input for a session.
pub async fn SessionRuntime::handle_input(
  self : SessionRuntime,
  text : String,
) -> @core.LoopResult {
  self.agent_loop.handle_input(text)
}

///|
/// Reset volatile in-memory context.
pub fn SessionRuntime::reset_context(self : SessionRuntime) -> Unit {
  self.model_runner.reset_context()
  self.tool_view.reset()
}

///|
/// Application-level runtime managing sessions.
pub struct AppRuntime {
  settings : @config.Settings
  workspace : String
  sessions : Map[String, SessionRuntime]
  store : @tape.FileTapeStore
}

///|
/// Create a new AppRuntime.
pub async fn AppRuntime::new(
  settings : @config.Settings,
  workspace : String,
) -> AppRuntime {
  let home = settings.home.unwrap_or("\{workspace}/.cub")
  let store = @tape.FileTapeStore::new(home, workspace)
  { settings, workspace, sessions: {}, store }
}

///|
/// Get or create a session.
pub fn AppRuntime::get_session(
  self : AppRuntime,
  session_id : String,
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

///|
/// Resolve API key from settings priority chain.
fn resolve_api_key(settings : @config.Settings) -> String {
  match settings.api_key {
    Some(k) => k
    None =>
      match settings.openrouter_api_key {
        Some(k) => k
        None => settings.llm_api_key.unwrap_or("")
      }
  }
}

///|
/// Create a new session with all components wired up.
fn AppRuntime::create_session(
  self : AppRuntime,
  session_id : String,
) -> SessionRuntime {
  // Create tape service
  let tape_name = "\{self.settings.tape_name}:\{session_slug(session_id)}"
  let tape = @tape.TapeService::new(tape_name, self.store)
  // Create tool registry and register builtin tools
  let allowed = if self.settings.allowed_tools.length() > 0 {
    Some(self.settings.allowed_tools)
  } else {
    None
  }
  let registry = @tools.ToolRegistry::new(allowed_tools=allowed)
  let tool_ctx = @tools.ToolContext::new(tape, self.workspace, session_id~)
  @tools.register_builtin_tools(registry, tool_ctx)
  // Register tape tools
  let home = self.settings.home.unwrap_or("\{self.workspace}/.cub")
  register_tape_tools(
    registry,
    tape,
    self.workspace,
    home,
    allowed_skills=self.settings.allowed_skills,
  )
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
      filter_skills(skills, self.settings.allowed_skills)
    },
    fn(name) { @skills.load_skill_body(name, ws) },
    self.settings.model,
    self.settings.max_steps,
    self.settings.max_tokens,
    timeout,
    self.settings.system_prompt,
    fn() {
      let agents = read_agents_md(ws)
      let memory = read_memory_md(home)
      if agents.is_empty() {
        memory
      } else if memory.is_empty() {
        agents
      } else {
        "\{agents}\n\n\{memory}"
      }
    },
    llm,
    registry,
  )
  // Create agent loop
  let agent_loop = @core.AgentLoop::new(router, model_runner, tape)
  { session_id, agent_loop, tape, model_runner, tool_view, registry }
}

///|
/// Handle input for a session.
pub async fn AppRuntime::handle_input(
  self : AppRuntime,
  session_id : String,
  text : String,
) -> @core.LoopResult {
  let session = self.get_session(session_id)
  session.handle_input(text)
}

///|
/// Reset session context.
pub fn AppRuntime::reset_session_context(
  self : AppRuntime,
  session_id : String,
) -> Unit {
  match self.sessions.get(session_id) {
    Some(s) => s.reset_context()
    None => ()
  }
}

///|
/// Discover skills for this workspace.
pub fn AppRuntime::discover_skills(
  self : AppRuntime,
) -> Array[@skills.SkillMetadata] {
  @skills.discover_skills(self.workspace)
}

///|
/// Load a skill body.
pub fn AppRuntime::load_skill_body(self : AppRuntime, name : String) -> String? {
  @skills.load_skill_body(name, self.workspace)
}

///|
/// Generate a short slug from session_id for tape file naming.
fn session_slug(session_id : String) -> String {
  let mut hash : UInt = 2166136261
  for i = 0; i < session_id.length(); i = i + 1 {
    hash = hash ^ session_id[i].to_uint()
    hash = hash * 16777619
  }
  uint_to_hex(hash)
}

///|
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

///|
/// Filter skills by allowed list (empty = allow all).
fn filter_skills(
  skills : Array[@skills.SkillMetadata],
  allowed : Array[String],
) -> Array[@skills.SkillMetadata] {
  if allowed.is_empty() {
    return skills
  }
  skills.filter(fn(s) { allowed.contains(s.name) })
}

///|
/// Read AGENTS.md from workspace root, returns empty string if not found.
fn read_agents_md(workspace : String) -> String {
  let path = "\{workspace}/AGENTS.md"
  let text = read_file_sync(path)
  if text.is_empty() {
    return ""
  }
  "<workspace_instructions>\n\{text}\n</workspace_instructions>"
}

///|
/// Synchronous file read via C FFI two-pass pattern.
fn read_file_sync(path : String) -> String {
  let path_bytes = @config.string_to_cstr(path)
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

///|
/// FFI: read file into buffer, returns size or -1 on error.
#borrow(path, buf)
extern "C" fn cub_read_file(path : Bytes, buf : Bytes, buf_size : Int) -> Int = "cub_read_file"

///|
/// FFI: write data to file, returns bytes written or -1 on error.
#borrow(path, data)
extern "C" fn cub_write_file(path : Bytes, data : Bytes, data_len : Int) -> Int = "cub_write_file"

///|
/// FFI: list directory entries as newline-separated string.
#borrow(path, buf)
extern "C" fn cub_list_dir(path : Bytes, buf : Bytes, buf_size : Int) -> Int = "cub_list_dir"

///|
/// List files in a directory synchronously.
fn list_dir_sync(path : String) -> Array[String] {
  let path_bytes = @config.string_to_cstr(path)
  let len = cub_list_dir(path_bytes, Bytes::new(0), 0)
  if len <= 0 {
    return []
  }
  let buf = Bytes::new(len)
  let actual = cub_list_dir(path_bytes, buf, len)
  if actual <= 0 {
    return []
  }
  let text = @utf8.decode_lossy(buf[:actual])
  let entries : Array[String] = []
  for part in text.split("\n") {
    let s = part.to_string()
    if not(s.is_empty()) {
      entries.push(s)
    }
  }
  entries
}

///|
/// Decode tape filename back to tape name.
/// Format: {workspace_hash}__{url_encoded_name}.jsonl → name
fn decode_tape_filename(filename : String) -> String {
  // Strip .jsonl suffix
  let base = filename[:filename.length() - 6].to_string() catch {
    _ => return filename
  }
  // Find __ separator
  let mut sep_pos = -1
  for i = 0; i < base.length() - 1; i = i + 1 {
    if base[i] == '_'.to_int().to_uint16() &&
      i + 1 < base.length() &&
      base[i + 1] == '_'.to_int().to_uint16() {
      sep_pos = i
      break
    }
  }
  if sep_pos < 0 {
    return base
  }
  // Get the encoded name part after __
  let encoded = base[sep_pos + 2:].to_string() catch { _ => return base }
  // Simple URL decode: %XX → char
  url_decode(encoded)
}

///|
/// Simple URL percent-decode.
fn url_decode(s : String) -> String {
  let buf = StringBuilder::new()
  let mut i = 0
  while i < s.length() {
    if s[i] == '%'.to_int().to_uint16() && i + 2 < s.length() {
      let hi = hex_digit(s[i + 1])
      let lo = hex_digit(s[i + 2])
      if hi >= 0 && lo >= 0 {
        buf.write_char((hi * 16 + lo).unsafe_to_char())
        i += 3
        continue
      }
    }
    buf.write_char(s[i].to_int().unsafe_to_char())
    i += 1
  }
  buf.to_string()
}

///|
/// Convert hex digit to int, -1 if invalid.
fn hex_digit(ch : UInt16) -> Int {
  let c = ch.to_int()
  if c >= 48 && c <= 57 {
    return c - 48
  } // 0-9
  if c >= 65 && c <= 70 {
    return c - 55
  } // A-F
  if c >= 97 && c <= 102 {
    return c - 87
  } // a-f
  -1
}

///|
/// Read MEMORY.md from home directory, returns empty string if not found.
fn read_memory_md(home : String) -> String {
  let path = "\{home}/MEMORY.md"
  let text = read_file_sync(path)
  if text.is_empty() {
    return ""
  }
  "<workspace_memory>\n\{text}\n</workspace_memory>"
}

///|
/// Register tape-related internal tools (help, tools, tape.info, etc.).
fn register_tape_tools(
  registry : @tools.ToolRegistry,
  tape : @tape.TapeService,
  workspace : String,
  home : String,
  allowed_skills? : Array[String] = [],
) -> Unit {
  // ,help
  registry.register("help", "Show available commands", handler=fn(_args) {
    let rows = registry.compact_rows()
    "Available commands:\n" + rows.map(fn(r) { "  ,\{r}" }).join("\n")
  })
  // ,tools
  registry.register("tools", "List available tools", handler=fn(_args) {
    let rows = registry.compact_rows()
    rows.join("\n")
  })
  // ,tool.describe
  let describe_registry = registry
  let td_props : Map[String, Json] = Map::new()
  td_props["name"] = @tools.string_prop("Tool name to describe")
  let td_params = @tools.make_params(td_props, ["name"])
  registry.register(
    "tool.describe",
    "Show tool details and parameter schema",
    parameters=td_params,
    handler=fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "tool.describe: missing name"
      }
      // Try exact match first, then model name
      let descriptors = describe_registry.descriptors()
      let mut found : @tools.ToolDescriptor? = None
      for d in descriptors {
        if d.name == name || @tools.to_model_name(d.name) == name {
          found = Some(d)
          break
        }
      }
      match found {
        None => "tool not found: \{name}"
        Some(d) => {
          let buf = StringBuilder::new()
          buf.write_string("Tool: ")
          buf.write_string(d.name)
          buf.write_string("\nDescription: ")
          buf.write_string(d.short_description)
          if d.detail.length() > 0 {
            buf.write_string("\nDetail: ")
            buf.write_string(d.detail)
          }
          buf.write_string("\nSource: ")
          buf.write_string(d.source)
          buf.write_string("\nParameters:\n")
          buf.write_string(d.tool.parameters.stringify())
          buf.to_string()
        }
      }
    },
  )
  // ,tape.info
  registry.register("tape.info", "Show tape status", handler=async fn(_args) {
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
  })
  // ,handoff
  let props : Map[String, Json] = Map::new()
  props["name"] = @tools.string_prop("Handoff name (e.g. 'refactor/phase2')")
  props["summary"] = @tools.string_prop("Current task status — what was done")
  props["context"] = @tools.string_prop(
    "Key context to carry forward (files, decisions)",
  )
  props["next_steps"] = @tools.string_prop("What should happen next")
  props["task"] = @tools.string_prop("Current task description")
  let handoff_params = @tools.make_params(props, ["name"])
  registry.register(
    "handoff",
    "Create a stage transition — carry forward state, not history",
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
      match args {
        { "context": String(c), .. } => state["context"] = c.to_json()
        _ => ()
      }
      match args {
        { "next_steps": String(ns), .. } => state["next_steps"] = ns.to_json()
        _ => ()
      }
      match args {
        { "task": String(t), .. } => state["task"] = t.to_json()
        _ => ()
      }
      ignore(tape.handoff(name, state=Some(state)))
      "handoff: \{name}"
    },
  )
  // ,anchors
  registry.register("anchors", "List anchor points", handler=async fn(_args) {
    let anchors = tape.anchors()
    if anchors.is_empty() {
      return "no anchors"
    }
    anchors.map(fn(a) { a.name }).join("\n")
  })
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
      if results.is_empty() {
        return "no results"
      }
      results.map(fn(e) { "\{e.kind}: \{e.payload.stringify()}" }).join("\n")
    },
  )
  // ,tape.reset
  registry.register("tape.reset", "Reset the tape", handler=async fn(args) {
    let archive = match args {
      { "archive": String(a), .. } => a == "true"
      _ => false
    }
    tape.reset(archive~)
  })
  // ,skills.list
  let ws_for_skills = workspace
  let skill_filter = allowed_skills
  registry.register("skills.list", "List available skills", handler=fn(_args) {
    let all_skills = @skills.discover_skills(ws_for_skills)
    let skills = filter_skills(all_skills, skill_filter)
    if skills.is_empty() {
      return "no skills found"
    }
    let lines = skills.map(fn(s) {
      let desc = if s.description.length() > 0 {
        " — \{s.description}"
      } else {
        ""
      }
      "  \{s.name}\{desc} [\{s.source}]"
    })
    "Available skills:\n" + lines.join("\n")
  })
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
        Some(body) => "skill: \{name}\n\n\{body}"
        None => "skill not found: \{name}"
      }
    },
  )
  // ,sessions
  let sessions_home = home
  registry.register("sessions", "List tape sessions in this workspace", handler=fn(
    _args,
  ) {
    let tape_dir = "\{sessions_home}/tapes"
    let files = list_dir_sync(tape_dir)
    let sessions : Array[String] = []
    for file in files {
      if file.length() > 6 {
        // Check for .jsonl suffix
        let has_suffix = try
          file[file.length() - 6:].to_string() == ".jsonl"
        catch {
          _ => false
        }
        if has_suffix {
          // Extract tape name from filename: {hash}__{name}.jsonl
          let name = decode_tape_filename(file)
          sessions.push(name)
        }
      }
    }
    if sessions.is_empty() {
      return "no sessions found"
    }
    "Sessions:\n" + sessions.map(fn(s) { "  \{s}" }).join("\n")
  })
  // ,memory.read
  let mem_home_read = home
  registry.register(
    "memory.read",
    "Read persistent workspace memory (MEMORY.md)",
    handler=fn(_args) {
      let text = read_file_sync("\{mem_home_read}/MEMORY.md")
      if text.is_empty() {
        "no memory saved yet"
      } else {
        text
      }
    },
  )
  // ,memory.save
  let mem_home_save = home
  let mem_props : Map[String, Json] = Map::new()
  mem_props["content"] = @tools.string_prop(
    "Content to save — facts, conventions, preferences (not conversation summaries)",
  )
  let mem_params = @tools.make_params(mem_props, ["content"])
  registry.register(
    "memory.save",
    "Save persistent facts to workspace memory (MEMORY.md) — survives across sessions",
    parameters=mem_params,
    handler=fn(args) {
      let content = match args {
        { "content": String(c), .. } => c
        _ => return "memory.save: missing content"
      }
      let path = "\{mem_home_save}/MEMORY.md"
      // Read existing content and append
      let existing = read_file_sync(path)
      let new_content = if existing.is_empty() {
        "# Workspace Memory\n\n\{content}\n"
      } else {
        "\{existing}\n\{content}\n"
      }
      let bytes = @config.string_to_cstr(path)
      let content_bytes = @utf8.encode(new_content)
      let result = cub_write_file(bytes, content_bytes, content_bytes.length())
      if result < 0 {
        "memory.save: write failed"
      } else {
        "saved to MEMORY.md"
      }
    },
  )
  // ,quit
  registry.register("quit", "Exit the session", handler=fn(_args) { "exit" })
}
