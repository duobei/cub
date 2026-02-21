///|
/// Tests for LLM types.
test "ToolCallInfo::from_json: valid tool call" {
  let s =
    #|{"id":"call_123","type":"function","function":{"name":"bash","arguments":"{}"}}
  let json = @json.parse(s) catch { _ => panic() }
  let tc = @llm.ToolCallInfo::from_json(json)
  inspect(tc is Some(_), content="true")
}

///|
test "ToolCallInfo::from_json: missing fields returns None" {
  let s =
    #|{"id":"call_123"}
  let json = @json.parse(s) catch { _ => panic() }
  inspect(@llm.ToolCallInfo::from_json(json), content="None")
}

///|
test "ToolCallInfo::to_json roundtrip" {
  let s =
    #|{"id":"call_1","type":"function","function":{"name":"bash","arguments":"{}"}}
  let json = @json.parse(s) catch { _ => panic() }
  let tc = @llm.ToolCallInfo::from_json(json).unwrap()
  let json2 = tc.to_json()
  let tc2 = @llm.ToolCallInfo::from_json(json2)
  inspect(tc2 is Some(_), content="true")
}
