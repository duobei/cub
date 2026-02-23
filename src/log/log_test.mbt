///|
/// Tests for log level types and ordering.
test "LogLevel to_string" {
  inspect(@log.LogLevel::Debug.to_string(), content="DEBUG")
  inspect(@log.LogLevel::Info.to_string(), content="INFO")
  inspect(@log.LogLevel::Warn.to_string(), content="WARN")
  inspect(@log.LogLevel::Error.to_string(), content="ERROR")
}

///|
test "LogLevel ordering" {
  // Debug < Info < Warn < Error
  inspect(@log.LogLevel::Debug < @log.LogLevel::Info, content="true")
  inspect(@log.LogLevel::Info < @log.LogLevel::Warn, content="true")
  inspect(@log.LogLevel::Warn < @log.LogLevel::Error, content="true")
  inspect(@log.LogLevel::Error < @log.LogLevel::Debug, content="false")
}

///|
test "LogLevel equality" {
  inspect(@log.LogLevel::Debug == @log.LogLevel::Debug, content="true")
  inspect(@log.LogLevel::Info == @log.LogLevel::Warn, content="false")
}
