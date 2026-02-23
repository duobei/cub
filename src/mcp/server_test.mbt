///|
/// Tests for MCP server JSON-RPC helpers.

// -- build_jsonrpc_response --

///|
test "build_jsonrpc_response format" {
  let resp = @mcp.build_jsonrpc_response((1).to_json(), "ok".to_json())
  let s = resp.stringify()
  inspect(s.contains("\"jsonrpc\":\"2.0\""), content="true")
  inspect(s.contains("\"id\":1"), content="true")
  inspect(s.contains("\"result\":\"ok\""), content="true")
}

// -- build_jsonrpc_error --

///|
test "build_jsonrpc_error format" {
  let resp = @mcp.build_jsonrpc_error((1).to_json(), -32601, "Method not found")
  let s = resp.stringify()
  inspect(s.contains("\"jsonrpc\":\"2.0\""), content="true")
  inspect(s.contains("\"id\":1"), content="true")
  inspect(s.contains("\"code\":-32601"), content="true")
  inspect(s.contains("Method not found"), content="true")
}

///|
test "build_jsonrpc_error with string id" {
  let resp = @mcp.build_jsonrpc_error("abc".to_json(), -32700, "Parse error")
  let s = resp.stringify()
  inspect(s.contains("\"id\":\"abc\""), content="true")
  inspect(s.contains("-32700"), content="true")
}

// -- build_jsonrpc_request (existing from client) --

///|
test "build_jsonrpc_request format" {
  let req = @mcp.build_jsonrpc_request(42, "tools/list", Json::object({}))
  inspect(req.contains("\"jsonrpc\":\"2.0\""), content="true")
  inspect(req.contains("\"id\":42"), content="true")
  inspect(req.contains("\"method\":\"tools/list\""), content="true")
}

// -- parse_jsonrpc_response (existing from client) --

///|
test "parse_jsonrpc_response result" {
  let resp = @mcp.parse_jsonrpc_response(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"status\":\"ok\"}}",
  )
  inspect(resp is Some(_), content="true")
}

///|
test "parse_jsonrpc_response error" {
  let resp = @mcp.parse_jsonrpc_response(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"not found\"}}",
  )
  match resp {
    Some({ "error": _, .. }) => ()
    _ => fail("expected error response")
  }
}

///|
test "parse_jsonrpc_response invalid" {
  let resp = @mcp.parse_jsonrpc_response("not json")
  inspect(resp is None, content="true")
}

// -- load_mcp_configs --

///|
test "load_mcp_configs valid" {
  let json =
    #|{"servers":[{"name":"test","command":"echo","args":["hello"],"env":{"FOO":"bar"}}]}
  let configs = @mcp.load_mcp_configs(json)
  inspect(configs.length(), content="1")
  inspect(configs[0].name, content="test")
  inspect(configs[0].command, content="echo")
  inspect(configs[0].args.length(), content="1")
  inspect(configs[0].args[0], content="hello")
}

///|
test "load_mcp_configs empty" {
  let configs = @mcp.load_mcp_configs("{}")
  inspect(configs.length(), content="0")
}

///|
test "load_mcp_configs invalid json" {
  let configs = @mcp.load_mcp_configs("not json")
  inspect(configs.length(), content="0")
}

// -- McpServer::new --

///|
test "McpServer new creates uninitialized server" {
  let registry = @tools.ToolRegistry::new()
  let server = @mcp.McpServer::new(registry)
  // Server starts uninitialized — verify it was created
  inspect(server.initialized, content="false")
}
