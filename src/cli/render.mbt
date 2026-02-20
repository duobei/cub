/// CLI ANSI rendering helpers stub.

/// Print with color.
pub fn print_colored(color : String, text : String) -> Unit {
  println(color + text + "\x1b[0m")
}

/// Print welcome banner.
pub fn print_welcome(model : String, workspace : String) -> Unit {
  ignore(model)
  ignore(workspace)
}

/// Print error.
pub fn print_error(text : String) -> Unit {
  println("Error: " + text)
}

/// Print info.
pub fn print_info(text : String) -> Unit {
  println(text)
}

/// Print assistant output.
pub fn print_assistant(text : String) -> Unit {
  println(text)
}

/// Print command output.
pub fn print_command(text : String) -> Unit {
  println(text)
}
