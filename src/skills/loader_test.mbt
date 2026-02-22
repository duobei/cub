/// Tests for skills loader functionality.

///|
test "parse_frontmatter extracts name and description" {
  let content =
    #|---
    #|name: my-skill
    #|description: Does something useful
    #|---
    #|
    #|Instructions here.
  let (meta, body) = @skills.parse_frontmatter(content)
  inspect(meta.get("name"), content="Some(\"my-skill\")")
  inspect(meta.get("description"), content="Some(\"Does something useful\")")
  inspect(body.contains("Instructions here"), content="true")
}

///|
test "parse_frontmatter handles missing frontmatter" {
  let content = "No frontmatter here.\nJust body text."
  let (meta, body) = @skills.parse_frontmatter(content)
  inspect(meta.length(), content="0")
  inspect(body.contains("No frontmatter here"), content="true")
}

///|
test "parse_frontmatter handles empty content" {
  let (meta, body) = @skills.parse_frontmatter("")
  inspect(meta.length(), content="0")
  inspect(body, content="")
}

///|
test "parse_frontmatter with metadata field" {
  let content =
    #|---
    #|name: discord-skill
    #|description: Discord helper
    #|metadata:
    #|  channel: discord
    #|---
    #|
    #|Body text.
  let (meta, _body) = @skills.parse_frontmatter(content)
  inspect(meta.get("name"), content="Some(\"discord-skill\")")
}
