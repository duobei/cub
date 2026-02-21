/// Command parsing helpers.

///|
/// Parsed command arguments.
pub struct ParsedArgs {
  kwargs : Map[String, String]
  positional : Array[String]
} derive(Show)

///|
/// Split command text into words using simple shell-like rules.
/// Handles double-quoted strings and backslash escapes.
pub fn parse_command_words(text : String) -> Array[String] {
  let words : Array[String] = []
  let buf = StringBuilder::new()
  let mut in_quote = false
  let mut escaped = false
  let mut has_content = false
  for ch in text {
    if escaped {
      buf.write_char(ch)
      has_content = true
      escaped = false
      continue
    }
    if ch == '\\' {
      escaped = true
      continue
    }
    if ch == '"' {
      in_quote = not(in_quote)
      has_content = true
      continue
    }
    if ch == '\'' {
      // For simplicity, treat single quotes same as double
      in_quote = not(in_quote)
      has_content = true
      continue
    }
    if not(in_quote) && (ch == ' ' || ch == '\t') {
      if has_content {
        words.push(buf.to_string())
        buf.reset()
        has_content = false
      }
      continue
    }
    buf.write_char(ch)
    has_content = true
  }
  if has_content {
    words.push(buf.to_string())
  }
  words
}

///|
/// Parse ',name ...' command line into name and args tokens.
pub fn parse_internal_command(line : String) -> (String, Array[String]) {
  let trimmed = line.trim().to_string()
  if trimmed.is_empty() {
    return ("", [])
  }
  // Strip leading comma
  let body = if trimmed[0] == ','.to_int().to_uint16() {
    trimmed[1:].to_string() catch {
      _ => ""
    }
  } else {
    trimmed
  }
  let body_trimmed = body.trim().to_string()
  let words = parse_command_words(body_trimmed)
  if words.is_empty() {
    return ("", [])
  }
  let name = words[0]
  let args : Array[String] = []
  for i = 1; i < words.length(); i = i + 1 {
    args.push(words[i])
  }
  (name, args)
}

///|
/// Parse tool arguments from tokens: supports key=value, --key value, --key, and positional.
pub fn parse_kv_arguments(tokens : Array[String]) -> ParsedArgs {
  let kwargs : Map[String, String] = {}
  let positional : Array[String] = []
  let mut idx = 0
  while idx < tokens.length() {
    let token = tokens[idx]
    if token.length() >= 2 && token.has_prefix("--") {
      let key = token[2:].to_string() catch { _ => token }
      // Check for --key=value
      let eq_pos = find_char(key, '=')
      if eq_pos >= 0 {
        let k = key[:eq_pos].to_string() catch { _ => key }
        let v = key[eq_pos + 1:].to_string() catch { _ => "" }
        kwargs[k] = v
        idx += 1
        continue
      }
      // Check for --key value
      if idx + 1 < tokens.length() && not(tokens[idx + 1].has_prefix("--")) {
        kwargs[key] = tokens[idx + 1]
        idx += 2
        continue
      }
      // Boolean flag
      kwargs[key] = "true"
      idx += 1
      continue
    }
    // Check for key=value
    let eq_pos = find_char(token, '=')
    if eq_pos > 0 {
      let k = token[:eq_pos].to_string() catch { _ => token }
      let v = token[eq_pos + 1:].to_string() catch { _ => "" }
      kwargs[k] = v
      idx += 1
      continue
    }
    positional.push(token)
    idx += 1
  }
  { kwargs, positional }
}

///|
/// Helper: find character position in string, returns -1 if not found.
fn find_char(s : String, ch : Char) -> Int {
  let target = ch.to_int().to_uint16()
  for i = 0; i < s.length(); i = i + 1 {
    if s[i] == target {
      return i
    }
  }
  -1
}
