/// LLM types for chat API interaction.

/// Information about a single tool call from the model.
pub struct ToolCallInfo {
  id : String
  type_ : String
  function_ : ToolCallFunction
} derive(Show)

/// The function part of a tool call.
pub struct ToolCallFunction {
  name : String
  arguments : String
} derive(Show)

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

/// Convert ToolCallInfo to JSON.
pub fn ToolCallInfo::to_json(self : ToolCallInfo) -> Json {
  {
    "id": self.id.to_json(),
    "type": self.type_.to_json(),
    "function": {
      "name": self.function_.name.to_json(),
      "arguments": self.function_.arguments.to_json(),
    },
  }
}

/// Response from a chat API call.
pub struct ChatResponse {
  text : String
  tool_calls : Array[ToolCallInfo]
  finish_reason : String
  error : String?
} derive(Show)

/// Kind of tool auto result.
pub enum ToolAutoKind {
  Text
  Tools
  Error
} derive(Show)

/// Result of an automatic tool execution cycle.
pub struct ToolAutoResult {
  kind : ToolAutoKind
  text : String
  tool_calls : Array[Json]
  tool_results : Array[Json]
  error : String?
} derive(Show)
