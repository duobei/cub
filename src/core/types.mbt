/// Shared core types.

///|
/// A detected command parsed from a line.
pub struct DetectedCommand {
  kind : String
  raw : String
  name : String
  args_tokens : Array[String]
} derive(Show)

///|
/// Result of one command execution.
pub struct CommandExecutionResult {
  command : String
  name : String
  status : String
  output : String
  elapsed_ms : Int
} derive(Show)

///|
/// Format as XML command block.
/// Output is escaped to prevent prompt injection via tool results.
pub fn CommandExecutionResult::block(self : CommandExecutionResult) -> String {
  let safe_name = escape_xml_attr(self.name)
  let safe_status = escape_xml_attr(self.status)
  let safe_output = escape_xml_body(self.output)
  "<command name=\"\{safe_name}\" status=\"\{safe_status}\" elapsed_ms=\"\{self.elapsed_ms}\">\n\{safe_output}\n</command>"
}

///|
/// Escape a string for use in XML attribute values.
fn escape_xml_attr(s : String) -> String {
  let buf = StringBuilder::new()
  for ch in s {
    match ch {
      '<' => buf.write_string("&lt;")
      '>' => buf.write_string("&gt;")
      '&' => buf.write_string("&amp;")
      '"' => buf.write_string("&quot;")
      _ => buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
/// Escape a string for use in XML body text.
fn escape_xml_body(s : String) -> String {
  let buf = StringBuilder::new()
  for ch in s {
    match ch {
      '<' => buf.write_string("&lt;")
      '>' => buf.write_string("&gt;")
      '&' => buf.write_string("&amp;")
      _ => buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
/// Routing outcome for user input.
pub struct UserRouteResult {
  enter_model : Bool
  model_prompt : String
  immediate_output : String
  exit_requested : Bool
} derive(Show)

///|
/// Routing outcome for assistant output.
pub struct AssistantRouteResult {
  visible_text : String
  next_prompt : String
  exit_requested : Bool
} derive(Show)

///|
/// Result of one model turn loop.
pub struct ModelTurnResult {
  visible_text : String
  exit_requested : Bool
  steps : Int
  error : String?
  command_followups : Int
  usage : @llm.TokenUsage?
} derive(Show)

///|
/// Result of the full agent loop for one input.
pub struct LoopResult {
  immediate_output : String
  assistant_output : String
  exit_requested : Bool
  steps : Int
  error : String?
  usage : @llm.TokenUsage?
} derive(Show)
