/// CLI ANSI rendering helpers.

/// ANSI color codes.
let ansi_reset : String = "\u001b[0m"
let ansi_bold : String = "\u001b[1m"
let ansi_red : String = "\u001b[31m"
let ansi_green : String = "\u001b[32m"
let ansi_yellow : String = "\u001b[33m"
let ansi_blue : String = "\u001b[34m"
let ansi_cyan : String = "\u001b[36m"
let ansi_dim : String = "\u001b[2m"

/// Print with color.
pub fn print_colored(color : String, text : String) -> Unit {
  println(color + text + ansi_reset)
}

/// Print welcome banner.
pub fn print_welcome(model : String, workspace : String) -> Unit {
  println("")
  print_colored(ansi_bold + ansi_cyan, "  cub")
  print_colored(ansi_dim, "  model: " + model)
  print_colored(ansi_dim, "  workspace: " + workspace)
  print_colored(ansi_dim, "  type ,help for commands, ,quit to exit")
  println("")
}

/// Print error.
pub fn print_error(text : String) -> Unit {
  print_colored(ansi_red, "error: " + text)
}

/// Print info.
pub fn print_info(text : String) -> Unit {
  print_colored(ansi_dim, text)
}

/// Print assistant output.
pub fn print_assistant(text : String) -> Unit {
  println(text)
}

/// Print command output.
pub fn print_command(text : String) -> Unit {
  print_colored(ansi_green, text)
}

/// Print the prompt (with newline since MoonBit has no print without newline).
pub fn print_prompt() -> Unit {
  println(ansi_bold + "> " + ansi_reset)
}
