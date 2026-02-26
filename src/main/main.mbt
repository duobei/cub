///|
/// CLI entry point for cub.
fn main {
  @async.run_async_main(async fn() {
    // Initialize environment snapshot before anything else
    @config.init_env()
    let args = @env.args()
    // Parse CLI flags and positional args
    let parsed = parse_cli_args(args)
    // Load settings
    let workspace = match parsed.workspace {
      Some(w) => w
      None => @env.current_dir().unwrap_or(".")
    }
    let settings = @config.load_settings(workspace_path=Some(workspace)).with_overrides(
      model=parsed.model,
      max_tokens=parsed.max_tokens,
      system_prompt=parsed.system_prompt,
      allowed_tools=parsed.allowed_tools,
      allowed_skills=parsed.allowed_skills,
    )
    // Parse command
    let command = parsed.command
    // Create runtime — CLI modes get tool confirmation, channels auto-approve
    let confirm_fn : (async (String, String) -> Bool)? = if command == "chat" {
      Some(@cli.confirm_tool)
    } else {
      None
    }
    let runtime = @app.AppRuntime::new(settings, workspace, confirm_fn~)
    match command {
      "chat" => {
        // Interactive CLI mode
        let session_id = parsed.session_id
        let cli = @cli.InteractiveCli::new(runtime, session_id~)
        cli.run()
      }
      "message" => {
        // Channel mode (Discord + Telegram)
        let manager = @channels.ChannelManager::new()
        // Discord
        let discord : @channels.DiscordChannel? = if settings.discord_enabled {
          match settings.discord_token {
            Some(t) => {
              let ch = @channels.DiscordChannel::new(
                t,
                allow_from=settings.discord_allow_from,
                allow_channels=settings.discord_allow_channels,
              )
              manager.add_discord(ch)
              Some(ch)
            }
            None => {
              @log.warn("cub", "discord enabled but no token set")
              None
            }
          }
        } else {
          None
        }
        // Telegram
        let telegram : @channels.TelegramChannel? = if settings.telegram_enabled {
          match settings.telegram_token {
            Some(t) => {
              let ch = @channels.TelegramChannel::new(
                t,
                allow_from=settings.telegram_allow_from,
                allow_chats=settings.telegram_allow_chats,
              )
              manager.add_telegram(ch)
              Some(ch)
            }
            None => {
              @log.warn("cub", "telegram enabled but no token set")
              None
            }
          }
        } else {
          None
        }
        if discord is None && telegram is None {
          println(
            "error: no channels enabled. Set CUB_DISCORD_ENABLED=true or CUB_TELEGRAM_ENABLED=true",
          )
          return
        }
        // Rate limiter: sliding window per session
        let rate_timestamps : Map[String, Array[Int64]] = {}
        let rate_limit = settings.rate_limit_per_minute
        // Per-session request queue: prevents interleaving when multiple
        // messages arrive for the same session while one is still processing.
        let session_busy : Map[String, Bool] = {}
        let session_queue : Map[String, Array[@channels.ChannelMessage]] = {}
        @log.info("cub", "starting message channels...")
        // Run health server and channel manager concurrently
        let health_port = settings.health_port
        let start_time = @async.now()
        @async.with_task_group(async fn(outer_group) {
          // Background: run health check HTTP server
          match health_port {
            Some(port) =>
              outer_group.spawn_bg(
                async fn() { run_health_server(port, start_time) },
                allow_failure=true,
              )
            None => ()
          }
          // Process a single message (extracted for queue drain reuse)
          async fn process_message(msg : @channels.ChannelMessage) -> Unit {
            // Check rate limit
            if rate_limit > 0 {
              let now = @async.now()
              let window_ms = 60000L
              let timestamps = match rate_timestamps.get(msg.session_id) {
                Some(ts) => ts
                None => {
                  let ts : Array[Int64] = []
                  rate_timestamps[msg.session_id] = ts
                  ts
                }
              }
              // Remove timestamps outside the window
              while timestamps.length() > 0 && now - timestamps[0] > window_ms {
                ignore(timestamps.remove(0))
              }
              if timestamps.length() >= rate_limit {
                @log.warn(
                  "rate",
                  "rate limited session \{msg.session_id} (\{timestamps.length()}/\{rate_limit} per minute)",
                )
                let channel_id = extract_channel_id(msg.session_id)
                if channel_id.length() > 0 {
                  if msg.session_id.has_prefix("telegram:") {
                    match telegram {
                      Some(tg) =>
                        tg.send_message(
                          channel_id, "Rate limited. Please wait a moment.",
                        )
                      None => ()
                    }
                  } else {
                    match discord {
                      Some(dc) =>
                        dc.send_message(
                          channel_id, "Rate limited. Please wait a moment.",
                        )
                      None => ()
                    }
                  }
                }
                return
              }
              timestamps.push(now)
            }
            let channel_id = extract_channel_id(msg.session_id)
            // Run typing indicator concurrently with message processing
            let typing_active : Ref[Bool] = { val: true }
            @async.with_task_group(async fn(group) {
              // Background: send typing indicators every 5s
              if channel_id.length() > 0 {
                group.spawn_bg(
                  async fn() {
                    while typing_active.val {
                      if msg.session_id.has_prefix("telegram:") {
                        match telegram {
                          Some(tg) => tg.send_typing(channel_id)
                          None => ()
                        }
                      } else {
                        match discord {
                          Some(dc) => dc.send_typing(channel_id)
                          None => ()
                        }
                      }
                      @async.sleep(5000)
                    }
                  },
                  allow_failure=true,
                )
              }
              // Send helper for this message
              let send_to_channel : async (String) -> Unit = async fn(text) {
                if text.is_empty() || channel_id.is_empty() {
                  return
                }
                if msg.session_id.has_prefix("telegram:") {
                  match telegram {
                    Some(tg) => tg.send_message(channel_id, text)
                    None => ()
                  }
                } else {
                  match discord {
                    Some(dc) => dc.send_message(channel_id, text)
                    None => ()
                  }
                }
              }
              // Foreground: process document attachments then handle input
              let prompt = process_documents(msg.prompt, msg.documents)
              let result = runtime.handle_input(
                msg.session_id,
                prompt,
                image_urls=msg.attachments,
              )
              typing_active.val = false
              // Send complete response at once
              let output_parts : Array[String] = []
              if result.immediate_output.length() > 0 {
                output_parts.push(result.immediate_output)
              }
              if result.assistant_output.length() > 0 {
                output_parts.push(result.assistant_output)
              }
              match result.error {
                Some(e) => output_parts.push("Error: \{e}")
                None => ()
              }
              if output_parts.length() > 0 {
                let response = output_parts.join("\n\n")
                send_to_channel(response)
              }
            })
          }
          // Queue-aware message dispatcher
          manager.run(async fn(msg) {
            let sid = msg.session_id
            // If this session is already processing, queue the message
            if session_busy.get(sid).unwrap_or(false) {
              let q = match session_queue.get(sid) {
                Some(q) => q
                None => {
                  let q : Array[@channels.ChannelMessage] = []
                  session_queue[sid] = q
                  q
                }
              }
              q.push(msg)
              @log.info(
                "queue",
                "queued message for busy session \{sid} (depth: \{q.length()})",
              )
              return
            }
            // Mark session as busy and process
            session_busy[sid] = true
            process_message(msg)
            // Drain queued messages for this session
            while true {
              let next = match session_queue.get(sid) {
                Some(q) => if q.length() > 0 { Some(q.remove(0)) } else { None }
                None => None
              }
              match next {
                Some(queued_msg) => process_message(queued_msg)
                None => break
              }
            }
            session_busy[sid] = false
          })
        }) // outer_group for health check
      }
      "run" => {
        // Single message mode
        if parsed.positional.is_empty() {
          println("usage: cub run <message>")
          return
        }
        let message = parsed.positional.join(" ")
        let result = runtime.handle_input("cli", message)
        match result.error {
          Some(e) => println("Error: \{e}")
          None => {
            let output = if result.assistant_output.length() > 0 {
              result.assistant_output
            } else {
              result.immediate_output
            }
            if output.length() > 0 {
              println(output)
            }
          }
        }
      }
      "serve" => {
        // MCP server mode — expose tools over JSON-RPC 2.0 stdio
        let session = runtime.get_session("mcp-server")
        let server = @mcp.McpServer::new(session.registry)
        server.run_stdio()
      }
      "version" => println("cub 0.1.0")
      _ => {
        println("cub - tape-first coding agent")
        println("")
        println("usage:")
        println("  cub [options]              interactive chat (default)")
        println("  cub chat [session_id]      interactive chat")
        println("  cub message                run channels (Discord/Telegram)")
        println("  cub run <msg>              run single message")
        println("  cub serve                  run MCP server on stdio")
        println("  cub version                show version")
        println("")
        println("options:")
        println("  --model <provider:model>   override model")
        println("  --workspace <path>         override workspace directory")
        println("  --max-tokens <n>           override max tokens")
        println("  --system-prompt <text>     override system prompt")
        println("  --tools <list>             filter tools (comma-separated)")
        println("  --skills <list>            filter skills (comma-separated)")
      }
    }
  })
}

///|
/// Parsed CLI arguments.
struct CliArgs {
  command : String // "chat", "message", "run", "version", "help"
  session_id : String // for chat command
  positional : Array[String] // remaining positional args (e.g. message for "run")
  model : String?
  workspace : String?
  max_tokens : Int?
  system_prompt : String?
  allowed_tools : Array[String]?
  allowed_skills : Array[String]?
}

///|
/// Parse CLI arguments, extracting flags and command.
fn parse_cli_args(args : Array[String]) -> CliArgs {
  let mut command = "chat"
  let mut session_id = "cli"
  let positional : Array[String] = []
  let mut model : String? = None
  let mut workspace : String? = None
  let mut max_tokens : Int? = None
  let mut system_prompt : String? = None
  let mut allowed_tools : Array[String]? = None
  let mut allowed_skills : Array[String]? = None
  let mut i = 1 // skip argv[0]
  let mut command_found = false
  while i < args.length() {
    let arg = args[i]
    if arg == "--model" && i + 1 < args.length() {
      i += 1
      model = Some(args[i])
    } else if arg == "--workspace" && i + 1 < args.length() {
      i += 1
      workspace = Some(args[i])
    } else if arg == "--max-tokens" && i + 1 < args.length() {
      i += 1
      max_tokens = Some(parse_int_or(args[i], 1024))
    } else if arg == "--system-prompt" && i + 1 < args.length() {
      i += 1
      system_prompt = Some(args[i])
    } else if arg == "--tools" && i + 1 < args.length() {
      i += 1
      allowed_tools = Some(split_comma(args[i]))
    } else if arg == "--skills" && i + 1 < args.length() {
      i += 1
      allowed_skills = Some(split_comma(args[i]))
    } else if arg == "--help" || arg == "-h" {
      command = "help"
      command_found = true
    } else if not(command_found) {
      command = arg
      command_found = true
      // For "chat", next positional is session_id
      if command == "chat" && i + 1 < args.length() {
        // Check if next arg is a flag
        let next = args[i + 1]
        if next.length() > 0 && next[0] != '-'.to_int().to_uint16() {
          i += 1
          session_id = next
        }
      }
    } else {
      positional.push(arg)
    }
    i += 1
  }
  {
    command,
    session_id,
    positional,
    model,
    workspace,
    max_tokens,
    system_prompt,
    allowed_tools,
    allowed_skills,
  }
}

///|
/// Split a comma-separated string into an array.
fn split_comma(s : String) -> Array[String] {
  let result : Array[String] = []
  for part in s.split(",") {
    let trimmed = part.to_string().trim().to_string()
    if trimmed.length() > 0 {
      result.push(trimmed)
    }
  }
  result
}

///|
/// Parse an integer string, returning default on failure.
fn parse_int_or(s : String, default_val : Int) -> Int {
  let mut result = 0
  let mut valid = false
  for i in 0..<s.length() {
    let ch = s[i].to_int()
    if ch >= 48 && ch <= 57 { // '0' to '9'
      result = result * 10 + (ch - 48)
      valid = true
    } else {
      return default_val
    }
  }
  if valid {
    result
  } else {
    default_val
  }
}

///|
/// Process document attachments: fetch text content and append to prompt.
async fn process_documents(
  prompt : String,
  documents : Array[@channels.Attachment],
) -> String {
  if documents.is_empty() {
    return prompt
  }
  let parts : Array[String] = [prompt]
  for doc in documents {
    let is_text = doc.content_type.has_prefix("text/") ||
      (
        doc.filename.length() > 4 &&
        (
          has_suffix(doc.filename, ".txt") ||
          has_suffix(doc.filename, ".md") ||
          has_suffix(doc.filename, ".csv") ||
          has_suffix(doc.filename, ".json") ||
          has_suffix(doc.filename, ".xml") ||
          has_suffix(doc.filename, ".yaml") ||
          has_suffix(doc.filename, ".yml") ||
          has_suffix(doc.filename, ".toml") ||
          has_suffix(doc.filename, ".ini") ||
          has_suffix(doc.filename, ".cfg") ||
          has_suffix(doc.filename, ".log") ||
          has_suffix(doc.filename, ".py") ||
          has_suffix(doc.filename, ".js") ||
          has_suffix(doc.filename, ".ts") ||
          has_suffix(doc.filename, ".rs") ||
          has_suffix(doc.filename, ".go") ||
          has_suffix(doc.filename, ".java") ||
          has_suffix(doc.filename, ".c") ||
          has_suffix(doc.filename, ".h") ||
          has_suffix(doc.filename, ".mbt")
        )
      )
    if is_text {
      // Fetch text content
      let headers : Map[String, String] = {}
      let (resp, data) = @http.get(doc.url, headers~) catch {
        _ => {
          parts.push("[Attachment: \{doc.filename} (fetch failed)]")
          continue
        }
      }
      if resp.code == 200 {
        let text = data.text() catch { _ => "" }
        if text.length() > 0 {
          let truncated = if text.length() > 10000 {
            let prefix = text[:10000].to_string() catch { _ => text }
            "\{prefix}\n[...truncated]"
          } else {
            text
          }
          parts.push(
            "--- File: \{doc.filename} ---\n\{truncated}\n--- End of \{doc.filename} ---",
          )
        }
      } else {
        parts.push("[Attachment: \{doc.filename} (HTTP \{resp.code})]")
      }
    } else if doc.content_type == "application/pdf" ||
      has_suffix(doc.filename, ".pdf") {
      // Extract text from PDF using pdftotext via curl pipeline
      let (exit_code, stdout_data, _stderr_data) = @process.collect_output(
        "bash",
        ["-c", "curl -sL \"$1\" | pdftotext - -", "bash", doc.url],
      ) catch {
        _ => {
          parts.push("[Attachment: \{doc.filename} (PDF extraction failed)]")
          continue
        }
      }
      if exit_code == 0 {
        let text = stdout_data.text() catch { _ => "" }
        if text.length() > 0 {
          let truncated = if text.length() > 20000 {
            let prefix = text[:20000].to_string() catch { _ => text }
            "\{prefix}\n[...truncated]"
          } else {
            text
          }
          parts.push(
            "--- File: \{doc.filename} ---\n\{truncated}\n--- End of \{doc.filename} ---",
          )
        } else {
          parts.push("[Attachment: \{doc.filename} (no text extracted)]")
        }
      } else {
        parts.push("[Attachment: \{doc.filename} (PDF extraction failed)]")
      }
    } else {
      parts.push("[Attachment: \{doc.filename}]")
    }
  }
  parts.join("\n\n")
}

///|
/// Check if string ends with a suffix.
fn has_suffix(s : String, suffix : String) -> Bool {
  if suffix.length() > s.length() {
    return false
  }
  let offset = s.length() - suffix.length()
  for i in 0..<suffix.length() {
    if s[offset + i] != suffix[i] {
      return false
    }
  }
  true
}

///|
/// Extract channel_id from session_id like "discord:123456".
fn extract_channel_id(session_id : String) -> String {
  let mut colon_pos = -1
  for i in 0..<session_id.length() {
    if session_id[i] == ':'.to_int().to_uint16() {
      colon_pos = i
      break
    }
  }
  if colon_pos < 0 {
    return session_id
  }
  session_id[colon_pos + 1:].to_string() catch {
    _ => session_id
  }
}

///|
/// Run an async HTTP health check server on the given port.
async fn run_health_server(port : Int, start_time : Int64) -> Unit {
  let addr_str = "0.0.0.0:\{port}"
  let addr = @socket.Addr::parse(addr_str) catch {
    _ => {
      @log.warn("health", "failed to parse address \{addr_str}")
      return
    }
  }
  let server = @http.Server::new(addr, reuse_addr=true) catch {
    _ => {
      @log.warn("health", "failed to start on port \{port}")
      return
    }
  }
  @log.info("health", "listening on port \{port}")
  server.run_forever(
    async fn(_req, _reader, conn) {
      let now = @async.now()
      let uptime = (now - start_time) / 1000L
      let body = "{\"status\":\"ok\",\"uptime\":\{uptime},\"sessions\":0}"
      let headers : Map[String, String] = {}
      headers["Content-Type"] = "application/json"
      headers["Content-Length"] = body.length().to_string()
      headers["Connection"] = "close"
      conn.send_response(200, "OK", extra_headers=headers)
      conn.write(body) catch {
        _ => ()
      }
      conn.flush() catch {
        _ => ()
      }
      conn.close()
    },
    allow_failure=true,
  )
}
