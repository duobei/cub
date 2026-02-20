/// CLI entry point for cub.

fn main {
  @async.run_async_main(
    async fn() {
      let args = @env.args()
      // Load settings
      let workspace = @env.current_dir().unwrap_or(".")
      let settings = @config.load_settings(workspace_path=Some(workspace))
      // Create runtime
      let runtime = @app.AppRuntime::new(settings, workspace)
      // Parse command
      let command = if args.length() > 1 { args[1] } else { "chat" }
      match command {
        "chat" => {
          // Interactive CLI mode
          let session_id = if args.length() > 2 { args[2] } else { "cli" }
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
          if args.length() < 3 {
            println("usage: cub run <message>")
            return
          }
          let message = args[2]
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
          println("  cub              interactive chat (default)")
          println("  cub chat         interactive chat")
          println("  cub message      run Discord channel")
          println("  cub run <msg>    run single message")
          println("  cub version      show version")
        }
      }
    },
  )
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
