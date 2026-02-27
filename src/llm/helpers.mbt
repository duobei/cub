/// Utility functions for the LLM module.

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
  for i in 0..<=(hlen - nlen) {
    let mut matched = true
    for j in 0..<nlen {
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
    usage: None,
    error: Some("no attempts made"),
  }
  for attempt = 0; attempt <= max_retries; attempt = attempt + 1 {
    let response = if self.on_chunk is Some(_) {
      self.chat_streaming(messages, tools~, max_tokens~, system_prompt~)
    } else {
      self.chat(messages, tools~, max_tokens~, system_prompt~)
    }
    // Report usage if available
    match (self.on_usage, response.usage) {
      (Some(cb), Some(u)) => cb(u.prompt_tokens, u.completion_tokens)
      _ => ()
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
