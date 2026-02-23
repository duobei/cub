# Cub

> Cub it. Build it.

Cub is a native coding agent CLI written in [MoonBit](https://www.moonbitlang.com/), inspired by and paying tribute to [Bub](https://github.com/psiace/bub).

Where Bub pioneered the tape-first, anchor-driven agent architecture in Python, Cub carries that vision forward as a native reimplementation — faster startup, single binary, zero runtime dependencies.

## Design

Inherited from Bub's philosophy:

1. **Append-only tape** — all context is a linear, inspectable log. No hidden state.
2. **Anchor & handoff** — explicit stage transitions instead of implicit branching.
3. **Strict command boundary** — only lines starting with `,` are commands.
4. **Unified routing** — the same model routes both user input and assistant output.

Extended by Cub:

5. **Self-evolving agent** — zero-token learning extraction, confidence decay, auto-crystallization of skills from experience.
6. **Multi-provider LLM** — one binary, any backend (OpenRouter, OpenAI, DeepSeek, MiniMax, Ollama).
7. **Parallel tool execution** — non-confirmation tools run concurrently.
8. **Smart context management** — tool-aware truncation and auto-handoff at 90% budget.

## Quick Start

```bash
moon build --target native
cp env.example .env
# edit .env with your API key
./_build/native/debug/build/main/main.exe
```

Minimal `.env`:

```bash
CUB_MODEL=openrouter:qwen/qwen3-coder-next
OPENROUTER_API_KEY=your_key_here
```

### Supported Providers

| Provider | Model Syntax | API Key |
|----------|-------------|---------|
| OpenRouter (default) | `openrouter:model` | `OPENROUTER_API_KEY` |
| OpenAI | `openai:gpt-4o` | `CUB_API_KEY` |
| DeepSeek | `deepseek:deepseek-chat` | `CUB_API_KEY` |
| MiniMax | `minimax:MiniMax-M2.5` | `CUB_API_KEY` |
| Ollama (local) | `ollama:llama3` | none (auto-detected) |

If no API key is configured, Cub auto-detects a running Ollama instance on `localhost:11434`.

## Usage

```
cub [options]              interactive chat (default)
cub chat [session_id]      interactive chat
cub message                run Discord/Telegram channel
cub run <msg>              run single message
cub version                show version
```

### CLI Options

```
--model <provider:model>   override model (e.g. minimax:MiniMax-M2.5)
--workspace <path>         override workspace directory
--max-tokens <n>           override max tokens
--system-prompt <text>     override system prompt
--tools <list>             filter tools (comma-separated)
--skills <list>            filter skills (comma-separated)
```

## Features

- **20 commands, 15 built-in tools** — file ops, grep, web, scheduling, sub-agents → [docs/commands.md](docs/commands.md)
- **Three-level skills + self-evolution** — project/user/builtin skills, learning extraction, auto-crystallization → [docs/skills.md](docs/skills.md)
- **Discord & Telegram** — run as a bot with typing indicators and context quoting → [docs/channels.md](docs/channels.md)
- **MCP, scripts, WASM plugins** — extend with external tool servers or custom plugins → [docs/extensions.md](docs/extensions.md)
- **Multi-model routing, health checks, full env var reference** → [docs/configuration.md](docs/configuration.md)

## Architecture

```
src/
├── main/       CLI entry, arg parsing, multi-channel dispatch
├── app/        Runtime, session management, tape tool registration
├── core/       Router, model runner, agent loop, command detection
├── llm/        Multi-provider LLM client, streaming SSE, retry
├── tape/       Append-only JSONL tape, anchor-aware context selection
├── tools/      Tool registry, progressive disclosure, builtin tools
├── skills/     Three-level discovery, SKILL.md parsing, builtin skills
├── channels/   Discord (WebSocket) + Telegram (HTTP long polling)
├── mcp/        MCP client (JSON-RPC 2.0 over stdio)
├── config/     .env loading, settings (CUB_ prefix)
├── cli/        Interactive REPL, async stdin, tool confirmation
├── ext/        Extension discovery, WASM/script loader
└── log/        Structured logging, level filtering
```

Zero C FFI — all I/O uses [moonbitlang/async](https://github.com/moonbitlang/async) (fs, http, process, stdio, socket). See [docs/architecture.md](docs/architecture.md) for detailed design.

## Build

```bash
moon fmt --check                       # format check
moon check --target native --deny-warn # type check (strict)
moon build --target native             # build binary
moon test --target native              # run 194 tests
```

Binary: `_build/native/debug/build/main/main.exe`

## Acknowledgments

Cub would not exist without [Bub](https://github.com/psiace/bub) by [@psiace](https://github.com/psiace). The architecture, the design philosophy, and the "tape-first" insight all originate from Bub and its underlying [republic](https://github.com/psiace/bub) framework. Thank you for showing that a coding agent can be predictable, inspectable, and recoverable.

## License

[Apache 2.0](./LICENSE)
