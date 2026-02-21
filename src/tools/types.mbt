/// Tool types for the tool system.

///|
/// A tool definition.
pub struct Tool {
  name : String
  description : String
  parameters : Json
  handler : async (Json) -> String raise Error
  requires_confirmation : Bool
}

///|
/// Implement Show for Tool.
pub impl Show for Tool with output(self, logger) {
  logger.write_string("Tool(")
  logger.write_string(self.name)
  logger.write_string(")")
}

///|
/// A tool descriptor with metadata.
pub struct ToolDescriptor {
  name : String
  short_description : String
  detail : String
  tool : Tool
  source : String
} derive(Show)

///|
/// Tool execution context passed to tool handlers.
pub struct ToolContext {
  tape : @tape.TapeService
  workspace : String
  session_id : String
}

///|
/// Create a new ToolContext.
pub fn ToolContext::new(
  tape : @tape.TapeService,
  workspace : String,
  session_id? : String = "cli",
) -> ToolContext {
  { tape, workspace, session_id }
}
