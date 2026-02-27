/// Filename/URL encoding, MCP client wiring, and extension tool registration.

///|
/// Generate a short slug from session_id for tape file naming.
fn session_slug(session_id : String) -> String {
  let mut hash : UInt = 2166136261
  for i in 0..<session_id.length() {
    hash = hash ^ session_id[i].to_uint()
    hash = hash * 16777619
  }
  uint_to_hex(hash)
}

///|
/// Convert UInt to hex string.
fn uint_to_hex(n : UInt) -> String {
  let hex_chars = "0123456789abcdef"
  let buf = StringBuilder::new()
  for i in 0..<8 {
    let nibble = ((n >> ((7 - i) * 4)) & 0xf).reinterpret_as_int()
    buf.write_char(hex_chars[nibble].to_int().unsafe_to_char())
  }
  buf.to_string()
}

///|
/// Decode tape filename back to tape name.
/// Format: {workspace_hash}__{url_encoded_name}.jsonl -> name
fn decode_tape_filename(filename : String) -> String {
  // Strip .jsonl suffix
  if filename.length() < 7 {
    return filename
  }
  let base = filename[:filename.length() - 6].to_string() catch {
    _ => return filename
  }
  // Find __ separator
  let mut sep_pos = -1
  for i in 0..<(base.length() - 1) {
    if base[i] == '_'.to_int().to_uint16() &&
      i + 1 < base.length() &&
      base[i + 1] == '_'.to_int().to_uint16() {
      sep_pos = i
      break
    }
  }
  if sep_pos < 0 {
    return base
  }
  // Get the encoded name part after __
  let encoded = base[sep_pos + 2:].to_string() catch { _ => return base }
  // Simple URL decode: %XX -> char
  url_decode(encoded)
}

///|
/// Simple URL percent-decode.
fn url_decode(s : String) -> String {
  let buf = StringBuilder::new()
  let mut i = 0
  while i < s.length() {
    if s[i] == '%'.to_int().to_uint16() && i + 2 < s.length() {
      let hi = hex_digit(s[i + 1])
      let lo = hex_digit(s[i + 2])
      if hi >= 0 && lo >= 0 {
        buf.write_char((hi * 16 + lo).unsafe_to_char())
        i += 3
        continue
      }
    }
    buf.write_char(s[i].to_int().unsafe_to_char())
    i += 1
  }
  buf.to_string()
}

///|
/// Convert hex digit to int, -1 if invalid.
fn hex_digit(ch : UInt16) -> Int {
  let c = ch.to_int()
  if c >= 48 && c <= 57 {
    return c - 48
  } // 0-9
  if c >= 65 && c <= 70 {
    return c - 55
  } // A-F
  if c >= 97 && c <= 102 {
    return c - 87
  } // a-f
  -1
}

///|
/// Load MCP client configurations and start servers.
async fn load_mcp_clients(home : String) -> Array[@mcp.McpClient] {
  let clients : Array[@mcp.McpClient] = []
  // Try loading from ~/.cub/mcp.json
  let config_path = "\{home}/mcp.json"
  let config_content = read_file_sync(config_path)
  let configs = if config_content.length() > 0 {
    @mcp.load_mcp_configs(config_content)
  } else {
    // Try CUB_MCP_SERVERS env var
    match @config.getenv("CUB_MCP_SERVERS") {
      Some(s) => @mcp.load_mcp_configs(s)
      None => []
    }
  }
  for config in configs {
    let client = @mcp.McpClient::new(config)
    let started = client.start()
    if started {
      ignore(client.discover_tools())
      clients.push(client)
    }
  }
  clients
}

///|
/// Register MCP tools into a tool registry.
fn register_mcp_tools(
  registry : @tools.ToolRegistry,
  mcp_clients : Array[@mcp.McpClient],
) -> Unit {
  for client in mcp_clients {
    let server_name = client.config.name
    for tool in client.tools {
      let tool_name = "mcp.\{server_name}.\{tool.name}"
      let mcp_tool_name = tool.name
      let mcp_client = client
      registry.register(
        tool_name,
        tool.description,
        parameters=tool.input_schema,
        handler=async fn(args) { mcp_client.call_tool(mcp_tool_name, args) },
      )
    }
  }
}

// -- Extension tools (script + WASM) --

///|
/// Register discovered extension tools into the registry.
async fn register_ext_tools(
  registry : @tools.ToolRegistry,
  home : String,
  workspace : String,
) -> Unit {
  let extensions = @ext.discover_extensions(home, workspace)
  let reg = registry
  for ext in extensions {
    let tool_name = "ext.\{ext.name}"
    let ext_type = ext.ext_type
    let ext_path = ext.path
    let ext_params = ext.parameters
    registry.register(
      tool_name,
      ext.description,
      parameters=ext_params,
      source="extension",
      handler=async fn(args) {
        run_extension(ext_type, ext_path, args, registry=reg, schema=ext_params)
      },
    )
  }
}

///|
/// Validate required parameters against a JSON Schema.
/// Returns an error string if validation fails, empty string if ok.
pub fn validate_required_params(args : Json, schema : Json) -> String {
  let required = match schema {
    { "required": Array(fields), .. } => fields
    _ => return ""
  }
  let provided = match args {
    Object(m) => m
    _ => return ""
  }
  let missing : Array[String] = []
  for field in required {
    match field {
      String(name) => if not(provided.contains(name)) { missing.push(name) }
      _ => ()
    }
  }
  if missing.is_empty() {
    ""
  } else {
    let names = missing.join(", ")
    "missing required parameters: \{names}"
  }
}

///|
/// Build a compact tool summary list for extension context.
fn build_available_tools_context(registry : @tools.ToolRegistry) -> Json {
  let tools : Array[Json] = []
  for desc in registry.descriptors() {
    let obj : Map[String, Json] = {}
    obj["name"] = desc.name.to_json()
    obj["description"] = desc.short_description.to_json()
    tools.push(Json::object(obj))
  }
  tools.to_json()
}

///|
/// Execute an extension (script or WASM plugin).
async fn run_extension(
  ext_type : @ext.ExtType,
  path : String,
  args : Json,
  registry~ : @tools.ToolRegistry,
  schema~ : Json,
) -> String {
  // Validate required parameters
  let validation = validate_required_params(args, schema)
  if not(validation.is_empty()) {
    return validation
  }
  // Enrich input with context for WASM plugins
  let enriched_args = match ext_type {
    @ext.ExtType::Wasm => {
      let wrapper : Map[String, Json] = {}
      wrapper["arguments"] = args
      wrapper["available_tools"] = build_available_tools_context(registry)
      Json::object(wrapper)
    }
    @ext.ExtType::Script => args
  }
  let args_str = enriched_args.stringify()
  let timeout = 30_000
  let (exit_code, stdout_data, stderr_data) = @async.with_timeout(timeout, async fn() {
    match ext_type {
      @ext.ExtType::Script => @platform.collect_output(path, [args_str])
      @ext.ExtType::Wasm => {
        let user_home = @config.getenv("HOME").unwrap_or("/home/ubuntu")
        let moonrun_bin = "\{user_home}/.moon/bin/moonrun"
        @platform.collect_output(moonrun_bin, [path, "--", args_str])
      }
    }
  }) catch {
    _ => return "extension timeout after 30s"
  }
  let stdout = stdout_data.text() catch { _ => "" }
  if exit_code != 0 {
    let stderr = stderr_data.text() catch { _ => "" }
    return "extension error (exit \{exit_code}): \{stderr}"
  }
  // Process JSONL output: intercept tool_call lines and execute them
  process_extension_output(stdout, registry)
}

///|
/// Process extension output, executing any embedded tool_call requests.
/// Lines with `{"type":"tool_call",...}` are intercepted and executed;
/// their results are appended. Other lines pass through as-is.
async fn process_extension_output(
  stdout : String,
  registry : @tools.ToolRegistry,
) -> String {
  let output_parts : Array[String] = []
  for line in stdout.split("\n") {
    let line_str = line.to_string().trim().to_string()
    if line_str.is_empty() {
      continue
    }
    // Try to parse as a tool_call JSON
    let json = @json.parse(line_str) catch { _ => Json::object({}) }
    match json {
      { "type": String("tool_call"), "name": String(name), "args": args, .. } =>
        if registry.has(name) {
          let result = registry.execute(name, kwargs=args) catch {
            e => {
              let err_msg = e.to_string()
              "tool_call error (\{name}): \{err_msg}"
            }
          }
          output_parts.push(result)
        } else {
          output_parts.push("tool_call error: unknown tool '\{name}'")
        }
      _ => output_parts.push(line_str)
    }
  }
  output_parts.join("\n")
}
