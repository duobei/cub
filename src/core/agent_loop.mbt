/// Forward-only agent loop.

///|
/// Deterministic single-session loop built on an endless tape.
pub struct AgentLoop {
  router : InputRouter
  model_runner : ModelRunner
  tape : @tape.TapeService
  post_task_fn : async (Int, String?, Map[String, String]) -> Unit
}

///|
/// Create a new AgentLoop.
pub fn AgentLoop::new(
  router : InputRouter,
  model_runner : ModelRunner,
  tape : @tape.TapeService,
  post_task_fn? : async (Int, String?, Map[String, String]) -> Unit = fn(
    _s,
    _e,
    _sk,
  ) {

  },
) -> AgentLoop {
  { router, model_runner, tape, post_task_fn }
}

///|
/// Handle one input turn.
pub async fn AgentLoop::handle_input(
  self : AgentLoop,
  raw : String,
  image_urls? : Array[String] = [],
) -> LoopResult {
  let route = self.router.route_user(raw)
  if route.exit_requested {
    return {
      immediate_output: route.immediate_output,
      assistant_output: "",
      exit_requested: true,
      steps: 0,
      error: None,
    }
  }
  if not(route.enter_model) {
    return {
      immediate_output: route.immediate_output,
      assistant_output: "",
      exit_requested: false,
      steps: 0,
      error: None,
    }
  }
  // Enter model loop
  let model_result = self.model_runner.run(route.model_prompt, image_urls~)
  // Record loop result event
  let result_data : Map[String, Json] = Map::new()
  result_data["steps"] = model_result.steps.to_json()
  result_data["followups"] = model_result.command_followups.to_json()
  result_data["exit_requested"] = model_result.exit_requested.to_json()
  match model_result.error {
    Some(e) => result_data["error"] = e.to_json()
    None => ()
  }
  self.tape.append_event("loop.result", Json::object(result_data))
  // Post-task learning extraction
  (self.post_task_fn)(
    model_result.steps,
    model_result.error,
    self.model_runner.get_expanded_skills(),
  )
  {
    immediate_output: route.immediate_output,
    assistant_output: model_result.visible_text,
    exit_requested: model_result.exit_requested,
    steps: model_result.steps,
    error: model_result.error,
  }
}
