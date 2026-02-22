/// Unified tool registry.

///|
/// ToolRegistry manages tool registration and execution.
pub struct ToolRegistry {
  tools : Map[String, ToolDescriptor]
  allowed_tools : Array[String]?
}

///|
/// Create a new ToolRegistry.
pub fn ToolRegistry::new(
  allowed_tools? : Array[String]? = None,
) -> ToolRegistry {
  { tools: Map::new(), allowed_tools }
}

///|
/// Register a tool.
pub fn ToolRegistry::register(
  self : ToolRegistry,
  name : String,
  short_description : String,
  detail? : String = "",
  parameters? : Json = Json::object(Map::new()),
  source? : String = "builtin",
  requires_confirmation? : Bool = false,
  handler~ : async (Json) -> String,
) -> Unit {
  // Check allowed_tools filter
  match self.allowed_tools {
    Some(allowed) => if not(allowed.contains(name)) { return }
    None => ()
  }
  let tool : Tool = {
    name,
    description: short_description,
    parameters,
    handler,
    requires_confirmation,
  }
  let descriptor : ToolDescriptor = {
    name,
    short_description,
    detail,
    tool,
    source,
  }
  self.tools[name] = descriptor
}

///|
/// Unregister a tool by name.
pub fn ToolRegistry::unregister(self : ToolRegistry, name : String) -> Unit {
  self.tools.remove(name)
}

///|
/// Check if a tool exists.
pub fn ToolRegistry::has(self : ToolRegistry, name : String) -> Bool {
  self.tools.contains(name)
}

///|
/// Get all descriptors.
pub fn ToolRegistry::descriptors(self : ToolRegistry) -> Array[ToolDescriptor] {
  self.tools.values().collect()
}

///|
/// Check if a tool requires confirmation before execution.
pub fn ToolRegistry::needs_confirmation(
  self : ToolRegistry,
  name : String,
) -> Bool {
  match self.tools.get(name) {
    Some(descriptor) => descriptor.tool.requires_confirmation
    None => false
  }
}

///|
/// Check if a tool must run serially (not in parallel with other tools).
/// This includes tools that need confirmation AND write-mutating tools.
pub fn ToolRegistry::is_serial(self : ToolRegistry, name : String) -> Bool {
  if self.needs_confirmation(name) {
    return true
  }
  // File-mutating tools must not run in parallel to avoid race conditions
  name == "fs.write" || name == "fs.edit"
}

///|
/// Execute a tool by name.
pub async fn ToolRegistry::execute(
  self : ToolRegistry,
  name : String,
  kwargs? : Json = Json::object(Map::new()),
) -> String {
  guard self.tools.get(name) is Some(descriptor) else {
    fail("unknown tool: \{name}")
  }
  (descriptor.tool.handler)(kwargs)
}

///|
/// Get model-compatible tool list (OpenAI function-calling format).
pub fn ToolRegistry::model_tools(self : ToolRegistry) -> Array[Json] {
  let tools : Array[Json] = []
  for _, descriptor in self.tools {
    let model_name = to_model_name(descriptor.name)
    let func : Map[String, Json] = Map::new()
    func["name"] = model_name.to_json()
    func["description"] = descriptor.short_description.to_json()
    func["parameters"] = descriptor.tool.parameters
    let tool_json : Map[String, Json] = Map::new()
    tool_json["type"] = "function".to_json()
    tool_json["function"] = Json::object(func)
    tools.push(Json::object(tool_json))
  }
  tools
}

///|
/// Get compact row summaries for all tools.
pub fn ToolRegistry::compact_rows(
  self : ToolRegistry,
  for_model? : Bool = false,
) -> Array[String] {
  let rows : Array[String] = []
  for _, descriptor in self.tools {
    let name = if for_model {
      to_model_name(descriptor.name)
    } else {
      descriptor.name
    }
    rows.push("\{name}: \{descriptor.short_description}")
  }
  rows
}

///|
/// Get detailed description for a tool.
pub fn ToolRegistry::detail(
  self : ToolRegistry,
  name : String,
  for_model? : Bool = false,
) -> String {
  ignore(for_model)
  match self.tools.get(name) {
    Some(d) => d.short_description
    None => "unknown tool: \{name}"
  }
}

///|
/// Convert dot-separated name to model-compatible underscore name.
pub fn to_model_name(name : String) -> String {
  name.replace(old=".", new="_")
}

///|
/// Convert model name back to dot-separated name.
pub fn from_model_name(model_name : String, registry : ToolRegistry) -> String {
  if registry.has(model_name) {
    return model_name
  }
  for name, _ in registry.tools {
    if to_model_name(name) == model_name {
      return name
    }
  }
  model_name
}
