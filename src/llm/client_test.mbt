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
