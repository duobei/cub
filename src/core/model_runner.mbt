/// Model turn runner.

///|
/// Tool continue prompt sent after tool execution.
let tool_continue_prompt : String = "Continue the task."

///|
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

///|
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
  registry : @tools.ToolRegistry,
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

///|
/// Reset volatile model-side context caches.
pub fn ModelRunner::reset_context(self : ModelRunner) -> Unit {
  self.expanded_skills.clear()
}

///|
/// Run the model turn loop: chat → handle tool calls / commands → repeat.
pub async fn ModelRunner::run(
  self : ModelRunner,
  prompt : String,
) -> ModelTurnResult {
  let mut current_prompt = prompt
  // Expand skill hints from the initial prompt
  self.expand_skill_hints(prompt)
  let mut step = 0
  let mut followups = 0
  let visible_parts : Array[String] = []
  let mut error : String? = None
  let mut exit_requested = false
  let mut consecutive_tool_failures = 0
  while step < self.max_steps && not(exit_requested) {
    step += 1
    // Record step start
    let step_data : Map[String, Json] = Map::new()
    step_data["step"] = step.to_json()
    step_data["model"] = self.model.to_json()
    self.tape.append_event("loop.step.start", Json::object(step_data))
    // Call the model
    let chat_result = self.chat(current_prompt)
    // Handle error — on API 400, try handoff to truncate bad history and retry once
    if chat_result.error is Some(err) {
      if is_api_bad_request(err) && step == 1 {
        // Truncate tape via handoff and retry
        let state : Map[String, Json] = {}
        state["reason"] = "auto_recovery_api_400".to_json()
        state["error"] = err.to_json()
        ignore(self.tape.handoff("auto/recovery", state=Some(state)))
        let retry_data : Map[String, Json] = Map::new()
        retry_data["step"] = step.to_json()
        retry_data["error"] = err.to_json()
        self.tape.append_event(
          "loop.step.retry_after_handoff",
          Json::object(retry_data),
        )
        // Retry with same prompt
        let retry_result = self.chat(current_prompt)
        if retry_result.error is Some(retry_err) {
          error = Some(retry_err)
          let err_data : Map[String, Json] = Map::new()
          err_data["step"] = step.to_json()
          err_data["error"] = retry_err.to_json()
          self.tape.append_event("loop.step.error", Json::object(err_data))
          break
        }
        // Retry succeeded — use retry_result as chat_result
        if retry_result.followup_prompt is Some(fp) {
          let fin_data : Map[String, Json] = Map::new()
          fin_data["step"] = step.to_json()
          fin_data["visible_text"] = false.to_json()
          fin_data["followup"] = true.to_json()
          fin_data["exit_requested"] = false.to_json()
          self.tape.append_event("loop.step.finish", Json::object(fin_data))
          current_prompt = fp
          followups += 1
          continue
        }
        let assistant_text = retry_result.text
        if assistant_text.trim().to_string().length() > 0 {
          let route = self.router.route_assistant(assistant_text)
          if route.visible_text.length() > 0 {
            visible_parts.push(route.visible_text)
          }
          if route.exit_requested {
            exit_requested = true
          }
          if route.next_prompt.length() > 0 {
            current_prompt = route.next_prompt
            followups += 1
            continue
          }
        }
        break
      }
      error = Some(err)
      let err_data : Map[String, Json] = Map::new()
      err_data["step"] = step.to_json()
      err_data["error"] = err.to_json()
      self.tape.append_event("loop.step.error", Json::object(err_data))
      break
    }
    // If tool calls were made, continue with follow-up
    if chat_result.followup_prompt is Some(fp) {
      // Track consecutive tool failures
      if chat_result.has_tool_errors {
        consecutive_tool_failures += 1
        if consecutive_tool_failures >= 5 {
          error = Some("too many consecutive tool failures")
          let fail_data : Map[String, Json] = Map::new()
          fail_data["step"] = step.to_json()
          fail_data["consecutive_failures"] = consecutive_tool_failures.to_json()
          self.tape.append_event(
            "loop.tool_failures_exceeded",
            Json::object(fail_data),
          )
          break
        }
        if consecutive_tool_failures >= 3 {
          // Inject warning into the follow-up prompt
          current_prompt = "\{fp}\n\n<system_warning>Multiple tool failures (\{consecutive_tool_failures} consecutive). Consider a different approach or verify your arguments.</system_warning>"
        } else {
          current_prompt = fp
        }
      } else {
        consecutive_tool_failures = 0
        current_prompt = fp
      }
      let fin_data : Map[String, Json] = Map::new()
      fin_data["step"] = step.to_json()
      fin_data["visible_text"] = false.to_json()
      fin_data["followup"] = true.to_json()
      fin_data["exit_requested"] = false.to_json()
      self.tape.append_event("loop.step.finish", Json::object(fin_data))
      followups += 1
      continue
    }
    // We got text back — check if empty
    let assistant_text = chat_result.text
    if assistant_text.trim().to_string().is_empty() {
      let empty_data : Map[String, Json] = Map::new()
      empty_data["step"] = step.to_json()
      self.tape.append_event("loop.step.empty", Json::object(empty_data))
      break
    }
    // Route assistant output (parse comma commands)
    let route = self.router.route_assistant(assistant_text)
    // Collect visible text
    if route.visible_text.length() > 0 {
      visible_parts.push(route.visible_text)
    }
    if route.exit_requested {
      exit_requested = true
    }
    // Record step finish
    let fin_data : Map[String, Json] = Map::new()
    fin_data["step"] = step.to_json()
    fin_data["visible_text"] = (route.visible_text.length() > 0).to_json()
    fin_data["followup"] = (route.next_prompt.length() > 0).to_json()
    fin_data["exit_requested"] = route.exit_requested.to_json()
    self.tape.append_event("loop.step.finish", Json::object(fin_data))
    // If no follow-up needed, we're done
    if route.next_prompt.is_empty() {
      break
    }
    current_prompt = route.next_prompt
    followups += 1
  }
  // Check max steps
  if step >= self.max_steps && error is None {
    error = Some("max_steps_reached=\{self.max_steps}")
    let max_data : Map[String, Json] = Map::new()
    max_data["max_steps"] = self.max_steps.to_json()
    self.tape.append_event("loop.max_steps", Json::object(max_data))
  }
  // Join visible parts
  let visible_text = join_visible_parts(visible_parts)
  {
    visible_text,
    exit_requested,
    steps: step,
    error,
    command_followups: followups,
  }
}

///|
/// Make a single chat call with tool execution.
async fn ModelRunner::chat(self : ModelRunner, prompt : String) -> ChatResult {
  let system_prompt = self.render_system_prompt()
  let execute_tool : async (String, Json) -> String = async fn(name, args) {
    // Convert model name back to registry name
    let tool_name = @tools.from_model_name(name, self.registry)
    self.registry.execute(tool_name, kwargs=args)
  }
  let registry = self.registry
  let needs_confirmation : (String) -> Bool = fn(name) {
    let tool_name = @tools.from_model_name(name, registry)
    registry.needs_confirmation(tool_name)
  }
  let timeout = self.model_timeout_seconds.unwrap_or(120)
  let result = @async.with_timeout(timeout * 1000, async fn() {
    self.llm.run_tools(
      self.tape.tape(),
      prompt,
      system_prompt~,
      max_tokens=self.max_tokens,
      tools_json=self.tools,
      needs_confirmation~,
      execute_tool~,
    )
  }) catch {
    _ => {
      // Retry once with 2x timeout
      @log.warn(
        "model",
        "timeout after \{timeout}s, retrying with \{timeout * 2}s",
      )
      let retry_result = @async.with_timeout(timeout * 2 * 1000, async fn() {
        self.llm.run_tools(
          self.tape.tape(),
          prompt,
          system_prompt~,
          max_tokens=self.max_tokens,
          tools_json=self.tools,
          needs_confirmation~,
          execute_tool~,
        )
      }) catch {
        _ =>
          return {
            text: "",
            error: Some(
              "model_timeout: no response within \{timeout * 2}s (after retry)",
            ),
            followup_prompt: None,
            has_tool_errors: false,
          }
      }
      return ChatResult::from_tool_auto(retry_result)
    }
  }
  ChatResult::from_tool_auto(result)
}

///|
/// Render the full system prompt.
fn ModelRunner::render_system_prompt(self : ModelRunner) -> String {
  let blocks : Array[String] = [
    self.base_system_prompt,
    (self.get_workspace_system_prompt)(),
    runtime_contract(),
    @tools.render_tool_prompt_block(self.tool_view),
    @skills.render_skill_prompt((self.list_skills)()),
    @skills.render_expanded_skills(self.expanded_skills),
  ]
  join_blocks(blocks)
}

///|
/// Join non-empty blocks with double newlines.
fn join_blocks(blocks : Array[String]) -> String {
  blocks.filter(fn(b) { not(b.trim().to_string().is_empty()) }).join("\n\n")
}

///|
/// Join visible parts with double newlines.
fn join_visible_parts(parts : Array[String]) -> String {
  parts.filter(fn(p) { not(p.is_empty()) }).join("\n\n").trim().to_string()
}

///|
/// Internal chat result (before being returned as ModelTurnResult).
priv struct ChatResult {
  text : String
  error : String?
  followup_prompt : String?
  has_tool_errors : Bool
}

///|
/// Convert a ToolAutoResult into a ChatResult.
fn ChatResult::from_tool_auto(output : @llm.ToolAutoResult) -> ChatResult {
  match output.kind {
    @llm.ToolAutoKind::Text =>
      {
        text: output.text,
        error: None,
        followup_prompt: None,
        has_tool_errors: false,
      }
    @llm.ToolAutoKind::Tools =>
      {
        text: "",
        error: None,
        followup_prompt: Some(tool_continue_prompt),
        has_tool_errors: output.has_tool_errors,
      }
    @llm.ToolAutoKind::Error => {
      let err_msg = output.error.unwrap_or("unknown error")
      {
        text: "",
        error: Some(err_msg),
        followup_prompt: None,
        has_tool_errors: false,
      }
    }
  }
}

///|
/// Scan text for $name hints and expand matching skills into expanded_skills.
fn ModelRunner::expand_skill_hints(self : ModelRunner, text : String) -> Unit {
  let mut i = 0
  while i < text.length() {
    if text[i] == '$'.to_int().to_uint16() {
      let start = i + 1
      let mut end = start
      while end < text.length() {
        let ch = text[end].to_int()
        if (ch >= 97 && ch <= 122) ||
          (ch >= 65 && ch <= 90) ||
          (ch >= 48 && ch <= 57) ||
          ch == 46 ||
          ch == 95 ||
          ch == 45 {
          end += 1
        } else {
          break
        }
      }
      if end > start {
        let hint = text[start:end].to_string() catch { _ => "" }
        if hint.length() > 0 && not(self.expanded_skills.contains(hint)) {
          match (self.load_skill_body)(hint) {
            Some(body) => self.expanded_skills[hint] = body
            None => ()
          }
        }
      }
      i = end
    } else {
      i += 1
    }
  }
}

///|
/// Check if an error string indicates an API 400 bad request.
fn is_api_bad_request(err : String) -> Bool {
  err.contains("API error (400)") || err.contains("bad_request_error")
}

///|
/// The runtime contract injected into every system prompt.
fn runtime_contract() -> String {
  let contract =
    #|<runtime_contract>
    #|1) Use tool calls for all actions (file ops, shell, web, git, tape, skills).
    #|2) Do not emit comma-prefixed commands in normal flow; use tool calls instead.
    #|3) If a compatibility fallback is required, runtime can still parse comma commands.
    #|4) Never emit '<command ...>' blocks yourself; those are runtime-generated.
    #|5) When enough evidence is collected, return plain natural language answer.
    #|6) Use '$name' hints to request detail expansion for tools/skills when needed.
    #|7) After completing complex tasks, reflect and save useful patterns via memory.save.
    #|8) For repeated workflows, create reusable skills via skill.create.
    #|9) Update AGENTS.md via agents.update to evolve workspace behavior over time.
    #|10) Use $git skill hint for git operations; use $project-analyze to understand the workspace.
    #|11) Use schedule.add to create timed tasks; schedule.list/remove to manage them.
    #|12) Use agent.spawn to delegate complex subtasks to a child agent process.
    #|</runtime_contract>
    #|<context_contract>
    #|Context is managed via tape anchors. Only entries after the last anchor are visible.
    #|When context grows large, use handoff to transition to a new stage.
    #|In the handoff state, describe the CURRENT task status and NEXT steps — not a summary of history.
    #|Example: handoff(name="refactor/phase2", summary="Completed router refactor. Next: update tests.", context="Files changed: router.mbt, types.mbt", next_steps="Run tests and fix failures")
    #|If you need to recall earlier conversation, use tape.search to retrieve specific information.
    #|MEMORY.md is already loaded into your system prompt — do NOT call memory.read unless the user asks.
    #|Use memory.save to persist important facts (project conventions, user preferences) across sessions.
    #|When you discover important information worth remembering, proactively call memory.save.
    #|</context_contract>
  contract
}
