/// Chat API calls for the LLM module.

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
  let (response, response_data) = @platform.http_post(url, body_str, headers~) catch {
    e =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        usage: None,
        error: Some("HTTP error: \{e}"),
      }
  }
  if response.code != 200 {
    let error_text = response_data.text() catch { _ => "HTTP \{response.code}" }
    return {
      text: "",
      tool_calls: [],
      finish_reason: "error",
      usage: None,
      error: Some("API error (\{response.code}): \{error_text}"),
    }
  }
  let response_text = response_data.text() catch {
    e =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        usage: None,
        error: Some("Failed to read response: \{e}"),
      }
  }
  let response_json = @json.parse(response_text) catch {
    e =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        usage: None,
        error: Some("Failed to parse JSON: \{e}"),
      }
  }
  parse_chat_response(response_json)
}
