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
test "to_model_name converts new tool names" {
  inspect(@tools.to_model_name("fs.list"), content="fs_list")
  inspect(@tools.to_model_name("fs.glob"), content="fs_glob")
  inspect(@tools.to_model_name("grep"), content="grep")
}

///|
test "ToolRegistry::compact_rows" {
  let reg = @tools.ToolRegistry::new()
  reg.register("bash", "run command", handler=fn(_args) { "ok" })
  let rows = reg.compact_rows()
  inspect(rows.length(), content="1")
  inspect(rows[0], content="bash: run command")
}

///|
test "to_model_name converts self-evolving tool names" {
  inspect(@tools.to_model_name("skill.create"), content="skill_create")
  inspect(@tools.to_model_name("skill.install"), content="skill_install")
  inspect(@tools.to_model_name("agents.update"), content="agents_update")
}

///|
test "extract_skill_name from valid frontmatter" {
  let content = "---\nname: my-skill\ndescription: a test\n---\n\nbody"
  inspect(@tools.extract_skill_name(content), content="my-skill")
}

///|
test "extract_skill_name from empty content" {
  inspect(@tools.extract_skill_name(""), content="")
}

///|
test "extract_skill_name from content without frontmatter" {
  inspect(@tools.extract_skill_name("no frontmatter here"), content="")
}

///|
test "extract_skill_name with spaces around name" {
  let content = "---\nname:   hello-world  \ndescription: test\n---\n"
  inspect(@tools.extract_skill_name(content), content="hello-world")
}

///|
test "parse_ddg_results respects max_results" {
  let html = "T1\nhttps://a.com\nsnippet1\nT2\nhttps://b.com\nsnippet2\nT3\nhttps://c.com\nsnippet3"
  let result = @tools.parse_ddg_results(html, 1)
  inspect(result.contains("https://a.com"), content="true")
  inspect(result.contains("https://c.com"), content="false")
}

///|
test "parse_ddg_results skips duckduckgo URLs" {
  let html = "DDG\nhttps://duckduckgo.com/something\nfoo\nReal\nhttps://example.com\nbar"
  let result = @tools.parse_ddg_results(html, 5)
  inspect(result.contains("duckduckgo.com"), content="false")
  inspect(result.contains("example.com"), content="true")
}

///|
test "parse_ddg_results no results" {
  let result = @tools.parse_ddg_results("no links here", 5)
  inspect(result, content="No results found.")
}

///|
test "parse_ddg_results extracts URLs" {
  let html = "Some intro\nExample Title\nhttps://example.com/page\nThis is a snippet about example.\nAnother Title\nhttps://another.org/docs\nAnother snippet."
  let result = @tools.parse_ddg_results(html, 5)
  inspect(result.contains("Example Title"), content="true")
  inspect(result.contains("https://example.com/page"), content="true")
  inspect(result.contains("Another Title"), content="true")
}
