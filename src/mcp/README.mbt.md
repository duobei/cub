# MCP — Model Context Protocol Client

The `mcp` package implements a JSON-RPC 2.0 client for the Model Context
Protocol (MCP), communicating with tool servers over stdio pipes.

## Server Configuration

Load MCP server configs from a JSON configuration file.

```mbt nocheck
///|
test "load mcp configs" {
  let json =
    #|{
    #|  "servers": [
    #|    {
    #|      "name": "my-tools",
    #|      "command": "/usr/bin/my-tool-server",
    #|      "args": ["--port", "3000"],
    #|      "env": { "API_KEY": "secret" }
    #|    }
    #|  ]
    #|}
  let configs = @mcp.load_mcp_configs(json)
  inspect(configs.length(), content="1")
  inspect(configs[0].name, content="my-tools")
  inspect(configs[0].command, content="/usr/bin/my-tool-server")
  inspect(configs[0].args.length(), content="2")
}
```

## JSON-RPC Message Building

```mbt nocheck
///|
test "build jsonrpc request" {
  let req = @mcp.build_jsonrpc_request(1, "tools/list", {})
  // Returns a valid JSON-RPC 2.0 request string
  let parsed = @json.parse(req)
  match parsed {
    Ok({ "jsonrpc": String(v), "method": String(m), "id": Number(id), .. }) => {
      inspect(v, content="2.0")
      inspect(m, content="tools/list")
      inspect(id, content="1")
    }
    _ => fail("invalid jsonrpc request")
  }
}
```

## Response Parsing

```mbt nocheck
///|
test "parse jsonrpc response" {
  let response =
    #|{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
  let result = @mcp.parse_jsonrpc_response(response)
  inspect(result is None, content="false")
}

///|
test "parse jsonrpc error response" {
  let response =
    #|{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"not found"}}
  let result = @mcp.parse_jsonrpc_response(response)
  // Error responses return None
  inspect(result is None, content="true")
}
```

## Client Lifecycle

The `McpClient` follows a connect-discover-call-stop lifecycle:

1. `McpClient::new(config)` — Create client from config
2. `client.start()` — Spawn server process and initialize
3. `client.discover_tools()` — List available tools
4. `client.call_tool(name, args)` — Invoke a tool
5. `client.stop()` — Terminate server process

Steps 2-5 are async and require a running MCP server process.
