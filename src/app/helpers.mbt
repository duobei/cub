/// Async filesystem and tape I/O utility functions.

///|
/// Read file content via async fs.
async fn read_file_sync(path : String) -> String {
  @platform.read_file_text(path) catch {
    _ => ""
  }
}

///|
/// Create directory recursively via async fs.
async fn mkdir_p_sync(path : String) -> Bool {
  @platform.mkdir(path, permission=0o755, recursive=true) catch {
    _ => return false
  }
  true
}

///|
/// Write file content via async fs. Creates parent directories.
async fn write_file_sync(path : String, content : String) -> Bool {
  // Create parent directory
  let mut last_slash = -1
  for i, ch in path {
    if ch == '/' {
      last_slash = i
    }
  }
  if last_slash > 0 {
    let parent = path[:last_slash].to_string() catch { _ => "" }
    if not(parent.is_empty()) {
      ignore(mkdir_p_sync(parent))
    }
  }
  @platform.write_file(path, content, create=0o644) catch {
    _ => return false
  }
  true
}

///|
/// Make file executable via async fs.
async fn chmod_x(path : String) -> Bool {
  @platform.chmod(path, 0o755) catch {
    _ => return false
  }
  true
}

///|
/// Remove a file or directory recursively via async fs.
async fn remove_path_sync(path : String) -> Bool {
  let file_kind = @platform.file_kind(path) catch { _ => return false }
  match file_kind {
    Directory =>
      @platform.rmdir(path, recursive=true) catch {
        _ => return false
      }
    _ => @platform.remove(path) catch { _ => return false }
  }
  true
}

///|
/// List files in a directory via async fs.
async fn list_dir_sync(path : String) -> Array[String] {
  @platform.readdir(path) catch {
    _ => []
  }
}

///|
/// Read identity from genome/identity.md (fallback: AGENTS.md).
async fn read_agents_md(workspace : String, home? : String = "") -> String {
  // Prefer genome/identity.md if home is provided
  if not(home.is_empty()) {
    let genome_text = read_file_sync("\{home}/genome/identity.md")
    if not(genome_text.is_empty()) {
      return "<workspace_instructions>\n\{genome_text}\n</workspace_instructions>"
    }
  }
  // Fallback to workspace/AGENTS.md
  let text = read_file_sync("\{workspace}/AGENTS.md")
  if text.is_empty() {
    return ""
  }
  "<workspace_instructions>\n\{text}\n</workspace_instructions>"
}

///|
/// Export tape entries to readable markdown format.
fn export_tape_to_markdown(entries : Array[@tape.TapeEntry]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("# Tape Export\n\n")
  for entry in entries {
    match entry.kind {
      "message" =>
        match entry.payload {
          { "role": String(role), "content": String(content), .. } => {
            let heading = if role == "user" { "User" } else { "Assistant" }
            buf.write_string("### \{heading}\n\{content}\n\n")
          }
          _ => ()
        }
      "tool_call" =>
        match entry.payload {
          { "calls": Array(calls), .. } =>
            for call in calls {
              match call {
                {
                  "function": {
                    "name": String(name),
                    "arguments": String(args),
                    ..
                  },
                  ..
                } =>
                  buf.write_string(
                    "### Tool Call: \{name}\n```json\n\{args}\n```\n\n",
                  )
                _ => ()
              }
            }
          _ => ()
        }
      "tool_result" =>
        match entry.payload {
          { "results": Array(results), .. } =>
            for result in results {
              let content = match result {
                { "content": String(c), .. } => c
                _ => result.stringify()
              }
              let max_len = 500
              let truncated = if content.length() > max_len {
                "\{content[:max_len]}\n[...truncated]" catch {
                  _ => content
                }
              } else {
                content
              }
              buf.write_string("### Result\n```\n\{truncated}\n```\n\n")
            }
          _ => ()
        }
      "anchor" =>
        match entry.payload {
          { "name": String(name), .. } =>
            buf.write_string("---\n**Handoff: \{name}**\n\n")
          _ => ()
        }
      _ => ()
    }
  }
  buf.to_string()
}
