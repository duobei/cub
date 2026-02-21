/// Interactive REPL with readline history and shell mode toggle.

///|
/// CLI-based tool confirmation using readline.
/// Returns true if user approves, false otherwise.
pub fn confirm_tool(tool_name : String, args : String) -> Bool {
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
/// Read a line using GNU readline (with editing and history).
fn readline_read(prompt : String) -> String? {
  let prompt_bytes = @config.string_to_cstr(prompt)
  // Two-pass: get length first
  let len = cub_readline(prompt_bytes, Bytes::new(0), 0)
  if len < 0 {
    return None // EOF
  }
  if len == 0 {
    return Some("")
  }
  let buf = Bytes::new(len)
  let actual = cub_readline(prompt_bytes, buf, len)
  if actual < 0 {
    return None
  }
  Some(@utf8.decode_lossy(buf[:actual]))
}

///|
/// Add a line to readline history.
fn add_history(line : String) -> Unit {
  let bytes = @config.string_to_cstr(line)
  cub_add_history(bytes)
}

///|
/// Load history from file.
fn load_history(path : String) -> Unit {
  let bytes = @config.string_to_cstr(path)
  ignore(cub_read_history(bytes))
}

///|
/// Save history to file.
fn save_history(path : String) -> Unit {
  let bytes = @config.string_to_cstr(path)
  ignore(cub_write_history(bytes))
}

///|
/// FFI bindings.
#borrow(prompt, buf)
extern "C" fn cub_readline(prompt : Bytes, buf : Bytes, buf_size : Int) -> Int = "cub_readline"

///|
#borrow(line)
extern "C" fn cub_add_history(line : Bytes) -> Unit = "cub_add_history"

///|
#borrow(path)
extern "C" fn cub_read_history(path : Bytes) -> Int = "cub_read_history"

///|
#borrow(path)
extern "C" fn cub_write_history(path : Bytes) -> Int = "cub_write_history"

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
