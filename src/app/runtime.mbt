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
  image_urls? : Array[String] = [],
) -> @core.LoopResult {
  self.agent_loop.handle_input(text, image_urls~)
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
  confirm_fn : ((String, String) -> Bool)?
  on_chunk : ((String) -> Unit)?
  mcp_clients : Array[@mcp.McpClient]
}

///|
/// Create a new AppRuntime.
pub async fn AppRuntime::new(
  settings : @config.Settings,
  workspace : String,
  confirm_fn? : ((String, String) -> Bool)? = None,
  on_chunk? : ((String) -> Unit)? = None,
) -> AppRuntime {
  let home = settings.home.unwrap_or("\{workspace}/.cub")
  let store = @tape.FileTapeStore::new(home, workspace)
  // Decay old learnings on startup
  decay_learnings(home, @async.now())
  // Load MCP servers
  let mcp_clients = load_mcp_clients(home)
  {
    settings,
    workspace,
    sessions: {},
    store,
    confirm_fn,
    on_chunk,
    mcp_clients,
  }
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
/// Detect if Ollama is running locally and return the first available model.
fn detect_ollama() -> String? {
  // Fetch http://localhost:11434/api/tags via C FFI
  let url_bytes = @config.string_to_cstr("http://localhost:11434/api/tags")
  let len = cub_http_get(url_bytes, Bytes::new(0), 0)
  if len <= 0 {
    return None
  }
  let buf = Bytes::new(len)
  let actual = cub_http_get(url_bytes, buf, len)
  if actual <= 0 {
    return None
  }
  let text = @utf8.decode_lossy(buf[:actual])
  // Parse JSON to extract first model name
  let json = @json.parse(text) catch { _ => return None }
  match json {
    { "models": Array(models), .. } =>
      if models.length() > 0 {
        match models[0] {
          { "name": String(name), .. } => Some("ollama:\{name}")
          _ => None
        }
      } else {
        None
      }
    _ => None
  }
}

///|
/// FFI: simple HTTP GET (for Ollama detection).
#borrow(url, buf)
extern "C" fn cub_http_get(url : Bytes, buf : Bytes, buf_size : Int) -> Int = "cub_http_get"

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
  // Register MCP tools
  register_mcp_tools(registry, self.mcp_clients)
  // Register extension tools (script + WASM)
  register_ext_tools(registry, home, self.workspace)
  // Create tool view
  let tool_view = @tools.ProgressiveToolView::new(registry)
  // Create LLM client — auto-detect Ollama if no API key configured
  let api_key = resolve_api_key(self.settings)
  let (model, api_base) = if api_key.is_empty() {
    match detect_ollama() {
      Some(ollama_model) => {
        @log.info("app", "no API key, auto-detected Ollama: \{ollama_model}")
        (ollama_model, Some("http://localhost:11434/v1"))
      }
      None => (self.settings.model, self.settings.api_base)
    }
  } else {
    (self.settings.model, self.settings.api_base)
  }
  let llm = @llm.LLMClient::new(
    model,
    api_key,
    api_base~,
    max_tokens=self.settings.max_tokens,
    context_budget=self.settings.context_budget,
    handoff_threshold=self.settings.handoff_threshold,
    confirm_fn=self.confirm_fn,
    on_chunk=self.on_chunk,
  )
  // Create optional vision and fast LLM clients
  let llm_vision : @llm.LLMClient? = match self.settings.model_vision {
    Some(m) =>
      Some(
        @llm.LLMClient::new(
          m,
          api_key,
          max_tokens=self.settings.max_tokens,
          context_budget=self.settings.context_budget,
          handoff_threshold=self.settings.handoff_threshold,
          confirm_fn=self.confirm_fn,
          on_chunk=self.on_chunk,
        ),
      )
    None => None
  }
  let llm_fast : @llm.LLMClient? = match self.settings.model_fast {
    Some(m) =>
      Some(
        @llm.LLMClient::new(
          m,
          api_key,
          max_tokens=self.settings.max_tokens,
          context_budget=self.settings.context_budget,
          handoff_threshold=self.settings.handoff_threshold,
          confirm_fn=self.confirm_fn,
          on_chunk=self.on_chunk,
        ),
      )
    None => None
  }
  // Create router
  let router = @core.InputRouter::new(registry, tool_view, tape, self.workspace)
  // Create model runner
  let ws = self.workspace
  let timeout : Int? = self.settings.model_timeout_seconds
  let model_runner = @core.ModelRunner::new(
    tape,
    router,
    tool_view,
    fn() {
      let skills = @skills.discover_skills(ws)
      filter_skills(skills, self.settings.allowed_skills)
    },
    fn(name) { @skills.load_skill_body(name, ws) },
    model,
    self.settings.max_steps,
    self.settings.max_tokens,
    timeout,
    self.settings.system_prompt,
    fn() {
      let agents = read_agents_md(ws)
      let memory = read_memory_md(home)
      let startup = read_startup_md(ws)
      let learnings = render_learnings(home)
      let parts : Array[String] = []
      if not(agents.is_empty()) {
        parts.push(agents)
      }
      if not(memory.is_empty()) {
        parts.push(memory)
      }
      if not(startup.is_empty()) {
        parts.push(startup)
      }
      if not(learnings.is_empty()) {
        parts.push(learnings)
      }
      parts.join("\n\n")
    },
    llm,
    registry,
    llm_vision~,
    llm_fast~,
  )
  // Create agent loop with post-task learning extraction
  let learn_home = home
  let learn_tape = tape
  let learn_ws = self.workspace
  let agent_loop = @core.AgentLoop::new(router, model_runner, tape, post_task_fn=async fn(
    steps,
    error,
    expanded_skills,
  ) {
    let entries = learn_tape.read_entries()
    let now_ms = @async.now()
    extract_learnings_from_tape(
      entries,
      steps,
      error,
      learn_home,
      now_ms,
      workspace=learn_ws,
    )
    update_skill_stats(learn_home, expanded_skills, steps, error)
  })
  { session_id, agent_loop, tape, model_runner, tool_view, registry }
}

///|
/// Save active session state to disk for resume on restart.
pub fn AppRuntime::save_active_session(
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
pub fn AppRuntime::load_active_sessions(
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

///|
/// Handle input for a session. Checks due schedules on each call.
pub async fn AppRuntime::handle_input(
  self : AppRuntime,
  session_id : String,
  text : String,
  image_urls? : Array[String] = [],
) -> @core.LoopResult {
  // Check due schedules before handling input
  let due = self.check_due_schedules()
  for msg in due {
    @log.info("schedule", "executing due task: \{msg}")
    let result = self.get_session("schedule").handle_input(msg)
    match result.error {
      Some(e) => @log.warn("schedule", "task failed: \{e}")
      None => ()
    }
  }
  let session = self.get_session(session_id)
  session.handle_input(text, image_urls~)
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
/// Export tape entries to readable markdown format.
fn export_tape_to_markdown(entries : Array[@tape.TapeEntry]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("# Tape Export\n\n")
  for entry in entries {
    match entry.kind {
      "message" =>
        match entry.payload {
          { "role": String(role), "content": String(content), .. } => {
            let heading = if role == "user" { "User" } else { "Assistant" }
            buf.write_string("### \{heading}\n\{content}\n\n")
          }
          _ => ()
        }
      "tool_call" =>
        match entry.payload {
          { "calls": Array(calls), .. } =>
            for call in calls {
              match call {
                {
                  "function": {
                    "name": String(name),
                    "arguments": String(args),
                    ..
                  },
                  ..
                } =>
                  buf.write_string(
                    "### Tool Call: \{name}\n```json\n\{args}\n```\n\n",
                  )
                _ => ()
              }
            }
          _ => ()
        }
      "tool_result" =>
        match entry.payload {
          { "results": Array(results), .. } =>
            for result in results {
              let content = match result {
                { "content": String(c), .. } => c
                _ => result.stringify()
              }
              let max_len = 500
              let truncated = if content.length() > max_len {
                "\{content[:max_len]}\n[...truncated]" catch {
                  _ => content
                }
              } else {
                content
              }
              buf.write_string("### Result\n```\n\{truncated}\n```\n\n")
            }
          _ => ()
        }
      "anchor" =>
        match entry.payload {
          { "name": String(name), .. } =>
            buf.write_string("---\n**Handoff: \{name}**\n\n")
          _ => ()
        }
      _ => ()
    }
  }
  buf.to_string()
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
/// FFI: recursively create directories.
#borrow(path)
extern "C" fn cub_mkdir_p(path : Bytes) -> Int = "cub_mkdir_p"

///|
/// Create directory recursively (sync).
fn mkdir_p_sync(path : String) -> Bool {
  let path_bytes = @config.string_to_cstr(path)
  cub_mkdir_p(path_bytes) == 0
}

///|
/// Write file content synchronously. Creates parent directories.
fn write_file_sync(path : String, content : String) -> Bool {
  // Create parent directory
  let mut last_slash = -1
  for i, ch in path {
    if ch == '/' {
      last_slash = i
    }
  }
  if last_slash > 0 {
    let parent = path[:last_slash].to_string() catch { _ => "" }
    if not(parent.is_empty()) {
      ignore(mkdir_p_sync(parent))
    }
  }
  let path_bytes = @config.string_to_cstr(path)
  let content_utf8 = @utf8.encode(content)
  cub_write_file(path_bytes, content_utf8, content_utf8.length()) >= 0
}

///|
/// FFI: make file executable (chmod +x).
#borrow(path)
extern "C" fn cub_chmod_x(path : Bytes) -> Int = "cub_chmod_x"

///|
/// FFI: remove a file or directory recursively.
#borrow(path)
extern "C" fn cub_remove_path(path : Bytes) -> Int = "cub_remove_path"

///|
/// Remove a file or directory recursively.
fn remove_path_sync(path : String) -> Bool {
  let path_bytes = @config.string_to_cstr(path)
  cub_remove_path(path_bytes) == 0
}

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
  if filename.length() < 7 {
    return filename
  }
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
  // ,tape.export
  registry.register("tape.export", "Export tape to markdown", handler=async fn(
    _args,
  ) {
    let entries = tape.read_entries()
    export_tape_to_markdown(entries)
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
    "Sessions:\n" +
    sessions.map(fn(s) { "  \{s}" }).join("\n") +
    "\n\nUse `,session <name>` to switch."
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
  // ,skill.create
  let skill_ws = workspace
  let skill_home = home
  let sc_props : Map[String, Json] = Map::new()
  sc_props["name"] = @tools.string_prop(
    "Skill name (lowercase, hyphens, e.g. 'code-review')",
  )
  sc_props["description"] = @tools.string_prop(
    "Short description for skill discovery",
  )
  sc_props["body"] = @tools.string_prop(
    "Full SKILL.md body content (instructions for the agent)",
  )
  sc_props["scope"] = @tools.string_prop(
    "Where to create: 'workspace' (default) or 'global'",
  )
  let sc_params = @tools.make_params(sc_props, ["name", "description", "body"])
  registry.register(
    "skill.create",
    "Create a new reusable skill (writes SKILL.md)",
    parameters=sc_params,
    handler=fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "skill.create: missing 'name'"
      }
      match @tools.sanitize_name(name) {
        None => return "skill.create: invalid name (must not contain / or ..)"
        Some(_) => ()
      }
      let description = match args {
        { "description": String(d), .. } => d
        _ => return "skill.create: missing 'description'"
      }
      let body = match args {
        { "body": String(b), .. } => b
        _ => return "skill.create: missing 'body'"
      }
      let scope = match args {
        { "scope": String(s), .. } => s
        _ => "workspace"
      }
      let base_dir = if scope == "global" {
        "\{skill_home}/skills"
      } else {
        "\{skill_ws}/.agent/skills"
      }
      let skill_dir = "\{base_dir}/\{name}"
      let skill_path = "\{skill_dir}/SKILL.md"
      let content = "---\nname: \{name}\ndescription: \{description}\n---\n\n\{body}\n"
      if write_file_sync(skill_path, content) {
        "created skill: \{name} at \{skill_path}"
      } else {
        "skill.create: failed to write \{skill_path}"
      }
    },
  )
  // ,tool.create
  let tc_ws = workspace
  let tc_home = home
  let tc_registry = registry
  let tc_props : Map[String, Json] = Map::new()
  tc_props["name"] = @tools.string_prop(
    "Tool name (lowercase, hyphens, e.g. 'check-pr')",
  )
  tc_props["type"] = @tools.string_prop(
    "Tool type: 'script' (bash/python executable) or 'wasm' (MoonBit plugin)",
  )
  tc_props["description"] = @tools.string_prop("Short description of the tool")
  tc_props["code"] = @tools.string_prop(
    "Source code — script content or MoonBit main.mbt source",
  )
  tc_props["parameters"] = @tools.string_prop(
    "Optional JSON Schema for tool parameters (as JSON string)",
  )
  tc_props["scope"] = @tools.string_prop(
    "Where to create: 'workspace' (default) or 'global'",
  )
  let tc_params = @tools.make_params(tc_props, [
    "name", "type", "description", "code",
  ])
  registry.register(
    "tool.create",
    "Create a new extension tool (script or WASM plugin) — self-extending",
    parameters=tc_params,
    requires_confirmation=true,
    handler=async fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "tool.create: missing 'name'"
      }
      match @tools.sanitize_name(name) {
        None => return "tool.create: invalid name (must not contain / or ..)"
        Some(_) => ()
      }
      let type_str = match args {
        { "type": String(t), .. } => t
        _ => return "tool.create: missing 'type' (script or wasm)"
      }
      let description = match args {
        { "description": String(d), .. } => d
        _ => return "tool.create: missing 'description'"
      }
      let code = match args {
        { "code": String(c), .. } => c
        _ => return "tool.create: missing 'code'"
      }
      let scope = match args {
        { "scope": String(s), .. } => s
        _ => "workspace"
      }
      let params_json : Json = match args {
        { "parameters": String(p), .. } => {
          let parsed : Json = @json.parse(p) catch {
            _ => return "tool.create: invalid parameters JSON"
          }
          parsed
        }
        _ => Json::object({})
      }
      let base_dir = if scope == "global" { tc_home } else { "\{tc_ws}/.agent" }
      match type_str {
        "script" => {
          let tool_dir = "\{base_dir}/tools"
          ignore(mkdir_p_sync(tool_dir))
          let script_path = "\{tool_dir}/\{name}.sh"
          if not(write_file_sync(script_path, code)) {
            return "tool.create: failed to write script"
          }
          // Make executable
          let path_bytes = @config.string_to_cstr(script_path)
          if cub_chmod_x(path_bytes) != 0 {
            return "tool.create: failed to chmod +x"
          }
          // Write manifest
          let manifest : Map[String, Json] = {}
          manifest["name"] = name.to_json()
          manifest["description"] = description.to_json()
          manifest["parameters"] = params_json
          let manifest_path = "\{tool_dir}/\{name}.json"
          ignore(
            write_file_sync(manifest_path, Json::object(manifest).stringify()),
          )
          // Hot-register into registry
          let tool_name = "ext.\{name}"
          let ext_path = script_path
          tc_registry.register(
            tool_name,
            description,
            parameters=params_json,
            source="extension",
            handler=async fn(call_args) {
              run_extension(@ext.ExtType::Script, ext_path, call_args)
            },
          )
          "created script tool: \{tool_name} at \{script_path}"
        }
        "wasm" => {
          let plugin_dir = "\{base_dir}/plugins/\{name}"
          let src_dir = "\{plugin_dir}/cmd/main"
          ignore(mkdir_p_sync(src_dir))
          // Write moon.mod.json
          let mod_json : Map[String, Json] = {}
          mod_json["name"] = name.to_json()
          mod_json["version"] = "0.1.0".to_json()
          ignore(
            write_file_sync(
              "\{plugin_dir}/moon.mod.json",
              Json::object(mod_json).stringify(),
            ),
          )
          // Write moon.pkg with is-main and imports (moon DSL format, not JSON)
          let pkg_content =
            #|import {
            #|  "moonbitlang/core/json",
            #|  "moonbitlang/core/env",
            #|}
            #|
            #|options(
            #|  "is-main": true,
            #|)
          ignore(write_file_sync("\{src_dir}/moon.pkg", pkg_content))
          // Write main.mbt
          if not(write_file_sync("\{src_dir}/main.mbt", code)) {
            return "tool.create: failed to write source"
          }
          // Write plugin.json manifest
          let manifest : Map[String, Json] = {}
          manifest["name"] = name.to_json()
          manifest["description"] = description.to_json()
          manifest["parameters"] = params_json
          ignore(
            write_file_sync(
              "\{plugin_dir}/plugin.json",
              Json::object(manifest).stringify(),
            ),
          )
          // Build the WASM plugin
          let (exit_code, _stdout_data, stderr_data) = @async.with_timeout(
            180_000,
            async fn() {
              @process.collect_output(
                "moon",
                ["build", "--target", "wasm-gc"],
                cwd=plugin_dir,
              )
            },
          ) catch {
            _ => return "tool.create: build timeout (180s)"
          }
          if exit_code != 0 {
            let stderr = stderr_data.text() catch { _ => "" }
            return "tool.create: build failed:\n\{stderr}"
          }
          // Find the built wasm file
          let wasm_path = @ext.find_wasm_in_plugin(plugin_dir)
          if wasm_path.is_empty() {
            return "tool.create: build succeeded but .wasm not found"
          }
          // Hot-register
          let tool_name = "ext.\{name}"
          let ext_wasm = wasm_path
          tc_registry.register(
            tool_name,
            description,
            parameters=params_json,
            source="extension",
            handler=async fn(call_args) {
              run_extension(@ext.ExtType::Wasm, ext_wasm, call_args)
            },
          )
          "created WASM tool: \{tool_name} (built at \{wasm_path})"
        }
        _ => "tool.create: type must be 'script' or 'wasm', got '\{type_str}'"
      }
    },
  )
  // ,ext.list
  let el_home = home
  let el_ws = workspace
  registry.register(
    "ext.list",
    "List installed extension tools (scripts and WASM plugins)",
    handler=fn(_args) {
      let extensions = @ext.discover_extensions(el_home, el_ws)
      if extensions.is_empty() {
        return "no extensions installed"
      }
      let lines : Array[String] = ["Extensions:"]
      for ext in extensions {
        let type_tag = match ext.ext_type {
          @ext.ExtType::Script => "script"
          @ext.ExtType::Wasm => "wasm"
        }
        lines.push(
          "  ext.\{ext.name} [\{type_tag}] [\{ext.scope}] \{ext.description}",
        )
      }
      lines.join("\n")
    },
  )
  // ,ext.remove
  let er_home = home
  let er_ws = workspace
  let er_registry = registry
  let er_props : Map[String, Json] = Map::new()
  er_props["name"] = @tools.string_prop("Extension name (without ext. prefix)")
  let er_params = @tools.make_params(er_props, ["name"])
  registry.register(
    "ext.remove",
    "Remove an installed extension tool",
    parameters=er_params,
    requires_confirmation=true,
    handler=fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "ext.remove: missing 'name'"
      }
      // Find the extension to determine path
      let extensions = @ext.discover_extensions(er_home, er_ws)
      let mut found : @ext.ExtManifest? = None
      for ext in extensions {
        if ext.name == name {
          found = Some(ext)
          break
        }
      }
      let ext = match found {
        Some(e) => e
        None => return "ext.remove: extension '\{name}' not found"
      }
      // Remove files
      match ext.ext_type {
        @ext.ExtType::Script => {
          remove_path_sync(ext.path) |> ignore
          // Also remove manifest sidecar
          let base = match ext.scope {
            "workspace" => "\{er_ws}/.agent/tools"
            _ => "\{er_home}/tools"
          }
          remove_path_sync("\{base}/\{name}.json") |> ignore
        }
        @ext.ExtType::Wasm => {
          let base = match ext.scope {
            "workspace" => "\{er_ws}/.agent/plugins"
            _ => "\{er_home}/plugins"
          }
          remove_path_sync("\{base}/\{name}") |> ignore
        }
      }
      // Unregister from registry
      er_registry.unregister("ext.\{name}")
      "removed extension: ext.\{name}"
    },
  )
  // ,agents.update
  let agents_ws = workspace
  let au_props : Map[String, Json] = Map::new()
  au_props["content"] = @tools.string_prop(
    "Full new content for AGENTS.md (replaces existing)",
  )
  au_props["append"] = @tools.string_prop(
    "Content to append to AGENTS.md (alternative to full replace)",
  )
  let au_params = @tools.make_params(au_props, [])
  registry.register(
    "agents.update",
    "Update workspace AGENTS.md to evolve agent behavior",
    parameters=au_params,
    handler=fn(args) {
      let path = "\{agents_ws}/AGENTS.md"
      match args {
        { "content": String(c), .. } => {
          // Safety: max 10KB
          if c.length() > 10240 {
            return "agents.update: content too large (max 10KB)"
          }
          if write_file_sync(path, c) {
            "updated AGENTS.md (full replace)"
          } else {
            "agents.update: write failed"
          }
        }
        { "append": String(a), .. } => {
          if a.length() > 10240 {
            return "agents.update: content too large (max 10KB)"
          }
          let existing = read_file_sync(path)
          let new_content = if existing.is_empty() {
            a
          } else {
            "\{existing}\n\n\{a}"
          }
          if new_content.length() > 10240 {
            return "agents.update: total content would exceed 10KB"
          }
          if write_file_sync(path, new_content) {
            "appended to AGENTS.md"
          } else {
            "agents.update: write failed"
          }
        }
        _ => "agents.update: provide 'content' (full replace) or 'append'"
      }
    },
  )
  // ,schedules — alias for schedule.list
  let sched_ws = workspace
  registry.register(
    "schedules",
    "List scheduled tasks (alias for schedule.list)",
    handler=fn(_args) {
      let sched_home = @config.getenv("HOME").unwrap_or("/tmp")
      let path = "\{sched_home}/.cub/schedules.json"
      let content = read_file_sync(path)
      if content.trim().to_string().is_empty() {
        return "no scheduled tasks"
      }
      let parsed : Json = @json.parse(content) catch {
        _ => return "no scheduled tasks"
      }
      match parsed {
        Array(items) => {
          if items.is_empty() {
            return "no scheduled tasks"
          }
          let lines : Array[String] = []
          for s in items {
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
            lines.push("  \{id}  [\{trigger}]  \{msg}")
          }
          "Scheduled tasks:\n" + lines.join("\n")
        }
        _ => "no scheduled tasks"
      }
    },
  )
  ignore(sched_ws)
  // ,evolution.stats
  let evo_home = home
  registry.register(
    "evolution.stats",
    "Show self-evolution metrics: learnings, skill stats, crystallized skills",
    handler=fn(_args) {
      let learnings = read_learnings(evo_home)
      let skill_stats = read_skill_stats(evo_home)
      let lines : Array[String] = ["# Evolution Stats", ""]
      // --- Learnings summary ---
      let total = learnings.length()
      let mut anti_patterns = 0
      let mut heuristics = 0
      let mut preferences = 0
      let mut active = 0 // confidence >= 0.3
      let mut max_reinforced = 0
      for entry in learnings {
        let type_ = match entry {
          { "type": String(t), .. } => t
          _ => ""
        }
        match type_ {
          "anti_pattern" => anti_patterns += 1
          "heuristic" => heuristics += 1
          "preference" => preferences += 1
          _ => ()
        }
        let confidence = match entry {
          { "confidence": Number(c, ..), .. } => c
          _ => 0.0
        }
        if confidence >= 0.3 {
          active += 1
        }
        let reinforced = match entry {
          { "reinforced": Number(r, ..), .. } => r.to_int()
          _ => 0
        }
        if reinforced > max_reinforced {
          max_reinforced = reinforced
        }
      }
      lines.push("## Learnings")
      lines.push("  total: \{total}")
      lines.push("  active (confidence >= 0.3): \{active}")
      lines.push("  anti_patterns: \{anti_patterns}")
      lines.push("  heuristics: \{heuristics}")
      lines.push("  preferences: \{preferences}")
      lines.push("  max reinforced: \{max_reinforced}")
      lines.push("")
      // --- Skill stats ---
      if not(skill_stats.is_empty()) {
        lines.push("## Skill Stats")
        for name, value in skill_stats {
          let uses = match value {
            { "uses": Number(n, ..), .. } => n.to_int()
            _ => 0
          }
          let successes = match value {
            { "successes": Number(n, ..), .. } => n.to_int()
            _ => 0
          }
          let failures = match value {
            { "failures": Number(n, ..), .. } => n.to_int()
            _ => 0
          }
          let total_steps = match value {
            { "total_steps": Number(n, ..), .. } => n.to_int()
            _ => 0
          }
          let avg_steps = if uses > 0 { total_steps / uses } else { 0 }
          lines.push(
            "  \{name}: \{uses} uses, \{successes} ok, \{failures} fail, avg \{avg_steps} steps",
          )
        }
        lines.push("")
      }
      // --- Active learnings detail ---
      if active > 0 {
        lines.push("## Active Learnings")
        let items : Array[(Double, String, String, Int)] = []
        for entry in learnings {
          let confidence = match entry {
            { "confidence": Number(c, ..), .. } => c
            _ => 0.0
          }
          if confidence < 0.3 {
            continue
          }
          let type_ = match entry {
            { "type": String(t), .. } => t
            _ => "unknown"
          }
          let content = match entry {
            { "content": String(c), .. } => c
            _ => continue
          }
          let reinforced = match entry {
            { "reinforced": Number(r, ..), .. } => r.to_int()
            _ => 0
          }
          items.push((confidence, type_, content, reinforced))
        }
        items.sort_by(fn(a, b) { b.0.compare(a.0) })
        for item in items {
          let tag = match item.1 {
            "anti_pattern" => "[avoid]"
            "heuristic" => "[effective]"
            "preference" => "[pattern]"
            _ => "[note]"
          }
          let conf_pct = (item.0 * 100.0).to_int()
          lines.push("  \{tag} \{item.2} (conf:\{conf_pct}% x\{item.3})")
        }
      }
      ignore(total)
      lines.join("\n")
    },
  )
  // ,ext.list
  let el_home = home
  let el_ws = workspace
  registry.register(
    "ext.list",
    "List installed extension tools (script + WASM)",
    handler=fn(_args) {
      let extensions = @ext.discover_extensions(el_home, el_ws)
      if extensions.is_empty() {
        return "no extensions installed"
      }
      let lines = extensions.map(fn(e) {
        let type_str = match e.ext_type {
          @ext.ExtType::Script => "script"
          @ext.ExtType::Wasm => "wasm"
        }
        "  ext.\{e.name}  [\{type_str}]  \{e.description}  (\{e.scope})"
      })
      "Extensions:\n" + lines.join("\n")
    },
  )
  // ,ext.remove
  let er_home = home
  let er_ws = workspace
  let er_registry = registry
  let er_props : Map[String, Json] = Map::new()
  er_props["name"] = @tools.string_prop(
    "Extension name to remove (without ext. prefix)",
  )
  er_props["scope"] = @tools.string_prop(
    "Scope to remove from: 'workspace' (default) or 'global'",
  )
  let er_params = @tools.make_params(er_props, ["name"])
  registry.register(
    "ext.remove",
    "Remove an installed extension tool",
    parameters=er_params,
    requires_confirmation=true,
    handler=fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "ext.remove: missing 'name'"
      }
      match @tools.sanitize_name(name) {
        None => return "ext.remove: invalid name"
        Some(_) => ()
      }
      let scope = match args {
        { "scope": String(s), .. } => s
        _ => "workspace"
      }
      let base_dir = if scope == "global" { er_home } else { "\{er_ws}/.agent" }
      // Try removing script tool
      let script_path = "\{base_dir}/tools/\{name}.sh"
      let manifest_path = "\{base_dir}/tools/\{name}.json"
      let mut removed = false
      if remove_path_sync(script_path) {
        removed = true
        ignore(remove_path_sync(manifest_path))
      }
      // Try removing WASM plugin directory
      let plugin_dir = "\{base_dir}/plugins/\{name}"
      if remove_path_sync(plugin_dir) {
        removed = true
      }
      if removed {
        // Unregister from registry
        er_registry.unregister("ext.\{name}")
        "removed extension: \{name} (\{scope})"
      } else {
        "ext.remove: extension '\{name}' not found in \{scope} scope"
      }
    },
  )
  // ,quit
  registry.register("quit", "Exit the session", handler=fn(_args) { "exit" })
}

///|
/// Read .agent/startup.md from workspace, returns empty string if not found.
fn read_startup_md(workspace : String) -> String {
  let path = "\{workspace}/.agent/startup.md"
  let text = read_file_sync(path)
  if text.is_empty() {
    return ""
  }
  "<startup_instructions>\n\{text}\n</startup_instructions>"
}

///|
/// Check and execute due scheduled tasks. Returns messages for due tasks.
/// For interval triggers, checks if enough time has elapsed since created_at_ms.
/// For date triggers, checks if the date has passed.
pub fn AppRuntime::check_due_schedules(self : AppRuntime) -> Array[String] {
  let home = self.settings.home.unwrap_or("\{self.workspace}/.cub")
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
  let due_messages : Array[String] = []
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
    let created_at_ms = match s {
      { "created_at_ms": Number(n, ..), .. } => n.to_int64()
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
          due_messages.push(message)
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
    // For cron and date triggers: keep for now (date not yet fully implemented)
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
/// Load MCP client configurations and start servers.
async fn load_mcp_clients(home : String) -> Array[@mcp.McpClient] {
  let clients : Array[@mcp.McpClient] = []
  // Try loading from ~/.cub/mcp.json
  let config_path = "\{home}/mcp.json"
  let config_content = read_file_sync(config_path)
  let configs = if config_content.length() > 0 {
    @mcp.load_mcp_configs(config_content)
  } else {
    // Try CUB_MCP_SERVERS env var
    match @config.getenv("CUB_MCP_SERVERS") {
      Some(s) => @mcp.load_mcp_configs(s)
      None => []
    }
  }
  for config in configs {
    let client = @mcp.McpClient::new(config)
    let started = client.start()
    if started {
      ignore(client.discover_tools())
      clients.push(client)
    }
  }
  clients
}

///|
/// Register MCP tools into a tool registry.
fn register_mcp_tools(
  registry : @tools.ToolRegistry,
  mcp_clients : Array[@mcp.McpClient],
) -> Unit {
  for client in mcp_clients {
    let server_name = client.config.name
    for tool in client.tools {
      let tool_name = "mcp.\{server_name}.\{tool.name}"
      let mcp_tool_name = tool.name
      let mcp_client = client
      registry.register(
        tool_name,
        tool.description,
        parameters=tool.input_schema,
        handler=async fn(args) { mcp_client.call_tool(mcp_tool_name, args) },
      )
    }
  }
}

// ── Extension tools (script + WASM) ──

///|
/// Register discovered extension tools into the registry.
fn register_ext_tools(
  registry : @tools.ToolRegistry,
  home : String,
  workspace : String,
) -> Unit {
  let extensions = @ext.discover_extensions(home, workspace)
  for ext in extensions {
    let tool_name = "ext.\{ext.name}"
    let ext_type = ext.ext_type
    let ext_path = ext.path
    registry.register(
      tool_name,
      ext.description,
      parameters=ext.parameters,
      source="extension",
      handler=async fn(args) { run_extension(ext_type, ext_path, args) },
    )
  }
}

///|
/// Execute an extension (script or WASM plugin).
async fn run_extension(
  ext_type : @ext.ExtType,
  path : String,
  args : Json,
) -> String {
  let args_str = args.stringify()
  let timeout = 30_000
  let (exit_code, stdout_data, stderr_data) = @async.with_timeout(timeout, async fn() {
    match ext_type {
      @ext.ExtType::Script => @process.collect_output(path, [args_str])
      @ext.ExtType::Wasm =>
        @process.collect_output("moonrun", [path, "--", args_str])
    }
  }) catch {
    _ => return "extension timeout after 30s"
  }
  let stdout = stdout_data.text() catch { _ => "" }
  if exit_code != 0 {
    let stderr = stderr_data.text() catch { _ => "" }
    return "extension error (exit \{exit_code}): \{stderr}"
  }
  stdout
}

// ── Learning extraction and persistence ──

///|
/// Read learnings from ~/.cub/learnings.json.
pub fn read_learnings(home : String) -> Array[Json] {
  let path = "\{home}/learnings.json"
  let content = read_file_sync(path)
  if content.is_empty() {
    return []
  }
  let parsed : Json = @json.parse(content) catch { _ => return [] }
  match parsed {
    Json::Array(arr) => arr
    _ => []
  }
}

///|
/// Render learnings as a prompt section for system prompt injection.
/// Only includes learnings with confidence >= 0.3, sorted by confidence desc.
pub fn render_learnings(home : String) -> String {
  let learnings = read_learnings(home)
  if learnings.is_empty() {
    return ""
  }
  // Filter and sort by confidence
  let items : Array[(Double, String, String)] = []
  for entry in learnings {
    let confidence = match entry {
      { "confidence": Json::Number(c, ..), .. } => c
      _ => 0.0
    }
    if confidence < 0.3 {
      continue
    }
    let type_ = match entry {
      { "type": Json::String(t), .. } => t
      _ => "unknown"
    }
    let content = match entry {
      { "content": Json::String(c), .. } => c
      _ => continue
    }
    items.push((confidence, type_, content))
  }
  if items.is_empty() {
    return ""
  }
  // Sort by confidence descending
  items.sort_by(fn(a, b) { b.0.compare(a.0) })
  // Render
  let lines : Array[String] = ["# Learnings from past tasks"]
  for item in items {
    let tag = match item.1 {
      "anti_pattern" => "[avoid]"
      "heuristic" => "[effective]"
      "preference" => "[pattern]"
      _ => "[note]"
    }
    lines.push("- \{tag} \{item.2}")
  }
  lines.join("\n")
}

///|
/// Write learnings to ~/.cub/learnings.json.
pub fn write_learnings(home : String, learnings : Array[Json]) -> Bool {
  let path = "\{home}/learnings.json"
  let json_str = Json::array(learnings).stringify()
  write_file_sync(path, json_str)
}

///|
/// Check if two learning contents are similar (substring containment or word overlap).
pub fn learnings_similar(a : String, b : String) -> Bool {
  if a.is_empty() || b.is_empty() {
    return false
  }
  let a_lower = a.to_lower()
  let b_lower = b.to_lower()
  // Substring containment (only for strings longer than 10 chars)
  if a_lower.length() > 10 && b_lower.length() > 10 {
    if a_lower.contains(b_lower) || b_lower.contains(a_lower) {
      return true
    }
  }
  // Word overlap: Jaccard >= 0.6
  let a_words = split_words(a_lower)
  let b_words = split_words(b_lower)
  if a_words.is_empty() || b_words.is_empty() {
    return false
  }
  let mut intersection = 0
  for w in a_words {
    for bw in b_words {
      if w == bw {
        intersection += 1
        break
      }
    }
  }
  let union = a_words.length() + b_words.length() - intersection
  if union == 0 {
    return false
  }
  // Jaccard similarity >= 0.6
  intersection * 10 >= union * 6
}

///|
/// Split a string into words (simple whitespace + punctuation split).
fn split_words(s : String) -> Array[String] {
  let words : Array[String] = []
  let buf = StringBuilder::new()
  for ch in s {
    if ch == ' ' ||
      ch == ',' ||
      ch == '.' ||
      ch == ':' ||
      ch == ';' ||
      ch == '(' ||
      ch == ')' ||
      ch == '[' ||
      ch == ']' {
      let word = buf.to_string().trim().to_string()
      if not(word.is_empty()) {
        words.push(word)
      }
      buf.reset()
    } else {
      buf.write_char(ch)
    }
  }
  let last = buf.to_string().trim().to_string()
  if not(last.is_empty()) {
    words.push(last)
  }
  words
}

///|
/// Add a learning with dedup-as-reinforcement.
/// Returns the proposed skill name if a learning was reinforced enough for crystallization.
pub fn add_learning(
  home : String,
  type_ : String,
  content : String,
  now_ms : Int64,
) -> String? {
  let learnings = read_learnings(home)
  // Check for similar existing learning
  for i, entry in learnings {
    match entry {
      {
        "content": Json::String(existing),
        "reinforced": Json::Number(r, ..),
        ..
      } =>
        if learnings_similar(content, existing) {
          // Reinforce: increment reinforced, update last_used
          let new_reinforced = r.to_int() + 1
          let updated : Map[String, Json] = {}
          updated["type"] = match entry {
            { "type": t, .. } => t
            _ => type_.to_json()
          }
          updated["content"] = existing.to_json()
          updated["confidence"] = match entry {
            { "confidence": c, .. } => c
            _ => 0.7.to_json()
          }
          updated["reinforced"] = new_reinforced.to_json()
          updated["last_used"] = now_ms.to_double().to_json()
          updated["created_at"] = match entry {
            { "created_at": c, .. } => c
            _ => now_ms.to_double().to_json()
          }
          learnings[i] = Json::object(updated)
          ignore(write_learnings(home, learnings))
          // Check if crystallization threshold reached
          if new_reinforced >= 3 {
            return Some(existing)
          }
          return None
        }
      _ => ()
    }
  }
  // New learning
  let entry : Map[String, Json] = {}
  entry["type"] = type_.to_json()
  entry["content"] = content.to_json()
  entry["confidence"] = 0.7.to_json()
  entry["reinforced"] = (1).to_json()
  entry["last_used"] = now_ms.to_double().to_json()
  entry["created_at"] = now_ms.to_double().to_json()
  learnings.push(Json::object(entry))
  ignore(write_learnings(home, learnings))
  None
}

///|
/// Decay learnings confidence based on time since last use.
/// Prunes entries with confidence < 0.1.
pub fn decay_learnings(home : String, now_ms : Int64) -> Unit {
  let learnings = read_learnings(home)
  if learnings.is_empty() {
    return
  }
  let ms_per_week : Int64 = 7L * 24L * 60L * 60L * 1000L
  let surviving : Array[Json] = []
  for entry in learnings {
    match entry {
      {
        "confidence": Json::Number(conf, ..),
        "last_used": Json::Number(lu, ..),
        ..
      } => {
        let last_used_ms = lu.to_int64()
        let elapsed_ms = now_ms - last_used_ms
        let weeks = if elapsed_ms > 0L {
          (elapsed_ms / ms_per_week).to_int()
        } else {
          0
        }
        // Apply decay: confidence *= 0.905^weeks (approximation of e^(-0.1*weeks))
        let mut new_conf = conf
        for _i = 0; _i < weeks; _i = _i + 1 {
          new_conf = new_conf * 0.905
        }
        if new_conf >= 0.1 {
          let updated : Map[String, Json] = {}
          // Copy all fields, update confidence
          match entry {
            { "type": t, .. } => updated["type"] = t
            _ => ()
          }
          match entry {
            { "content": c, .. } => updated["content"] = c
            _ => ()
          }
          updated["confidence"] = new_conf.to_json()
          match entry {
            { "reinforced": r, .. } => updated["reinforced"] = r
            _ => ()
          }
          match entry {
            { "last_used": l, .. } => updated["last_used"] = l
            _ => ()
          }
          match entry {
            { "created_at": c, .. } => updated["created_at"] = c
            _ => ()
          }
          surviving.push(Json::object(updated))
        }
      }
      _ => surviving.push(entry)
    }
  }
  // Always write back — confidence values may have been updated even if no entries pruned
  ignore(write_learnings(home, surviving))
}

///|
/// Extract learnings from tape after task completion (zero-token, no LLM).
pub fn extract_learnings_from_tape(
  entries : Array[@tape.TapeEntry],
  steps : Int,
  error : String?,
  home : String,
  now_ms : Int64,
  workspace? : String = "",
) -> Unit {
  // Collect tool calls since last anchor
  let tool_names : Array[String] = []
  let mut last_anchor_idx = -1
  for i, entry in entries {
    if entry.kind == "anchor" {
      last_anchor_idx = i
    }
  }
  let start_idx = if last_anchor_idx >= 0 { last_anchor_idx + 1 } else { 0 }
  for i = start_idx; i < entries.length(); i = i + 1 {
    let entry = entries[i]
    if entry.kind == "tool_call" {
      match entry.payload {
        { "calls": Json::Array(calls), .. } =>
          for call in calls {
            match call {
              { "function": { "name": Json::String(n), .. }, .. } =>
                tool_names.push(n)
              _ => ()
            }
          }
        _ => ()
      }
    }
  }
  if tool_names.is_empty() {
    return
  }
  // Detect patterns
  match error {
    Some(err) => {
      // Task failed — record anti-pattern with truncated tool list
      let unique_tools : Array[String] = []
      for name in tool_names {
        if not(unique_tools.contains(name)) {
          unique_tools.push(name)
        }
      }
      let tools_display = if unique_tools.length() > 5 {
        let first5 = unique_tools[:5].to_array()
        first5.join(", ") + " (+\{unique_tools.length() - 5} more)"
      } else {
        unique_tools.join(", ")
      }
      // Truncate error message
      let err_short = if err.length() > 100 {
        let truncated = err[:100].to_string() catch { _ => err }
        truncated + "..."
      } else {
        err
      }
      let content = "Task failed after \{steps} steps using [\{tools_display}]: \{err_short}"
      match add_learning(home, "anti_pattern", content, now_ms) {
        Some(c) =>
          if not(workspace.is_empty()) {
            ignore(crystallize_skill(workspace, "anti_pattern", c))
          }
        None => ()
      }
    }
    None => {
      // Task succeeded
      if steps <= 3 && tool_names.length() > 0 {
        // Efficient completion — deduplicate and cap at 5 unique tools
        let unique_tools : Array[String] = []
        for name in tool_names {
          if not(unique_tools.contains(name)) {
            unique_tools.push(name)
          }
        }
        let display = if unique_tools.length() > 5 {
          let first5 = unique_tools[:5].to_array()
          first5.join(", ") + " (+\{unique_tools.length() - 5} more)"
        } else {
          unique_tools.join(", ")
        }
        let content = "Efficient: completed in \{steps} steps via \{display}"
        match add_learning(home, "heuristic", content, now_ms) {
          Some(c) =>
            if not(workspace.is_empty()) {
              ignore(crystallize_skill(workspace, "heuristic", c))
            }
          None => ()
        }
      }
      // Detect repeated consecutive tool usage (5+ same tool in a row)
      // Skip generic tools (bash, fs_read) — they're too common to be useful
      let generic_tools = ["bash", "fs_read", "fs.read", "grep"]
      let mut run_start = 0
      for i = 1; i <= tool_names.length(); i = i + 1 {
        if i == tool_names.length() || tool_names[i] != tool_names[run_start] {
          let run_len = i - run_start
          let tool = tool_names[run_start]
          if run_len >= 5 && not(generic_tools.contains(tool)) {
            let content = "Pattern: \{tool} called \{run_len} times consecutively"
            match add_learning(home, "preference", content, now_ms) {
              Some(c) =>
                if not(workspace.is_empty()) {
                  ignore(crystallize_skill(workspace, "preference", c))
                }
              None => ()
            }
          }
          run_start = i
        }
      }
    }
  }
}

///|
/// Read skill stats from ~/.cub/skill_stats.json.
pub fn read_skill_stats(home : String) -> Map[String, Json] {
  let path = "\{home}/skill_stats.json"
  let content = read_file_sync(path)
  if content.is_empty() {
    return {}
  }
  let parsed : Json = @json.parse(content) catch { _ => return {} }
  match parsed {
    Json::Object(obj) => obj
    _ => {}
  }
}

///|
/// Write skill stats to ~/.cub/skill_stats.json.
pub fn write_skill_stats(home : String, stats : Map[String, Json]) -> Bool {
  let path = "\{home}/skill_stats.json"
  let json_str = Json::object(stats).stringify()
  write_file_sync(path, json_str)
}

///|
/// Update skill stats after a task completes.
/// Records usage count, success/failure, and average steps.
pub fn update_skill_stats(
  home : String,
  expanded_skills : Map[String, String],
  steps : Int,
  error : String?,
) -> Unit {
  if expanded_skills.is_empty() {
    return
  }
  let stats = read_skill_stats(home)
  for name, _ in expanded_skills {
    let entry = match stats.get(name) {
      Some(Json::Object(obj)) => obj
      _ => {
        let m : Map[String, Json] = {}
        m["uses"] = (0).to_json()
        m["successes"] = (0).to_json()
        m["failures"] = (0).to_json()
        m["total_steps"] = (0).to_json()
        m
      }
    }
    // Increment counts
    let uses = match entry.get("uses") {
      Some(Json::Number(n, ..)) => n.to_int() + 1
      _ => 1
    }
    entry["uses"] = uses.to_json()
    match error {
      None => {
        let s = match entry.get("successes") {
          Some(Json::Number(n, ..)) => n.to_int() + 1
          _ => 1
        }
        entry["successes"] = s.to_json()
      }
      Some(_) => {
        let f = match entry.get("failures") {
          Some(Json::Number(n, ..)) => n.to_int() + 1
          _ => 1
        }
        entry["failures"] = f.to_json()
      }
    }
    let total = match entry.get("total_steps") {
      Some(Json::Number(n, ..)) => n.to_int() + steps
      _ => steps
    }
    entry["total_steps"] = total.to_json()
    stats[name] = Json::object(entry)
  }
  write_skill_stats(home, stats) |> ignore
}

///|
/// Generate a skill name from learning content.
pub fn skill_name_from_content(content : String) -> String {
  let words = split_words(content.to_lower())
  // Take up to 3 meaningful words, skip common ones
  let skip = [
    "the", "a", "an", "in", "via", "to", "is", "of", "and", "or", "for",
  ]
  let parts : Array[String] = []
  for word in words {
    if parts.length() >= 3 {
      break
    }
    if word.length() > 2 && not(skip.contains(word)) {
      parts.push(word)
    }
  }
  if parts.is_empty() {
    return "auto-skill"
  }
  let joined = parts.join("-")
  "auto-\{joined}"
}

///|
/// Crystallize a learning into a skill file.
/// Creates .agent/skills/auto-{name}/SKILL.md from a reinforced learning.
pub fn crystallize_skill(
  workspace : String,
  type_ : String,
  content : String,
) -> String? {
  let name = skill_name_from_content(content)
  match @tools.sanitize_name(name) {
    None => return None
    Some(_) => ()
  }
  let skill_dir = "\{workspace}/.agent/skills/\{name}"
  let skill_path = "\{skill_dir}/SKILL.md"
  // Don't overwrite existing skills
  let existing = read_file_sync(skill_path)
  if not(existing.is_empty()) {
    return None
  }
  let tag = match type_ {
    "anti_pattern" => "Avoid this pattern"
    "heuristic" => "Effective approach"
    "preference" => "Preferred pattern"
    _ => "Learned pattern"
  }
  let body = "---\nname: \{name}\ndescription: \{tag} - crystallized from repeated experience\n---\n\n## \{tag}\n\n\{content}\n\nThis skill was auto-crystallized from repeated task patterns.\n"
  if write_file_sync(skill_path, body) {
    Some(name)
  } else {
    None
  }
}
