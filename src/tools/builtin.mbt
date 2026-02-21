/// Built-in tools: bash, fs.read, fs.write, fs.edit, fs.list, fs.glob, grep, web.fetch, web.search,
/// schedule.add, schedule.remove, schedule.list, agent.spawn, skill.install, done.

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
  register_fs_list(registry, ctx)
  register_fs_glob(registry, ctx)
  register_grep(registry, ctx)
  register_web_fetch(registry, ctx)
  register_web_search(registry, ctx)
  register_skill_install(registry, ctx)
  register_schedule_add(registry, ctx)
  register_schedule_remove(registry, ctx)
  register_schedule_list(registry, ctx)
  register_agent_spawn(registry, ctx)
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
/// Register fs.list tool.
fn register_fs_list(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["path"] = string_prop(
    "Directory path (relative to workspace or absolute)",
  )
  let bool_prop : Map[String, Json] = Map::new()
  bool_prop["type"] = "boolean".to_json()
  bool_prop["description"] = "List recursively (default: false)".to_json()
  bool_prop["default"] = false.to_json()
  props["recursive"] = Json::object(bool_prop)
  let params = make_params(props, ["path"])
  registry.register(
    "fs.list",
    "List directory contents",
    detail="List files and directories. Use recursive=true to list all files recursively.",
    parameters=params,
    handler=async fn(args) {
      let path = match args {
        { "path": String(p), .. } => resolve_path(workspace, p)
        _ => workspace
      }
      let recursive = match args {
        { "recursive": True, .. } => true
        _ => false
      }
      list_directory(path, recursive)
    },
  )
}

///|
/// List directory contents.
async fn list_directory(path : String, recursive : Bool) -> String {
  let (cmd, cmd_args) = if recursive {
    ("find", [path, "-type", "f", "-not", "-path", "*/.*"])
  } else {
    ("ls", ["-1ap", path])
  }
  let (exit_code, stdout_data, stderr_data) = @async.with_timeout(15000, async fn() {
    @process.collect_output(cmd, cmd_args)
  }) catch {
    e => fail("fs.list: \{e}")
  }
  let stdout_text = stdout_data.text() catch { _ => "" }
  let stderr_text = stderr_data.text() catch { _ => "" }
  if exit_code != 0 {
    fail("fs.list: \{stderr_text}")
  }
  // Truncate at 200 entries
  let lines : Array[String] = []
  for line in stdout_text.split("\n") {
    let s = line.to_string()
    if s.is_empty() {
      continue
    }
    lines.push(s)
    if lines.length() >= 200 {
      break
    }
  }
  let total = stdout_text
    .split("\n")
    .fold(init=0, fn(acc, l) {
      if l.to_string().is_empty() {
        acc
      } else {
        acc + 1
      }
    })
  let result = lines.join("\n")
  if total > 200 {
    "\{result}\n\n[showing 200 of \{total} entries]"
  } else {
    result
  }
}

///|
/// Register fs.glob tool.
fn register_fs_glob(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["pattern"] = string_prop("File name pattern (e.g. *.mbt, *.json)")
  props["path"] = string_prop("Base directory to search (default: workspace)")
  let params = make_params(props, ["pattern"])
  registry.register(
    "fs.glob",
    "Find files by name pattern",
    detail="Search for files matching a glob pattern. Returns matching file paths.",
    parameters=params,
    handler=async fn(args) {
      let pattern = match args {
        { "pattern": String(p), .. } => p
        _ => fail("fs.glob: missing 'pattern' argument")
      }
      let path = match args {
        { "path": String(p), .. } => resolve_path(workspace, p)
        _ => workspace
      }
      glob_files(path, pattern)
    },
  )
}

///|
/// Find files matching a glob pattern.
async fn glob_files(path : String, pattern : String) -> String {
  let (exit_code, stdout_data, _stderr_data) = @async.with_timeout(15000, async fn() {
    @process.collect_output("find", [path, "-type", "f", "-name", pattern])
  }) catch {
    e => fail("fs.glob: \{e}")
  }
  let stdout_text = stdout_data.text() catch { _ => "" }
  if exit_code != 0 || stdout_text.trim().to_string().is_empty() {
    return "no matches found"
  }
  // Truncate at 200 results
  let lines : Array[String] = []
  for line in stdout_text.split("\n") {
    let s = line.to_string()
    if s.is_empty() {
      continue
    }
    lines.push(s)
    if lines.length() >= 200 {
      break
    }
  }
  let total = stdout_text
    .split("\n")
    .fold(init=0, fn(acc, l) {
      if l.to_string().is_empty() {
        acc
      } else {
        acc + 1
      }
    })
  let result = lines.join("\n")
  if total > 200 {
    "\{result}\n\n[showing 200 of \{total} matches]"
  } else {
    result
  }
}

///|
/// Register grep tool.
fn register_grep(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["pattern"] = string_prop("Search pattern (regex)")
  props["path"] = string_prop("Directory to search (default: workspace)")
  props["include"] = string_prop("File glob filter (e.g. *.mbt)")
  props["max_results"] = int_prop("Max matches to return", default_val=Some(50))
  let params = make_params(props, ["pattern"])
  registry.register(
    "grep",
    "Search file contents by pattern",
    detail="Search for a regex pattern in files. Returns matching lines with file paths and line numbers.",
    parameters=params,
    handler=async fn(args) {
      let pattern = match args {
        { "pattern": String(p), .. } => p
        _ => fail("grep: missing 'pattern' argument")
      }
      let path = match args {
        { "path": String(p), .. } => resolve_path(workspace, p)
        _ => workspace
      }
      let file_glob : String? = match args {
        { "include": String(i), .. } => Some(i)
        _ => None
      }
      let max_results = match args {
        { "max_results": Number(n, ..), .. } => n.to_int()
        _ => 50
      }
      grep_files(path, pattern, file_glob, max_results)
    },
  )
}

///|
/// Search file contents by regex pattern.
async fn grep_files(
  path : String,
  pattern : String,
  file_glob : String?,
  max_results : Int,
) -> String {
  let grep_args : Array[String] = ["-rn", "--color=never"]
  match file_glob {
    Some(fg) => grep_args.push("--include=\{fg}")
    None => ()
  }
  grep_args.push(pattern)
  grep_args.push(path)
  let (exit_code, stdout_data, stderr_data) = @async.with_timeout(15000, async fn() {
    @process.collect_output("grep", grep_args)
  }) catch {
    e => fail("grep: \{e}")
  }
  let stdout_text = stdout_data.text() catch { _ => "" }
  let stderr_text = stderr_data.text() catch { _ => "" }
  // grep returns 1 when no matches found (not an error)
  if exit_code > 1 {
    fail("grep: \{stderr_text}")
  }
  if stdout_text.trim().to_string().is_empty() {
    return "no matches found"
  }
  // Truncate at max_results
  let lines : Array[String] = []
  for line in stdout_text.split("\n") {
    let s = line.to_string()
    if s.is_empty() {
      continue
    }
    lines.push(s)
    if lines.length() >= max_results {
      break
    }
  }
  let total = stdout_text
    .split("\n")
    .fold(init=0, fn(acc, l) {
      if l.to_string().is_empty() {
        acc
      } else {
        acc + 1
      }
    })
  let result = lines.join("\n")
  if total > max_results {
    "\{result}\n\n[showing \{max_results} of \{total} matches]"
  } else {
    result
  }
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
    "Search the web and return results",
    detail="Search using DuckDuckGo and return top results with titles, URLs, and snippets.",
    parameters=params,
    handler=fn(args) raise {
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

///|
/// Generate a short unique job ID from current timestamp.

///|
/// Global counter for generating unique job IDs within a process.
let job_counter : Ref[Int] = { val: 0 }

///|
/// Generate a unique job ID using timestamp + counter.
fn generate_job_id() -> String {
  let ts = @async.now()
  job_counter.val = job_counter.val + 1
  let count = job_counter.val
  // FNV-1a hash mixing timestamp + counter
  let mut hash : UInt = 2166136261
  // Mix in timestamp bytes
  for i = 0; i < 8; i = i + 1 {
    let byte = ((ts >> (i * 8)) & 0xFFL).to_int().reinterpret_as_uint()
    hash = hash ^ byte
    hash = hash * 16777619
  }
  // Mix in counter
  hash = hash ^ count.reinterpret_as_uint()
  hash = hash * 16777619
  let hex_chars = "0123456789abcdef"
  let buf = StringBuilder::new()
  buf.write_string("job_")
  for i = 0; i < 8; i = i + 1 {
    let nibble = ((hash >> ((7 - i) * 4)) & 0xf).reinterpret_as_int()
    buf.write_char(hex_chars[nibble].to_int().unsafe_to_char())
  }
  buf.to_string()
}

///|
/// Register schedule.add tool.
fn register_schedule_add(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["message"] = string_prop("Message/task to execute when triggered")
  props["trigger"] = string_prop(
    "Trigger specification: 'cron:*/5 * * * *', 'date:2026-02-23T10:00:00', or 'interval:30m'",
  )
  props["session_id"] = string_prop(
    "Session ID to run the task in (optional, default: schedule)",
  )
  let params = make_params(props, ["message", "trigger"])
  registry.register(
    "schedule.add",
    "Add a scheduled task",
    detail="Schedule a task to run at a future time or on a recurring basis. Supports cron expressions, specific dates, and intervals (e.g. 30m, 1h, 2d).",
    parameters=params,
    handler=async fn(args) {
      let message = match args {
        { "message": String(m), .. } => m
        _ => fail("schedule.add: missing 'message' argument")
      }
      let trigger = match args {
        { "trigger": String(t), .. } => t
        _ => fail("schedule.add: missing 'trigger' argument")
      }
      let session_id = match args {
        { "session_id": String(s), .. } => s
        _ => "schedule"
      }
      // Validate trigger format
      if not(trigger.has_prefix("cron:")) &&
        not(trigger.has_prefix("date:")) &&
        not(trigger.has_prefix("interval:")) {
        fail(
          "schedule.add: trigger must start with 'cron:', 'date:', or 'interval:'",
        )
      }
      // Validate interval format if interval trigger
      if trigger.has_prefix("interval:") {
        let interval_str = trigger[9:].to_string() catch {
          _ => fail("schedule.add: invalid interval format")
        }
        if parse_interval_seconds(interval_str) <= 0 {
          fail(
            "schedule.add: invalid interval format (use e.g. '30m', '1h', '2d')",
          )
        }
      }
      let job_id = generate_job_id()
      // Build schedule entry
      let entry : Map[String, Json] = Map::new()
      entry["id"] = job_id.to_json()
      entry["message"] = message.to_json()
      entry["trigger"] = trigger.to_json()
      entry["session_id"] = session_id.to_json()
      let now_ms = @async.now()
      entry["created_at_ms"] = now_ms.to_json()
      entry["enabled"] = true.to_json()
      // Read existing schedules
      let schedules_path = resolve_schedules_path(workspace)
      let existing = read_schedules_file(schedules_path)
      existing.push(Json::object(entry))
      // Write back
      write_schedules_file(schedules_path, existing)
      "scheduled: \{job_id} (trigger: \{trigger})"
    },
  )
}

///|
/// Resolve the path to schedules.json.
fn resolve_schedules_path(_workspace : String) -> String {
  let home = @config.getenv("HOME").unwrap_or("/tmp")
  "\{home}/.cub/schedules.json"
}

///|
/// Read schedules from JSON file as sync via C FFI.
fn read_schedules_file(path : String) -> Array[Json] {
  let path_bytes = @config.string_to_cstr(path)
  let len = cub_read_file_ffi(path_bytes, Bytes::new(0), 0)
  if len <= 0 {
    return []
  }
  let buf = Bytes::new(len)
  let actual = cub_read_file_ffi(path_bytes, buf, len)
  if actual <= 0 {
    return []
  }
  let content = @utf8.decode_lossy(buf[:actual])
  if content.trim().to_string().is_empty() {
    return []
  }
  let parsed : Json = @json.parse(content) catch { _ => return [] }
  match parsed {
    Array(items) => items
    _ => []
  }
}

///|
/// FFI: read file for tools package.
#borrow(path, buf)
extern "C" fn cub_read_file_ffi(
  path : Bytes,
  buf : Bytes,
  buf_size : Int,
) -> Int = "cub_tools_read_file"

///|
/// Write schedules to JSON file. Raises on failure.
async fn write_schedules_file(path : String, schedules : Array[Json]) -> Unit {
  let json = Json::array(schedules)
  let content = json.stringify()
  // Create parent directory
  let parent = get_parent_dir(path)
  if parent.length() > 0 {
    @fs.mkdir(parent, permission=0o755, recursive=true) catch {
      _ => ()
    }
  }
  @fs.write_file(path, content, create=0o644) catch {
    e => fail("schedule: failed to write \{path}: \{e}")
  }
}

///|
/// Parse interval string like "30m", "1h", "2d" into seconds.
pub fn parse_interval_seconds(s : String) -> Int {
  let trimmed = s.trim().to_string()
  if trimmed.is_empty() {
    return -1
  }
  let last_char = trimmed[trimmed.length() - 1]
  let num_str = trimmed[:trimmed.length() - 1].to_string() catch {
    _ => return -1
  }
  let num = @strconv.parse_int(num_str) catch { _ => return -1 }
  if num <= 0 {
    return -1
  }
  let multiplier = if last_char == 's'.to_int().to_uint16() {
    1
  } else if last_char == 'm'.to_int().to_uint16() {
    60
  } else if last_char == 'h'.to_int().to_uint16() {
    3600
  } else if last_char == 'd'.to_int().to_uint16() {
    86400
  } else {
    return -1
  }
  num * multiplier
}

///|
/// Register schedule.remove tool.
fn register_schedule_remove(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["id"] = string_prop("Job ID to remove")
  let params = make_params(props, ["id"])
  registry.register(
    "schedule.remove",
    "Remove a scheduled task",
    detail="Remove a scheduled task by its job ID.",
    parameters=params,
    handler=async fn(args) {
      let id = match args {
        { "id": String(i), .. } => i
        _ => fail("schedule.remove: missing 'id' argument")
      }
      let path = resolve_schedules_path(workspace)
      let schedules = read_schedules_file(path)
      let filtered = schedules.filter(fn(s) {
        match s {
          { "id": String(sid), .. } => sid != id
          _ => true
        }
      })
      if filtered.length() == schedules.length() {
        fail("schedule.remove: job '\{id}' not found")
      }
      write_schedules_file(path, filtered)
      "removed: \{id}"
    },
  )
}

///|
/// Register schedule.list tool.
fn register_schedule_list(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let params = make_params(Map::new(), [])
  registry.register(
    "schedule.list",
    "List all scheduled tasks",
    detail="Show all pending scheduled tasks with their triggers and messages.",
    parameters=params,
    handler=fn(_args) {
      let path = resolve_schedules_path(workspace)
      let schedules = read_schedules_file(path)
      if schedules.is_empty() {
        return "no scheduled tasks"
      }
      let lines : Array[String] = []
      for s in schedules {
        let id = match s {
          { "id": String(i), .. } => i
          _ => "?"
        }
        let msg = match s {
          { "message": String(m), .. } => m
          _ => ""
        }
        let trigger = match s {
          { "trigger": String(t), .. } => t
          _ => ""
        }
        let enabled = match s {
          { "enabled": True, .. } => "active"
          _ => "disabled"
        }
        // Truncate message for display
        let display_msg = if msg.length() > 60 {
          "\{msg[:60]}..." catch {
            _ => msg
          }
        } else {
          msg
        }
        lines.push("  \{id}  [\{trigger}]  \{display_msg}  (\{enabled})")
      }
      "Scheduled tasks:\n" + lines.join("\n")
    },
  )
}

///|
/// Register agent.spawn tool.
fn register_agent_spawn(registry : ToolRegistry, ctx : ToolContext) -> Unit {
  let workspace = ctx.workspace
  let props : Map[String, Json] = Map::new()
  props["task"] = string_prop("Task description for the sub-agent to execute")
  props["session_id"] = string_prop(
    "Session ID for the sub-agent (optional, auto-generated if omitted)",
  )
  props["timeout_seconds"] = int_prop(
    "Maximum seconds for sub-agent to run",
    default_val=Some(300),
  )
  let params = make_params(props, ["task"])
  registry.register(
    "agent.spawn",
    "Spawn a sub-agent to handle a task",
    detail="Launch a sub-agent process that runs independently with its own session. The sub-agent inherits the workspace but has its own tape. Returns the sub-agent's final output.",
    parameters=params,
    requires_confirmation=true,
    handler=async fn(args) {
      let task = match args {
        { "task": String(t), .. } => t
        _ => fail("agent.spawn: missing 'task' argument")
      }
      let child_session = match args {
        { "session_id": String(s), .. } => s
        _ => "child_\{generate_job_id()}"
      }
      let timeout = match args {
        { "timeout_seconds": Number(n, ..), .. } => n.to_int()
        _ => 300
      }
      spawn_sub_agent(workspace, child_session, task, timeout)
    },
  )
}

///|
/// Spawn a sub-agent as a subprocess.
async fn spawn_sub_agent(
  workspace : String,
  _session_id : String,
  task : String,
  timeout : Int,
) -> String {
  // Find the cub binary
  let cub_bin = match @config.getenv("CUB_BIN") {
    Some(b) => b
    None => {
      // Try common locations via C FFI (lightweight: only check file size)
      let candidates = [
        "\{workspace}/_build/native/debug/build/main/main.exe",
        "/usr/local/bin/cub",
      ]
      let mut found = ""
      for c in candidates {
        let path_bytes = @config.string_to_cstr(c)
        let size = cub_read_file_ffi(path_bytes, Bytes::new(0), 0)
        if size > 0 {
          found = c
          break
        }
      }
      if found.is_empty() {
        fail("agent.spawn: cannot find cub binary (set CUB_BIN)")
      }
      found
    }
  }
  let (exit_code, stdout_data, stderr_data) = @async.with_timeout(
    timeout * 1000,
    async fn() {
      @process.collect_output(cub_bin, ["run", "--workspace", workspace, task])
    },
  ) catch {
    _ => fail("agent.spawn: timeout after \{timeout}s")
  }
  let stdout_text = stdout_data.text() catch { _ => "" }
  let stderr_text = stderr_data.text() catch { _ => "" }
  if exit_code != 0 {
    let error_output = if stderr_text.length() > 0 {
      stderr_text
    } else {
      stdout_text
    }
    fail("agent.spawn: exit=\{exit_code}: \{error_output}")
  }
  if stdout_text.trim().to_string().is_empty() {
    "(sub-agent produced no output)"
  } else {
    stdout_text
  }
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
