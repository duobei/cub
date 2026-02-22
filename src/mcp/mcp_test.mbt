/// Tests for MCP client.

///|
test "build_jsonrpc_request: contains method and id" {
  let req = @mcp.build_jsonrpc_request(1, "tools/list", Json::object({}))
  // Verify it's valid JSON containing expected fields
  inspect(req.contains("\"jsonrpc\":\"2.0\""), content="true")
  inspect(req.contains("\"id\":1"), content="true")
  inspect(req.contains("\"method\":\"tools/list\""), content="true")
}

///|
test "parse_jsonrpc_response: success result" {
  let text =
    #|{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
  let result = @mcp.parse_jsonrpc_response(text)
  inspect(result is None, content="false")
}

///|
test "parse_jsonrpc_response: error result" {
  let text =
    #|{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"invalid"}}
  let result = @mcp.parse_jsonrpc_response(text)
  inspect(result is None, content="false")
}

///|
test "parse_jsonrpc_response: invalid json" {
  let result = @mcp.parse_jsonrpc_response("not json")
  inspect(result is None, content="true")
}

///|
test "load_mcp_configs: valid config" {
  let json =
    #|{"servers":[{"name":"test","command":"echo","args":["-n"],"env":{"FOO":"bar"}}]}
  let configs = @mcp.load_mcp_configs(json)
  inspect(configs.length(), content="1")
  inspect(configs[0].name, content="test")
  inspect(configs[0].command, content="echo")
  inspect(configs[0].args.length(), content="1")
  inspect(configs[0].args[0], content="-n")
}

///|
test "load_mcp_configs: empty servers" {
  let configs = @mcp.load_mcp_configs("{\"servers\":[]}")
  inspect(configs.length(), content="0")
}

///|
test "load_mcp_configs: invalid json" {
  let configs = @mcp.load_mcp_configs("not json")
  inspect(configs.length(), content="0")
}
