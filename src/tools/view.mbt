/// Tool view helpers.

/// Render the combined tool prompt section.
pub fn render_tool_prompt_block(view : ProgressiveToolView) -> String {
  let compact = view.compact_block()
  let expanded = view.expanded_block()
  if compact.length() == 0 && expanded.length() == 0 {
    return ""
  }
  let buf = StringBuilder::new()
  if compact.length() > 0 {
    buf.write_string(compact)
  }
  if expanded.length() > 0 {
    if compact.length() > 0 {
      buf.write_string("\n\n")
    }
    buf.write_string(expanded)
  }
  buf.to_string()
}
