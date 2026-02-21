/// Shared core types.

/// A detected command parsed from a line.
pub struct DetectedCommand {
  kind : String
  raw : String
  name : String
  args_tokens : Array[String]
} derive(Show)

/// Result of one command execution.
pub struct CommandExecutionResult {
  command : String
  name : String
  status : String
  output : String
  elapsed_ms : Int
} derive(Show)

/// Format as XML command block.
pub fn CommandExecutionResult::block(self : CommandExecutionResult) -> String {
  "<command name=\"\{self.name}\" status=\"\{self.status}\" elapsed_ms=\"\{self.elapsed_ms}\">\n\{self.output}\n</command>"
}

/// Routing outcome for user input.
pub struct UserRouteResult {
  enter_model : Bool
  model_prompt : String
  immediate_output : String
  exit_requested : Bool
} derive(Show)

/// Routing outcome for assistant output.
pub struct AssistantRouteResult {
  visible_text : String
  next_prompt : String
  exit_requested : Bool
} derive(Show)

/// Result of one model turn loop.
pub struct ModelTurnResult {
  visible_text : String
  exit_requested : Bool
  steps : Int
  error : String?
  command_followups : Int
} derive(Show)

/// Result of the full agent loop for one input.
pub struct LoopResult {
  immediate_output : String
  assistant_output : String
  exit_requested : Bool
  steps : Int
  error : String?
} derive(Show)
