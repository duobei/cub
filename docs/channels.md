# Channels

Cub can connect to chat platforms as a bot, running the same agent loop over incoming messages.

## Discord Bot

```bash
# Add to .env:
CUB_DISCORD_ENABLED=true
CUB_DISCORD_TOKEN=your_bot_token
CUB_DISCORD_ALLOW_CHANNELS=["channel_id"]
CUB_DISCORD_ALLOW_FROM=["user_id"]    # optional

# Run:
cub message
```

Features: WebSocket gateway, context quoting (referenced messages), typing indicators, auto-reconnect with heartbeat.

## Telegram Bot

```bash
# Add to .env:
CUB_TELEGRAM_ENABLED=true
CUB_TELEGRAM_TOKEN=your_bot_token
CUB_TELEGRAM_ALLOW_CHATS=["chat_id"]
CUB_TELEGRAM_ALLOW_FROM=["user_id"]   # optional

# Run:
cub message
```

Features: HTTP long polling, markdown-to-HTML conversion (code blocks, bold, italic, strikethrough, links), typing indicators.

## Running Channels

Both channels can run simultaneously. A systemd service file (`cub.service`) is included for persistent deployment.

Use `cub message` to start channel listeners. The same agent loop, tools, and skills are available in channel mode as in interactive CLI mode.

## Prompt Format

Channel messages are formatted as metadata JSON with a channel prefix, so the model knows who's speaking:

```
channel: $discord
{"message":"hello","channel_id":"123","username":"alice","sender_id":"456","message_id":"789"}
```

This enables multi-user awareness in group chats. Each session is keyed by `{channel}:{channel_id}`, so Discord and Telegram maintain separate tapes.

## Session Management

Sessions are created on demand and kept in memory. Tape files (`.cub/tapes/`) provide persistence — on restart, sessions are recreated from tape when the next message arrives. No separate session persistence file is needed.

## Per-Session Queuing

Messages for a session that is currently processing are queued and handled sequentially. This prevents concurrent requests from interleaving tool calls or corrupting tape state.
