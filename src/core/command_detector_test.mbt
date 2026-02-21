///|
/// Tests for command detection and parsing.
test "detect_line_command empty string" {
  let result = detect_line_command("")
  inspect(result is None, content="true")
}

///|
test "detect_line_command normal text not a command" {
  let result = detect_line_command("hello world")
  inspect(result is None, content="true")
}

///|
test "detect_line_command comma prefix detected" {
  let result = detect_line_command(",help")
  match result {
    Some(cmd) => {
      inspect(cmd.kind, content="internal")
      inspect(cmd.name, content="help")
      inspect(cmd.args_tokens.length(), content="0")
    }
    None => fail("expected command")
  }
}

///|
test "detect_line_command with args" {
  let result = detect_line_command(",tool.describe bash")
  match result {
    Some(cmd) => {
      inspect(cmd.name, content="tool.describe")
      inspect(cmd.args_tokens.length(), content="1")
      inspect(cmd.args_tokens[0], content="bash")
    }
    None => fail("expected command")
  }
}

///|
test "detect_line_command comma only returns None" {
  let result = detect_line_command(",")
  inspect(result is None, content="true")
}

///|
test "parse_internal_command basic" {
  let (name, args) = parse_internal_command(",help")
  inspect(name, content="help")
  inspect(args.length(), content="0")
}

///|
test "parse_internal_command with args" {
  let (name, args) = parse_internal_command(",bash echo hello")
  inspect(name, content="bash")
  inspect(args.length(), content="2")
  inspect(args[0], content="echo")
  inspect(args[1], content="hello")
}

///|
test "parse_internal_command empty" {
  let (name, _args) = parse_internal_command("")
  inspect(name, content="")
}

///|
test "parse_command_words simple" {
  let words = parse_command_words("hello world")
  inspect(words.length(), content="2")
  inspect(words[0], content="hello")
  inspect(words[1], content="world")
}

///|
test "parse_command_words quoted string" {
  let words = parse_command_words("echo \"hello world\"")
  inspect(words.length(), content="2")
  inspect(words[0], content="echo")
  inspect(words[1], content="hello world")
}

///|
test "parse_command_words escaped character" {
  let words = parse_command_words("echo hello\\ world")
  inspect(words.length(), content="2")
  inspect(words[0], content="echo")
  inspect(words[1], content="hello world")
}

///|
test "parse_command_words empty" {
  let words = parse_command_words("")
  inspect(words.length(), content="0")
}

///|
test "parse_kv_arguments key=value" {
  let parsed = parse_kv_arguments(["key=value"])
  inspect(parsed.kwargs.get("key").unwrap(), content="value")
  inspect(parsed.positional.length(), content="0")
}

///|
test "parse_kv_arguments --flag value" {
  let parsed = parse_kv_arguments(["--name", "test"])
  inspect(parsed.kwargs.get("name").unwrap(), content="test")
}

///|
test "parse_kv_arguments --flag=value" {
  let parsed = parse_kv_arguments(["--name=test"])
  inspect(parsed.kwargs.get("name").unwrap(), content="test")
}

///|
test "parse_kv_arguments boolean flag" {
  let parsed = parse_kv_arguments(["--verbose"])
  inspect(parsed.kwargs.get("verbose").unwrap(), content="true")
}

///|
test "parse_kv_arguments positional" {
  let parsed = parse_kv_arguments(["pos1", "pos2"])
  inspect(parsed.positional.length(), content="2")
  inspect(parsed.positional[0], content="pos1")
}

///|
test "parse_kv_arguments mixed" {
  let parsed = parse_kv_arguments(["--name", "test", "file.txt", "--verbose"])
  inspect(parsed.kwargs.get("name").unwrap(), content="test")
  inspect(parsed.kwargs.get("verbose").unwrap(), content="true")
  inspect(parsed.positional.length(), content="1")
  inspect(parsed.positional[0], content="file.txt")
}
