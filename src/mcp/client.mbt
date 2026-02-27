/// MCP client — JSON-RPC 2.0 over stdio transport.

///|
/// Create a new MCP client for a server configuration.
pub fn McpClient::new(config : McpServerConfig) -> McpClient {
  {
    config,
    pid: -1,
    writer: None,
    reader: None,
    request_id: 0,
    initialized: false,
    tools: [],
  }
}

///|
/// Check if the MCP server process is still alive.
pub async fn McpClient::is_alive(self : McpClient) -> Bool {
  if self.pid <= 0 {
    return false
  }
  let pid_str = self.pid.to_string()
  let kill_args : Array[String] = ["-0", pid_str]
  let rc = @platform.run("kill", kill_args[:])
  rc == 0
}

///|
/// Start the MCP server process and perform initialization handshake.
pub async fn McpClient::start(self : McpClient) -> Bool {
  let (stdin_input, writer) = @platform.write_to_process() catch {
    _ => {
      @log.error("mcp", "failed to create stdin pipe")
      return false
    }
  }
  let (reader, stdout_output) = @platform.read_from_process() catch {
    _ => {
      writer.close()
      @log.error("mcp", "failed to create stdout pipe")
      return false
    }
  }
  let pid = @platform.spawn_orphan(
    self.config.command,
    self.config.args[:],
    extra_env=self.config.env,
    stdin=stdin_input,
    stdout=stdout_output,
  )
  if pid <= 0 {
    writer.close()
    reader.close()
    @log.error("mcp", "failed to spawn process: \{self.config.command}")
    return false
  }
  self.pid = pid
  self.writer = Some(writer)
  self.reader = Some(reader)
  @log.info("mcp", "spawned \{self.config.name} (pid \{pid})")
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
/// Maximum response size from MCP tool call (100KB).
let mcp_max_response_size : Int = 102400

///|
/// Validate an MCP tool name: must be alphanumeric, dots, underscores, hyphens only.
fn is_valid_tool_name(name : String) -> Bool {
  if name.is_empty() || name.length() > 128 {
    return false
  }
  for ch in name {
    let c = ch.to_int()
    let ok = (c >= 97 && c <= 122) || // a-z
      (c >= 65 && c <= 90) || // A-Z
      (c >= 48 && c <= 57) || // 0-9
      c == 46 || // .
      c == 95 || // _
      c == 45 // -
    if not(ok) {
      return false
    }
  }
  true
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
        // Sanitize tool name
        if not(is_valid_tool_name(name)) {
          @log.warn(
            "mcp",
            "\{self.config.name}: skipping tool with invalid name",
          )
          continue
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
  // Validate tool name
  if not(is_valid_tool_name(name)) {
    return "error: invalid tool name"
  }
  let params : Map[String, Json] = {}
  params["name"] = name.to_json()
  params["arguments"] = arguments
  // Call with timeout (30s is handled by send_request internally)
  let result = self.send_request("tools/call", Json::object(params))
  let response = match result {
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
  // Truncate oversized responses
  if response.length() > mcp_max_response_size {
    let truncated = response[:mcp_max_response_size].to_string() catch {
      _ => response
    }
    return "\{truncated}\n[...truncated at 100KB]"
  }
  response
}

///|
/// Stop the MCP server process.
pub async fn McpClient::stop(self : McpClient) -> Unit {
  if self.pid <= 0 {
    return
  }
  // Close pipes
  match self.writer {
    Some(w) => w.close()
    None => ()
  }
  match self.reader {
    Some(r) => r.close()
    None => ()
  }
  self.writer = None
  self.reader = None
  // Send SIGTERM
  let pid_str = self.pid.to_string()
  let term_args : Array[String] = ["-TERM", pid_str]
  ignore(@platform.run("kill", term_args[:]))
  @async.sleep(200)
  // Check if still alive, force kill if needed
  let check_args : Array[String] = ["-0", pid_str]
  let rc = @platform.run("kill", check_args[:])
  if rc == 0 {
    let kill_args : Array[String] = ["-9", pid_str]
    ignore(@platform.run("kill", kill_args[:]))
  }
  @log.info("mcp", "stopped \{self.config.name}")
  self.pid = -1
  self.initialized = false
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
  let writer = match self.writer {
    Some(w) => w
    None => {
      @log.error("mcp", "no writer for \{rpc_method}")
      return None
    }
  }
  writer.write(line) catch {
    _ => {
      @log.error("mcp", "write failed for \{rpc_method}")
      return None
    }
  }
  let reader = match self.reader {
    Some(r) => r
    None => {
      @log.error("mcp", "no reader for \{rpc_method}")
      return None
    }
  }
  // Read response with 30s timeout
  let result = @async.with_timeout_opt(30000, async fn() {
    while true {
      let text = reader.read_until("\n") catch { _ => return None }
      match text {
        None => return None
        Some(line_text) => {
          let trimmed = line_text.trim().to_string()
          if trimmed.is_empty() {
            continue
          }
          let json = @json.parse(trimmed) catch { _ => continue }
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
            _ => () // notification or unrelated message
          }
        }
      }
    }
    None
  })
  match result {
    Some(inner) => inner
    None => {
      @log.warn("mcp", "timeout waiting for response to \{rpc_method}")
      None
    }
  }
}

///|
/// Send a JSON-RPC notification (no response expected).
async fn McpClient::send_notification(
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
  let writer = match self.writer {
    Some(w) => w
    None => return
  }
  writer.write(line) catch {
    _ => ()
  }
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
      { "args": Array(a), .. } =>
        a.filter_map(fn(item) {
          match item {
            String(s) => Some(s)
            _ => None
          }
        })
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
