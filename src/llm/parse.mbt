/// Chat response parsing for the LLM module.

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
        usage: None,
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
          usage: None,
          error: Some("no choices in response"),
        }
      }
    _ =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        usage: None,
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
  // Extract usage
  let usage : TokenUsage? = match response_json {
    {
      "usage": {
        "prompt_tokens": Number(pt, ..),
        "completion_tokens": Number(ct, ..),
        "total_tokens": Number(tt, ..),
        ..
      },
      ..
    } =>
      Some({
        prompt_tokens: pt.to_int(),
        completion_tokens: ct.to_int(),
        total_tokens: tt.to_int(),
      })
    _ => None
  }
  { text, tool_calls, finish_reason, error: None, usage }
}
