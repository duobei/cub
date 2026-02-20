/// Simple interactive REPL stub.

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
pub async fn InteractiveCli::run(self : InteractiveCli) -> Unit!Error {
  ignore(self)
  abort("InteractiveCli::run not implemented")
}
