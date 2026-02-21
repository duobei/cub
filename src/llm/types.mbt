/// LLM types for chat API interaction.

///|
/// Information about a single tool call from the model.
pub struct ToolCallInfo {
  id : String
  type_ : String
  function_ : ToolCallFunction
} derive(Show)

///|
/// The function part of a tool call.
pub struct ToolCallFunction {
  name : String
  arguments : String
} derive(Show)

///|
/// Parse ToolCallInfo from JSON.
pub fn ToolCallInfo::from_json(json : Json) -> ToolCallInfo? {
  match json {
    {
      "id": String(id),
      "type": String(type_),
      "function": { "name": String(name), "arguments": String(args), .. },
      ..
    } => Some({ id, type_, function_: { name, arguments: args } })
    _ => None
  }
}

///|
/// Convert ToolCallInfo to JSON for sending back to the API.
pub fn ToolCallInfo::to_json(self : ToolCallInfo) -> Json {
  let func : Map[String, Json] = Map::new()
  func["name"] = self.function_.name.to_json()
  func["arguments"] = self.function_.arguments.to_json()
  let obj : Map[String, Json] = Map::new()
  obj["id"] = self.id.to_json()
  obj["type"] = self.type_.to_json()
  obj["function"] = Json::object(func)
  Json::object(obj)
}

///|
/// Response from a chat API call.
pub struct ChatResponse {
  text : String
  tool_calls : Array[ToolCallInfo]
  finish_reason : String
  error : String?
} derive(Show)

///|
/// Kind of tool auto result.
pub enum ToolAutoKind {
  Text
  Tools
  Error
} derive(Show)

///|
/// Result of an automatic tool execution cycle.
pub struct ToolAutoResult {
  kind : ToolAutoKind
  text : String
  tool_calls : Array[Json]
  tool_results : Array[Json]
  error : String?
} derive(Show)
