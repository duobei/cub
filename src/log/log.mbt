/// Structured logging with level filtering and stderr output.

///|
/// Log severity levels.
pub enum LogLevel {
  Debug
  Info
  Warn
  Error
} derive(Eq, Compare)

///|
/// Convert log level to display string.
pub fn LogLevel::to_string(self : LogLevel) -> String {
  match self {
    Debug => "DEBUG"
    Info => "INFO"
    Warn => "WARN"
    Error => "ERROR"
  }
}

///|
/// Global minimum log level (set from CUB_LOG_LEVEL env var).
let global_level : Ref[LogLevel] = { val: Info }

///|
/// Whether the global level has been initialized.
let level_initialized : Ref[Bool] = { val: false }

///|
/// Initialize log level from environment variable CUB_LOG_LEVEL.
fn ensure_initialized() -> Unit {
  if level_initialized.val {
    return
  }
  level_initialized.val = true
  match @config.getenv("CUB_LOG_LEVEL") {
    Some(s) => {
      let lower = s.to_lower()
      match lower {
        "debug" => global_level.val = Debug
        "info" => global_level.val = Info
        "warn" | "warning" => global_level.val = Warn
        "error" => global_level.val = Error
        _ => () // keep default Info
      }
    }
    None => ()
  }
}

///|
/// Log a message at the given level with a source tag.
/// Output goes to stderr to avoid interfering with stdout user output.
pub fn log(level : LogLevel, source : String, msg : String) -> Unit {
  ensure_initialized()
  if level < global_level.val {
    return
  }
  let level_str = level.to_string()
  let line = "[\{level_str}] [\{source}] \{msg}"
  cub_log_stderr(line)
}

///|
/// Convenience: log at debug level.
pub fn debug(source : String, msg : String) -> Unit {
  log(Debug, source, msg)
}

///|
/// Convenience: log at info level.
pub fn info(source : String, msg : String) -> Unit {
  log(Info, source, msg)
}

///|
/// Convenience: log at warn level.
pub fn warn(source : String, msg : String) -> Unit {
  log(Warn, source, msg)
}

///|
/// Convenience: log at error level.
pub fn error(source : String, msg : String) -> Unit {
  log(Error, source, msg)
}

///|
/// FFI: write a line to stderr.
fn cub_log_stderr(line : String) -> Unit {
  let bytes = @config.string_to_cstr(line)
  ignore(cub_write_stderr(bytes, bytes.length() - 1))
}

///|
#borrow(buf)
extern "C" fn cub_write_stderr(buf : Bytes, len : Int) -> Int = "cub_write_stderr"
