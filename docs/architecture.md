# Architecture

## Source Layout

```
src/
├── main/       CLI entry, arg parsing, multi-channel dispatch
├── app/        Runtime, session management, AGENTS.md + MEMORY.md reading, tape tool registration
├── core/       Router, model runner (error recovery + timeout retry), agent loop, command detection
├── llm/        Multi-provider LLM client, API retry with exponential backoff, streaming SSE, token budget
├── tape/       Append-only JSONL tape, anchor-aware context selection, timestamps in meta
├── tools/      Tool registry, progressive disclosure, builtin tools (bash, fs, grep, web, schedule, agent)
├── skills/     Three-level discovery, SKILL.md parsing, 5 builtin skills, async fs
├── channels/   Discord (WebSocket, heartbeat, context quoting) + Telegram (HTTP long polling, markdown→HTML)
├── mcp/        MCP client (JSON-RPC 2.0 over stdio, async process pipes, tool discovery)
├── config/     .env loading via /proc/self/environ, settings (CUB_ prefix)
├── cli/        Interactive REPL with async stdin, history, session switching, tool confirmation
├── ext/        Extension discovery, WASM/script loader, hot-registration
└── log/        Structured logging via println, level from CUB_LOG_LEVEL
```

## Zero C FFI

All I/O uses [moonbitlang/async](https://github.com/nicball/async) — file system, HTTP, process spawning, stdio, and sockets. No C foreign function interface calls.

## Data Flow

```
User Input
  → Router (command detection, skill hint matching)
    → Model Runner (LLM API call with retry + streaming)
      → Agent Loop (parse response, detect tool calls)
        → Tool Execution (parallel for non-confirmation tools)
          → Tape (append results as JSONL entries)
            → Context Selection (anchor-aware, budget-constrained)
              → Next Model Runner iteration
```

## Key Abstractions

| Abstraction | Package | Role |
|-------------|---------|------|
| `AppRuntime` | `app` | Holds session state, tape, tool registry, config — passed to all subsystems |
| `TapeService` | `tape` | Append-only log with anchors, handoffs, and context windowing |
| `ToolRegistry` | `tools` | Name→handler map with schema, confirmation flags, and progressive view |
| `LLMClient` | `llm` | Provider-agnostic API client with retry, streaming, and token counting |
| `ProgressiveToolView` | `tools` | Shows abbreviated tool results initially, full on demand |

## Async Patterns

- **Tool confirmation** — `confirm_fn` callback: auto-approve in channels, interactive `[y/N]` in CLI
- **Streaming SSE** — `chat_streaming()` with `on_chunk` callback for real-time output
- **Parallel tool execution** — non-confirmation tool calls run concurrently via `task_group`
- **Channel typing indicators** — 5-second loop via `task_group`, cancelled when response ready

## Error Recovery

- **Consecutive tool failures** — counter tracks failures; ≥3 warns the model, ≥5 aborts the loop
- **Timeout retry** — on timeout, retries once with 2× the original timeout
- **API retry with backoff** — exponential backoff (1s → 2s → 4s), retries 429/5xx, skips 400/401/403
- **Confidence decay** — learnings decay at `0.905^weeks`, auto-pruned below 0.1
