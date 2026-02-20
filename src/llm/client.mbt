/// LLM client for OpenAI-compatible chat API.

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
  let provider = try { model[:colon_pos].to_string() } catch { _ => model }
  let model_id = try { model[colon_pos + 1:].to_string() } catch { _ => model }
  (provider, model_id)
}

/// LLM client for OpenAI-compatible chat API.
pub struct LLMClient {
  model_id : String
  provider : String
  api_key : String
  api_base : String
  extra_headers : Map[String, String]
  max_tokens : Int
}

/// Create a new LLMClient from model spec (e.g., "openrouter:qwen/qwen3-coder-next").
pub fn LLMClient::new(
  model : String,
  api_key : String,
  api_base~ : String? = None,
  extra_headers~ : Map[String, String] = Map::new(),
  max_tokens~ : Int = 1024
) -> LLMClient {
  let (provider, model_id) = parse_model_spec(model)
  let base = match api_base {
    Some(b) => b
    None => provider_base_url(provider)
  }
  { model_id, provider, api_key, api_base: base, extra_headers, max_tokens }
}

/// Build the request body JSON.
fn LLMClient::build_request_body(
  self : LLMClient,
  messages : Array[Json],
  tools : Array[Json],
  max_tokens : Int,
  system_prompt : String?
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
  // Extract text content
  let text = match message {
    { "content": String(c), .. } => c
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

/// Make a chat API call.
pub async fn LLMClient::chat(
  self : LLMClient,
  messages : Array[Json],
  tools~ : Array[Json] = [],
  max_tokens~ : Int = 0,
  system_prompt~ : String? = None
) -> ChatResponse {
  let actual_max_tokens = if max_tokens > 0 { max_tokens } else { self.max_tokens }
  let body = self.build_request_body(messages, tools, actual_max_tokens, system_prompt)
  let body_str = body.stringify()
  let url = self.api_base + "/chat/completions"
  // Build headers
  let headers : Map[String, String] = Map::new()
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer " + self.api_key
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
  let (response, response_data) = try {
    @http.post(url, body_str, headers~)
  } catch {
    e => {
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("HTTP error: " + e.to_string()),
      }
    }
  }
  if response.code != 200 {
    let error_text = try {
      response_data.text()
    } catch {
      _ => "HTTP " + response.code.to_string()
    }
    return {
      text: "",
      tool_calls: [],
      finish_reason: "error",
      error: Some("API error (\{response.code}): " + error_text),
    }
  }
  let response_text = try {
    response_data.text()
  } catch {
    e => {
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("Failed to read response: " + e.to_string()),
      }
    }
  }
  let response_json = try {
    @json.parse(response_text)
  } catch {
    e => {
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        error: Some("Failed to parse JSON: " + e.to_string()),
      }
    }
  }
  parse_chat_response(response_json)
}

/// Run a single tool-use cycle: chat → execute tools → return result.
pub async fn LLMClient::run_tools(
  self : LLMClient,
  tape : @tape.Tape,
  prompt : String,
  system_prompt~ : String = "",
  max_tokens~ : Int = 0,
  tools_json~ : Array[Json] = [],
  execute_tool~ : async (String, Json) -> String
) -> ToolAutoResult {
  // Record user message to tape
  tape.append(@tape.TapeEntry::message("user", prompt))
  // Get messages from tape
  let messages = tape.read_messages()
  // Call LLM
  let sp : String? = if system_prompt.length() > 0 {
    Some(system_prompt)
  } else {
    None
  }
  let response = self.chat(messages, tools=tools_json, max_tokens~, system_prompt=sp)
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
  if response.tool_calls.length() == 0 {
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
  let call_jsons : Array[Json] = []
  for tc in response.tool_calls {
    call_jsons.push(tc.to_json())
  }
  tape.append(@tape.TapeEntry::tool_call(call_jsons))
  // Execute each tool call
  let result_jsons : Array[Json] = []
  for tc in response.tool_calls {
    let args : Json = try {
      @json.parse(tc.function_.arguments)
    } catch {
      _ => Json::object(Map::new())
    }
    let result_text = try {
      execute_tool(tc.function_.name, args)
    } catch {
      e => "Error: " + e.to_string()
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
