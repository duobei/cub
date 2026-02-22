/// Tests for Discord channel functionality.

///|
test "check_permission allows message in allowed channel" {
  let dc = @channels.DiscordChannel::new("token", allow_channels=["123"])
  let result = dc.check_permission("123", "user1", "bob", "hello")
  inspect(result, content="ok")
}

///|
test "check_permission ignores message in non-allowed channel" {
  let dc = @channels.DiscordChannel::new("token", allow_channels=["123"])
  let result = dc.check_permission("456", "user1", "bob", "hello")
  inspect(result, content="ignored")
}

///|
test "check_permission denies unauthorized sender" {
  let dc = @channels.DiscordChannel::new("token", allow_channels=["123"], allow_from=[
    "user1",
  ])
  let result = dc.check_permission("123", "user2", "charlie", "hello")
  inspect(result, content="denied")
}

///|
test "check_permission allows authorized sender by name" {
  let dc = @channels.DiscordChannel::new("token", allow_channels=["123"], allow_from=[
    "bob",
  ])
  let result = dc.check_permission("123", "user2", "bob", "hello")
  inspect(result, content="ok")
}

///|
test "check_permission ignores when no channels configured" {
  let dc = @channels.DiscordChannel::new("token")
  let result = dc.check_permission("123", "user1", "bob", "hello")
  inspect(result, content="ignored")
}

///|
test "check_permission allows command in allowed channel" {
  let dc = @channels.DiscordChannel::new("token", allow_channels=["123"])
  let result = dc.check_permission("123", "user1", "bob", ",help")
  inspect(result, content="ok")
}

///|
test "chunk_message returns single chunk for short text" {
  let chunks = @channels.chunk_message("hello world", 100)
  inspect(chunks.length(), content="1")
  inspect(chunks[0], content="hello world")
}

///|
test "chunk_message splits long text" {
  let text = "line1\nline2\nline3\nline4"
  let chunks = @channels.chunk_message(text, 12)
  inspect(chunks.length() > 1, content="true")
}

///|
test "chunk_message handles text without newlines" {
  let text = "abcdefghijklmnop"
  let chunks = @channels.chunk_message(text, 5)
  // Should split into multiple chunks even without newlines
  inspect(chunks.length() > 1, content="true")
}
