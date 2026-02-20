/// Input command detection.

/// Detect whether one line should be treated as a command.
pub fn detect_line_command(line : String) -> DetectedCommand? {
  let stripped = line.trim().to_string()
  if stripped.length() == 0 {
    return None
  }
  if stripped[0] == ','.to_int().to_uint16() {
    let (name, args_tokens) = parse_internal_command(stripped)
    if name.length() == 0 {
      return None
    }
    Some({ kind: "internal", raw: stripped, name, args_tokens })
  } else {
    None
  }
}
