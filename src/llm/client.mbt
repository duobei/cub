/// LLM client for OpenAI-compatible chat API.

///|
/// Strip <think>...</think> reasoning blocks from model output.
fn strip_think_tags(text : String) -> String {
  let mut result = text
  for {
    let start = find_substring(result, "<think>")
    if start < 0 {
      break
    }
    let end = find_substring(result, "</think>")
    if end < 0 {
      // Unclosed <think> — strip from start to end
      result = result[:start].to_string() catch { _ => "" }
      break
    }
    let before = result[:start].to_string() catch { _ => "" }
    let after = result[end + 8:].to_string() catch { _ => "" }
    result = before + after
  }
  result.trim().to_string()
}

///|
/// Find substring position, returns -1 if not found.
fn find_substring(haystack : String, needle : String) -> Int {
  let hlen = haystack.length()
  let nlen = needle.length()
  if nlen > hlen {
    return -1
  }
  for i = 0; i <= hlen - nlen; i = i + 1 {
    let mut matched = true
    for j = 0; j < nlen; j = j + 1 {
      if haystack[i + j] != needle[j] {
        matched = false
        break
      }
    }
    if matched {
      return i
    }
  }
  -1
}

///|
/// Strip image_url parts from a message, converting array content to text-only.
/// For non-vision providers, this prevents API errors from image_url parts in tape history.
fn strip_image_parts(msg : Json) -> Json {
  match msg {
    { "role": String(role), "content": Array(parts), .. } => {
      // Extract text parts only
      let texts : Array[String] = []
      for part in parts {
        match part {
          { "type": String("text"), "text": String(t), .. } => texts.push(t)
          {
            "type": String("image_url"),
            "image_url": { "url": String(u), .. },
            ..
          } => texts.push("[image: \{u}]")
          _ => ()
        }
      }
      let m : Map[String, Json] = {}
      m["role"] = role.to_json()
      m["content"] = texts.join("\n").to_json()
      Json::object(m)
    }
    _ => msg
  }
}

///|
/// Check if a provider supports vision (image_url content parts).
pub fn supports_vision(provider : String) -> Bool {
  match provider {
    "openai" | "openrouter" | "ollama" => true
    _ => false
  }
}

///|
/// Known provider base URLs.
fn provider_base_url(provider : String) -> String {
  match provider {
    "openrouter" => "https://openrouter.ai/api/v1"
    "openai" => "https://api.openai.com/v1"
    "deepseek" => "https://api.deepseek.com/v1"
    "ollama" => "http://localhost:11434/v1"
    "minimax" => "https://api.minimaxi.com/v1"
    _ => "https://openrouter.ai/api/v1" // fallback
  }
}

///|
/// Parse "provider:model" format into (provider, model_id).
pub fn parse_model_spec(model : String) -> (String, String) {
  // Find first ':'
  let mut colon_pos = -1
  for i, ch in model {
    if ch == ':' {
      colon_pos = i
      break
    }
  }
  if colon_pos < 0 {
    return ("openrouter", model)
  }
  let provider = model[:colon_pos].to_string() catch { _ => model }
  let model_id = model[colon_pos + 1:].to_string() catch { _ => model }
  (provider, model_id)
}

///|
/// LLM client for OpenAI-compatible chat API.
pub struct LLMClient {
  model_id : String
  provider : String
  api_key : String
  api_base : String
  extra_headers : Map[String, String]
  max_tokens : Int
  context_budget : Int
  handoff_threshold : Int
  confirm_fn : ((String, String) -> Bool)?
  on_chunk : ((String) -> Unit)?
}

///|
/// Create a new LLMClient from model spec (e.g., "openrouter:qwen/qwen3-coder-next").
pub fn LLMClient::new(
  model : String,
  api_key : String,
  api_base? : String? = None,
  extra_headers? : Map[String, String] = Map::new(),
  max_tokens? : Int = 1024,
  context_budget? : Int = 128000,
  handoff_threshold? : Int = 90,
  confirm_fn? : ((String, String) -> Bool)? = None,
  on_chunk? : ((String) -> Unit)? = None,
) -> LLMClient {
  let (provider, model_id) = parse_model_spec(model)
  let base = api_base.unwrap_or(provider_base_url(provider))
  {
    model_id,
    provider,
    api_key,
    api_base: base,
    extra_headers,
    max_tokens,
    context_budget,
    handoff_threshold,
    confirm_fn,
    on_chunk,
  }
}

///|
/// Build the request body JSON.
fn LLMClient::build_request_body(
  self : LLMClient,
  messages : Array[Json],
  tools : Array[Json],
  max_tokens : Int,
  system_prompt : String?,
) -> Json {
  let body : Map[String, Json] = Map::new()
  body["model"] = self.model_id.to_json()
  // Prepend system prompt if provided
  let msgs : Array[Json] = []
  match system_prompt {
    Some(sp) =>
      if sp.length() > 0 {
        let sys_msg : Map[String, Json] = Map::new()
        sys_msg["role"] = "system".to_json()
        sys_msg["content"] = sp.to_json()
        msgs.push(Json::object(sys_msg))
      }
    None => ()
  }
  let vision = supports_vision(self.provider)
  for m in messages {
    if vision {
      msgs.push(m)
    } else {
      msgs.push(strip_image_parts(m))
    }
  }
  body["messages"] = Json::array(msgs)
  if tools.length() > 0 {
    body["tools"] = Json::array(tools)
  }
  // Use max_completion_tokens for OpenAI provider, max_tokens for others
  if self.provider == "openai" {
    body["max_completion_tokens"] = max_tokens.to_json()
  } else {
    body["max_tokens"] = max_tokens.to_json()
  }
  Json::object(body)
}

///|
/// Build the request body JSON with stream=true.
fn LLMClient::build_stream_request_body(
  self : LLMClient,
  messages : Array[Json],
  tools : Array[Json],
  max_tokens : Int,
  system_prompt : String?,
) -> Json {
  let body = self.build_request_body(messages, tools, max_tokens, system_prompt)
  match body {
    Object(map) => {
      map["stream"] = true.to_json()
      Json::object(map)
    }
    _ => body
  }
}

///|
/// Make a streaming chat API call, calling on_chunk for each content delta.
/// Returns the full accumulated response.
pub async fn LLMClient::chat_streaming(
  self : LLMClient,
  messages : Array[Json],
  tools? : Array[Json] = [],
  max_tokens? : Int = 0,
  system_prompt? : String? = None,
) -> ChatResponse {
  let actual_max_tokens = if max_tokens > 0 {
    max_tokens
  } else {
    self.max_tokens
  }
  let body = self.build_stream_request_body(
    messages, tools, actual_max_tokens, system_prompt,
  )
  let body_str = body.stringify()
  let url = "\{self.api_base}/chat/completions"
  // Build headers
  let headers : Map[String, String] = Map::new()
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer \{self.api_key}"
  if self.provider == "openrouter" {
    headers["X-Title"] = "cub"
    headers["HTTP-Referer"] = "https://github.com/duobei/cub"
  }
  for k, v in self.extra_headers {
    headers[k] = v
  }
  // Use post_stream for streaming
  let client = @http.post_stream(url, headers~) catch {
    e =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("HTTP stream error: \{e}"),
      }
  }
  // Write request body
  client.write(body_str) catch {
    e => {
      client.close()
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("HTTP write error: \{e}"),
      }
    }
  }
  client.flush() catch {
    _ => ()
  }
  let response = client.end_request() catch {
    e => {
      client.close()
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("HTTP request error: \{e}"),
      }
    }
  }
  if response.code != 200 {
    let err_text = client.read_all() catch { _ => "" }
    let err_str = err_text.text() catch { _ => "HTTP \{response.code}" }
    client.close()
    return {
      text: "",
      tool_calls: [],
      finish_reason: "error",
      error: Some("API error (\{response.code}): \{err_str}"),
    }
  }
  // Read SSE stream
  let content_buf = StringBuilder::new()
  // For tool calls, we accumulate argument fragments by index
  let tc_ids : Map[Int, String] = {} // index → id
  let tc_names : Map[Int, String] = {} // index → function name
  let tc_args : Map[Int, StringBuilder] = {} // index → accumulated arguments
  let mut finish_reason = "stop"
  for {
    let line = client.read_until("\n") catch { _ => break }
    match line {
      None => break
      Some(l) => {
        let trimmed = l.trim().to_string()
        if trimmed.is_empty() {
          continue
        }
        if trimmed == "data: [DONE]" {
          break
        }
        if trimmed.has_prefix("data: ") {
          let json_str = trimmed[6:].to_string() catch { _ => continue }
          let json = @json.parse(json_str) catch { _ => continue }
          // Extract finish_reason
          match json {
            { "choices": [{ "finish_reason": String(fr), .. }, ..], .. } =>
              finish_reason = fr
            _ => ()
          }
          // Extract content delta
          match json {
            {
              "choices": [{ "delta": { "content": String(c), .. }, .. }, ..],
              ..
            } =>
              if c.length() > 0 {
                content_buf.write_string(c)
                match self.on_chunk {
                  Some(cb) => cb(c)
                  None => ()
                }
              }
            _ => ()
          }
          // Extract tool call deltas
          match json {
            {
              "choices": [
                { "delta": { "tool_calls": Array(calls), .. }, .. },
                ..,
              ],
              ..
            } =>
              for call in calls {
                let idx = match call {
                  { "index": Number(n, ..), .. } => n.to_int()
                  _ => 0
                }
                match call {
                  { "id": String(id), .. } => tc_ids[idx] = id
                  _ => ()
                }
                match call {
                  { "function": { "name": String(name), .. }, .. } =>
                    tc_names[idx] = name
                  _ => ()
                }
                match call {
                  { "function": { "arguments": String(args), .. }, .. } => {
                    if not(tc_args.contains(idx)) {
                      tc_args[idx] = StringBuilder::new()
                    }
                    match tc_args.get(idx) {
                      Some(sb) => sb.write_string(args)
                      None => ()
                    }
                  }
                  _ => ()
                }
              }
            _ => ()
          }
        }
      }
    }
  }
  client.close()
  // Build tool calls from accumulated fragments
  let tool_calls : Array[ToolCallInfo] = []
  for idx, id in tc_ids {
    let name = tc_names.get(idx).unwrap_or("")
    let args = match tc_args.get(idx) {
      Some(sb) => sb.to_string()
      None => ""
    }
    tool_calls.push({
      id,
      type_: "function",
      function_: { name, arguments: args },
    })
  }
  let text = strip_think_tags(content_buf.to_string())
  { text, tool_calls, finish_reason, error: None }
}

///|
/// Parse a chat completion response JSON into ChatResponse.
fn parse_chat_response(response_json : Json) -> ChatResponse {
  // Check for error
  match response_json {
    { "error": Object(_), .. } => {
      let err_msg = match response_json {
        { "error": { "message": String(m), .. }, .. } => m
        _ => response_json.stringify()
      }
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some(err_msg),
      }
    }
    _ => ()
  }
  // Extract first choice
  let choice = match response_json {
    { "choices": Array(choices), .. } =>
      if choices.length() > 0 {
        choices[0]
      } else {
        return {
          text: "",
          tool_calls: [],
          finish_reason: "error",
          error: Some("no choices in response"),
        }
      }
    _ =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("invalid response format"),
      }
  }
  let finish_reason = match choice {
    { "finish_reason": String(r), .. } => r
    _ => "unknown"
  }
  let message = match choice {
    { "message": Object(_), .. } =>
      match choice {
        { "message": msg, .. } => msg
        _ => Json::object(Map::new())
      }
    _ => Json::object(Map::new())
  }
  // Extract text content (strip <think> reasoning blocks)
  let text = match message {
    { "content": String(c), .. } => strip_think_tags(c)
    _ => ""
  }
  // Extract tool calls
  let tool_calls : Array[ToolCallInfo] = []
  match message {
    { "tool_calls": Array(calls), .. } =>
      for call in calls {
        match ToolCallInfo::from_json(call) {
          Some(tc) => tool_calls.push(tc)
          None => ()
        }
      }
    _ => ()
  }
  { text, tool_calls, finish_reason, error: None }
}

///|
/// Make a chat API call.
pub async fn LLMClient::chat(
  self : LLMClient,
  messages : Array[Json],
  tools? : Array[Json] = [],
  max_tokens? : Int = 0,
  system_prompt? : String? = None,
) -> ChatResponse {
  let actual_max_tokens = if max_tokens > 0 {
    max_tokens
  } else {
    self.max_tokens
  }
  let body = self.build_request_body(
    messages, tools, actual_max_tokens, system_prompt,
  )
  let body_str = body.stringify()
  let url = "\{self.api_base}/chat/completions"
  // Build headers
  let headers : Map[String, String] = Map::new()
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer \{self.api_key}"
  // OpenRouter-specific headers
  if self.provider == "openrouter" {
    headers["X-Title"] = "cub"
    headers["HTTP-Referer"] = "https://github.com/duobei/cub"
  }
  // Merge extra headers
  for k, v in self.extra_headers {
    headers[k] = v
  }
  // Make HTTP request
  let (response, response_data) = @http.post(url, body_str, headers~) catch {
    e =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("HTTP error: \{e}"),
      }
  }
  if response.code != 200 {
    let error_text = response_data.text() catch { _ => "HTTP \{response.code}" }
    return {
      text: "",
      tool_calls: [],
      finish_reason: "error",
      error: Some("API error (\{response.code}): \{error_text}"),
    }
  }
  let response_text = response_data.text() catch {
    e =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("Failed to read response: \{e}"),
      }
  }
  let response_json = @json.parse(response_text) catch {
    e =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("Failed to parse JSON: \{e}"),
      }
  }
  parse_chat_response(response_json)
}

///|
/// Estimate token count from messages (rough: chars / 4).
fn estimate_tokens(messages : Array[Json], system_prompt : String) -> Int {
  let mut chars = system_prompt.length()
  for msg in messages {
    chars += msg.stringify().length()
  }
  chars / 4
}

///|
/// Check if an error is retryable (connection errors, 429, 500-503).
pub fn is_retryable_error(error : String) -> Bool {
  error.contains("HTTP error:") ||
  error.contains("API error (429)") ||
  error.contains("API error (500)") ||
  error.contains("API error (501)") ||
  error.contains("API error (502)") ||
  error.contains("API error (503)")
}

///|
/// Retry chat with exponential backoff.
/// Retries on connection errors, 429, and 500-503. Does not retry 400/401/403.
pub async fn LLMClient::retry_chat(
  self : LLMClient,
  messages : Array[Json],
  tools? : Array[Json] = [],
  max_tokens? : Int = 0,
  system_prompt? : String? = None,
) -> ChatResponse {
  let max_retries = 3
  let initial_delay = 1000 // ms
  let multiplier = 2
  let max_delay = 10000 // ms
  let mut delay = initial_delay
  let mut last_response : ChatResponse = {
    text: "",
    tool_calls: [],
    finish_reason: "error",
    error: Some("no attempts made"),
  }
  for attempt = 0; attempt <= max_retries; attempt = attempt + 1 {
    let response = if self.on_chunk is Some(_) {
      self.chat_streaming(messages, tools~, max_tokens~, system_prompt~)
    } else {
      self.chat(messages, tools~, max_tokens~, system_prompt~)
    }
    // Success or non-retryable error: return immediately
    match response.error {
      None => return response
      Some(err) =>
        if not(is_retryable_error(err)) {
          return response
        } else if attempt < max_retries {
          @log.warn(
            "llm",
            "retry \{attempt + 1}/\{max_retries} after \{delay}ms: \{err}",
          )
          @async.sleep(delay)
          delay = delay * multiplier
          if delay > max_delay {
            delay = max_delay
          }
          last_response = response
        } else {
          last_response = response
        }
    }
  }
  last_response
}

///|
/// Summarize chat messages into a compact handoff state.
pub fn summarize_messages_for_handoff(
  messages : Array[Json],
) -> Map[String, Json] {
  let state : Map[String, Json] = {}
  // Collect user task descriptions (first and last user messages)
  let user_msgs : Array[String] = []
  let tool_names : Array[String] = []
  let mut last_assistant = ""
  for msg in messages {
    match msg {
      { "role": String("user"), "content": String(c), .. } => user_msgs.push(c)
      { "role": String("assistant"), "content": String(c), .. } =>
        if c.length() > 0 {
          last_assistant = c
        }
      { "role": String("tool"), "name": String(n), .. } =>
        if not(tool_names.contains(n)) {
          tool_names.push(n)
        }
      _ => ()
    }
  }
  // Task: first user message (the original request)
  if user_msgs.length() > 0 {
    let task = user_msgs[0]
    let max_task = 500
    let task_text = if task.length() > max_task {
      "\{task[:max_task]}" catch {
        _ => task
      }
    } else {
      task
    }
    state["task"] = task_text.to_json()
  }
  // Summary: last assistant response (current state)
  if last_assistant.length() > 0 {
    let max_summary = 1000
    let summary = if last_assistant.length() > max_summary {
      "\{last_assistant[:max_summary]}" catch {
        _ => last_assistant
      }
    } else {
      last_assistant
    }
    state["summary"] = summary.to_json()
  }
  // Tools used
  if tool_names.length() > 0 {
    state["tools_used"] = tool_names.join(", ").to_json()
  }
  // Context: last user message if different from first
  if user_msgs.length() > 1 {
    let last_user = user_msgs[user_msgs.length() - 1]
    let max_ctx = 300
    let ctx = if last_user.length() > max_ctx {
      "\{last_user[:max_ctx]}" catch {
        _ => last_user
      }
    } else {
      last_user
    }
    state["context"] = ctx.to_json()
  }
  state
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
    let state = summarize_messages_for_handoff(messages)
    ignore(tape.handoff("auto/context_overflow", state=Some(state)))
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
          let args : Json = @json.parse(tc_args_str) catch {
            _ => {
              @log.warn("llm", "failed to parse tool args for \{tc_name}")
              Json::object(Map::new())
            }
          }
          let result_text = execute_tool(tc_name, args) catch {
            e => "Error: \{e}"
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
      let args : Json = @json.parse(tc.function_.arguments) catch {
        _ => {
          @log.warn("llm", "failed to parse tool args for \{tc.function_.name}")
          Json::object(Map::new())
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
  }
  // Execute confirmation-required tools serially
  for tc in serial_calls {
    let args : Json = @json.parse(tc.function_.arguments) catch {
      _ => Json::object(Map::new())
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
  }
}
