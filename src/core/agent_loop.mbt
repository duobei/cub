/// Forward-only agent loop stub.

/// Deterministic single-session loop built on an endless tape.
pub struct AgentLoop {
  router : InputRouter
  model_runner : ModelRunner
  tape : @tape.TapeService
}

/// Create a new AgentLoop.
pub fn AgentLoop::new(
  router : InputRouter,
  model_runner : ModelRunner,
  tape : @tape.TapeService
) -> AgentLoop {
  { router, model_runner, tape }
}

/// Handle one input turn.
pub async fn AgentLoop::handle_input(
  self : AgentLoop,
  raw : String
) -> LoopResult!Error {
  ignore(self)
  ignore(raw)
  abort("AgentLoop::handle_input not implemented")
}
