/// Model turn runner stub.

/// Runs assistant loop over tape with command-aware follow-up handling.
pub struct ModelRunner {
  tape : @tape.TapeService
  router : InputRouter
  tool_view : @tools.ProgressiveToolView
  tools : Array[Json]
  list_skills : () -> Array[@skills.SkillMetadata]
  load_skill_body : (String) -> String?
  model : String
  max_steps : Int
  max_tokens : Int
  model_timeout_seconds : Int?
  base_system_prompt : String
  get_workspace_system_prompt : () -> String
  llm : @llm.LLMClient
  registry : @tools.ToolRegistry
  expanded_skills : Map[String, String]
}

/// Create a new ModelRunner.
pub fn ModelRunner::new(
  tape : @tape.TapeService,
  router : InputRouter,
  tool_view : @tools.ProgressiveToolView,
  tools : Array[Json],
  list_skills : () -> Array[@skills.SkillMetadata],
  load_skill_body : (String) -> String?,
  model : String,
  max_steps : Int,
  max_tokens : Int,
  model_timeout_seconds : Int?,
  base_system_prompt : String,
  get_workspace_system_prompt : () -> String,
  llm : @llm.LLMClient,
  registry : @tools.ToolRegistry
) -> ModelRunner {
  {
    tape,
    router,
    tool_view,
    tools,
    list_skills,
    load_skill_body,
    model,
    max_steps,
    max_tokens,
    model_timeout_seconds,
    base_system_prompt,
    get_workspace_system_prompt,
    llm,
    registry,
    expanded_skills: {},
  }
}

/// Reset volatile model-side context caches.
pub fn ModelRunner::reset_context(self : ModelRunner) -> Unit {
  self.expanded_skills.clear()
}

/// Run the model turn loop.
pub async fn ModelRunner::run(
  self : ModelRunner,
  prompt : String
) -> ModelTurnResult!Error {
  ignore(self)
  ignore(prompt)
  abort("ModelRunner::run not implemented")
}
