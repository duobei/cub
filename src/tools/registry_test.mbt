///|
/// Tests for tool registry.
test "ToolRegistry::register and has" {
  let reg = @tools.ToolRegistry::new()
  reg.register("test_tool", "a test tool", handler=fn(_args) { "ok" })
  inspect(reg.has("test_tool"), content="true")
  inspect(reg.has("missing"), content="false")
}

///|
test "ToolRegistry::needs_confirmation default false" {
  let reg = @tools.ToolRegistry::new()
  reg.register("safe_tool", "safe", handler=fn(_args) { "ok" })
  inspect(reg.needs_confirmation("safe_tool"), content="false")
}

///|
test "ToolRegistry::needs_confirmation set true" {
  let reg = @tools.ToolRegistry::new()
  reg.register("bash", "run command", requires_confirmation=true, handler=fn(
    _args,
  ) {
    "ok"
  })
  inspect(reg.needs_confirmation("bash"), content="true")
}

///|
test "ToolRegistry::needs_confirmation unknown tool" {
  let reg = @tools.ToolRegistry::new()
  inspect(reg.needs_confirmation("nonexistent"), content="false")
}

///|
test "ToolRegistry::allowed_tools filter" {
  let reg = @tools.ToolRegistry::new(allowed_tools=Some(["allowed"]))
  reg.register("allowed", "ok", handler=fn(_args) { "ok" })
  reg.register("blocked", "nope", handler=fn(_args) { "ok" })
  inspect(reg.has("allowed"), content="true")
  inspect(reg.has("blocked"), content="false")
}

///|
test "to_model_name converts dots to underscores" {
  inspect(@tools.to_model_name("fs.read"), content="fs_read")
  inspect(@tools.to_model_name("memory.save"), content="memory_save")
  inspect(@tools.to_model_name("bash"), content="bash")
}

///|
test "from_model_name converts back" {
  let reg = @tools.ToolRegistry::new()
  reg.register("fs.read", "read file", handler=fn(_args) { "ok" })
  inspect(@tools.from_model_name("fs_read", reg), content="fs.read")
  inspect(@tools.from_model_name("fs.read", reg), content="fs.read")
}

///|
test "ToolRegistry::model_tools generates OpenAI format" {
  let reg = @tools.ToolRegistry::new()
  reg.register("bash", "run command", handler=fn(_args) { "ok" })
  let tools = reg.model_tools()
  inspect(tools.length(), content="1")
  match tools[0] {
    { "type": String(t), "function": { "name": String(n), .. }, .. } => {
      inspect(t, content="function")
      inspect(n, content="bash")
    }
    _ => fail("unexpected format")
  }
}

///|
test "ToolRegistry::compact_rows" {
  let reg = @tools.ToolRegistry::new()
  reg.register("bash", "run command", handler=fn(_args) { "ok" })
  let rows = reg.compact_rows()
  inspect(rows.length(), content="1")
  inspect(rows[0], content="bash: run command")
}
