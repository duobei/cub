///|
test "derive_tool_name strips extension" {
  inspect(@ext.derive_tool_name("check-pr.sh"), content="check-pr")
  inspect(@ext.derive_tool_name("my_tool.py"), content="my_tool")
  inspect(@ext.derive_tool_name("simple"), content="simple")
  inspect(@ext.derive_tool_name("multi.dot.name.sh"), content="multi.dot.name")
}

///|
test "derive_tool_name handles edge cases" {
  inspect(@ext.derive_tool_name(".hidden"), content=".hidden")
  inspect(@ext.derive_tool_name("a.b"), content="a")
}

///|
test "discover_extensions returns empty for nonexistent dirs" {
  let results = @ext.discover_extensions("/nonexistent/home", "/nonexistent/ws")
  inspect(results.length(), content="0")
}
