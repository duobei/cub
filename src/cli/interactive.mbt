/// Simple interactive REPL.

/// Interactive CLI session.
pub struct InteractiveCli {
  runtime : @app.AppRuntime
  session_id : String
}

/// Create a new InteractiveCli.
pub fn InteractiveCli::new(
  runtime : @app.AppRuntime,
  session_id~ : String = "cli"
) -> InteractiveCli {
  { runtime, session_id }
}

/// Run the interactive REPL.
pub async fn InteractiveCli::run(self : InteractiveCli) -> Unit {
  print_welcome(self.runtime.settings.model, self.runtime.workspace)
  // Ensure bootstrap anchor
  let session = self.runtime.get_session(self.session_id)
  session.tape.ensure_bootstrap_anchor()
  // REPL loop
  for {
    print_prompt()
    let line = @stdio.stdin.read_until("\n")
    match line {
      None => break // EOF
      Some(raw) => {
        let trimmed = raw.trim().to_string()
        if trimmed.length() == 0 {
          continue
        }
        let result = self.runtime.handle_input(self.session_id, trimmed)
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
  print_info("Bye.")
}
