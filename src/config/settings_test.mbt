///|
/// Tests for settings and .env parsing.
test "parse_dotenv basic key=value" {
  let env = parse_dotenv("KEY=value")
  inspect(env.get("KEY").unwrap(), content="value")
}

///|
test "parse_dotenv quoted values" {
  let env = parse_dotenv("KEY=\"hello world\"")
  inspect(env.get("KEY").unwrap(), content="hello world")
}

///|
test "parse_dotenv single quoted values" {
  let env = parse_dotenv("KEY='hello world'")
  inspect(env.get("KEY").unwrap(), content="hello world")
}

///|
test "parse_dotenv skips comments" {
  let content = "# comment\nKEY=value\n# another comment"
  let env = parse_dotenv(content)
  inspect(env.length(), content="1")
  inspect(env.get("KEY").unwrap(), content="value")
}

///|
test "parse_dotenv skips empty lines" {
  let content = "\nKEY=value\n\nKEY2=value2\n"
  let env = parse_dotenv(content)
  inspect(env.length(), content="2")
}

///|
test "parse_dotenv value with equals sign" {
  let env = parse_dotenv("URL=https://example.com?a=1&b=2")
  inspect(env.get("URL").unwrap(), content="https://example.com?a=1&b=2")
}

///|
test "parse_dotenv_line comment returns None" {
  let result = parse_dotenv_line("# comment")
  inspect(result is None, content="true")
}

///|
test "parse_dotenv_line empty returns None" {
  let result = parse_dotenv_line("")
  inspect(result is None, content="true")
}

///|
test "parse_dotenv_line no equals returns None" {
  let result = parse_dotenv_line("NOEQUALS")
  inspect(result is None, content="true")
}

///|
test "parse_dotenv multiple entries" {
  let content = "A=1\nB=2\nC=3"
  let env = parse_dotenv(content)
  inspect(env.length(), content="3")
  inspect(env.get("A").unwrap(), content="1")
  inspect(env.get("B").unwrap(), content="2")
  inspect(env.get("C").unwrap(), content="3")
}

///|
test "get_env_bool true values" {
  let env : Map[String, String] = {}
  env["A"] = "true"
  env["B"] = "1"
  env["C"] = "yes"
  env["D"] = "TRUE"
  inspect(get_env_bool(env, "A").unwrap(), content="true")
  inspect(get_env_bool(env, "B").unwrap(), content="true")
  inspect(get_env_bool(env, "C").unwrap(), content="true")
  inspect(get_env_bool(env, "D").unwrap(), content="true")
}

///|
test "get_env_bool false values" {
  let env : Map[String, String] = {}
  env["A"] = "false"
  env["B"] = "0"
  env["C"] = "no"
  inspect(get_env_bool(env, "A").unwrap(), content="false")
  inspect(get_env_bool(env, "B").unwrap(), content="false")
  inspect(get_env_bool(env, "C").unwrap(), content="false")
}

///|
test "get_env_bool unknown returns None" {
  let env : Map[String, String] = {}
  env["A"] = "maybe"
  inspect(get_env_bool(env, "A") is None, content="true")
}

///|
test "get_env_int valid integer" {
  let env : Map[String, String] = {}
  env["N"] = "42"
  inspect(get_env_int(env, "N").unwrap(), content="42")
}

///|
test "get_env_int invalid returns None" {
  let env : Map[String, String] = {}
  env["N"] = "abc"
  inspect(get_env_int(env, "N") is None, content="true")
}

///|
test "get_env_list comma separated" {
  let env : Map[String, String] = {}
  env["LIST"] = "a, b, c"
  let result = get_env_list(env, "LIST")
  inspect(result.length(), content="3")
  inspect(result[0], content="a")
  inspect(result[1], content="b")
  inspect(result[2], content="c")
}

///|
test "get_env_list json array" {
  let env : Map[String, String] = {}
  env["LIST"] = "[\"x\", \"y\"]"
  let result = get_env_list(env, "LIST")
  inspect(result.length(), content="2")
  inspect(result[0], content="x")
  inspect(result[1], content="y")
}

///|
test "get_env_list missing key returns empty" {
  let env : Map[String, String] = {}
  let result = get_env_list(env, "MISSING")
  inspect(result.length(), content="0")
}

///|
test "Settings default values" {
  let s = Settings::default()
  inspect(s.max_tokens, content="1024")
  inspect(s.max_steps, content="100")
  inspect(s.proactive_response, content="false")
  inspect(s.telegram_enabled, content="false")
  inspect(s.discord_enabled, content="false")
  inspect(s.discord_command_prefix, content="!")
}

///|
test "Settings with_overrides applies model" {
  let s = Settings::default().with_overrides(model=Some("ollama:llama3"))
  inspect(s.model, content="ollama:llama3")
  // Other fields unchanged
  inspect(s.max_tokens, content="1024")
}

///|
test "Settings with_overrides applies max_tokens" {
  let s = Settings::default().with_overrides(max_tokens=Some(2048))
  inspect(s.max_tokens, content="2048")
}

///|
test "Settings with_overrides None leaves original" {
  let s = Settings::default().with_overrides()
  inspect(s.model, content="openrouter:qwen/qwen3-coder-next")
}

///|
test "string_to_cstr null terminated" {
  let bytes = string_to_cstr("hi")
  // "hi" = 2 UTF-8 bytes + 1 null terminator = 3
  inspect(bytes.length(), content="3")
  inspect(bytes[2], content="b'\\x00'")
}
