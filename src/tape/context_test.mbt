///|
/// Tests for tape context selection.
test "select_messages empty entries" {
  let entries : Array[TapeEntry] = []
  let msgs = select_messages(entries)
  inspect(msgs.length(), content="0")
}

///|
test "select_messages single user message" {
  let entries = [TapeEntry::message("user", "hello")]
  let msgs = select_messages(entries)
  inspect(msgs.length(), content="1")
  match msgs[0] {
    { "role": String(r), "content": String(c), .. } => {
      inspect(r, content="user")
      inspect(c, content="hello")
    }
    _ => fail("unexpected message format")
  }
}

///|
test "select_messages skips entries before anchor" {
  let entries = [
    TapeEntry::message("user", "old message"),
    TapeEntry::message("assistant", "old reply"),
    TapeEntry::anchor("test"),
    TapeEntry::message("user", "new message"),
  ]
  let msgs = select_messages(entries)
  // Should only have the message after anchor (no anchor state → no system msg)
  inspect(msgs.length(), content="1")
  match msgs[0] {
    { "content": String(c), .. } => inspect(c, content="new message")
    _ => fail("unexpected format")
  }
}

///|
test "select_messages injects anchor state as handoff_context" {
  let state : Map[String, Json] = {}
  state["summary"] = "did stuff".to_json()
  state["task"] = "do more".to_json()
  let entries = [
    TapeEntry::anchor("handoff", state=Some(state)),
    TapeEntry::message("user", "continue"),
  ]
  let msgs = select_messages(entries)
  // First message is the handoff context system message, second is user message
  inspect(msgs.length(), content="2")
  match msgs[0] {
    { "role": String(r), "content": String(c), .. } => {
      inspect(r, content="system")
      inspect(c.contains("Summary: did stuff"), content="true")
      inspect(c.contains("Current task: do more"), content="true")
    }
    _ => fail("expected system message")
  }
}

///|
test "select_messages drops orphan tool_call without tool_result" {
  let call_json : Map[String, Json] = {}
  call_json["id"] = "call_1".to_json()
  let func : Map[String, Json] = {}
  func["name"] = "test_tool".to_json()
  func["arguments"] = "{}".to_json()
  call_json["function"] = Json::object(func)
  let entries = [
    TapeEntry::message("user", "do something"),
    TapeEntry::tool_call([Json::object(call_json)]),
    // No tool_result follows — orphan
    TapeEntry::message("user", "next question"),
  ]
  let msgs = select_messages(entries)
  // Should have 2 user messages, orphan tool_call dropped
  inspect(msgs.length(), content="2")
}

///|
test "select_messages pairs tool_call with tool_result" {
  let call_json : Map[String, Json] = {}
  call_json["id"] = "call_1".to_json()
  let func : Map[String, Json] = {}
  func["name"] = "bash".to_json()
  func["arguments"] = "{\"command\": \"echo hi\"}".to_json()
  call_json["function"] = Json::object(func)
  let entries = [
    TapeEntry::message("user", "run echo"),
    TapeEntry::tool_call([Json::object(call_json)]),
    TapeEntry::tool_result(["hi".to_json()]),
  ]
  let msgs = select_messages(entries)
  // user msg + assistant (tool_call) msg + tool result msg = 3
  inspect(msgs.length(), content="3")
  // Second message should be assistant with tool_calls
  match msgs[1] {
    { "role": String(r), "tool_calls": Array(_), .. } =>
      inspect(r, content="assistant")
    _ => fail("expected assistant message with tool_calls")
  }
  // Third message should be tool result
  match msgs[2] {
    { "role": String(r), "tool_call_id": String(id), .. } => {
      inspect(r, content="tool")
      inspect(id, content="call_1")
    }
    _ => fail("expected tool message")
  }
}

///|
test "extract_anchor_context with all fields" {
  let state : Map[String, Json] = {}
  state["summary"] = "done A".to_json()
  state["context"] = "file X modified".to_json()
  state["next_steps"] = "do B".to_json()
  state["task"] = "build feature".to_json()
  let payload : Map[String, Json] = {}
  payload["state"] = Json::object(state)
  let result = extract_anchor_context(Json::object(payload))
  inspect(result.contains("Summary: done A"), content="true")
  inspect(result.contains("Context: file X modified"), content="true")
  inspect(result.contains("Next steps: do B"), content="true")
  inspect(result.contains("Current task: build feature"), content="true")
}

///|
test "extract_anchor_context with empty state" {
  let result = extract_anchor_context(Json::null())
  inspect(result, content="")
}

///|
test "smart_truncate short text passes through" {
  let text = "line1\nline2\nline3"
  let result = smart_truncate(text, "bash")
  inspect(result, content="line1\nline2\nline3")
}

///|
test "smart_truncate default truncation" {
  let lines : Array[String] = []
  for i in 0..<100 {
    lines.push("line \{i}")
  }
  let text = lines.join("\n")
  let result = smart_truncate(text, "unknown")
  inspect(result.contains("100 lines total"), content="true")
  inspect(result.contains("line 0"), content="true")
}

///|
test "smart_truncate bash keeps tail for errors" {
  let lines : Array[String] = []
  for i in 0..<100 {
    lines.push("line \{i}")
  }
  let text = lines.join("\n")
  let result = smart_truncate(text, "bash")
  // bash: head=10, tail=30, should keep last 30 lines
  inspect(result.contains("line 99"), content="true")
  inspect(result.contains("lines omitted"), content="true")
}

///|
test "smart_truncate fs.read keeps head and tail" {
  let lines : Array[String] = []
  for i in 0..<100 {
    lines.push("line \{i}")
  }
  let text = lines.join("\n")
  let result = smart_truncate(text, "fs_read")
  // fs_read: head=40, tail=20, should keep both
  inspect(result.contains("line 0"), content="true")
  inspect(result.contains("line 99"), content="true")
  inspect(result.contains("lines omitted"), content="true")
}

///|
test "smart_truncate grep keeps top 60" {
  let lines : Array[String] = []
  for i in 0..<100 {
    lines.push("match \{i}")
  }
  let text = lines.join("\n")
  let result = smart_truncate(text, "grep")
  // grep: head=60, tail=10
  inspect(result.contains("match 0"), content="true")
  inspect(result.contains("match 59"), content="true")
  inspect(result.contains("match 99"), content="true")
  inspect(result.contains("lines omitted"), content="true")
}

///|
test "smart_truncate fs.list keeps top 60" {
  let lines : Array[String] = []
  for i in 0..<100 {
    lines.push("file_\{i}.txt")
  }
  let text = lines.join("\n")
  let result = smart_truncate(text, "fs_list")
  inspect(result.contains("file_0.txt"), content="true")
  inspect(result.contains("100 lines total"), content="true")
}

///|
test "smart_truncate bash head=10 tail=30" {
  let lines : Array[String] = []
  for i in 0..<100 {
    lines.push("log \{i}")
  }
  let text = lines.join("\n")
  let result = smart_truncate(text, "bash")
  // head=10: line 0-9
  inspect(result.contains("log 0"), content="true")
  inspect(result.contains("log 9"), content="true")
  // tail=30: line 70-99
  inspect(result.contains("log 70"), content="true")
  inspect(result.contains("log 99"), content="true")
  // middle omitted
  inspect(result.contains("60 lines omitted"), content="true")
}

///|
test "smart_truncate exactly at limit passes through" {
  let lines : Array[String] = []
  for i in 0..<80 {
    lines.push("line \{i}")
  }
  let text = lines.join("\n")
  let result = smart_truncate(text, "bash")
  // 80 lines = exactly at limit, no truncation
  inspect(result == text, content="true")
}

///|
test "select_messages drops tool_result when tool_call has invalid args" {
  // Simulate a tool_call with invalid JSON arguments (truncated by model)
  let call_json : Map[String, Json] = {}
  call_json["id"] = "call_bad".to_json()
  let func : Map[String, Json] = {}
  func["name"] = "fs_write".to_json()
  func["arguments"] = "{\"content\": \"truncated...".to_json() // invalid JSON
  call_json["function"] = Json::object(func)
  // The tool_result references the bad call's id
  let result_json : Map[String, Json] = {}
  result_json["tool_call_id"] = "call_bad".to_json()
  result_json["name"] = "fs_write".to_json()
  result_json["content"] = "Error: missing path".to_json()
  let entries = [
    TapeEntry::message("user", "write a file"),
    TapeEntry::tool_call([Json::object(call_json)]),
    TapeEntry::tool_result([Json::object(result_json)]),
    TapeEntry::message("user", "next question"),
  ]
  let msgs = select_messages(entries)
  // Should have 2 user messages only — tool_call and tool_result both dropped
  inspect(msgs.length(), content="2")
  match msgs[0] {
    { "content": String(c), .. } => inspect(c, content="write a file")
    _ => fail("expected first user message")
  }
  match msgs[1] {
    { "content": String(c), .. } => inspect(c, content="next question")
    _ => fail("expected second user message")
  }
}

///|
test "select_messages keeps valid tool_call but drops filtered result" {
  // One valid call, one invalid call in the same tool_call entry
  let good_call : Map[String, Json] = {}
  good_call["id"] = "call_good".to_json()
  let good_func : Map[String, Json] = {}
  good_func["name"] = "bash".to_json()
  good_func["arguments"] = "{\"command\": \"ls\"}".to_json()
  good_call["function"] = Json::object(good_func)
  let bad_call : Map[String, Json] = {}
  bad_call["id"] = "call_bad".to_json()
  let bad_func : Map[String, Json] = {}
  bad_func["name"] = "fs_write".to_json()
  bad_func["arguments"] = "not valid json".to_json()
  bad_call["function"] = Json::object(bad_func)
  // Results for both
  let good_result : Map[String, Json] = {}
  good_result["tool_call_id"] = "call_good".to_json()
  good_result["name"] = "bash".to_json()
  good_result["content"] = "file1 file2".to_json()
  let bad_result : Map[String, Json] = {}
  bad_result["tool_call_id"] = "call_bad".to_json()
  bad_result["name"] = "fs_write".to_json()
  bad_result["content"] = "Error".to_json()
  let entries = [
    TapeEntry::message("user", "do stuff"),
    TapeEntry::tool_call([Json::object(good_call), Json::object(bad_call)]),
    TapeEntry::tool_result([Json::object(good_result), Json::object(bad_result)]),
  ]
  let msgs = select_messages(entries)
  // user msg + assistant (with only good call) + good tool result = 3
  inspect(msgs.length(), content="3")
  // Assistant should have only 1 tool_call
  match msgs[1] {
    { "role": String("assistant"), "tool_calls": Array(calls), .. } =>
      inspect(calls.length(), content="1")
    _ => fail("expected assistant with tool_calls")
  }
  // Tool result should be for good call only
  match msgs[2] {
    { "role": String("tool"), "tool_call_id": String(id), .. } =>
      inspect(id, content="call_good")
    _ => fail("expected tool result for good call")
  }
}

///|
test "validate_tool_call valid call" {
  let call : Map[String, Json] = {}
  call["id"] = "call_1".to_json()
  let func : Map[String, Json] = {}
  func["name"] = "bash".to_json()
  func["arguments"] = "{\"cmd\": \"ls\"}".to_json()
  call["function"] = Json::object(func)
  inspect(validate_tool_call(Json::object(call)), content="true")
}

///|
test "validate_tool_call invalid arguments" {
  let call : Map[String, Json] = {}
  call["id"] = "call_1".to_json()
  let func : Map[String, Json] = {}
  func["name"] = "bash".to_json()
  func["arguments"] = "not json{".to_json()
  call["function"] = Json::object(func)
  inspect(validate_tool_call(Json::object(call)), content="false")
}

///|
test "validate_tool_call missing id" {
  let call : Map[String, Json] = {}
  let func : Map[String, Json] = {}
  func["name"] = "bash".to_json()
  func["arguments"] = "{}".to_json()
  call["function"] = Json::object(func)
  inspect(validate_tool_call(Json::object(call)), content="false")
}

///|
test "validate_tool_call empty name" {
  let call : Map[String, Json] = {}
  call["id"] = "call_1".to_json()
  let func : Map[String, Json] = {}
  func["name"] = "".to_json()
  func["arguments"] = "{}".to_json()
  call["function"] = Json::object(func)
  inspect(validate_tool_call(Json::object(call)), content="false")
}
