/// Interactive REPL with history and shell mode toggle.

///|
/// In-memory command history (max 500 entries).
let cli_history : Array[String] = []

///|
/// CLI-based tool confirmation using async stdin.
/// Returns true if user approves, false otherwise.
pub async fn confirm_tool(tool_name : String, args : String) -> Bool {
  // Truncate long args for display
  let display_args = if args.length() > 200 {
    (args[:200].to_string() catch { _ => args }) + "..."
  } else {
    args
  }
  let prompt = "\u001b[33mRun \{tool_name}: \{display_args}? [y/N] \u001b[0m"
  match readline_read(prompt) {
    None => false
    Some(line) => {
      let answer = line.trim().to_string().to_lower()
      answer == "y" || answer == "yes"
    }
  }
}

///|
/// Interactive CLI session.
pub struct InteractiveCli {
  runtime : @app.AppRuntime
  mut session_id : String
  mut shell_mode : Bool
  history_path : String
}

///|
/// Create a new InteractiveCli.
pub fn InteractiveCli::new(
  runtime : @app.AppRuntime,
  session_id? : String = "cli",
) -> InteractiveCli {
  let home = runtime.settings.home.unwrap_or(".cub")
  { runtime, session_id, shell_mode: false, history_path: "\{home}/history" }
}

///|
/// Read a line from stdin with a prompt.
async fn readline_read(prompt : String) -> String? {
  @stdio.stdout.write(prompt) catch {
    _ => ()
  }
  let line = @stdio.stdin.read_until("\n") catch { _ => return None }
  line
}

///|
/// Add a line to in-memory history.
fn add_history(line : String) -> Unit {
  if line.is_empty() {
    return
  }
  if cli_history.length() >= 500 {
    ignore(cli_history.remove(0))
  }
  cli_history.push(line)
}

///|
/// Load history from file into memory.
async fn load_history(path : String) -> Unit {
  let text = @platform.read_file_text(path) catch { _ => return }
  for line in text.split("\n") {
    let s = line.to_string()
    if s.length() > 0 {
      cli_history.push(s)
    }
  }
}

///|
/// Save in-memory history to file.
async fn save_history(path : String) -> Unit {
  let content = cli_history.join("\n")
  @platform.write_file(path, content, create=0o644) catch {
    _ => ()
  }
}

///|
/// Run the interactive REPL.
pub async fn InteractiveCli::run(self : InteractiveCli) -> Unit {
  print_welcome(self.runtime.settings.model, self.runtime.workspace)
  // Load history
  load_history(self.history_path)
  // Ensure bootstrap anchor
  let session = self.runtime.get_session(self.session_id)
  session.tape.ensure_bootstrap_anchor()
  // REPL loop
  for {
    let prompt = if self.shell_mode { "$ " } else { "> " }
    let line = readline_read(prompt)
    match line {
      None => break // EOF
      Some(raw) => {
        let trimmed = raw.trim().to_string()
        if trimmed.is_empty() {
          continue
        }
        // Add to history
        add_history(trimmed)
        // Handle shell mode toggle
        if trimmed == ",sh" {
          self.shell_mode = not(self.shell_mode)
          if self.shell_mode {
            print_info(
              "Shell mode ON — input goes directly to bash. Type ,sh to exit.",
            )
          } else {
            print_info("Shell mode OFF — back to normal chat.")
          }
          continue
        }
        // Handle session switching: ,session <name>
        if trimmed.has_prefix(",session ") {
          let name = trimmed[9:].to_string() catch { _ => "" }
          let name = name.trim().to_string()
          if name.is_empty() {
            print_error("Usage: ,session <name>")
          } else {
            self.session_id = name
            // Ensure the session is initialized with bootstrap anchor
            let session = self.runtime.get_session(self.session_id)
            session.tape.ensure_bootstrap_anchor()
            print_info("Switched to session: \{name}")
          }
          continue
        }
        // In shell mode, prefix with comma to run as shell command
        let input = if self.shell_mode { ",\{trimmed}" } else { trimmed }
        let result = self.runtime.handle_input(self.session_id, input)
        if result.immediate_output.length() > 0 {
          print_command(result.immediate_output)
        }
        match result.error {
          Some(e) => print_error(e)
          None => ()
        }
        if result.assistant_output.length() > 0 {
          println("")
          print_assistant(result.assistant_output)
          println("")
        }
        if result.exit_requested {
          break
        }
      }
    }
  }
  // Save history on exit
  save_history(self.history_path)
  print_info("Bye.")
}
