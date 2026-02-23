///|
/// Tests for router, model runner helpers, and LLM vision routing.

// -- resolve_internal_name --

///|
test "resolve_internal_name tool alias" {
  inspect(@core.resolve_internal_name("tool"), content="tool.describe")
}

///|
test "resolve_internal_name tape alias" {
  inspect(@core.resolve_internal_name("tape"), content="tape.info")
}

///|
test "resolve_internal_name skill alias" {
  inspect(@core.resolve_internal_name("skill"), content="skills.describe")
}

///|
test "resolve_internal_name passthrough" {
  inspect(@core.resolve_internal_name("help"), content="help")
  inspect(@core.resolve_internal_name("bash"), content="bash")
  inspect(@core.resolve_internal_name("handoff"), content="handoff")
}

// -- is_api_bad_request --

///|
test "is_api_bad_request matches 400 error" {
  inspect(
    @core.is_api_bad_request("API error (400): invalid request"),
    content="true",
  )
}

///|
test "is_api_bad_request matches bad_request_error" {
  inspect(
    @core.is_api_bad_request("bad_request_error: messages too long"),
    content="true",
  )
}

///|
test "is_api_bad_request rejects other errors" {
  inspect(
    @core.is_api_bad_request("API error (500): internal"),
    content="false",
  )
  inspect(@core.is_api_bad_request("timeout"), content="false")
  inspect(@core.is_api_bad_request(""), content="false")
}

// -- join_lines --

///|
test "join_lines empty" {
  inspect(@core.join_lines([]), content="")
}

///|
test "join_lines single" {
  inspect(@core.join_lines(["hello"]), content="hello")
}

///|
test "join_lines multiple" {
  let result = @core.join_lines(["hello", "world"])
  inspect(result, content="hello\nworld")
}

///|
test "join_lines trims result" {
  let result = @core.join_lines(["  hello  ", "  world  "])
  inspect(result, content="hello  \n  world")
}

// -- join_blocks --

///|
test "join_blocks filters empty" {
  let result = @core.join_blocks(["hello", "", "  ", "world"])
  inspect(result, content="hello\n\nworld")
}

///|
test "join_blocks all empty" {
  let result = @core.join_blocks(["", "  ", "\n"])
  inspect(result, content="")
}

///|
test "join_blocks single block" {
  let result = @core.join_blocks(["only one"])
  inspect(result, content="only one")
}

// -- join_visible_parts --

///|
test "join_visible_parts filters empty" {
  let result = @core.join_visible_parts(["hello", "", "world"])
  inspect(result, content="hello\n\nworld")
}

///|
test "join_visible_parts trims" {
  let result = @core.join_visible_parts(["  hello  "])
  inspect(result, content="hello")
}

///|
test "join_visible_parts empty array" {
  let result = @core.join_visible_parts([])
  inspect(result, content="")
}

// -- supports_vision --

///|
test "supports_vision openai" {
  inspect(@llm.supports_vision("openai"), content="true")
}

///|
test "supports_vision openrouter" {
  inspect(@llm.supports_vision("openrouter"), content="true")
}

///|
test "supports_vision ollama" {
  inspect(@llm.supports_vision("ollama"), content="true")
}

///|
test "supports_vision deepseek no vision" {
  inspect(@llm.supports_vision("deepseek"), content="false")
}

///|
test "supports_vision minimax no vision" {
  inspect(@llm.supports_vision("minimax"), content="false")
}

///|
test "supports_vision unknown provider" {
  inspect(@llm.supports_vision("unknown"), content="false")
}
