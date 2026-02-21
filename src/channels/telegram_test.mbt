///|
/// Tests for Telegram channel helpers.
test "escape_html: escapes ampersand" {
  inspect(@channels.escape_html("a & b"), content="a &amp; b")
}

///|
test "escape_html: escapes less than" {
  inspect(@channels.escape_html("a < b"), content="a &lt; b")
}

///|
test "escape_html: escapes greater than" {
  inspect(@channels.escape_html("a > b"), content="a &gt; b")
}

///|
test "escape_html: all three" {
  inspect(
    @channels.escape_html("<b>test & go</b>"),
    content="&lt;b&gt;test &amp; go&lt;/b&gt;",
  )
}

///|
test "escape_html: no special chars unchanged" {
  inspect(@channels.escape_html("hello world"), content="hello world")
}

///|
test "escape_html: empty string" {
  inspect(@channels.escape_html(""), content="")
}
