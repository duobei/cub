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
      let opts : Map[String, Json] = {}
      opts["include_usage"] = true.to_json()
      map["stream_options"] = Json::object(opts)
      Json::object(map)
    }
    _ => body
  }
}
