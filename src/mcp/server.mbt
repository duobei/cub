/// MCP server — exposes registered tools over JSON-RPC 2.0 stdio transport.

///|
/// MCP server that exposes a tool registry to external clients.
pub struct McpServer {
  registry : @tools.ToolRegistry
  mut initialized : Bool
}

///|
/// Create a new MCP server wrapping a tool registry.
pub fn McpServer::new(registry : @tools.ToolRegistry) -> McpServer {
  { registry, initialized: false }
}

///|
/// Run the MCP server on stdio, reading JSON-RPC requests from stdin
/// and writing responses to stdout.
pub async fn McpServer::run_stdio(self : McpServer) -> Unit {
  @log.info("mcp-server", "listening on stdio")
  while true {
    let raw = @stdio.stdin.read_until("\n") catch { _ => break }
    let line = match raw {
      Some(s) => s
      None => break
    }
    let trimmed = line.trim().to_string()
    if trimmed.is_empty() {
      continue
    }
    let response = self.handle_request(trimmed)
    match response {
      Some(resp) => {
        let out = resp.stringify()
        println(out)
      }
      None => () // notification — no response
    }
  }
}

///|
/// Handle a single JSON-RPC request string. Returns None for notifications.
pub async fn McpServer::handle_request(
  self : McpServer,
  text : String,
) -> Json? {
  let null_id : Json = @json.parse("null") catch { _ => "".to_json() }
  let json = @json.parse(text) catch {
    _ => return Some(build_jsonrpc_error(null_id, -32700, "Parse error"))
  }
  let id : Json = match json {
    { "id": id, .. } => id
    _ => null_id
  }
  let rpc_method = match json {
    { "method": String(m), .. } => m
    _ => return Some(build_jsonrpc_error(id, -32600, "Invalid Request"))
  }
  match rpc_method {
    "initialize" => {
      self.initialized = true
      Some(build_jsonrpc_response(id, self.handle_initialize()))
    }
    "notifications/initialized" => None // notification, no response
    "tools/list" => {
      if not(self.initialized) {
        return Some(build_jsonrpc_error(id, -32002, "Server not initialized"))
      }
      Some(build_jsonrpc_response(id, self.handle_tools_list()))
    }
    "tools/call" => {
      if not(self.initialized) {
        return Some(build_jsonrpc_error(id, -32002, "Server not initialized"))
      }
      let params = match json {
        { "params": Object(p), .. } => p
        _ =>
          return Some(
            build_jsonrpc_error(id, -32602, "Missing params for tools/call"),
          )
      }
      let name = match params.get("name") {
        Some(String(n)) => n
        _ =>
          return Some(
            build_jsonrpc_error(id, -32602, "Missing tool name in params"),
          )
      }
      let arguments = match params.get("arguments") {
        Some(args) => args
        _ => Json::object({})
      }
      let result = self.handle_tools_call(name, arguments)
      Some(build_jsonrpc_response(id, result))
    }
    _ => Some(build_jsonrpc_error(id, -32601, "Method not found"))
  }
}

///|
/// Handle initialize request — return server info and capabilities.
fn McpServer::handle_initialize(self : McpServer) -> Json {
  ignore(self)
  let result : Map[String, Json] = {}
  let server_info : Map[String, Json] = {}
  server_info["name"] = "cub".to_json()
  server_info["version"] = "0.1.0".to_json()
  result["serverInfo"] = Json::object(server_info)
  let capabilities : Map[String, Json] = {}
  capabilities["tools"] = Json::object({})
  result["capabilities"] = Json::object(capabilities)
  result["protocolVersion"] = "2024-11-05".to_json()
  Json::object(result)
}

///|
/// Handle tools/list — return all registered tool descriptors.
fn McpServer::handle_tools_list(self : McpServer) -> Json {
  let tools : Array[Json] = []
  for desc in self.registry.descriptors() {
    let tool_obj : Map[String, Json] = {}
    tool_obj["name"] = desc.name.to_json()
    tool_obj["description"] = desc.short_description.to_json()
    tool_obj["inputSchema"] = desc.tool.parameters
    tools.push(Json::object(tool_obj))
  }
  let result : Map[String, Json] = {}
  result["tools"] = tools.to_json()
  Json::object(result)
}

///|
/// Handle tools/call — execute a tool and return the result.
async fn McpServer::handle_tools_call(
  self : McpServer,
  name : String,
  arguments : Json,
) -> Json {
  if not(self.registry.has(name)) {
    let err : Map[String, Json] = {}
    err["isError"] = true.to_json()
    let content : Array[Json] = []
    let part : Map[String, Json] = {}
    part["type"] = "text".to_json()
    part["text"] = "Tool not found: \{name}".to_json()
    content.push(Json::object(part))
    err["content"] = content.to_json()
    return Json::object(err)
  }
  let output = self.registry.execute(name, kwargs=arguments) catch {
    e => {
      let err_result : Map[String, Json] = {}
      err_result["isError"] = true.to_json()
      let content : Array[Json] = []
      let part : Map[String, Json] = {}
      part["type"] = "text".to_json()
      let err_msg = e.to_string()
      part["text"] = "Error: \{err_msg}".to_json()
      content.push(Json::object(part))
      err_result["content"] = content.to_json()
      return Json::object(err_result)
    }
  }
  let result : Map[String, Json] = {}
  let content : Array[Json] = []
  let part : Map[String, Json] = {}
  part["type"] = "text".to_json()
  part["text"] = output.to_json()
  content.push(Json::object(part))
  result["content"] = content.to_json()
  Json::object(result)
}

///|
/// Build a JSON-RPC 2.0 success response.
pub fn build_jsonrpc_response(id : Json, result : Json) -> Json {
  let resp : Map[String, Json] = {}
  resp["jsonrpc"] = "2.0".to_json()
  resp["id"] = id
  resp["result"] = result
  Json::object(resp)
}

///|
/// Build a JSON-RPC 2.0 error response.
pub fn build_jsonrpc_error(id : Json, code : Int, message : String) -> Json {
  let resp : Map[String, Json] = {}
  resp["jsonrpc"] = "2.0".to_json()
  resp["id"] = id
  let err : Map[String, Json] = {}
  err["code"] = code.to_json()
  err["message"] = message.to_json()
  resp["error"] = Json::object(err)
  Json::object(resp)
}
