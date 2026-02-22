/// MCP client — JSON-RPC 2.0 over stdio transport.

///|
/// FFI: spawn a child process with bidirectional pipes.
#borrow(command, args, env_keys, env_vals)
extern "C" fn cub_mcp_spawn(
  command : Bytes,
  args : Bytes,
  env_keys : Bytes,
  env_vals : Bytes,
) -> Int = "cub_mcp_spawn"

///|
/// FFI: write data to child stdin.
#borrow(data)
extern "C" fn cub_mcp_write(slot : Int, data : Bytes, len : Int) -> Int = "cub_mcp_write"

///|
/// FFI: read data from child stdout.
#borrow(buf)
extern "C" fn cub_mcp_read(slot : Int, buf : Bytes, buf_size : Int) -> Int = "cub_mcp_read"

///|
/// FFI: kill child process.
extern "C" fn cub_mcp_kill(slot : Int) -> Int = "cub_mcp_kill"

///|
/// FFI: check if process is alive.
extern "C" fn cub_mcp_alive(slot : Int) -> Int = "cub_mcp_alive"

///|
/// Create a new MCP client for a server configuration.
pub fn McpClient::new(config : McpServerConfig) -> McpClient {
  { config, slot: -1, request_id: 0, initialized: false, tools: [] }
}

///|
/// Check if the MCP server process is still alive.
pub fn McpClient::is_alive(self : McpClient) -> Bool {
  if self.slot < 0 {
    return false
  }
  cub_mcp_alive(self.slot) == 1
}

///|
/// Start the MCP server process and perform initialization handshake.
pub async fn McpClient::start(self : McpClient) -> Bool {
  let cmd = @config.string_to_cstr(self.config.command)
  let args_str = self.config.args.join("\n")
  let args = @config.string_to_cstr(args_str)
  let env_keys_arr : Array[String] = []
  let env_vals_arr : Array[String] = []
  for k, v in self.config.env {
    env_keys_arr.push(k)
    env_vals_arr.push(v)
  }
  let env_keys = @config.string_to_cstr(env_keys_arr.join("\n"))
  let env_vals = @config.string_to_cstr(env_vals_arr.join("\n"))
  let slot = cub_mcp_spawn(cmd, args, env_keys, env_vals)
  if slot < 0 {
    @log.error("mcp", "failed to spawn process: \{self.config.command}")
    return false
  }
  self.slot = slot
  @log.info("mcp", "spawned \{self.config.name} (slot \{slot})")
  // Wait briefly for process to start
  @async.sleep(500)
  // Send initialize request
  let init_result = self.send_request("initialize", {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": { "name": "cub", "version": "0.1.0" },
  })
  match init_result {
    Some(_) => {
      // Send initialized notification
      self.send_notification("notifications/initialized", Json::object({}))
      self.initialized = true
      @log.info("mcp", "\{self.config.name} initialized")
      true
    }
    None => {
      @log.error("mcp", "\{self.config.name} initialization failed")
      false
    }
  }
}

///|
/// Discover tools from the MCP server.
pub async fn McpClient::discover_tools(self : McpClient) -> Array[McpTool] {
  if not(self.initialized) {
    return []
  }
  let result = self.send_request("tools/list", Json::object({}))
  match result {
    Some({ "tools": Array(tools), .. }) => {
      self.tools.clear()
      for tool in tools {
        let name = match tool {
          { "name": String(n), .. } => n
          _ => continue
        }
        let description = match tool {
          { "description": String(d), .. } => d
          _ => ""
        }
        let input_schema = match tool {
          { "inputSchema": schema, .. } => schema
          _ => Json::object({})
        }
        self.tools.push({ name, description, input_schema })
      }
      @log.info(
        "mcp",
        "\{self.config.name}: discovered \{self.tools.length()} tools",
      )
      self.tools
    }
    _ => {
      @log.warn("mcp", "\{self.config.name}: tools/list failed")
      []
    }
  }
}

///|
/// Call a tool on the MCP server.
pub async fn McpClient::call_tool(
  self : McpClient,
  name : String,
  arguments : Json,
) -> String {
  if not(self.initialized) {
    return "error: MCP server not initialized"
  }
  let params : Map[String, Json] = {}
  params["name"] = name.to_json()
  params["arguments"] = arguments
  let result = self.send_request("tools/call", Json::object(params))
  match result {
    Some({ "content": Array(parts), .. }) => {
      let texts : Array[String] = []
      for part in parts {
        match part {
          { "type": String("text"), "text": String(t), .. } => texts.push(t)
          _ => ()
        }
      }
      texts.join("\n")
    }
    Some({ "error": error, .. }) => "error: \{error.stringify()}"
    Some(other) => other.stringify()
    None => "error: no response from MCP server"
  }
}

///|
/// Stop the MCP server process.
pub fn McpClient::stop(self : McpClient) -> Unit {
  if self.slot >= 0 {
    ignore(cub_mcp_kill(self.slot))
    @log.info("mcp", "stopped \{self.config.name}")
    self.slot = -1
    self.initialized = false
  }
}

///|
/// Send a JSON-RPC request and wait for response.
async fn McpClient::send_request(
  self : McpClient,
  rpc_method : String,
  params : Json,
) -> Json? {
  self.request_id += 1
  let id = self.request_id
  let req : Map[String, Json] = {}
  req["jsonrpc"] = "2.0".to_json()
  req["id"] = id.to_json()
  req["method"] = rpc_method.to_json()
  req["params"] = params
  let msg = Json::object(req).stringify()
  let line = "\{msg}\n"
  let line_bytes = @utf8.encode(line)
  let written = cub_mcp_write(self.slot, line_bytes, line_bytes.length())
  if written < 0 {
    @log.error("mcp", "write failed for \{rpc_method}")
    return None
  }
  // Read response with timeout (up to 30s)
  let buf = Bytes::new(65536)
  let response_buf = StringBuilder::new()
  let mut attempts = 0
  while attempts < 300 {
    attempts += 1
    let n = cub_mcp_read(self.slot, buf, 65536)
    if n > 0 {
      response_buf.write_string(@utf8.decode_lossy(buf[:n]))
      let text = response_buf.to_string()
      // Look for complete JSON-RPC response (newline-delimited)
      match find_jsonrpc_response(text, id) {
        Some(result) => return Some(result)
        None => ()
      }
    } else if n < 0 {
      @log.error("mcp", "read error for \{rpc_method}")
      return None
    }
    @async.sleep(100)
  }
  @log.warn("mcp", "timeout waiting for response to \{rpc_method}")
  None
}

///|
/// Send a JSON-RPC notification (no response expected).
fn McpClient::send_notification(
  self : McpClient,
  rpc_method : String,
  params : Json,
) -> Unit {
  let req : Map[String, Json] = {}
  req["jsonrpc"] = "2.0".to_json()
  req["method"] = rpc_method.to_json()
  req["params"] = params
  let msg = Json::object(req).stringify()
  let line = "\{msg}\n"
  let line_bytes = @utf8.encode(line)
  ignore(cub_mcp_write(self.slot, line_bytes, line_bytes.length()))
}

///|
/// Find a JSON-RPC response with matching ID in newline-delimited text.
fn find_jsonrpc_response(text : String, id : Int) -> Json? {
  for line in text.split("\n") {
    let line_str = line.to_string().trim().to_string()
    if line_str.is_empty() {
      continue
    }
    let json = @json.parse(line_str) catch { _ => continue }
    match json {
      { "id": Number(n, ..), "result": result, .. } =>
        if n.to_int() == id {
          return Some(result)
        }
      { "id": Number(n, ..), "error": error, .. } =>
        if n.to_int() == id {
          let err_map : Map[String, Json] = {}
          err_map["error"] = error
          return Some(Json::object(err_map))
        }
      _ => ()
    }
  }
  None
}

///|
/// Build a JSON-RPC request message string.
pub fn build_jsonrpc_request(
  id : Int,
  rpc_method : String,
  params : Json,
) -> String {
  let req : Map[String, Json] = {}
  req["jsonrpc"] = "2.0".to_json()
  req["id"] = id.to_json()
  req["method"] = rpc_method.to_json()
  req["params"] = params
  Json::object(req).stringify()
}

///|
/// Parse a JSON-RPC response, extracting the result or error.
pub fn parse_jsonrpc_response(text : String) -> Json? {
  let json = @json.parse(text) catch { _ => return None }
  match json {
    { "result": result, .. } => Some(result)
    { "error": error, .. } => {
      let err_map : Map[String, Json] = {}
      err_map["error"] = error
      Some(Json::object(err_map))
    }
    _ => None
  }
}

///|
/// Load MCP server configurations from a JSON string.
pub fn load_mcp_configs(json_str : String) -> Array[McpServerConfig] {
  let configs : Array[McpServerConfig] = []
  let parsed = @json.parse(json_str) catch { _ => return configs }
  let servers = match parsed {
    { "servers": Array(s), .. } => s
    _ => return configs
  }
  for server in servers {
    let name = match server {
      { "name": String(n), .. } => n
      _ => continue
    }
    let command = match server {
      { "command": String(c), .. } => c
      _ => continue
    }
    let args : Array[String] = match server {
      { "args": Array(a), .. } => {
        let result : Array[String] = []
        for item in a {
          match item {
            String(s) => result.push(s)
            _ => ()
          }
        }
        result
      }
      _ => []
    }
    let env : Map[String, String] = match server {
      { "env": Object(e), .. } => {
        let result : Map[String, String] = {}
        for k, v in e {
          match v {
            String(s) => result[k] = s
            _ => ()
          }
        }
        result
      }
      _ => {}
    }
    configs.push({ name, command, args, env })
  }
  configs
}
