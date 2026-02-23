# Extensions

Cub supports external tool integration via MCP servers, script tools, and WASM plugins.

## MCP (Model Context Protocol)

Cub includes a built-in MCP client that connects to external tool servers via JSON-RPC 2.0 over stdio.

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

## Management

Use `tool.create`, `ext.list`, and `ext.remove` commands to manage extensions at runtime.
