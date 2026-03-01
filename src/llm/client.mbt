/// LLM client for OpenAI-compatible chat API.

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
  confirm_fn : (async (String, String) -> Bool)?
  on_chunk : ((String) -> Unit)?
  on_usage : (async (Int, Int) -> Unit)?
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
  confirm_fn? : (async (String, String) -> Bool)? = None,
  on_chunk? : ((String) -> Unit)? = None,
  on_usage? : (async (Int, Int) -> Unit)? = None,
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
    on_usage,
  }
}

///|
/// Merge system_prompt and all system messages into a single system message.
/// Providers like MiniMax reject multiple system messages.
/// The merged message is placed at position 0.
pub fn merge_system_prompt(
  messages : Array[Json],
  system_prompt : String?,
) -> Array[Json] {
  // Collect all system message contents and non-system messages
  let sys_parts : Array[String] = []
  let other_msgs : Array[Json] = []
  match system_prompt {
    Some(sp) => if sp.length() > 0 { sys_parts.push(sp) }
    None => ()
  }
  for m in messages {
    match m {
      { "role": String("system"), "content": String(c), .. } =>
        sys_parts.push(c)
      _ => other_msgs.push(m)
    }
  }
  if sys_parts.is_empty() {
    return other_msgs
  }
  let result : Array[Json] = []
  let sys_msg : Map[String, Json] = Map::new()
  sys_msg["role"] = "system".to_json()
  sys_msg["content"] = sys_parts.join("\n").to_json()
  result.push(Json::object(sys_msg))
  result.append(other_msgs)
  result
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
  let vision = supports_vision(self.provider)
  let processed : Array[Json] = if vision {
    messages.copy()
  } else {
    messages.map(strip_image_parts)
  }
  let msgs = merge_system_prompt(processed, system_prompt)
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
      let opts : Map[String, Json] = {}
      opts["include_usage"] = true.to_json()
      map["stream_options"] = Json::object(opts)
      Json::object(map)
    }
    _ => body
  }
}
