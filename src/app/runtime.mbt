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
/// Handle input for a session. Uses fork/merge for atomic tape writes —
/// if the process crashes mid-execution, the main tape is untouched.
pub async fn SessionRuntime::handle_input(
  self : SessionRuntime,
  text : String,
  image_urls? : Array[String] = [],
) -> @core.LoopResult {
  self.tape.fork()
  let result = self.agent_loop.handle_input(text, image_urls~)
  self.tape.merge()
  result
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
  confirm_fn : (async (String, String) -> Bool)?
  on_chunk : ((String) -> Unit)?
  mcp_clients : Array[@mcp.McpClient]
  mut p2p_peers_fn : (() -> Array[Json])?
  mut p2p_skill_list_fn : (async (String) -> Array[Json])?
  mut p2p_pull_skill_fn : (async (String, String) -> String?)?
}

///|
/// Create a new AppRuntime.
pub async fn AppRuntime::new(
  settings : @config.Settings,
  workspace : String,
  confirm_fn? : (async (String, String) -> Bool)? = None,
  on_chunk? : ((String) -> Unit)? = None,
  p2p_peers_fn? : (() -> Array[Json])? = None,
) -> AppRuntime {
  let home = settings.home.unwrap_or("\{workspace}/.cub")
  let store = @tape.FileTapeStore::new(home, workspace)
  // Migrate legacy data to genome/ (idempotent, runs once)
  ignore(@genome.migrate_to_genome(home, workspace))
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
    p2p_peers_fn,
    p2p_skill_list_fn: None,
    p2p_pull_skill_fn: None,
  }
}

///|
/// Set the P2P peers function (called after P2P channel is created).
pub fn AppRuntime::set_p2p_peers_fn(
  self : AppRuntime,
  f : () -> Array[Json],
) -> Unit {
  self.p2p_peers_fn = Some(f)
}

///|
/// Set the P2P skill list request function.
pub fn AppRuntime::set_p2p_skill_list_fn(
  self : AppRuntime,
  f : async (String) -> Array[Json],
) -> Unit {
  self.p2p_skill_list_fn = Some(f)
}

///|
/// Set the P2P pull skill request function.
pub fn AppRuntime::set_p2p_pull_skill_fn(
  self : AppRuntime,
  f : async (String, String) -> String?,
) -> Unit {
  self.p2p_pull_skill_fn = Some(f)
}

///|
/// Get or create a session.
pub async fn AppRuntime::get_session(
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
async fn detect_ollama() -> String? {
  let headers : Map[String, String] = {}
  let (resp, data) = @platform.http_get(
    "http://localhost:11434/api/tags",
    headers~,
  ) catch {
    _ => return None
  }
  if resp.code != 200 {
    return None
  }
  let text = data.text() catch { _ => return None }
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
/// Create a new session with all components wired up.
async fn AppRuntime::create_session(
  self : AppRuntime,
  session_id : String,
) -> SessionRuntime {
  // Create tape service
  let tape_name = "\{self.settings.tape_name}:\{session_slug(session_id)}"
  let tape = @tape.TapeService::new(tape_name, self.store)
  tape.ensure_bootstrap_anchor()
  // Create tool registry and register builtin tools
  let allowed = if self.settings.allowed_tools.length() > 0 {
    Some(self.settings.allowed_tools)
  } else {
    None
  }
  let registry = @tools.ToolRegistry::new(allowed_tools=allowed)
  let tool_ctx = @tools.ToolContext::new(tape, self.workspace, session_id~)
  @tools.register_builtin_tools(registry, tool_ctx)
  // Create LLM client — auto-detect Ollama if no API key configured
  // (moved before register_tape_tools so handoff handler can use it)
  let home = self.settings.home.unwrap_or("\{self.workspace}/.cub")
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
  let cost_home = home
  let cost_sid = session_id
  let on_usage : (async (Int, Int) -> Unit)? = Some(async fn(pt, ct) {
    @genome.record_usage(cost_home, cost_sid, pt, ct)
  })
  let llm = @llm.LLMClient::new(
    model,
    api_key,
    api_base~,
    max_tokens=self.settings.max_tokens,
    context_budget=self.settings.context_budget,
    handoff_threshold=self.settings.handoff_threshold,
    confirm_fn=self.confirm_fn,
    on_chunk=self.on_chunk,
    on_usage~,
  )
  // Register tape tools (with LLM for auto-summarization)
  register_tape_tools(
    registry,
    tape,
    self.workspace,
    home,
    allowed_skills=self.settings.allowed_skills,
    llm=Some(llm),
    p2p_peers_fn=self.p2p_peers_fn,
    p2p_skill_list_fn=self.p2p_skill_list_fn,
    p2p_pull_skill_fn=self.p2p_pull_skill_fn,
  )
  // Register MCP tools
  register_mcp_tools(registry, self.mcp_clients)
  // Register extension tools (script + WASM)
  register_ext_tools(registry, home, self.workspace)
  // Create tool view
  let tool_view = @tools.ProgressiveToolView::new(registry)
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
          on_usage~,
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
          on_usage~,
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
    async fn() {
      let skills = @skills.discover_skills(ws, cub_home=home)
      filter_skills(skills, self.settings.allowed_skills)
    },
    async fn(name) { @skills.load_skill_body(name, ws, cub_home=home) },
    model,
    self.settings.max_steps,
    self.settings.max_tokens,
    timeout,
    self.settings.system_prompt,
    async fn() {
      let agents = read_agents_md(ws, home~)
      let startup = read_startup_md(ws)
      let learnings = render_learnings(home)
      let parts : Array[String] = []
      if not(agents.is_empty()) {
        parts.push(agents)
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
  let learn_llm = llm
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
      llm=Some(learn_llm),
    )
    update_skill_stats(learn_home, expanded_skills, steps, error)
  })
  { session_id, agent_loop, tape, model_runner, tool_view, registry }
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
pub async fn AppRuntime::discover_skills(
  self : AppRuntime,
) -> Array[@skills.SkillMetadata] {
  let home = self.settings.home.unwrap_or("\{self.workspace}/.cub")
  @skills.discover_skills(self.workspace, cub_home=home)
}

///|
/// Load a skill body.
pub async fn AppRuntime::load_skill_body(
  self : AppRuntime,
  name : String,
) -> String? {
  let home = self.settings.home.unwrap_or("\{self.workspace}/.cub")
  @skills.load_skill_body(name, self.workspace, cub_home=home)
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
