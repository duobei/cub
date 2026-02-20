/// CLI entry point for cub.

fn main {
  @async.run_async_main(
    async fn() {
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
      )
      // Create runtime
      let runtime = @app.AppRuntime::new(settings, workspace)
      // Parse command
      let command = parsed.command
      match command {
        "chat" => {
          // Interactive CLI mode
          let session_id = parsed.session_id
          let cli = @cli.InteractiveCli::new(runtime, session_id~)
          cli.run()
        }
        "message" => {
          // Channel mode (Discord)
          if not(settings.discord_enabled) {
            println("error: discord not enabled. Set CUB_DISCORD_ENABLED=true")
            return
          }
          if settings.discord_token is None {
            println("error: missing discord token. Set CUB_DISCORD_TOKEN")
            return
          }
          let token = match settings.discord_token {
            Some(t) => t
            None => ""
          }
          let discord = @channels.DiscordChannel::new(
            token,
            allow_from=settings.discord_allow_from,
            allow_channels=settings.discord_allow_channels,
          )
          let manager = @channels.ChannelManager::new()
          manager.add_discord(discord)
          println("[cub] starting message channels...")
          manager.run(
            async fn(msg) {
              let result = runtime.handle_input(msg.session_id, msg.prompt)
              // Send response back to Discord
              let output_parts : Array[String] = []
              if result.immediate_output.length() > 0 {
                output_parts.push(result.immediate_output)
              }
              if result.assistant_output.length() > 0 {
                output_parts.push(result.assistant_output)
              }
              match result.error {
                Some(e) => output_parts.push("Error: " + e)
                None => ()
              }
              if output_parts.length() > 0 {
                let response = output_parts.join("\n\n")
                // Extract channel_id from session_id (format: "discord:{channel_id}")
                let channel_id = extract_channel_id(msg.session_id)
                if channel_id.length() > 0 {
                  discord.send_message(channel_id, response)
                }
              }
            },
          )
        }
        "run" => {
          // Single message mode
          if parsed.positional.length() == 0 {
            println("usage: cub run <message>")
            return
          }
          let message = parsed.positional.join(" ")
          let result = runtime.handle_input("cli", message)
          match result.error {
            Some(e) => println("Error: " + e)
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
        "version" => println("cub 0.1.0")
        _ => {
          println("cub - tape-first coding agent")
          println("")
          println("usage:")
          println("  cub [options]              interactive chat (default)")
          println("  cub chat [session_id]      interactive chat")
          println("  cub message                run Discord channel")
          println("  cub run <msg>              run single message")
          println("  cub version                show version")
          println("")
          println("options:")
          println("  --model <provider:model>   override model")
          println("  --workspace <path>         override workspace directory")
          println("  --max-tokens <n>           override max tokens")
          println("  --system-prompt <text>     override system prompt")
        }
      }
    },
  )
}

/// Parsed CLI arguments.
struct CliArgs {
  command : String        // "chat", "message", "run", "version", "help"
  session_id : String     // for chat command
  positional : Array[String]  // remaining positional args (e.g. message for "run")
  model : String?
  workspace : String?
  max_tokens : Int?
  system_prompt : String?
}

/// Parse CLI arguments, extracting flags and command.
fn parse_cli_args(args : Array[String]) -> CliArgs {
  let mut command = "chat"
  let mut session_id = "cli"
  let positional : Array[String] = []
  let mut model : String? = None
  let mut workspace : String? = None
  let mut max_tokens : Int? = None
  let mut system_prompt : String? = None
  let mut i = 1  // skip argv[0]
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
  { command, session_id, positional, model, workspace, max_tokens, system_prompt }
}

/// Parse an integer string, returning default on failure.
fn parse_int_or(s : String, default_val : Int) -> Int {
  let mut result = 0
  let mut valid = false
  for i = 0; i < s.length(); i = i + 1 {
    let ch = s[i].to_int()
    if ch >= 48 && ch <= 57 {  // '0' to '9'
      result = result * 10 + (ch - 48)
      valid = true
    } else {
      return default_val
    }
  }
  if valid { result } else { default_val }
}

/// Extract channel_id from session_id like "discord:123456".
fn extract_channel_id(session_id : String) -> String {
  let mut colon_pos = -1
  for i = 0; i < session_id.length(); i = i + 1 {
    if session_id[i] == ':'.to_int().to_uint16() {
      colon_pos = i
      break
    }
  }
  if colon_pos < 0 {
    return session_id
  }
  try {
    session_id[colon_pos + 1:].to_string()
  } catch {
    _ => session_id
  }
}
