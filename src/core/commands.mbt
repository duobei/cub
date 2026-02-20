/// Command parsing helpers stub.

/// Parsed command arguments.
pub struct ParsedArgs {
  kwargs : Map[String, String]
  positional : Array[String]
} derive(Show)

/// Split command text into words.
pub fn parse_command_words(text : String) -> Array[String] {
  ignore(text)
  []
}

/// Parse ',name ...' command line into name and args tokens.
pub fn parse_internal_command(line : String) -> (String, Array[String]) {
  ignore(line)
  ("", [])
}

/// Parse tool arguments from tokens.
pub fn parse_kv_arguments(tokens : Array[String]) -> ParsedArgs {
  ignore(tokens)
  { kwargs: {}, positional: [] }
}
