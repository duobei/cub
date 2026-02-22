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

///|
test "markdown_to_html: plain text escapes HTML" {
  inspect(
    @channels.markdown_to_html("a < b & c > d"),
    content="a &lt; b &amp; c &gt; d",
  )
}

///|
test "markdown_to_html: inline code" {
  inspect(
    @channels.markdown_to_html("use `foo()` here"),
    content="use <code>foo()</code> here",
  )
}

///|
test "markdown_to_html: bold text" {
  inspect(
    @channels.markdown_to_html("this is **bold** text"),
    content="this is <b>bold</b> text",
  )
}

///|
test "markdown_to_html: italic text" {
  inspect(
    @channels.markdown_to_html("this is *italic* text"),
    content="this is <i>italic</i> text",
  )
}

///|
test "markdown_to_html: strikethrough" {
  inspect(
    @channels.markdown_to_html("this is ~~deleted~~ text"),
    content="this is <s>deleted</s> text",
  )
}

///|
test "markdown_to_html: link" {
  inspect(
    @channels.markdown_to_html("click [here](https://example.com)"),
    content="click <a href=\"https://example.com\">here</a>",
  )
}

///|
test "markdown_to_html: code block" {
  let input = "```python\nprint(\"hello\")\n```"
  let result = @channels.markdown_to_html(input)
  inspect(
    result,
    content="<pre><code class=\"language-python\">print(&quot;hello&quot;)\n</code></pre>",
  )
}

///|
test "markdown_to_html: code block escapes HTML" {
  let input = "```\n<b>not bold</b>\n```"
  let result = @channels.markdown_to_html(input)
  inspect(
    result,
    content="<pre><code>&lt;b&gt;not bold&lt;/b&gt;\n</code></pre>",
  )
}

///|
test "markdown_to_html: mixed content" {
  inspect(
    @channels.markdown_to_html("**bold** and `code`"),
    content="<b>bold</b> and <code>code</code>",
  )
}
