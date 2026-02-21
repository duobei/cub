/// Built-in tools: bash, fs.read, fs.write, fs.edit, web.fetch, web.search, done.

///|
/// Default subprocess timeout in seconds.
let subprocess_timeout_seconds : Int = 30

///|
/// Register all built-in tools.
pub fn register_builtin_tools(
  registry : ToolRegistry,
  ctx : ToolContext,
) -> Unit {
  register_bash(registry, ctx)
  register_fs_read(registry, ctx)
  register_fs_write(registry, ctx)
  register_fs_edit(registry, ctx)
  register_web_fetch(registry, ctx)
  register_web_search(registry, ctx)
  register_done(registry, ctx)
}

///|
/// Build a JSON Schema object for tool parameters.
pub fn make_params(
  properties : Map[String, Json],
  required : Array[String],
) -> Json {
  let schema : Map[String, Json] = Map::new()
  schema["type"] = "object".to_json()
  schema["properties"] = Json::object(properties)
  if required.length() > 0 {
    let req_json : Array[Json] = []
    for r in required {
      req_json.push(r.to_json())
    }
    schema["required"] = Json::array(req_json)
  }
  Json::object(schema)
}

///|
/// Helper: create a string property schema.
pub fn string_prop(description : String) -> Json {
  let p : Map[String, Json] = Map::new()
  p["type"] = "string".to_json()
  p["description"] = description.to_json()
  Json::object(p)
}

///|
/// Helper: create an integer property schema.
fn int_prop(description : String, default_val? : Int? = None) -> Json {
  let p : Map[String, Json] = Map::new()
  p["type"] = "integer".to_json()
  p["description"] = description.to_json()
  match default_val {
    Some(d) => p["default"] = d.to_json()
    None => ()
  }
  Json::object(p)
}

///|
/// Helper: resolve a path relative to workspace.
fn resolve_path(workspace : String, path : String) -> String {
  if path.length() > 0 && path[0] == '/'.to_int().to_uint16() {
    path // absolute
  } else {
    "\{workspace}/\{path}"
  }
}

///|
/// Register bash tool.
fn register_bash(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let session_id = ctx.session_id
  let props : Map[String, Json] = Map::new()
  props["cmd"] = string_prop("Shell command to execute")
  props["cwd"] = string_prop("Working directory (default: workspace)")
  props["timeout_seconds"] = int_prop(
    "Maximum seconds to allow command to run",
    default_val=Some(subprocess_timeout_seconds),
  )
  let params = make_params(props, ["cmd"])
  registry.register(
    "bash",
    "Run shell command",
    detail="Execute a shell command using bash -lc. Returns stdout on success, stderr on failure.",
    parameters=params,
    requires_confirmation=true,
    handler=async fn(args) {
      let cmd = match args {
        { "cmd": String(c), .. } => c
        _ => fail("bash: missing 'cmd' argument")
      }
      let cwd = match args {
        { "cwd": String(c), .. } => c
        _ => workspace
      }
      let timeout = match args {
        { "timeout_seconds": Number(n, ..), .. } => n.to_int()
        _ => subprocess_timeout_seconds
      }
      run_bash_command(cmd, cwd, timeout, workspace, session_id)
    },
  )
}

///|
/// Execute a bash command.
async fn run_bash_command(
  cmd : String,
  cwd : String,
  timeout : Int,
  workspace : String,
  session_id : String,
) -> String {
  // Load workspace .env into extra environment
  let extra_env : Map[String, String] = {}
  let env_path = "\{workspace}/.env"
  let env_content = try {
    let data = @fs.read_file(env_path)
    data.text()
  } catch {
    _ => ""
  }
  if env_content.length() > 0 {
    let dotenv = @config.parse_dotenv(env_content)
    for k, v in dotenv {
      extra_env[k] = v
    }
  }
  extra_env["CUB_SESSION_ID"] = session_id
  let (exit_code, stdout_data, stderr_data) = @async.with_timeout(
    timeout * 1000,
    async fn() {
      @process.collect_output("bash", ["-lc", cmd], cwd~, extra_env~)
    },
  ) catch {
    e => fail("bash error: \{e}")
  }
  let stdout_text = stdout_data.text() catch { _ => "" }
  let stderr_text = stderr_data.text() catch { _ => "" }
  if exit_code != 0 {
    let error_output = if stderr_text.length() > 0 {
      stderr_text
    } else {
      stdout_text
    }
    fail("exit=\{exit_code}: \{error_output}")
  }
  if stdout_text.length() > 0 {
    stdout_text
  } else {
    "(no output)"
  }
}

///|
/// Register fs.read tool.
fn register_fs_read(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["path"] = string_prop("File path (relative to workspace or absolute)")
  props["offset"] = int_prop(
    "Line offset to start reading from",
    default_val=Some(0),
  )
  props["limit"] = int_prop("Maximum number of lines to read")
  let params = make_params(props, ["path"])
  registry.register(
    "fs.read",
    "Read file content",
    detail="Read file content with optional line offset and limit.",
    parameters=params,
    handler=async fn(args) {
      let path = match args {
        { "path": String(p), .. } => resolve_path(workspace, p)
        _ => fail("fs.read: missing 'path' argument")
      }
      let offset = match args {
        { "offset": Number(n, ..), .. } => n.to_int()
        _ => 0
      }
      let limit : Int? = match args {
        { "limit": Number(n, ..), .. } => Some(n.to_int())
        _ => None
      }
      read_file_content(path, offset, limit)
    },
  )
}

///|
/// Read file content with optional offset and limit.
async fn read_file_content(path : String, offset : Int, limit : Int?) -> String {
  let content = @fs.read_file(path).text() catch { e => fail("fs.read: \{e}") }
  let lines : Array[StringView] = []
  for line in content.split("\n") {
    lines.push(line)
  }
  let start = if offset < lines.length() { offset } else { lines.length() }
  let end = match limit {
    Some(l) => {
      let e = start + l
      if e < lines.length() {
        e
      } else {
        lines.length()
      }
    }
    None => lines.length()
  }
  let result = StringBuilder::new()
  for i = start; i < end; i = i + 1 {
    if i > start {
      result.write_char('\n')
    }
    result.write_string(lines[i].to_string())
  }
  result.to_string()
}

///|
/// Register fs.write tool.
fn register_fs_write(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["path"] = string_prop("File path (relative to workspace or absolute)")
  props["content"] = string_prop("File content to write")
  let params = make_params(props, ["path", "content"])
  registry.register(
    "fs.write",
    "Write file content",
    detail="Write content to a file. Creates parent directories if needed.",
    parameters=params,
    handler=async fn(args) {
      let path = match args {
        { "path": String(p), .. } => resolve_path(workspace, p)
        _ => fail("fs.write: missing 'path' argument")
      }
      let content = match args {
        { "content": String(c), .. } => c
        _ => fail("fs.write: missing 'content' argument")
      }
      write_file_content(path, content)
    },
  )
}

///|
/// Write content to a file, creating parent directories as needed.
async fn write_file_content(path : String, content : String) -> String {
  // Create parent directory
  let parent = get_parent_dir(path)
  if parent.length() > 0 {
    @fs.mkdir(parent, permission=0o755, recursive=true) catch {
      _ => ()
    }
  }
  @fs.write_file(path, content, create=0o644) catch {
    e => fail("fs.write: \{e}")
  }
  "wrote: \{path}"
}

///|
/// Get parent directory from a path.
fn get_parent_dir(path : String) -> String {
  let mut last_slash = -1
  for i, ch in path {
    if ch == '/' {
      last_slash = i
    }
  }
  if last_slash <= 0 {
    ""
  } else {
    path[:last_slash].to_string() catch {
      _ => ""
    }
  }
}

///|
/// Register fs.edit tool.
fn register_fs_edit(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["path"] = string_prop("File path (relative to workspace or absolute)")
  props["old_string"] = string_prop("The exact text to find and replace")
  props["new_string"] = string_prop("The replacement text")
  let bool_prop : Map[String, Json] = Map::new()
  bool_prop["type"] = "boolean".to_json()
  bool_prop["description"] = "Replace all occurrences (default: false)".to_json()
  bool_prop["default"] = false.to_json()
  props["replace_all"] = Json::object(bool_prop)
  let params = make_params(props, ["path", "old_string", "new_string"])
  registry.register(
    "fs.edit",
    "Edit file by replacing text",
    detail="Find and replace exact text in a file. Use replace_all=true to replace all occurrences.",
    parameters=params,
    handler=async fn(args) {
      let path = match args {
        { "path": String(p), .. } => resolve_path(workspace, p)
        _ => fail("fs.edit: missing 'path' argument")
      }
      let old_string = match args {
        { "old_string": String(s), .. } => s
        _ => fail("fs.edit: missing 'old_string' argument")
      }
      let new_string = match args {
        { "new_string": String(s), .. } => s
        _ => fail("fs.edit: missing 'new_string' argument")
      }
      let replace_all = match args {
        { "replace_all": True, .. } => true
        _ => false
      }
      edit_file_content(path, old_string, new_string, replace_all)
    },
  )
}

///|
/// Edit a file by finding and replacing text.
async fn edit_file_content(
  path : String,
  old_string : String,
  new_string : String,
  replace_all : Bool,
) -> String {
  let content = @fs.read_file(path).text() catch { e => fail("fs.edit: \{e}") }
  if not(content.contains(old_string)) {
    fail("fs.edit: old_string not found in file")
  }
  let new_content = if replace_all {
    content.replace(old=old_string, new=new_string)
  } else {
    // Replace first occurrence only
    let idx = find_substring_in(content, old_string)
    if idx < 0 {
      fail("fs.edit: old_string not found in file")
    }
    let before = content[:idx].to_string() catch { _ => "" }
    let after = content[idx + old_string.length():].to_string() catch {
      _ => ""
    }
    before + new_string + after
  }
  @fs.write_file(path, new_content, create=0o644) catch {
    e => fail("fs.edit: \{e}")
  }
  "edited: \{path}"
}

///|
/// Find substring position in a string.
fn find_substring_in(haystack : String, needle : String) -> Int {
  if needle.is_empty() {
    return 0
  }
  if needle.length() > haystack.length() {
    return -1
  }
  let limit = haystack.length() - needle.length()
  for i = 0; i <= limit; i = i + 1 {
    let mut matched = true
    for j = 0; j < needle.length(); j = j + 1 {
      if haystack[i + j] != needle[j] {
        matched = false
        break
      }
    }
    if matched {
      return i
    }
  }
  -1
}

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
    handler=fn(args) raise {
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
/// Fetch URL content via C FFI, strip HTML tags.
fn fetch_url(raw_url : String) -> String raise {
  let url = normalize_url(raw_url)
  let url_bytes = @config.string_to_cstr(url)
  // First pass: get content size
  let len = cub_web_fetch(url_bytes, Bytes::new(0), 0)
  if len <= 0 {
    fail("web.fetch: failed to fetch URL")
  }
  // Second pass: read content
  let buf = Bytes::new(len)
  let actual = cub_web_fetch(url_bytes, buf, len)
  if actual <= 0 {
    fail("web.fetch: failed to read response")
  }
  let raw = @utf8.decode_lossy(buf[:actual])
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
/// FFI: fetch URL content into buffer, returns size or -1 on error.
#borrow(url, buf)
extern "C" fn cub_web_fetch(url : Bytes, buf : Bytes, buf_size : Int) -> Int = "cub_web_fetch"

///|
/// Register web.search tool.
fn register_web_search(registry : ToolRegistry, _ctx : ToolContext) -> Unit {
  let props : Map[String, Json] = Map::new()
  props["query"] = string_prop("Search query")
  props["max_results"] = int_prop("Max results to return", default_val=Some(5))
  let params = make_params(props, ["query"])
  registry.register(
    "web.search",
    "Search the web",
    detail="Search the web using DuckDuckGo. Returns search URL and uses web.fetch to get results.",
    parameters=params,
    handler=fn(args) raise {
      let query = match args {
        { "query": String(q), .. } => q
        _ => fail("web.search: missing 'query' argument")
      }
      let encoded = url_encode(query)
      let search_url = "https://duckduckgo.com/?q=\{encoded}"
      let lite_url = "https://lite.duckduckgo.com/lite/?q=\{encoded}"
      let result = StringBuilder::new()
      result.write_string("Search URL: ")
      result.write_string(search_url)
      result.write_string("\n\nTo get results, use web.fetch with: ")
      result.write_string(lite_url)
      result.to_string()
    },
  )
}

///|
/// URL-encode a string (percent-encoding).
fn url_encode(s : String) -> String {
  let buf = StringBuilder::new()
  let hex = "0123456789ABCDEF"
  let utf8 = @utf8.encode(s)
  for i = 0; i < utf8.length(); i = i + 1 {
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
/// Register done tool.
fn register_done(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  ignore(ctx)
  let params = make_params(Map::new(), [])
  registry.register(
    "done",
    "Signal task completion",
    detail="Call this tool when the task is complete. Stops the agent loop.",
    parameters=params,
    handler=fn(_args) { "done" },
  )
}
