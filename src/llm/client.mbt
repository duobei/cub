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
/// Known provider base URLs.
fn provider_base_url(provider : String) -> String {
  match provider {
    "openrouter" => "https://openrouter.ai/api/v1"
    "openai" => "https://api.openai.com/v1"
    "deepseek" => "https://api.deepseek.com/v1"
    "ollama" => "http://localhost:11434/v1"
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
}

///|
/// Create a new LLMClient from model spec (e.g., "openrouter:qwen/qwen3-coder-next").
pub fn LLMClient::new(
  model : String,
  api_key : String,
  api_base? : String? = None,
  extra_headers? : Map[String, String] = Map::new(),
  max_tokens? : Int = 1024,
) -> LLMClient {
  let (provider, model_id) = parse_model_spec(model)
  let base = api_base.unwrap_or(provider_base_url(provider))
  { model_id, provider, api_key, api_base: base, extra_headers, max_tokens }
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
  for m in messages {
    msgs.push(m)
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
/// Context budget warning threshold (80% of 128k default).
let context_budget_tokens : Int = 128000

///|
/// Run a single tool-use cycle: chat → execute tools → return result.
pub async fn LLMClient::run_tools(
  self : LLMClient,
  tape : @tape.Tape,
  prompt : String,
  system_prompt? : String = "",
  max_tokens? : Int = 0,
  tools_json? : Array[Json] = [],
  execute_tool~ : async (String, Json) -> String,
) -> ToolAutoResult {
  // Record user message to tape
  tape.append(@tape.TapeEntry::message("user", prompt))
  // Get messages from tape
  let messages = tape.read_messages()
  // Estimate token usage and inject budget warning if needed
  let estimated = estimate_tokens(messages, system_prompt)
  let threshold = context_budget_tokens * 4 / 5 // 80%
  let sp : String? = if system_prompt.length() > 0 {
    if estimated > threshold {
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
  let response = self.chat(
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
    }
  }
  // Record assistant tool calls
  let call_jsons = response.tool_calls.map(fn(tc) { tc.to_json() })
  tape.append(@tape.TapeEntry::tool_call(call_jsons))
  // Execute each tool call
  let result_jsons : Array[Json] = []
  for tc in response.tool_calls {
    let args : Json = @json.parse(tc.function_.arguments) catch {
      _ => Json::object(Map::new())
    }
    let result_text = execute_tool(tc.function_.name, args) catch {
      e => "Error: \{e}"
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
  }
}
