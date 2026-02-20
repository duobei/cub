/// Application runtime stub.

/// Per-session runtime holding all components.
pub struct SessionRuntime {
  agent_loop : @core.AgentLoop
  tape : @tape.TapeService
  model_runner : @core.ModelRunner
  tool_view : @tools.ProgressiveToolView
  registry : @tools.ToolRegistry
}

/// Application-level runtime managing sessions.
pub struct AppRuntime {
  settings : @config.Settings
  workspace : String
  sessions : Map[String, SessionRuntime]
  store : @tape.FileTapeStore
}

/// Create a new AppRuntime.
pub fn AppRuntime::new(
  settings : @config.Settings,
  workspace : String
) -> AppRuntime {
  ignore(settings)
  ignore(workspace)
  abort("AppRuntime::new not implemented")
}

/// Get or create a session.
pub fn AppRuntime::get_session(
  self : AppRuntime,
  session_id : String
) -> SessionRuntime {
  ignore(self)
  ignore(session_id)
  abort("AppRuntime::get_session not implemented")
}

/// Handle input for a session.
pub async fn AppRuntime::handle_input(
  self : AppRuntime,
  session_id : String,
  text : String
) -> @core.LoopResult!Error {
  ignore(self)
  ignore(session_id)
  ignore(text)
  abort("AppRuntime::handle_input not implemented")
}

/// Reset session context.
pub fn AppRuntime::reset_session_context(
  self : AppRuntime,
  session_id : String
) -> Unit {
  ignore(self)
  ignore(session_id)
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
