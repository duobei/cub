///|
/// Tests for ProgressiveToolView and schema builders.

// -- ProgressiveToolView --

///|
test "ProgressiveToolView new and all_tools" {
  let registry = @tools.ToolRegistry::new()
  registry.register("test_tool", "A test tool", handler=fn(_args) { "ok" })
  let view = @tools.ProgressiveToolView::new(registry)
  let tools = view.all_tools()
  inspect(tools.length(), content="1")
  inspect(tools[0], content="test_tool")
}

///|
test "ProgressiveToolView note_selected and expanded_block" {
  let registry = @tools.ToolRegistry::new()
  registry.register("bash", "Run command", handler=fn(_args) { "ok" })
  let view = @tools.ProgressiveToolView::new(registry)
  // Initially no expanded
  inspect(view.expanded_block(), content="")
  // Select a tool
  view.note_selected("bash")
  let block = view.expanded_block()
  inspect(block.contains("<tool_details>"), content="true")
  inspect(block.contains("bash"), content="true")
}

///|
test "ProgressiveToolView reset clears expanded" {
  let registry = @tools.ToolRegistry::new()
  registry.register("bash", "Run command", handler=fn(_args) { "ok" })
  let view = @tools.ProgressiveToolView::new(registry)
  view.note_selected("bash")
  inspect(view.expanded_block().length() > 0, content="true")
  view.reset()
  inspect(view.expanded_block(), content="")
}

///|
test "ProgressiveToolView note_hint matches tool" {
  let registry = @tools.ToolRegistry::new()
  registry.register("fs.read", "Read file", handler=fn(_args) { "ok" })
  let view = @tools.ProgressiveToolView::new(registry)
  let matched = view.note_hint("fs.read")
  inspect(matched, content="true")
  inspect(view.expanded_block().contains("fs.read"), content="true")
}

///|
test "ProgressiveToolView note_hint no match" {
  let registry = @tools.ToolRegistry::new()
  registry.register("bash", "Run command", handler=fn(_args) { "ok" })
  let view = @tools.ProgressiveToolView::new(registry)
  let matched = view.note_hint("nonexistent")
  inspect(matched, content="false")
}

///|
test "ProgressiveToolView compact_block" {
  let registry = @tools.ToolRegistry::new()
  registry.register("bash", "Run command", handler=fn(_args) { "ok" })
  let view = @tools.ProgressiveToolView::new(registry)
  let block = view.compact_block()
  inspect(block.contains("<tools>"), content="true")
  inspect(block.contains("bash"), content="true")
  inspect(block.contains("</tools>"), content="true")
}

///|
test "ProgressiveToolView compact_block empty registry" {
  let registry = @tools.ToolRegistry::new()
  let view = @tools.ProgressiveToolView::new(registry)
  inspect(view.compact_block(), content="")
}

// -- make_params --

///|
test "make_params basic schema" {
  let props : Map[String, Json] = {}
  props["name"] = @tools.string_prop("The name")
  let schema = @tools.make_params(props, ["name"])
  let s = schema.stringify()
  inspect(s.contains("\"type\":\"object\""), content="true")
  inspect(s.contains("\"required\""), content="true")
  inspect(s.contains("\"name\""), content="true")
}

///|
test "make_params no required" {
  let props : Map[String, Json] = {}
  props["path"] = @tools.string_prop("File path")
  let schema = @tools.make_params(props, [])
  let s = schema.stringify()
  inspect(s.contains("\"type\":\"object\""), content="true")
  // No required array when empty
  inspect(s.contains("required"), content="false")
}

// -- string_prop --

///|
test "string_prop creates string type schema" {
  let prop = @tools.string_prop("A description")
  let s = prop.stringify()
  inspect(s.contains("\"type\":\"string\""), content="true")
  inspect(s.contains("A description"), content="true")
}

// -- ToolRegistry unregister --

///|
test "ToolRegistry unregister removes tool" {
  let registry = @tools.ToolRegistry::new()
  registry.register("temp", "Temporary tool", handler=fn(_args) { "ok" })
  inspect(registry.has("temp"), content="true")
  registry.unregister("temp")
  inspect(registry.has("temp"), content="false")
}

///|
test "ToolRegistry unregister nonexistent is safe" {
  let registry = @tools.ToolRegistry::new()
  registry.unregister("nonexistent")
  // Should not crash
  inspect(registry.has("nonexistent"), content="false")
}

// -- render_tool_prompt_block --

///|
test "render_tool_prompt_block empty" {
  let registry = @tools.ToolRegistry::new()
  let view = @tools.ProgressiveToolView::new(registry)
  let block = @tools.render_tool_prompt_block(view)
  // With no tools, should be empty or minimal
  inspect(block.is_empty(), content="true")
}

///|
test "render_tool_prompt_block with tools" {
  let registry = @tools.ToolRegistry::new()
  registry.register("bash", "Run command", handler=fn(_args) { "ok" })
  let view = @tools.ProgressiveToolView::new(registry)
  let block = @tools.render_tool_prompt_block(view)
  inspect(block.contains("tools"), content="true")
}
