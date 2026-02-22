///|
/// Tests for tape entry types.
test "message creates correct payload" {
  let entry = @tape.TapeEntry::message("user", "hello")
  inspect(entry.kind, content="message")
  match entry.payload {
    { "role": String(r), "content": String(c), .. } => {
      inspect(r, content="user")
      inspect(c, content="hello")
    }
    _ => fail("unexpected payload format")
  }
}

///|
test "message_with_images creates vision format" {
  let entry = @tape.TapeEntry::message_with_images("user", "describe this", [
    "https://example.com/img.png",
  ])
  inspect(entry.kind, content="message")
  match entry.payload {
    { "role": String(r), "content": Array(parts), .. } => {
      inspect(r, content="user")
      inspect(parts.length(), content="2")
      // First part should be text
      match parts[0] {
        { "type": String(t), "text": String(txt), .. } => {
          inspect(t, content="text")
          inspect(txt, content="describe this")
        }
        _ => fail("expected text part")
      }
      // Second part should be image_url
      match parts[1] {
        { "type": String(t), "image_url": { "url": String(u), .. }, .. } => {
          inspect(t, content="image_url")
          inspect(u, content="https://example.com/img.png")
        }
        _ => fail("expected image_url part")
      }
    }
    _ => fail("expected array content for vision format")
  }
}

///|
test "message_with_images multiple images" {
  let entry = @tape.TapeEntry::message_with_images("user", "compare", [
    "https://a.com/1.png", "https://b.com/2.png",
  ])
  match entry.payload {
    { "content": Array(parts), .. } => inspect(parts.length(), content="3") // 1 text + 2 images
    _ => fail("expected array content")
  }
}

///|
test "message_with_images empty text omits text part" {
  let entry = @tape.TapeEntry::message_with_images("user", "", [
    "https://example.com/img.png",
  ])
  match entry.payload {
    { "content": Array(parts), .. } => {
      inspect(parts.length(), content="1") // only image, no text
      match parts[0] {
        { "type": String(t), .. } => inspect(t, content="image_url")
        _ => fail("expected image_url part")
      }
    }
    _ => fail("expected array content")
  }
}
