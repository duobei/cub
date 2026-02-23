# Extensions

Cub supports external tool integration via MCP servers, script tools, and WASM plugins.

## MCP (Model Context Protocol)

Cub includes both an MCP client and an MCP server, communicating via JSON-RPC 2.0 over stdio.

### MCP Server Mode

Run `cub serve` to expose all registered tools as an MCP server. External agents or tools can call Cub's tools via the standard MCP protocol:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test"}}}' | cub serve
```

Supported methods: `initialize`, `tools/list`, `tools/call`.

### MCP Client

Cub's built-in MCP client connects to external tool servers.

Configure servers in `~/.cub/mcp.json`:

```json
{
  "servers": [
    {
      "name": "my-tools",
      "command": "/usr/bin/my-tool-server",
      "args": ["--verbose"],
      "env": { "API_KEY": "secret" }
    }
  ]
}
```

Discovered tools are registered as `mcp.<server>.<tool>` and appear alongside built-in tools.

## Script Tools

Place an executable script (e.g., `check-pr.sh`) in a tools directory. Optionally add a `check-pr.json` companion manifest for description and parameter schema.

## WASM Plugins

Place a MoonBit WASM plugin directory with a `plugin.json` manifest:

```json
{
  "name": "my-plugin",
  "description": "What the plugin does",
  "parameters": { "type": "object", "properties": {} }
}
```

## Discovery Paths

| Priority | Scripts | WASM Plugins |
|----------|---------|--------------|
| 1 (workspace) | `.agent/tools/` | `.agent/plugins/` |
| 2 (global) | `~/.cub/tools/` | `~/.cub/plugins/` |

## WASM Plugin Features

- **Parameter validation** — if `plugin.json` defines `required` fields, they are validated before execution
- **Available tools context** — WASM plugins receive an `available_tools` array in their input JSON, listing all registered tools
- **Bidirectional tool calls** — plugins can output `{"type":"tool_call","name":"...","args":{}}` JSONL lines to invoke other registered tools; results are appended to the output

## Management

Use `tool.create`, `ext.list`, and `ext.remove` commands to manage extensions at runtime.
