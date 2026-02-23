# Tape — Append-Only JSONL Conversation Store

The `tape` package provides an append-only JSONL tape for storing conversation
entries (messages, tool calls, tool results, events, anchors). It supports
anchor-aware context selection for LLM handoff recovery and smart truncation
of tool results.

## Creating Tape Entries

Entries are the basic unit of storage. Each has a `kind`, `payload`, and `meta`.

```mbt nocheck
///|
test "create message entries" {
  let user_msg = @tape.TapeEntry::message("user", "hello")
  inspect(user_msg.kind, content="message")

  let sys_msg = @tape.TapeEntry::system("You are helpful.")
  inspect(sys_msg.kind, content="system")

  let event = @tape.TapeEntry::event("session/start")
  inspect(event.kind, content="event")
}
```

## Anchors for Handoff Recovery

Anchors mark resumption points in the tape. Context selection only processes
entries after the last anchor, injecting anchor state as a system message.

```mbt nocheck
///|
test "create anchor entry" {
  let state : Map[String, Json] = { "summary": String("discussed API design") }
  let anchor = @tape.TapeEntry::anchor("handoff/v1", state=Some(state))
  inspect(anchor.kind, content="anchor")
}
```

## Context Selection

`select_messages` converts tape entries into LLM-ready chat messages,
respecting anchor boundaries.

```mbt nocheck
///|
test "select_messages from entries" {
  let entries = [
    @tape.TapeEntry::system("You are helpful."),
    @tape.TapeEntry::message("user", "What is 2+2?"),
    @tape.TapeEntry::message("assistant", "4"),
  ]
  let messages = @tape.select_messages(entries)
  inspect(messages.length(), content="3")
}
```

## Smart Truncation

Tool results are intelligently truncated based on the tool type to preserve
the most relevant output.

```mbt nocheck
///|
test "smart_truncate preserves short text" {
  let text = "short output"
  let result = @tape.smart_truncate(text, "bash")
  inspect(result, content="short output")
}
```

## Tool Call Validation

```mbt nocheck
///|
test "validate well-formed tool call" {
  let call : Json = {
    "id": "call_1",
    "function": { "name": "bash", "arguments": "{\"command\": \"ls\"}" },
  }
  inspect(@tape.validate_tool_call(call), content="true")
}
```
