///|
/// Tests for LLM client helpers.

// --- is_retryable_error ---

test "is_retryable_error: HTTP connection error is retryable" {
  inspect(
    @llm.is_retryable_error("HTTP error: connection refused"),
    content="true",
  )
}

///|
test "is_retryable_error: 429 rate limit is retryable" {
  inspect(
    @llm.is_retryable_error("API error (429): rate limit"),
    content="true",
  )
}

///|
test "is_retryable_error: 500 server error is retryable" {
  inspect(@llm.is_retryable_error("API error (500): internal"), content="true")
}

///|
test "is_retryable_error: 502 bad gateway is retryable" {
  inspect(
    @llm.is_retryable_error("API error (502): bad gateway"),
    content="true",
  )
}

///|
test "is_retryable_error: 503 unavailable is retryable" {
  inspect(
    @llm.is_retryable_error("API error (503): unavailable"),
    content="true",
  )
}

///|
test "is_retryable_error: 400 bad request is NOT retryable" {
  inspect(
    @llm.is_retryable_error("API error (400): bad request"),
    content="false",
  )
}

///|
test "is_retryable_error: 401 unauthorized is NOT retryable" {
  inspect(
    @llm.is_retryable_error("API error (401): unauthorized"),
    content="false",
  )
}

///|
test "is_retryable_error: 403 forbidden is NOT retryable" {
  inspect(
    @llm.is_retryable_error("API error (403): forbidden"),
    content="false",
  )
}

///|
test "is_retryable_error: parse error is NOT retryable" {
  inspect(
    @llm.is_retryable_error("Failed to parse JSON: unexpected"),
    content="false",
  )
}

// --- parse_model_spec ---

///|
test "parse_model_spec: provider:model format" {
  let (provider, model) = @llm.parse_model_spec("openrouter:qwen/qwen3")
  inspect(provider, content="openrouter")
  inspect(model, content="qwen/qwen3")
}

///|
test "parse_model_spec: no colon defaults to openrouter" {
  let (provider, model) = @llm.parse_model_spec("gpt-4")
  inspect(provider, content="openrouter")
  inspect(model, content="gpt-4")
}

///|
test "parse_model_spec: deepseek provider" {
  let (provider, model) = @llm.parse_model_spec("deepseek:deepseek-chat")
  inspect(provider, content="deepseek")
  inspect(model, content="deepseek-chat")
}

///|
test "parse_model_spec: minimax provider" {
  let (provider, model) = @llm.parse_model_spec("minimax:MiniMax-M2.5")
  inspect(provider, content="minimax")
  inspect(model, content="MiniMax-M2.5")
}

///|
test "parse_model_spec: ollama provider" {
  let (provider, model) = @llm.parse_model_spec("ollama:llama3")
  inspect(provider, content="ollama")
  inspect(model, content="llama3")
}

// --- summarize_messages_for_handoff ---

///|
test "summarize_messages_for_handoff: extracts task from first user message" {
  let msgs : Array[Json] = []
  let m1 : Map[String, Json] = {}
  m1["role"] = "user".to_json()
  m1["content"] = "build a new feature".to_json()
  msgs.push(Json::object(m1))
  let state = @llm.summarize_messages_for_handoff(msgs)
  let expected =
    #|Some(String("build a new feature"))
  inspect(state.get("task"), content=expected)
}

///|
test "summarize_messages_for_handoff: extracts last assistant as summary" {
  let msgs : Array[Json] = []
  let u : Map[String, Json] = {}
  u["role"] = "user".to_json()
  u["content"] = "do task".to_json()
  msgs.push(Json::object(u))
  let a : Map[String, Json] = {}
  a["role"] = "assistant".to_json()
  a["content"] = "I completed step 1".to_json()
  msgs.push(Json::object(a))
  let state = @llm.summarize_messages_for_handoff(msgs)
  let expected =
    #|Some(String("I completed step 1"))
  inspect(state.get("summary"), content=expected)
}

///|
test "summarize_messages_for_handoff: collects tool names" {
  let msgs : Array[Json] = []
  let u : Map[String, Json] = {}
  u["role"] = "user".to_json()
  u["content"] = "run tests".to_json()
  msgs.push(Json::object(u))
  let t1 : Map[String, Json] = {}
  t1["role"] = "tool".to_json()
  t1["name"] = "bash".to_json()
  t1["content"] = "ok".to_json()
  msgs.push(Json::object(t1))
  let t2 : Map[String, Json] = {}
  t2["role"] = "tool".to_json()
  t2["name"] = "fs_read".to_json()
  t2["content"] = "file contents".to_json()
  msgs.push(Json::object(t2))
  let state = @llm.summarize_messages_for_handoff(msgs)
  match state.get("tools_used") {
    Some(String(s)) => {
      inspect(s.contains("bash"), content="true")
      inspect(s.contains("fs_read"), content="true")
    }
    _ => fail("expected tools_used")
  }
}

///|
test "summarize_messages_for_handoff: context from last user msg" {
  let msgs : Array[Json] = []
  let u1 : Map[String, Json] = {}
  u1["role"] = "user".to_json()
  u1["content"] = "original task".to_json()
  msgs.push(Json::object(u1))
  let u2 : Map[String, Json] = {}
  u2["role"] = "user".to_json()
  u2["content"] = "continue with step 2".to_json()
  msgs.push(Json::object(u2))
  let state = @llm.summarize_messages_for_handoff(msgs)
  let expected_task =
    #|Some(String("original task"))
  inspect(state.get("task"), content=expected_task)
  let expected_ctx =
    #|Some(String("continue with step 2"))
  inspect(state.get("context"), content=expected_ctx)
}

///|
test "summarize_messages_for_handoff: empty messages" {
  let msgs : Array[Json] = []
  let state = @llm.summarize_messages_for_handoff(msgs)
  inspect(state.get("task"), content="None")
  inspect(state.get("summary"), content="None")
}
