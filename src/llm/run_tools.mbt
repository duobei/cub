/// Tool execution loop for the LLM module.

///|
/// Try to parse tool arguments JSON. Returns Ok(Json) or Err with descriptive message.
fn try_parse_tool_args(name : String, args_str : String) -> (Json, Bool) {
  let parsed = @json.parse(args_str) catch {
    _ => {
      @log.warn("llm", "invalid JSON args for \{name} (truncated?)")
      return (Json::object(Map::new()), false)
    }
  }
  (parsed, true)
}

///|
/// Run a single tool-use cycle: chat → execute tools → return result.
pub async fn LLMClient::run_tools(
  self : LLMClient,
  tape : @tape.Tape,
  prompt : String,
  system_prompt? : String = "",
  max_tokens? : Int = 0,
  tools_json? : Array[Json] = [],
  image_urls? : Array[String] = [],
  needs_confirmation? : (String) -> Bool = fn(_name) { false },
  is_serial? : (String) -> Bool = fn(_name) { false },
  execute_tool~ : async (String, Json) -> String,
) -> ToolAutoResult {
  // Record user message to tape (with images if present)
  if image_urls.length() > 0 {
    if supports_vision(self.provider) {
      tape.append(
        @tape.TapeEntry::message_with_images("user", prompt, image_urls),
      )
    } else {
      // Fallback: include image URLs as text for non-vision models
      let urls_text = image_urls.join("\n")
      let fallback = "\{prompt}\n\n[Attached images:\n\{urls_text}\n]"
      tape.append(@tape.TapeEntry::message("user", fallback))
    }
  } else {
    tape.append(@tape.TapeEntry::message("user", prompt))
  }
  // Get messages from tape
  let mut messages = tape.read_messages()
  // Estimate token usage and manage context budget
  let mut estimated = estimate_tokens(messages, system_prompt)
  let budget = self.context_budget
  let critical_threshold = budget * self.handoff_threshold / 100
  // Auto-handoff at threshold: summarize and truncate context
  if estimated > critical_threshold {
    @log.warn(
      "llm",
      "context at ~\{estimated} tokens (>\{critical_threshold}), auto-handoff",
    )
    // Save the current user message before handoff
    let mut last_user_content = ""
    let mut i = messages.length() - 1
    while i >= 0 {
      match messages[i] {
        { "role": String("user"), "content": String(c), .. } => {
          last_user_content = c
          break
        }
        _ => ()
      }
      i -= 1
    }
    let state = self.summarize_for_handoff(messages)
    ignore(tape.handoff("auto/context_overflow", state=Some(state)))
    // Re-append user message after the anchor so it's visible in new context
    if not(last_user_content.is_empty()) {
      tape.append(@tape.TapeEntry::message("user", last_user_content))
    }
    messages = tape.read_messages()
    estimated = estimate_tokens(messages, system_prompt)
  }
  let warning_threshold = budget * 4 / 5 // 80%
  let sp : String? = if system_prompt.length() > 0 {
    if estimated > warning_threshold {
      let warning =
        #|
        #|<context_warning>
        #|WARNING: Context is at ~{estimated} tokens (~80% of budget).
        #|You SHOULD use handoff NOW to transition to a new stage.
        #|Carry forward the current task state, not history.
        #|</context_warning>
      Some("\{system_prompt}\{warning}")
    } else {
      Some(system_prompt)
    }
  } else {
    None
  }
  let response = self.retry_chat(
    messages,
    tools=tools_json,
    max_tokens~,
    system_prompt=sp,
  )
  // Handle error
  if response.error is Some(err) {
    return {
      kind: ToolAutoKind::Error,
      text: "",
      tool_calls: [],
      tool_results: [],
      error: Some(err),
      has_tool_errors: false,
      usage: response.usage,
    }
  }
  // If no tool calls, return text
  if response.tool_calls.is_empty() {
    // Record assistant message
    tape.append(@tape.TapeEntry::message("assistant", response.text))
    return {
      kind: ToolAutoKind::Text,
      text: response.text,
      tool_calls: [],
      tool_results: [],
      error: None,
      has_tool_errors: false,
      usage: response.usage,
    }
  }
  // Record assistant tool calls
  let call_jsons = response.tool_calls.map(fn(tc) { tc.to_json() })
  tape.append(@tape.TapeEntry::tool_call(call_jsons))
  // Separate tool calls into serial (confirmation + write-mutating) and parallel-safe
  let serial_calls : Array[ToolCallInfo] = []
  let parallel_calls : Array[ToolCallInfo] = []
  for tc in response.tool_calls {
    if is_serial(tc.function_.name) {
      serial_calls.push(tc)
    } else {
      parallel_calls.push(tc)
    }
  }
  // Execute tool calls with parallel optimization
  let result_jsons : Array[Json] = []
  let mut any_tool_error = false
  // Execute parallel-safe tools concurrently when there are multiple
  if parallel_calls.length() > 1 {
    // Pre-allocate result slots to preserve order
    let parallel_results : Array[String] = []
    for _tc in parallel_calls {
      parallel_results.push("")
    }
    // Use task group for concurrent execution
    @async.with_task_group(fn(group) {
      for idx, tc in parallel_calls {
        let tc_args_str = tc.function_.arguments
        let tc_name = tc.function_.name
        let slot = idx
        group.spawn_bg(async fn() {
          let (args, ok) = try_parse_tool_args(tc_name, tc_args_str)
          let result_text = if ok {
            execute_tool(tc_name, args) catch {
              e => "Error: \{e}"
            }
          } else {
            "Error: tool arguments are not valid JSON (likely truncated by model). Try splitting the content into smaller pieces or using a shorter argument."
          }
          parallel_results[slot] = result_text
        })
      }
    })
    // Collect results in original order
    for idx, tc in parallel_calls {
      let result_text = parallel_results[idx]
      if result_text.has_prefix("Error: ") {
        any_tool_error = true
      }
      let result_obj : Map[String, Json] = Map::new()
      result_obj["tool_call_id"] = tc.id.to_json()
      result_obj["name"] = tc.function_.name.to_json()
      result_obj["content"] = result_text.to_json()
      result_jsons.push(Json::object(result_obj))
    }
  } else {
    // Single parallel call or none — execute sequentially
    for tc in parallel_calls {
      let (args, ok) = try_parse_tool_args(
        tc.function_.name,
        tc.function_.arguments,
      )
      let result_text = if ok {
        execute_tool(tc.function_.name, args) catch {
          e => {
            any_tool_error = true
            "Error: \{e}"
          }
        }
      } else {
        any_tool_error = true
        "Error: tool arguments are not valid JSON (likely truncated by model). Try splitting the content into smaller pieces or using a shorter argument."
      }
      let result_obj : Map[String, Json] = Map::new()
      result_obj["tool_call_id"] = tc.id.to_json()
      result_obj["name"] = tc.function_.name.to_json()
      result_obj["content"] = result_text.to_json()
      result_jsons.push(Json::object(result_obj))
    }
  }
  // Execute confirmation-required tools serially
  for tc in serial_calls {
    let (args, ok) = try_parse_tool_args(
      tc.function_.name,
      tc.function_.arguments,
    )
    if not(ok) {
      any_tool_error = true
      let result_obj : Map[String, Json] = Map::new()
      result_obj["tool_call_id"] = tc.id.to_json()
      result_obj["name"] = tc.function_.name.to_json()
      result_obj["content"] = "Error: tool arguments are not valid JSON (likely truncated by model). Try splitting the content into smaller pieces or using a shorter argument.".to_json()
      result_jsons.push(Json::object(result_obj))
      continue
    }
    // Check if tool requires user confirmation (not just serial execution)
    if needs_confirmation(tc.function_.name) {
      match self.confirm_fn {
        Some(cfn) =>
          if not(cfn(tc.function_.name, tc.function_.arguments)) {
            let result_obj : Map[String, Json] = Map::new()
            result_obj["tool_call_id"] = tc.id.to_json()
            result_obj["name"] = tc.function_.name.to_json()
            result_obj["content"] = "[denied by user]".to_json()
            result_jsons.push(Json::object(result_obj))
            continue
          }
        None => () // No confirm_fn means auto-approve
      }
    }
    let result_text = execute_tool(tc.function_.name, args) catch {
      e => {
        any_tool_error = true
        "Error: \{e}"
      }
    }
    let result_obj : Map[String, Json] = Map::new()
    result_obj["tool_call_id"] = tc.id.to_json()
    result_obj["name"] = tc.function_.name.to_json()
    result_obj["content"] = result_text.to_json()
    result_jsons.push(Json::object(result_obj))
  }
  // Record tool results
  tape.append(@tape.TapeEntry::tool_result(result_jsons))
  {
    kind: ToolAutoKind::Tools,
    text: response.text,
    tool_calls: call_jsons,
    tool_results: result_jsons,
    error: None,
    has_tool_errors: any_tool_error,
    usage: response.usage,
  }
}
