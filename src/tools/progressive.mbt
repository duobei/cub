/// Progressive tool prompt rendering.
/// Shows compact listing by default, expands schema on demand via hints.

///|
/// Renders compact tool view and expands schema on demand.
pub struct ProgressiveToolView {
  registry : ToolRegistry
  expanded : Map[String, Bool]
}

///|
/// Create a new ProgressiveToolView.
pub fn ProgressiveToolView::new(registry : ToolRegistry) -> ProgressiveToolView {
  { registry, expanded: {} }
}

///|
/// Mark a tool as expanded (selected).
pub fn ProgressiveToolView::note_selected(
  self : ProgressiveToolView,
  name : String,
) -> Unit {
  self.expanded[name] = true
}

///|
/// Get all tool names.
pub fn ProgressiveToolView::all_tools(
  self : ProgressiveToolView,
) -> Array[String] {
  self.registry.descriptors().map(fn(d) { d.name })
}

///|
/// Reset expanded state.
pub fn ProgressiveToolView::reset(self : ProgressiveToolView) -> Unit {
  self.expanded.clear()
}

///|
/// Expand a tool when hint matches. Returns true if a tool was expanded.
pub fn ProgressiveToolView::note_hint(
  self : ProgressiveToolView,
  hint : String,
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

///|
/// Render compact tool listing block.
pub fn ProgressiveToolView::compact_block(self : ProgressiveToolView) -> String {
  let rows = self.registry.compact_rows(for_model=true)
  if rows.is_empty() {
    return ""
  }
  "<tools>\n" + rows.map(fn(r) { "- \{r}" }).join("\n") + "\n</tools>"
}

///|
/// Render expanded tool details block for tools that have been selected/hinted.
pub fn ProgressiveToolView::expanded_block(
  self : ProgressiveToolView,
) -> String {
  if self.expanded.is_empty() {
    return ""
  }
  let entries : Array[String] = []
  for name, _ in self.expanded {
    let detail = self.registry.detail(name)
    entries.push("## \{name}: \{detail}")
  }
  "<tool_details>\n" + entries.join("\n") + "\n</tool_details>"
}
