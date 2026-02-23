///|
/// Tests for extension helpers.

///|
test "derive_tool_name strips extension" {
  inspect(@ext.derive_tool_name("check-pr.sh"), content="check-pr")
}

///|
test "derive_tool_name strips py extension" {
  inspect(@ext.derive_tool_name("my_tool.py"), content="my_tool")
}

///|
test "derive_tool_name no extension" {
  inspect(@ext.derive_tool_name("mytool"), content="mytool")
}

///|
test "derive_tool_name wasm extension" {
  inspect(@ext.derive_tool_name("plugin.wasm"), content="plugin")
}

///|
test "ExtType equality" {
  inspect(@ext.ExtType::Script == @ext.ExtType::Script, content="true")
  inspect(@ext.ExtType::Wasm == @ext.ExtType::Wasm, content="true")
  inspect(@ext.ExtType::Script == @ext.ExtType::Wasm, content="false")
}

///|
test "ExtType show" {
  inspect(@ext.ExtType::Script.to_string(), content="Script")
  inspect(@ext.ExtType::Wasm.to_string(), content="Wasm")
}
