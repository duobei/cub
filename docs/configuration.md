# Configuration

All settings use the `CUB_` prefix. Loaded from `.env` file or environment variables.

## Multi-Model Routing

Cub supports routing different tasks to different models:

| Variable | Purpose | Default |
|----------|---------|---------|
| `CUB_MODEL` | Primary reasoning model | `openrouter:qwen/qwen3-coder-next` |
| `CUB_MODEL_VISION` | Image analysis | same as primary |
| `CUB_MODEL_FAST` | Tool continuations | same as primary |

## Health Check

Enable an HTTP health endpoint for monitoring:

```bash
CUB_HEALTH_PORT=8080
```

```
GET /health → {"status":"ok","uptime":123,"sessions":0}
```

## Environment Variable Reference

### Model & API

| Variable | Default | Description |
|----------|---------|-------------|
| `CUB_MODEL` | `openrouter:qwen/qwen3-coder-next` | LLM model (provider:model) |
| `CUB_MODEL_VISION` | — | Vision model for images |
| `CUB_MODEL_FAST` | — | Fast model for tool continuations |
| `CUB_API_KEY` | — | API key (fallback: `LLM_API_KEY`, `OPENROUTER_API_KEY`) |
| `CUB_API_BASE` | — | Custom API base URL |
| `CUB_MODEL_TIMEOUT_SECONDS` | `90` | Request timeout |

### Runtime

| Variable | Default | Description |
|----------|---------|-------------|
| `CUB_MAX_TOKENS` | `1024` | Max output tokens per response |
| `CUB_MAX_STEPS` | `100` | Max agent loop steps |
| `CUB_CONTEXT_BUDGET` | `128000` | Context window token budget |
| `CUB_HANDOFF_THRESHOLD` | `90` | Auto-handoff at N% of budget |
| `CUB_SYSTEM_PROMPT` | — | Custom system prompt override |
| `CUB_HOME` | `~/.cub` | Config home directory |
| `CUB_TAPE_NAME` | `cub` | Tape store name |
| `CUB_LOG_LEVEL` | `info` | Log level (debug/info/warn/error) |
| `CUB_RATE_LIMIT_PER_MINUTE` | `10` | Sliding window rate limit per session |
| `CUB_HEALTH_PORT` | — | HTTP health check port |

### Channels

| Variable | Default | Description |
|----------|---------|-------------|
| `CUB_DISCORD_ENABLED` | `false` | Enable Discord bot |
| `CUB_DISCORD_TOKEN` | — | Discord bot token |
| `CUB_DISCORD_ALLOW_CHANNELS` | — | Allowed channel IDs (JSON array) |
| `CUB_DISCORD_ALLOW_FROM` | — | Allowed user IDs (JSON array) |
| `CUB_DISCORD_COMMAND_PREFIX` | `!` | Command prefix |
| `CUB_TELEGRAM_ENABLED` | `false` | Enable Telegram bot |
| `CUB_TELEGRAM_TOKEN` | — | Telegram bot token |
| `CUB_TELEGRAM_ALLOW_CHATS` | — | Allowed chat IDs (JSON array) |
| `CUB_TELEGRAM_ALLOW_FROM` | — | Allowed user IDs (JSON array) |
