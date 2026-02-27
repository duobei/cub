/// Web tools: web.fetch, web.search, skill.install.

///|
/// Register web.fetch tool.
fn register_web_fetch(registry : ToolRegistry, _ctx : ToolContext) -> Unit {
  let props : Map[String, Json] = Map::new()
  props["url"] = string_prop("URL to fetch")
  let params = make_params(props, ["url"])
  registry.register(
    "web.fetch",
    "Fetch URL content",
    detail="Fetch a URL and return its content as plain text. HTML tags are stripped.",
    parameters=params,
    handler=async fn(args) {
      let url = match args {
        { "url": String(u), .. } => u
        _ => fail("web.fetch: missing 'url' argument")
      }
      fetch_url(url)
    },
  )
}

///|
/// Normalize a URL: ensure scheme, validate format.
fn normalize_url(raw : String) -> String raise {
  let url = raw.trim().to_string()
  if url.is_empty() {
    fail("web.fetch: empty URL")
  }
  // Check if it has a scheme
  let has_scheme = url.contains("://")
  if has_scheme {
    // Validate scheme is http or https
    let lower = url.to_lower()
    if lower.has_prefix("http://") || lower.has_prefix("https://") {
      return url
    }
    fail("web.fetch: unsupported scheme (only http/https)")
  }
  // No scheme — auto-upgrade to https
  "https://\{url}"
}

///|
/// Fetch URL content via async HTTP, strip HTML tags.
async fn fetch_url(raw_url : String) -> String {
  let url = normalize_url(raw_url)
  let headers : Map[String, String] = {}
  let (resp, data) = @platform.http_get(url, headers~) catch {
    e => fail("web.fetch: failed to fetch URL: \{e}")
  }
  if resp.code != 200 {
    fail("web.fetch: HTTP \{resp.code}")
  }
  let raw = data.text() catch { _ => "" }
  if raw.is_empty() {
    fail("web.fetch: empty response")
  }
  // Strip HTML tags and decode basic entities
  let stripped = strip_html_tags(raw)
  // Truncate if very large (keep first 50K chars)
  let max_len = 50000
  if stripped.length() > max_len {
    "\{stripped[:max_len]}\n\n[truncated]" catch {
      _ => stripped
    }
  } else {
    stripped
  }
}

///|
/// Strip HTML tags from a string (regex-free scanner).
fn strip_html_tags(html : String) -> String {
  let buf = StringBuilder::new()
  let mut in_tag = false
  let mut in_script = false
  let mut in_style = false
  let mut last_was_space = false
  let lt = '<'.to_int()
  let gt = '>'.to_int()
  for i, ch in html {
    let c = ch.to_int()
    if c == lt {
      // Check for <script or <style
      if not(in_tag) {
        let rest = peek_tag_name(html, i + 1)
        if rest == "script" {
          in_script = true
        } else if rest == "style" {
          in_style = true
        } else if rest == "/script" {
          in_script = false
        } else if rest == "/style" {
          in_style = false
        }
      }
      in_tag = true
      continue
    }
    if c == gt {
      in_tag = false
      continue
    }
    if in_tag || in_script || in_style {
      continue
    }
    // Collapse whitespace
    let is_ws = c == ' '.to_int() ||
      c == '\t'.to_int() ||
      c == '\n'.to_int() ||
      c == '\r'.to_int()
    if is_ws {
      if not(last_was_space) {
        buf.write_char(' ')
        last_was_space = true
      }
    } else {
      buf.write_char(ch.to_int().unsafe_to_char())
      last_was_space = false
    }
  }
  let result = buf.to_string()
  // Decode common HTML entities
  result
  .replace(old="&amp;", new="&")
  .replace(old="&lt;", new="<")
  .replace(old="&gt;", new=">")
  .replace(old="&quot;", new="\"")
  .replace(old="&#39;", new="'")
  .replace(old="&nbsp;", new=" ")
}

///|
/// Peek at the tag name starting at position i in the string.
fn peek_tag_name(s : String, start : Int) -> String {
  let buf = StringBuilder::new()
  let mut i = start
  // Skip leading /
  if i < s.length() && s[i].to_int() == '/'.to_int() {
    buf.write_char('/')
    i += 1
  }
  while i < s.length() {
    let c = s[i].to_int()
    if c == ' '.to_int() ||
      c == '>'.to_int() ||
      c == '\t'.to_int() ||
      c == '\n'.to_int() ||
      c == '/'.to_int() {
      break
    }
    // Lowercase
    let ch = if c >= 'A'.to_int() && c <= 'Z'.to_int() {
      (c + 32).unsafe_to_char()
    } else {
      c.unsafe_to_char()
    }
    buf.write_char(ch)
    i += 1
  }
  buf.to_string()
}

///|
/// Register web.search tool.
fn register_web_search(registry : ToolRegistry, _ctx : ToolContext) -> Unit {
  let props : Map[String, Json] = Map::new()
  props["query"] = string_prop("Search query")
  props["max_results"] = int_prop("Max results to return", default_val=Some(5))
  let params = make_params(props, ["query"])
  registry.register(
    "web.search",
    "Search the web and return results",
    detail="Search using DuckDuckGo and return top results with titles, URLs, and snippets.",
    parameters=params,
    handler=async fn(args) {
      let query = match args {
        { "query": String(q), .. } => q
        _ => fail("web.search: missing 'query' argument")
      }
      let max_results = match args {
        { "max_results": Number(n, ..), .. } => n.to_int()
        _ => 5
      }
      let encoded = url_encode(query)
      let lite_url = "https://lite.duckduckgo.com/lite/?q=\{encoded}"
      let raw_html = fetch_url(lite_url)
      parse_ddg_results(raw_html, max_results)
    },
  )
}

///|
/// Parse DuckDuckGo Lite search results from HTML text.
pub fn parse_ddg_results(html : String, max_results : Int) -> String {
  let results : Array[String] = []
  // DuckDuckGo Lite results are in <a> tags with class="result-link"
  // or simple <a rel="nofollow"> links followed by snippet text.
  // The stripped HTML (tags removed) contains: "N. Title URL snippet" pattern.
  // Since we already stripped HTML tags, we parse the plain text.
  // Look for numbered results: "1. Title  http://..."
  let lines : Array[String] = []
  for line in html.split("\n") {
    let trimmed = line.to_string().trim().to_string()
    if not(trimmed.is_empty()) {
      lines.push(trimmed)
    }
  }
  // Find lines that look like URLs (contain http:// or https://)
  let mut i = 0
  while i < lines.length() && results.length() < max_results {
    let line = lines[i]
    if line.contains("http://") || line.contains("https://") {
      // This line likely contains a result URL
      // Previous line might be the title, next line might be the snippet
      let title = if i > 0 { lines[i - 1] } else { "" }
      let url = extract_first_url(line)
      let snippet = if i + 1 < lines.length() {
        let next = lines[i + 1]
        if not(next.contains("http://")) && not(next.contains("https://")) {
          next
        } else {
          ""
        }
      } else {
        ""
      }
      if not(url.is_empty()) &&
        not(url.contains("duckduckgo.com")) &&
        title.length() > 1 {
        let n = results.length() + 1
        let entry = if snippet.is_empty() {
          "\{n}. \{title}\n   \{url}"
        } else {
          "\{n}. \{title}\n   \{url}\n   \{snippet}"
        }
        results.push(entry)
      }
    }
    i += 1
  }
  if results.is_empty() {
    "No results found."
  } else {
    results.join("\n\n")
  }
}

///|
/// Extract the first URL from a string.
fn extract_first_url(s : String) -> String {
  let mut start = find_substring_in(s, "https://")
  if start < 0 {
    start = find_substring_in(s, "http://")
  }
  if start < 0 {
    return ""
  }
  // Find end of URL (space, quote, or end of string)
  let buf = StringBuilder::new()
  for j = start; j < s.length(); j = j + 1 {
    let c = s[j].to_int()
    if c == ' '.to_int() ||
      c == '"'.to_int() ||
      c == '\''.to_int() ||
      c == '<'.to_int() ||
      c == '>'.to_int() {
      break
    }
    buf.write_char(c.unsafe_to_char())
  }
  buf.to_string()
}

///|
/// URL-encode a string (percent-encoding).
fn url_encode(s : String) -> String {
  let buf = StringBuilder::new()
  let hex = "0123456789ABCDEF"
  let utf8 = @utf8.encode(s)
  for i in 0..<utf8.length() {
    let b = utf8[i].to_int()
    if (b >= 'A'.to_int() && b <= 'Z'.to_int()) ||
      (b >= 'a'.to_int() && b <= 'z'.to_int()) ||
      (b >= '0'.to_int() && b <= '9'.to_int()) ||
      b == '-'.to_int() ||
      b == '_'.to_int() ||
      b == '.'.to_int() ||
      b == '~'.to_int() {
      buf.write_char(b.unsafe_to_char())
    } else if b == ' '.to_int() {
      buf.write_char('+')
    } else {
      buf.write_char('%')
      buf.write_char(hex[(b >> 4) & 0xF].to_int().unsafe_to_char())
      buf.write_char(hex[b & 0xF].to_int().unsafe_to_char())
    }
  }
  buf.to_string()
}

///|
/// Register skill.install tool.
fn register_skill_install(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["url"] = string_prop("URL to a SKILL.md file")
  props["name"] = string_prop("Override skill name (optional)")
  props["scope"] = string_prop(
    "Where to install: 'workspace' (default) or 'global'",
  )
  let params = make_params(props, ["url"])
  registry.register(
    "skill.install",
    "Install a skill from a URL",
    detail="Download a SKILL.md file from a URL and install it as a local skill.",
    parameters=params,
    handler=async fn(args) {
      let url = match args {
        { "url": String(u), .. } => u
        _ => fail("skill.install: missing 'url'")
      }
      let scope = match args {
        { "scope": String(s), .. } => s
        _ => "workspace"
      }
      // Validate URL against SSRF
      if not(is_safe_url(url)) {
        fail("skill.install: URL blocked (local/private addresses not allowed)")
      }
      // Fetch the SKILL.md content
      let content = fetch_url(url)
      // Extract name from frontmatter or override
      let skill_name = match args {
        { "name": String(n), .. } => n
        _ => extract_skill_name(content)
      }
      if skill_name.is_empty() {
        fail("skill.install: could not determine skill name")
      }
      match sanitize_name(skill_name) {
        None =>
          fail("skill.install: invalid skill name (must not contain / or ..)")
        Some(_) => ()
      }
      // Determine install path
      let base_dir = if scope == "global" {
        let home_dir = @config.getenv("HOME").unwrap_or("/tmp")
        "\{home_dir}/.agent/skills"
      } else {
        "\{workspace}/.agent/skills"
      }
      let skill_dir = "\{base_dir}/\{skill_name}"
      let skill_path = "\{skill_dir}/SKILL.md"
      // Create directory and write file
      write_file_content(skill_path, content)
    },
  )
}

///|
/// Extract skill name from SKILL.md frontmatter.
pub fn extract_skill_name(content : String) -> String {
  // Look for "name: xxx" in frontmatter (between --- markers)
  let mut in_frontmatter = false
  for line in content.split("\n") {
    let s = line.to_string().trim().to_string()
    if s == "---" {
      if in_frontmatter {
        break
      }
      in_frontmatter = true
      continue
    }
    if in_frontmatter && s.has_prefix("name:") {
      let name = s[5:].to_string() catch { _ => "" }
      return name.trim().to_string()
    }
  }
  ""
}
