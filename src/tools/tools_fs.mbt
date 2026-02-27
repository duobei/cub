/// Filesystem tools: fs.read, fs.write, fs.edit, fs.list, fs.glob, grep.

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
      let raw_path = match args {
        { "path": String(p), .. } => p
        _ => fail("fs.read: missing 'path' argument")
      }
      let path = match safe_resolve_path(workspace, raw_path) {
        Ok(p) => p
        Err(e) => fail("fs.read: \{e}")
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
  let content = @platform.read_file_text(path) catch {
    e => fail("fs.read: \{e}")
  }
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
      let raw_path = match args {
        { "path": String(p), .. } => p
        _ => fail("fs.write: missing 'path' argument")
      }
      let path = match safe_resolve_path(workspace, raw_path) {
        Ok(p) => p
        Err(e) => fail("fs.write: \{e}")
      }
      if is_ext_path(path) {
        return "ERROR: Do not manually write to .agent/plugins/ or .agent/tools/. Use tool.create instead — it handles scaffolding, build, and hot-registration in one call."
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
    @platform.mkdir(parent, permission=0o755, recursive=true) catch {
      _ => ()
    }
  }
  @platform.write_file(path, content, create=0o644) catch {
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
      let raw_path = match args {
        { "path": String(p), .. } => p
        _ => fail("fs.edit: missing 'path' argument")
      }
      let path = match safe_resolve_path(workspace, raw_path) {
        Ok(p) => p
        Err(e) => fail("fs.edit: \{e}")
      }
      if is_ext_path(path) {
        return "ERROR: Do not manually edit files under .agent/plugins/ or .agent/tools/. Use tool.create instead — it handles scaffolding, build, and hot-registration in one call."
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
  let content = @platform.read_file_text(path) catch {
    e => fail("fs.edit: \{e}")
  }
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
  @platform.write_file(path, new_content, create=0o644) catch {
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
  for i in 0..<=limit {
    let mut matched = true
    for j in 0..<needle.length() {
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
        { "path": String(p), .. } =>
          match safe_resolve_path(workspace, p) {
            Ok(rp) => rp
            Err(e) => fail("fs.list: \{e}")
          }
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
    @platform.collect_output(cmd, cmd_args)
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
        { "path": String(p), .. } =>
          match safe_resolve_path(workspace, p) {
            Ok(rp) => rp
            Err(e) => fail("fs.glob: \{e}")
          }
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
    @platform.collect_output("find", [path, "-type", "f", "-name", pattern])
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
        { "path": String(p), .. } =>
          match safe_resolve_path(workspace, p) {
            Ok(rp) => rp
            Err(e) => fail("grep: \{e}")
          }
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
    @platform.collect_output("grep", grep_args)
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
