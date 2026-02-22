/// Extension discovery and loading.

///|
/// Discover extensions from all search paths.
/// Priority: workspace tools/plugins > global tools/plugins.
/// Deduplicates by name (first wins = workspace overrides global).
pub fn discover_extensions(
  home : String,
  workspace : String,
) -> Array[ExtManifest] {
  let seen : Map[String, Bool] = {}
  let results : Array[ExtManifest] = []
  // Search order: workspace first, then global
  let dirs = [
    ("\{workspace}/.agent/tools", ExtType::Script, "workspace"),
    ("\{workspace}/.agent/plugins", ExtType::Wasm, "workspace"),
    ("\{home}/tools", ExtType::Script, "global"),
    ("\{home}/plugins", ExtType::Wasm, "global"),
  ]
  for item in dirs {
    let (dir, ext_type, scope) = item
    let entries = list_ext_dir(dir)
    for entry in entries {
      let manifest = load_entry(dir, entry, ext_type, scope)
      match manifest {
        Some(m) =>
          if not(seen.contains(m.name)) {
            seen[m.name] = true
            results.push(m)
          }
        None => ()
      }
    }
  }
  results
}

///|
/// Load a single directory entry as an extension manifest.
fn load_entry(
  dir : String,
  entry : String,
  ext_type : ExtType,
  scope : String,
) -> ExtManifest? {
  match ext_type {
    Script => load_script_entry(dir, entry, scope)
    Wasm => load_wasm_entry(dir, entry, scope)
  }
}

///|
/// Load a script tool entry. Expects an executable file (e.g. check-pr.sh).
/// Optionally reads a .json manifest with the same base name.
fn load_script_entry(
  dir : String,
  entry : String,
  scope : String,
) -> ExtManifest? {
  // Skip manifest .json files — they are metadata, not tools
  if entry.has_suffix(".json") {
    return None
  }
  let path = "\{dir}/\{entry}"
  let name = derive_tool_name(entry)
  if name.is_empty() {
    return None
  }
  // Try to read companion manifest
  let (description, parameters) = read_script_manifest(dir, entry)
  Some({ name, ext_type: Script, description, path, parameters, scope })
}

///|
/// Load a WASM plugin entry. Expects a directory with plugin.json manifest.
fn load_wasm_entry(
  dir : String,
  entry : String,
  scope : String,
) -> ExtManifest? {
  let plugin_dir = "\{dir}/\{entry}"
  let manifest_path = "\{plugin_dir}/plugin.json"
  let content = read_ext_file(manifest_path)
  if content.is_empty() {
    return None
  }
  let parsed : Json = @json.parse(content) catch { _ => return None }
  let name = match parsed {
    { "name": String(n), .. } => n
    _ => entry
  }
  let description = match parsed {
    { "description": String(d), .. } => d
    _ => "WASM plugin: \{name}"
  }
  let parameters = match parsed {
    { "parameters": Object(_) as p, .. } => p
    _ => Json::object({})
  }
  // Find the wasm file
  let wasm_path = find_wasm_file(plugin_dir)
  if wasm_path.is_empty() {
    return None
  }
  Some({ name, ext_type: Wasm, description, path: wasm_path, parameters, scope })
}

///|
/// Find the .wasm file in a plugin directory (public API).
pub fn find_wasm_in_plugin(plugin_dir : String) -> String {
  find_wasm_file(plugin_dir)
}

///|
/// Find the .wasm file in a plugin directory.
/// Looks in _build subdirectories for main.wasm.
fn find_wasm_file(plugin_dir : String) -> String {
  // Common path: _build/target/wasm-gc/release/build/main/main.wasm
  let candidates = [
    "\{plugin_dir}/_build/wasm-gc/release/build/cmd/main/main.wasm",
    "\{plugin_dir}/_build/wasm-gc/debug/build/cmd/main/main.wasm",
    "\{plugin_dir}/main.wasm",
  ]
  for path in candidates {
    let content = read_ext_file(path)
    if not(content.is_empty()) {
      return path
    }
  }
  // Fallback: scan for any .wasm file
  let entries = list_ext_dir(plugin_dir)
  for entry in entries {
    if entry.has_suffix(".wasm") {
      return "\{plugin_dir}/\{entry}"
    }
  }
  ""
}

///|
/// Read companion .json manifest for a script tool.
/// Returns (description, parameters).
fn read_script_manifest(dir : String, entry : String) -> (String, Json) {
  let base = strip_extension(entry)
  let manifest_path = "\{dir}/\{base}.json"
  let content = read_ext_file(manifest_path)
  if content.is_empty() {
    return ("Script tool: \{base}", Json::object({}))
  }
  let parsed : Json = @json.parse(content) catch {
    _ => return ("Script tool: \{base}", Json::object({}))
  }
  let description = match parsed {
    { "description": String(d), .. } => d
    _ => "Script tool: \{base}"
  }
  let parameters = match parsed {
    { "parameters": Object(_) as p, .. } => p
    _ => Json::object({})
  }
  (description, parameters)
}

///|
/// Derive a tool name from a filename.
/// "check-pr.sh" -> "check-pr", "my_tool.py" -> "my_tool"
pub fn derive_tool_name(filename : String) -> String {
  strip_extension(filename)
}

///|
/// Strip file extension from a filename.
fn strip_extension(filename : String) -> String {
  let mut last_dot = -1
  for i = 0; i < filename.length(); i = i + 1 {
    if filename[i] == '.'.to_int().to_uint16() {
      last_dot = i
    }
  }
  if last_dot > 0 {
    filename[:last_dot].to_string() catch {
      _ => filename
    }
  } else {
    filename
  }
}

///|
/// List directory entries via C FFI.
fn list_ext_dir(path : String) -> Array[String] {
  let path_bytes = @config.string_to_cstr(path)
  let len = cub_ext_list_dir(path_bytes, Bytes::new(0), 0)
  if len <= 0 {
    return []
  }
  let buf = Bytes::new(len)
  let actual = cub_ext_list_dir(path_bytes, buf, len)
  if actual <= 0 {
    return []
  }
  let text = @utf8.decode_lossy(buf[:actual])
  let entries : Array[String] = []
  for part in text.split("\n") {
    let s = part.to_string()
    if not(s.is_empty()) {
      entries.push(s)
    }
  }
  entries
}

///|
/// Read file content via C FFI.
fn read_ext_file(path : String) -> String {
  let path_bytes = @config.string_to_cstr(path)
  let len = cub_ext_read_file(path_bytes, Bytes::new(0), 0)
  if len <= 0 {
    return ""
  }
  let buf = Bytes::new(len)
  let actual = cub_ext_read_file(path_bytes, buf, len)
  if actual <= 0 {
    return ""
  }
  @utf8.decode_lossy(buf[:actual])
}

///|
/// FFI: list directory entries.
#borrow(path, buf)
extern "C" fn cub_ext_list_dir(
  path : Bytes,
  buf : Bytes,
  buf_size : Int,
) -> Int = "cub_ext_list_dir"

///|
/// FFI: read file content.
#borrow(path, buf)
extern "C" fn cub_ext_read_file(
  path : Bytes,
  buf : Bytes,
  buf_size : Int,
) -> Int = "cub_ext_read_file"
