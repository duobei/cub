/// Internal command registration: tape tools, memory, skills, sessions, extensions.

///|
/// Register tape-related internal tools (help, tools, tape.info, etc.).
fn register_tape_tools(
  registry : @tools.ToolRegistry,
  tape : @tape.TapeService,
  workspace : String,
  home : String,
  allowed_skills? : Array[String] = [],
  llm? : @llm.LLMClient? = None,
  p2p_peers_fn? : (() -> Array[Json])? = None,
  p2p_skill_list_fn? : (async (String) -> Array[Json])? = None,
  p2p_pull_skill_fn? : (async (String, String) -> String?)? = None,
) -> Unit {
  // ,help
  registry.register("help", "Show available commands", handler=fn(_args) {
    let rows = registry.compact_rows()
    "Available commands:\n" + rows.map(fn(r) { "  ,\{r}" }).join("\n")
  })
  // ,tools
  registry.register("tools", "List available tools", handler=fn(_args) {
    let rows = registry.compact_rows()
    rows.join("\n")
  })
  // ,tool.describe
  let describe_registry = registry
  let td_props : Map[String, Json] = Map::new()
  td_props["name"] = @tools.string_prop("Tool name to describe")
  let td_params = @tools.make_params(td_props, ["name"])
  registry.register(
    "tool.describe",
    "Show tool details and parameter schema",
    parameters=td_params,
    handler=fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "tool.describe: missing name"
      }
      // Try exact match first, then model name
      let descriptors = describe_registry.descriptors()
      let mut found : @tools.ToolDescriptor? = None
      for d in descriptors {
        if d.name == name || @tools.to_model_name(d.name) == name {
          found = Some(d)
          break
        }
      }
      match found {
        None => "tool not found: \{name}"
        Some(d) => {
          let buf = StringBuilder::new()
          buf
          ..write_string("Tool: ")
          ..write_string(d.name)
          ..write_string("\nDescription: ")
          .write_string(d.short_description)
          if d.detail.length() > 0 {
            buf..write_string("\nDetail: ").write_string(d.detail)
          }
          buf
          ..write_string("\nSource: ")
          ..write_string(d.source)
          ..write_string("\nParameters:\n")
          .write_string(d.tool.parameters.stringify())
          buf.to_string()
        }
      }
    },
  )
  // ,tape.info
  registry.register("tape.info", "Show tape status", handler=async fn(_args) {
    let info = tape.info()
    let buf = StringBuilder::new()
    buf
    ..write_string("tape: ")
    ..write_string(info.name)
    ..write_string("\nentries: ")
    ..write_string(info.entries.to_string())
    ..write_string("\nanchors: ")
    ..write_string(info.anchors.to_string())
    .write_string("\nlast_anchor: ")
    match info.last_anchor {
      Some(a) => buf.write_string(a)
      None => buf.write_string("-")
    }
    buf
    ..write_string("\nentries_since_last_anchor: ")
    .write_string(info.entries_since_last_anchor.to_string())
    buf.to_string()
  })
  // ,handoff
  let props : Map[String, Json] = Map::new()
  props["name"] = @tools.string_prop("Handoff name (e.g. 'refactor/phase2')")
  props["summary"] = @tools.string_prop("Current task status — what was done")
  props["context"] = @tools.string_prop(
    "Key context to carry forward (files, decisions)",
  )
  props["next_steps"] = @tools.string_prop("What should happen next")
  props["task"] = @tools.string_prop("Current task description")
  let handoff_params = @tools.make_params(props, ["name"])
  let handoff_llm = llm
  registry.register(
    "handoff",
    "Create a stage transition — carry forward state, not history",
    parameters=handoff_params,
    handler=async fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => "handoff"
      }
      let state : Map[String, Json] = Map::new()
      match args {
        { "summary": String(s), .. } => state["summary"] = s.to_json()
        _ => ()
      }
      match args {
        { "context": String(c), .. } => state["context"] = c.to_json()
        _ => ()
      }
      match args {
        { "next_steps": String(ns), .. } => state["next_steps"] = ns.to_json()
        _ => ()
      }
      match args {
        { "task": String(t), .. } => state["task"] = t.to_json()
        _ => ()
      }
      // Auto-summarize via LLM when no state fields were provided
      let final_state = if state.is_empty() {
        match handoff_llm {
          Some(l) => {
            let messages = tape.tape().read_messages()
            let auto_state = l.summarize_for_handoff(messages) catch {
              _ => @llm.summarize_messages_for_handoff(messages)
            }
            auto_state
          }
          None => state
        }
      } else {
        state
      }
      ignore(tape.handoff(name, state=Some(final_state)))
      "handoff: \{name}"
    },
  )
  // ,anchors — detailed anchor info with summary, timestamp, entry count
  registry.register(
    "anchors",
    "List anchor points with summary, timestamp, and entry counts",
    handler=async fn(_args) {
      let details = tape.anchors_detailed()
      if details.is_empty() {
        return "no anchors"
      }
      let lines : Array[String] = []
      for d in details {
        let id = match d {
          { "id": Number(n, ..), .. } => n.to_int()
          _ => 0
        }
        let name = match d {
          { "name": String(n), .. } => n
          _ => "-"
        }
        let ts = match d {
          { "ts": Number(n, ..), .. } => n.to_int64()
          _ => 0L
        }
        let entries_after = match d {
          { "entries_after": Number(n, ..), .. } => n.to_int()
          _ => 0
        }
        let summary = match d {
          { "summary": String(s), .. } => s
          _ => ""
        }
        let task = match d {
          { "task": String(t), .. } => t
          _ => ""
        }
        let ts_str = if ts > 0L { @genome.format_iso8601(ts) } else { "-" }
        let buf = StringBuilder::new()
        buf
        ..write_string("#\{id} ")
        ..write_string(name)
        ..write_string(" (\{ts_str}, \{entries_after} entries after)")
        .write_string("")
        if summary.length() > 0 {
          buf..write_string("\n  summary: ").write_string(summary)
        }
        if task.length() > 0 {
          buf..write_string("\n  task: ").write_string(task)
        }
        lines.push(buf.to_string())
      }
      lines.join("\n")
    },
  )
  // ,tape.search (searches current tape with optional kind filter and pagination)
  let search_props : Map[String, Json] = Map::new()
  search_props["query"] = @tools.string_prop("Search query (substring match)")
  search_props["kind"] = @tools.string_prop(
    "Filter by entry kind: message, tool_call, tool_result, event, anchor (optional)",
  )
  search_props["offset"] = @tools.string_prop(
    "Skip first N matches for pagination (optional, default 0)",
  )
  search_props["limit"] = @tools.string_prop(
    "Max results to return (optional, default 20)",
  )
  search_props["all_tapes"] = @tools.string_prop(
    "Search all tapes in workspace: true/false (optional, default false)",
  )
  let search_params = @tools.make_params(search_props, ["query"])
  registry.register(
    "tape.search",
    "Search tape entries by substring — supports kind filter and pagination",
    parameters=search_params,
    handler=async fn(args) {
      let query = match args {
        { "query": String(q), .. } => q
        _ => return "tape.search: missing query"
      }
      let kind = match args {
        { "kind": String(k), .. } => k
        _ => ""
      }
      let offset = match args {
        { "offset": String(s), .. } => {
          let parsed : Json = @json.parse(s) catch { _ => Json::null() }
          match parsed {
            Number(n, ..) => n.to_int()
            _ => 0
          }
        }
        { "offset": Number(n, ..), .. } => n.to_int()
        _ => 0
      }
      let limit = match args {
        { "limit": String(s), .. } => {
          let parsed : Json = @json.parse(s) catch { _ => Json::null() }
          match parsed {
            Number(n, ..) => n.to_int()
            _ => 20
          }
        }
        { "limit": Number(n, ..), .. } => n.to_int()
        _ => 20
      }
      let all_tapes = match args {
        { "all_tapes": String(s), .. } => s == "true"
        _ => false
      }
      if all_tapes {
        let results = tape.search_all(query, limit~)
        if results.is_empty() {
          return "no results"
        }
        return results
          .map(fn(pair) {
            "[\{pair.0}] #\{pair.1.id} [\{pair.1.kind}] \{pair.1.payload.stringify()}"
          })
          .join("\n")
      }
      let results = tape.search(query, limit~, kind~, offset~)
      if results.is_empty() {
        return "no results"
      }
      results
      .map(fn(e) { "#\{e.id} [\{e.kind}] \{e.payload.stringify()}" })
      .join("\n")
    },
  )
  // ,tape.read_range — batch read entries by ID range
  let rr_props : Map[String, Json] = Map::new()
  rr_props["start_id"] = @tools.string_prop("Start entry ID (inclusive)")
  rr_props["end_id"] = @tools.string_prop("End entry ID (inclusive)")
  let rr_params = @tools.make_params(rr_props, ["start_id", "end_id"])
  registry.register(
    "tape.read_range",
    "Read tape entries by ID range — use for small-batch programmatic queries",
    parameters=rr_params,
    handler=async fn(args) {
      let start_id = match args {
        { "start_id": String(s), .. } => {
          let parsed : Json = @json.parse(s) catch {
            _ => return "invalid start_id"
          }
          match parsed {
            Number(n, ..) => n.to_int()
            _ => return "invalid start_id"
          }
        }
        { "start_id": Number(n, ..), .. } => n.to_int()
        _ => return "tape.read_range: missing start_id"
      }
      let end_id = match args {
        { "end_id": String(s), .. } => {
          let parsed : Json = @json.parse(s) catch {
            _ => return "invalid end_id"
          }
          match parsed {
            Number(n, ..) => n.to_int()
            _ => return "invalid end_id"
          }
        }
        { "end_id": Number(n, ..), .. } => n.to_int()
        _ => return "tape.read_range: missing end_id"
      }
      let entries = tape.read_range(start_id, end_id)
      if entries.is_empty() {
        return "no entries in range \{start_id}-\{end_id}"
      }
      entries
      .map(fn(e) { "#\{e.id} [\{e.kind}] \{e.payload.stringify()}" })
      .join("\n")
    },
  )
  // ,tape.since_anchor — read entries after a named anchor
  let sa_props : Map[String, Json] = Map::new()
  sa_props["name"] = @tools.string_prop("Anchor name to read entries after")
  let sa_params = @tools.make_params(sa_props, ["name"])
  registry.register(
    "tape.since_anchor",
    "Read entries after a specific anchor — for examining a tape section",
    parameters=sa_params,
    handler=async fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "tape.since_anchor: missing name"
      }
      let entries = tape.entries_since_anchor(name)
      if entries.is_empty() {
        return "no entries after anchor '\{name}' (anchor not found or no entries after it)"
      }
      let header = "entries after anchor '\{name}': \{entries.length()}\n"
      header +
      entries
      .map(fn(e) { "#\{e.id} [\{e.kind}] \{e.payload.stringify()}" })
      .join("\n")
    },
  )
  // ,tape.reset
  registry.register("tape.reset", "Reset the tape", handler=async fn(args) {
    let archive = match args {
      { "archive": String(a), .. } => a == "true"
      _ => false
    }
    tape.reset(archive~)
  })
  // ,tape.export
  registry.register("tape.export", "Export tape to markdown", handler=async fn(
    _args,
  ) {
    let entries = tape.read_entries()
    export_tape_to_markdown(entries)
  })
  // ,skills.list
  let ws_for_skills = workspace
  let skill_filter = allowed_skills
  registry.register("skills.list", "List available skills", handler=async fn(
    _args,
  ) {
    let all_skills = @skills.discover_skills(ws_for_skills)
    let skills = filter_skills(all_skills, skill_filter)
    if skills.is_empty() {
      return "no skills found"
    }
    let lines = skills.map(fn(s) {
      let desc = if s.description.length() > 0 {
        " — \{s.description}"
      } else {
        ""
      }
      "  \{s.name}\{desc} [\{s.source}]"
    })
    "Available skills:\n" + lines.join("\n")
  })
  // ,skills.describe
  let ws_for_describe = workspace
  let describe_props : Map[String, Json] = Map::new()
  describe_props["name"] = @tools.string_prop("Skill name")
  let describe_params = @tools.make_params(describe_props, ["name"])
  registry.register(
    "skills.describe",
    "Show skill details",
    parameters=describe_params,
    handler=async fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "skills.describe: missing name"
      }
      match @skills.load_skill_body(name, ws_for_describe) {
        Some(body) => "skill: \{name}\n\n\{body}"
        None => "skill not found: \{name}"
      }
    },
  )
  // ,sessions
  let sessions_home = home
  registry.register("sessions", "List tape sessions in this workspace", handler=async fn(
    _args,
  ) {
    let tape_dir = "\{sessions_home}/tapes"
    let files = list_dir_sync(tape_dir)
    let sessions : Array[String] = []
    for file in files {
      if file.length() > 6 {
        // Check for .jsonl suffix
        let has_suffix = try
          file[file.length() - 6:].to_string() == ".jsonl"
        catch {
          _ => false
        }
        if has_suffix {
          // Extract tape name from filename: {hash}__{name}.jsonl
          let name = decode_tape_filename(file)
          sessions.push(name)
        }
      }
    }
    if sessions.is_empty() {
      return "no sessions found"
    }
    "Sessions:\n" +
    sessions.map(fn(s) { "  \{s}" }).join("\n") +
    "\n\nUse `,session <name>` to switch."
  })
  // ,skill.create
  let skill_ws = workspace
  let skill_home = home
  let sc_props : Map[String, Json] = Map::new()
  sc_props["name"] = @tools.string_prop(
    "Skill name (lowercase, hyphens, e.g. 'code-review')",
  )
  sc_props["description"] = @tools.string_prop(
    "Short description for skill discovery",
  )
  sc_props["body"] = @tools.string_prop(
    "Full SKILL.md body content (instructions for the agent)",
  )
  sc_props["scope"] = @tools.string_prop(
    "Where to create: 'workspace' (default) or 'global'",
  )
  let sc_params = @tools.make_params(sc_props, ["name", "description", "body"])
  registry.register(
    "skill.create",
    "Create a new reusable skill (writes SKILL.md)",
    parameters=sc_params,
    handler=async fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "skill.create: missing 'name'"
      }
      match @tools.sanitize_name(name) {
        None => return "skill.create: invalid name (must not contain / or ..)"
        Some(_) => ()
      }
      let description = match args {
        { "description": String(d), .. } => d
        _ => return "skill.create: missing 'description'"
      }
      let body = match args {
        { "body": String(b), .. } => b
        _ => return "skill.create: missing 'body'"
      }
      let scope = match args {
        { "scope": String(s), .. } => s
        _ => "workspace"
      }
      let base_dir = if scope == "global" {
        "\{skill_home}/skills"
      } else {
        "\{skill_ws}/.agent/skills"
      }
      let skill_dir = "\{base_dir}/\{name}"
      let skill_path = "\{skill_dir}/SKILL.md"
      let content = "---\nname: \{name}\ndescription: \{description}\n---\n\n\{body}\n"
      if write_file_sync(skill_path, content) {
        "created skill: \{name} at \{skill_path}"
      } else {
        "skill.create: failed to write \{skill_path}"
      }
    },
  )
  // ,tool.create
  let tc_ws = workspace
  let tc_home = home
  let tc_registry = registry
  let tc_props : Map[String, Json] = Map::new()
  tc_props["name"] = @tools.string_prop(
    "Tool name (lowercase, hyphens, e.g. 'check-pr')",
  )
  tc_props["type"] = @tools.string_prop(
    "Tool type: 'script' (bash/python executable) or 'wasm' (MoonBit plugin)",
  )
  tc_props["description"] = @tools.string_prop("Short description of the tool")
  tc_props["code"] = @tools.string_prop(
    "Source code. For script: bash/python. For wasm: MoonBit code — do NOT include 'import' or 'options' (auto-generated). Start directly with 'fn main { let args = @env.args(); let input = if args.length() > 1 { args[1] } else { \"{}\" }; let parsed = @json.parse(input) catch { _ => ... }; /* logic */; println(result_json) }'. Available: @json.parse, @env.args, String methods, Int/Double math.",
  )
  tc_props["parameters"] = @tools.string_prop(
    "Optional JSON Schema for tool parameters (as JSON string)",
  )
  tc_props["scope"] = @tools.string_prop(
    "Where to create: 'workspace' (default) or 'global'",
  )
  let tc_params = @tools.make_params(tc_props, [
    "name", "type", "description", "code",
  ])
  registry.register(
    "tool.create",
    "PREFERRED way to create extension tools. Handles all scaffolding, build, and hot-registration in one step. Do NOT manually create files — always use this tool instead.",
    parameters=tc_params,
    requires_confirmation=true,
    handler=async fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "tool.create: missing 'name'"
      }
      match @tools.sanitize_name(name) {
        None => return "tool.create: invalid name (must not contain / or ..)"
        Some(_) => ()
      }
      let type_str = match args {
        { "type": String(t), .. } => t
        _ => return "tool.create: missing 'type' (script or wasm)"
      }
      let description = match args {
        { "description": String(d), .. } => d
        _ => return "tool.create: missing 'description'"
      }
      let code = match args {
        { "code": String(c), .. } => c
        _ => return "tool.create: missing 'code'"
      }
      let scope = match args {
        { "scope": String(s), .. } => s
        _ => "workspace"
      }
      let params_json : Json = match args {
        { "parameters": String(p), .. } => {
          let parsed : Json = @json.parse(p) catch {
            _ => return "tool.create: invalid parameters JSON"
          }
          parsed
        }
        _ => Json::object({})
      }
      let base_dir = if scope == "global" { tc_home } else { "\{tc_ws}/.agent" }
      match type_str {
        "script" => {
          let tool_dir = "\{base_dir}/tools"
          ignore(mkdir_p_sync(tool_dir))
          let script_path = "\{tool_dir}/\{name}.sh"
          if not(write_file_sync(script_path, code)) {
            return "tool.create: failed to write script"
          }
          // Make executable
          if not(chmod_x(script_path)) {
            return "tool.create: failed to chmod +x"
          }
          // Write manifest
          let manifest : Map[String, Json] = {}
          manifest["name"] = name.to_json()
          manifest["description"] = description.to_json()
          manifest["parameters"] = params_json
          let manifest_path = "\{tool_dir}/\{name}.json"
          ignore(
            write_file_sync(manifest_path, Json::object(manifest).stringify()),
          )
          // Hot-register into registry
          let tool_name = "ext.\{name}"
          let ext_path = script_path
          let script_reg = tc_registry
          let script_schema = params_json
          tc_registry.register(
            tool_name,
            description,
            parameters=params_json,
            source="extension",
            handler=async fn(call_args) {
              run_extension(
                @ext.ExtType::Script,
                ext_path,
                call_args,
                registry=script_reg,
                schema=script_schema,
              )
            },
          )
          "created script tool: \{tool_name} at \{script_path}"
        }
        "wasm" => {
          let plugin_dir = "\{base_dir}/plugins/\{name}"
          let src_dir = "\{plugin_dir}/cmd/main"
          ignore(mkdir_p_sync(src_dir))
          // Write moon.mod.json
          let mod_json : Map[String, Json] = {}
          mod_json["name"] = name.to_json()
          mod_json["version"] = "0.1.0".to_json()
          ignore(
            write_file_sync(
              "\{plugin_dir}/moon.mod.json",
              Json::object(mod_json).stringify(),
            ),
          )
          // Write moon.pkg with is-main and imports (moon DSL format, not JSON)
          let pkg_content =
            #|import {
            #|  "moonbitlang/core/json",
            #|  "moonbitlang/core/env",
            #|}
            #|
            #|options(
            #|  "is-main": true,
            #|)
          ignore(write_file_sync("\{src_dir}/moon.pkg", pkg_content))
          // Write main.mbt — strip import/options blocks (moon.pkg handles those)
          let clean_code = strip_pkg_declarations(code)
          if not(write_file_sync("\{src_dir}/main.mbt", clean_code)) {
            return "tool.create: failed to write source"
          }
          // Write plugin.json manifest
          let manifest : Map[String, Json] = {}
          manifest["name"] = name.to_json()
          manifest["description"] = description.to_json()
          manifest["parameters"] = params_json
          ignore(
            write_file_sync(
              "\{plugin_dir}/plugin.json",
              Json::object(manifest).stringify(),
            ),
          )
          // Build the WASM plugin
          let (exit_code, _stdout_data, stderr_data) = @async.with_timeout(
            180_000,
            async fn() {
              // Use absolute path — systemd env lacks ~/.moon/bin in PATH
              let user_home = @config.getenv("HOME").unwrap_or("/home/ubuntu")
              let moon_bin = "\{user_home}/.moon/bin/moon"
              @platform.collect_output(
                moon_bin,
                ["build", "--target", "wasm"],
                cwd=plugin_dir,
              )
            },
          ) catch {
            _ => return "tool.create: build timeout (180s)"
          }
          if exit_code != 0 {
            let stderr = stderr_data.text() catch { _ => "" }
            return "tool.create: build failed:\n\{stderr}"
          }
          // Find the built wasm file
          let wasm_path = @ext.find_wasm_in_plugin(plugin_dir)
          if wasm_path.is_empty() {
            return "tool.create: build succeeded but .wasm not found"
          }
          // Hot-register
          let tool_name = "ext.\{name}"
          let ext_wasm = wasm_path
          let wasm_reg = tc_registry
          let wasm_schema = params_json
          tc_registry.register(
            tool_name,
            description,
            parameters=params_json,
            source="extension",
            handler=async fn(call_args) {
              run_extension(
                @ext.ExtType::Wasm,
                ext_wasm,
                call_args,
                registry=wasm_reg,
                schema=wasm_schema,
              )
            },
          )
          "created WASM tool: \{tool_name} (built at \{wasm_path})"
        }
        _ => "tool.create: type must be 'script' or 'wasm', got '\{type_str}'"
      }
    },
  )
  // ,ext.list
  let el_home = home
  let el_ws = workspace
  registry.register(
    "ext.list",
    "List installed extension tools (script + WASM)",
    handler=async fn(_args) {
      let extensions = @ext.discover_extensions(el_home, el_ws)
      if extensions.is_empty() {
        return "no extensions installed"
      }
      let lines = extensions.map(fn(e) {
        let type_str = match e.ext_type {
          @ext.ExtType::Script => "script"
          @ext.ExtType::Wasm => "wasm"
        }
        "  ext.\{e.name}  [\{type_str}]  \{e.description}  (\{e.scope})"
      })
      "Extensions:\n" + lines.join("\n")
    },
  )
  // ,ext.remove
  let er_home = home
  let er_ws = workspace
  let er_registry = registry
  let er_props : Map[String, Json] = Map::new()
  er_props["name"] = @tools.string_prop(
    "Extension name to remove (without ext. prefix)",
  )
  er_props["scope"] = @tools.string_prop(
    "Scope to remove from: 'workspace' (default) or 'global'",
  )
  let er_params = @tools.make_params(er_props, ["name"])
  registry.register(
    "ext.remove",
    "Remove an installed extension tool",
    parameters=er_params,
    requires_confirmation=true,
    handler=async fn(args) {
      let name = match args {
        { "name": String(n), .. } => n
        _ => return "ext.remove: missing 'name'"
      }
      match @tools.sanitize_name(name) {
        None => return "ext.remove: invalid name"
        Some(_) => ()
      }
      let scope = match args {
        { "scope": String(s), .. } => s
        _ => "workspace"
      }
      let base_dir = if scope == "global" { er_home } else { "\{er_ws}/.agent" }
      // Try removing script tool
      let script_path = "\{base_dir}/tools/\{name}.sh"
      let manifest_path = "\{base_dir}/tools/\{name}.json"
      let mut removed = false
      if remove_path_sync(script_path) {
        removed = true
        ignore(remove_path_sync(manifest_path))
      }
      // Try removing WASM plugin directory
      let plugin_dir = "\{base_dir}/plugins/\{name}"
      if remove_path_sync(plugin_dir) {
        removed = true
      }
      if removed {
        // Unregister from registry
        er_registry.unregister("ext.\{name}")
        "removed extension: \{name} (\{scope})"
      } else {
        "ext.remove: extension '\{name}' not found in \{scope} scope"
      }
    },
  )
  // ,agents.update — writes to genome/identity.md + AGENTS.md (compat)
  let agents_ws = workspace
  let agents_home = home
  let au_props : Map[String, Json] = Map::new()
  au_props["content"] = @tools.string_prop(
    "Full new content for identity (replaces existing)",
  )
  au_props["append"] = @tools.string_prop(
    "Content to append to identity (alternative to full replace)",
  )
  let au_params = @tools.make_params(au_props, [])
  registry.register(
    "agents.update",
    "Update agent identity to evolve behavior",
    parameters=au_params,
    handler=async fn(args) {
      let legacy_path = "\{agents_ws}/AGENTS.md"
      let genome_path = "\{agents_home}/genome/identity.md"
      match args {
        { "content": String(c), .. } => {
          // Safety: max 10KB
          if c.length() > 10240 {
            return "agents.update: content too large (max 10KB)"
          }
          ignore(write_file_sync(genome_path, c))
          ignore(write_file_sync(legacy_path, c))
          "updated identity (genome/identity.md + AGENTS.md)"
        }
        { "append": String(a), .. } => {
          if a.length() > 10240 {
            return "agents.update: content too large (max 10KB)"
          }
          // Read from genome path first, fallback to legacy
          let existing = {
            let g = read_file_sync(genome_path)
            if g.is_empty() {
              read_file_sync(legacy_path)
            } else {
              g
            }
          }
          let new_content = if existing.is_empty() {
            a
          } else {
            "\{existing}\n\n\{a}"
          }
          if new_content.length() > 10240 {
            return "agents.update: total content would exceed 10KB"
          }
          ignore(write_file_sync(genome_path, new_content))
          ignore(write_file_sync(legacy_path, new_content))
          "appended to identity (genome/identity.md + AGENTS.md)"
        }
        _ => "agents.update: provide 'content' (full replace) or 'append'"
      }
    },
  )
  // ,cost.balance — show token usage
  let cost_home = home
  registry.register(
    "cost.balance",
    "Show cumulative token usage and cost tracking",
    handler=async fn(_args) { @genome.format_balance(cost_home) },
  )
  // ,schedules — alias for schedule.list
  let sched_ws = workspace
  registry.register(
    "schedules",
    "List scheduled tasks (alias for schedule.list)",
    handler=async fn(_args) {
      let sched_home = @config.getenv("HOME").unwrap_or("/tmp")
      let path = "\{sched_home}/.cub/schedules.json"
      let content = read_file_sync(path)
      if content.trim().to_string().is_empty() {
        return "no scheduled tasks"
      }
      let parsed : Json = @json.parse(content) catch {
        _ => return "no scheduled tasks"
      }
      match parsed {
        Array(items) => {
          if items.is_empty() {
            return "no scheduled tasks"
          }
          let lines : Array[String] = []
          for s in items {
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
            lines.push("  \{id}  [\{trigger}]  \{msg}")
          }
          "Scheduled tasks:\n" + lines.join("\n")
        }
        _ => "no scheduled tasks"
      }
    },
  )
  ignore(sched_ws)
  // ,evolution.stats
  let evo_home = home
  registry.register(
    "evolution.stats",
    "Show self-evolution metrics: learnings, skill stats, crystallized skills",
    handler=async fn(_args) {
      let learnings = read_learnings(evo_home)
      let skill_stats = read_skill_stats(evo_home)
      let lines : Array[String] = ["# Evolution Stats", ""]
      // --- Learnings summary ---
      let total = learnings.length()
      let mut anti_patterns = 0
      let mut heuristics = 0
      let mut preferences = 0
      let mut active = 0 // confidence >= 0.3
      let mut max_reinforced = 0
      for entry in learnings {
        let type_ = match entry {
          { "type": String(t), .. } => t
          _ => ""
        }
        match type_ {
          "anti_pattern" => anti_patterns += 1
          "heuristic" => heuristics += 1
          "preference" => preferences += 1
          _ => ()
        }
        let confidence = match entry {
          { "confidence": Number(c, ..), .. } => c
          _ => 0.0
        }
        if confidence >= 0.3 {
          active += 1
        }
        let reinforced = match entry {
          { "reinforced": Number(r, ..), .. } => r.to_int()
          _ => 0
        }
        if reinforced > max_reinforced {
          max_reinforced = reinforced
        }
      }
      lines.push("## Learnings")
      lines.push("  total: \{total}")
      lines.push("  active (confidence >= 0.3): \{active}")
      lines.push("  anti_patterns: \{anti_patterns}")
      lines.push("  heuristics: \{heuristics}")
      lines.push("  preferences: \{preferences}")
      lines.push("  max reinforced: \{max_reinforced}")
      lines.push("")
      // --- Skill stats ---
      if not(skill_stats.is_empty()) {
        lines.push("## Skill Stats")
        for name, value in skill_stats {
          let uses = match value {
            { "uses": Number(n, ..), .. } => n.to_int()
            _ => 0
          }
          let successes = match value {
            { "successes": Number(n, ..), .. } => n.to_int()
            _ => 0
          }
          let failures = match value {
            { "failures": Number(n, ..), .. } => n.to_int()
            _ => 0
          }
          let total_steps = match value {
            { "total_steps": Number(n, ..), .. } => n.to_int()
            _ => 0
          }
          let avg_steps = if uses > 0 { total_steps / uses } else { 0 }
          lines.push(
            "  \{name}: \{uses} uses, \{successes} ok, \{failures} fail, avg \{avg_steps} steps",
          )
        }
        lines.push("")
      }
      // --- Active learnings detail ---
      if active > 0 {
        lines.push("## Active Learnings")
        let items : Array[(Double, String, String, Int)] = []
        for entry in learnings {
          let confidence = match entry {
            { "confidence": Number(c, ..), .. } => c
            _ => 0.0
          }
          if confidence < 0.3 {
            continue
          }
          let type_ = match entry {
            { "type": String(t), .. } => t
            _ => "unknown"
          }
          let content = match entry {
            { "content": String(c), .. } => c
            _ => continue
          }
          let reinforced = match entry {
            { "reinforced": Number(r, ..), .. } => r.to_int()
            _ => 0
          }
          items.push((confidence, type_, content, reinforced))
        }
        items.sort_by(fn(a, b) { b.0.compare(a.0) })
        for item in items {
          let tag = match item.1 {
            "anti_pattern" => "[avoid]"
            "heuristic" => "[effective]"
            "preference" => "[pattern]"
            _ => "[note]"
          }
          let conf_pct = (item.0 * 100.0).to_int()
          lines.push("  \{tag} \{item.2} (conf:\{conf_pct}% x\{item.3})")
        }
      }
      ignore(total)
      lines.join("\n")
    },
  )
  // ,peer.list — list connected P2P peers
  match p2p_peers_fn {
    Some(list_fn) =>
      registry.register("peer.list", "List connected P2P peers", handler=fn(
        _args,
      ) {
        let peers = list_fn()
        if peers.is_empty() {
          "No peers connected."
        } else {
          let lines = peers.map(fn(p) {
            let id = match p {
              { "id": String(id), .. } => id
              _ => "unknown"
            }
            let addr = match p {
              { "addr": String(a), .. } => a
              _ => ""
            }
            let gen = match p {
              { "generation": Number(g, ..), .. } => g.to_int().to_string()
              _ => "?"
            }
            "- \{id} (gen \{gen}) @ \{addr}"
          })
          "\{peers.length()} peer(s) connected:\n" + lines.join("\n")
        }
      })
    None => ()
  }
  // ,peer.skills — request skill list from a connected peer
  match p2p_skill_list_fn {
    Some(list_fn) => {
      let ps_props : Map[String, Json] = Map::new()
      ps_props["peer_id"] = @tools.string_prop("ID of the peer to query")
      let ps_params = @tools.make_params(ps_props, ["peer_id"])
      registry.register(
        "peer.skills",
        "Request skill list from a connected P2P peer",
        parameters=ps_params,
        handler=async fn(args) {
          let peer_id = match args {
            { "peer_id": String(id), .. } => id
            _ => return "peer.skills: missing peer_id"
          }
          let skills = list_fn(peer_id)
          if skills.is_empty() {
            return "No skills found on peer \{peer_id} (or peer not connected)."
          }
          let lines = skills.map(fn(s) {
            let name = match s {
              { "name": String(n), .. } => n
              _ => "unknown"
            }
            let desc = match s {
              { "description": String(d), .. } => d
              _ => ""
            }
            let source = match s {
              { "source": String(src), .. } => src
              _ => ""
            }
            if desc.length() > 0 {
              "  \{name} — \{desc} [\{source}]"
            } else {
              "  \{name} [\{source}]"
            }
          })
          "Skills on peer \{peer_id}:\n" + lines.join("\n")
        },
      )
    }
    None => ()
  }
  // ,peer.pull_skill — fetch and save a skill from a peer
  match p2p_pull_skill_fn {
    Some(pull_fn) => {
      let pp_home = home
      let pp_props : Map[String, Json] = Map::new()
      pp_props["peer_id"] = @tools.string_prop("ID of the peer to pull from")
      pp_props["name"] = @tools.string_prop("Skill name to pull")
      let pp_params = @tools.make_params(pp_props, ["peer_id", "name"])
      registry.register(
        "peer.pull_skill",
        "Fetch a skill from a P2P peer and save it locally",
        parameters=pp_params,
        handler=async fn(args) {
          let peer_id = match args {
            { "peer_id": String(id), .. } => id
            _ => return "peer.pull_skill: missing peer_id"
          }
          let name = match args {
            { "name": String(n), .. } => n
            _ => return "peer.pull_skill: missing name"
          }
          match @tools.sanitize_name(name) {
            None =>
              return "peer.pull_skill: invalid skill name (must not contain / or ..)"
            Some(_) => ()
          }
          let body = pull_fn(peer_id, name)
          match body {
            None =>
              "peer.pull_skill: skill '\{name}' not found on peer \{peer_id}"
            Some(content) => {
              let skill_dir = "\{pp_home}/genome/skills/\{name}"
              let skill_path = "\{skill_dir}/SKILL.md"
              if write_file_sync(skill_path, content) {
                "Pulled skill '\{name}' from peer \{peer_id} → \{skill_path}"
              } else {
                "peer.pull_skill: failed to write \{skill_path}"
              }
            }
          }
        },
      )
    }
    None => ()
  }
  // ,quit
  registry.register("quit", "Exit the session", handler=fn(_args) { "exit" })
}

///|
/// Strip package-level declarations (import/options blocks) from MoonBit code.
/// These belong in moon.pkg, not in .mbt files.
fn strip_pkg_declarations(code : String) -> String {
  let lines : Array[String] = []
  let mut skip = false
  let mut brace_depth = 0
  for part in code.split("\n") {
    let line = part.to_string()
    let trimmed = line.trim().to_string()
    if not(skip) &&
      (
        trimmed.has_prefix("import ") ||
        trimmed == "import" ||
        trimmed.has_prefix("options(") ||
        trimmed.has_prefix("options (")
      ) {
      skip = true
      brace_depth = 0
    }
    if skip {
      for i in 0..<trimmed.length() {
        let ch = trimmed[i]
        if ch == '{'.to_int().to_uint16() || ch == '('.to_int().to_uint16() {
          brace_depth += 1
        } else if ch == '}'.to_int().to_uint16() ||
          ch == ')'.to_int().to_uint16() {
          brace_depth -= 1
          if brace_depth <= 0 {
            skip = false
          }
        }
      }
      continue
    }
    if not(trimmed.is_empty()) || lines.length() > 0 {
      lines.push(line)
    }
  }
  // Trim leading empty lines
  while lines.length() > 0 && lines[0].trim().to_string().is_empty() {
    ignore(lines.remove(0))
  }
  lines.join("\n")
}
