/// Platform process abstraction — subprocess operations.
/// All callers should use these instead of @process directly.
/// Types (@process.WriteToProcess, @process.ReadFromProcess) are accessed
/// through the underlying module when needed in struct/param declarations.

///|
/// Run a command and wait for exit code.
pub async fn run(cmd : String, args : ArrayView[String]) -> Int {
  @process.run(cmd, args)
}

///|
/// Collect stdout/stderr from a command.
pub async fn collect_output(
  cmd : String,
  args : Array[String],
  cwd? : String = "",
  extra_env? : Map[String, String] = {},
) -> (Int, &@io.Data, &@io.Data) {
  if cwd.is_empty() && extra_env.is_empty() {
    @process.collect_output(cmd, args)
  } else if cwd.is_empty() {
    @process.collect_output(cmd, args, extra_env~)
  } else if extra_env.is_empty() {
    @process.collect_output(cmd, args, cwd~)
  } else {
    @process.collect_output(cmd, args, cwd~, extra_env~)
  }
}

///|
/// Create a writable pipe for process stdin.
pub fn write_to_process() -> (&@process.ProcessInput, @process.WriteToProcess) raise {
  @process.write_to_process()
}

///|
/// Create a readable pipe for process stdout.
pub fn read_from_process() -> (
  @process.ReadFromProcess,
  &@process.ProcessOutput,
) raise {
  @process.read_from_process()
}

///|
/// Spawn a detached process.
pub async fn spawn_orphan(
  cmd : String,
  args : ArrayView[String],
  extra_env? : Map[String, String] = {},
  stdin~ : &@process.ProcessInput,
  stdout~ : &@process.ProcessOutput,
) -> Int {
  @process.spawn_orphan(cmd, args, extra_env~, stdin~, stdout~)
}
