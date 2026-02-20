/// Progressive tool prompt rendering.
/// Shows compact listing by default, expands schema on demand via hints.

/// Renders compact tool view and expands schema on demand.
pub struct ProgressiveToolView {
  registry : ToolRegistry
  expanded : Map[String, Bool]
}

/// Create a new ProgressiveToolView.
pub fn ProgressiveToolView::new(registry : ToolRegistry) -> ProgressiveToolView {
  { registry, expanded: {} }
}

/// Mark a tool as expanded (selected).
pub fn ProgressiveToolView::note_selected(
  self : ProgressiveToolView,
  name : String
) -> Unit {
  self.expanded[name] = true
}

/// Get all tool names.
pub fn ProgressiveToolView::all_tools(
  self : ProgressiveToolView
) -> Array[String] {
  let names : Array[String] = []
  for d in self.registry.descriptors() {
    names.push(d.name)
  }
  names
}

/// Reset expanded state.
pub fn ProgressiveToolView::reset(self : ProgressiveToolView) -> Unit {
  self.expanded.clear()
}

/// Expand a tool when hint matches. Returns true if a tool was expanded.
pub fn ProgressiveToolView::note_hint(
  self : ProgressiveToolView,
  hint : String
) -> Bool {
  // Check if hint matches a tool name or model name
  for d in self.registry.descriptors() {
    if d.name == hint || to_model_name(d.name) == hint {
      self.expanded[d.name] = true
      return true
    }
  }
  false
}

/// Render compact tool listing block.
pub fn ProgressiveToolView::compact_block(self : ProgressiveToolView) -> String {
  let rows = self.registry.compact_rows(for_model=true)
  if rows.length() == 0 {
    return ""
  }
  let buf = StringBuilder::new()
  buf.write_string("<tools>\n")
  for row in rows {
    buf.write_string("- ")
    buf.write_string(row)
    buf.write_char('\n')
  }
  buf.write_string("</tools>")
  buf.to_string()
}

/// Render expanded tool details block for tools that have been selected/hinted.
pub fn ProgressiveToolView::expanded_block(
  self : ProgressiveToolView
) -> String {
  if self.expanded.length() == 0 {
    return ""
  }
  let buf = StringBuilder::new()
  buf.write_string("<tool_details>\n")
  for name, _ in self.expanded {
    let detail = self.registry.detail(name)
    buf.write_string("## ")
    buf.write_string(name)
    buf.write_string(": ")
    buf.write_string(detail)
    buf.write_char('\n')
  }
  buf.write_string("</tool_details>")
  buf.to_string()
}
