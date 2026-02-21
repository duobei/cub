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

5. **Self-evolving agent** — creates skills, updates workspace rules, learns from experience.
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

### Built-in Commands

| Command | Description |
|---------|-------------|
| `,help` | Show available commands |
| `,tools` | List available tools |
| `,tool.describe <name>` | Show tool parameter details |
| `,tape.info` | Show tape status |
| `,tape.search <query>` | Search tape entries |
| `,tape.export` | Export tape to markdown |
| `,tape.reset` | Reset the tape |
| `,handoff` | Create a tape handoff (stage transition) |
| `,anchors` | List anchor points |
| `,sessions` | List all sessions |
| `,session <name>` | Switch to named session |
| `,skills.list` | List available skills |
| `,skills.describe <name>` | Show skill details |
| `,skill.create` | Create a new skill |
| `,memory.read` | Read persistent MEMORY.md |
| `,memory.save` | Append to persistent MEMORY.md |
| `,agents.update` | Update workspace AGENTS.md |
| `,sh` | Toggle shell mode |
| `,quit` | Exit the session |

### Built-in Tools

| Tool | Description |
|------|-------------|
| `bash` | Execute shell commands (requires confirmation) |
| `fs.read` | Read file content (with offset/limit) |
| `fs.write` | Write file content (creates parent dirs) |
| `fs.edit` | Find and replace text in files |
| `fs.list` | List directory contents (recursive option) |
| `fs.glob` | Find files by name pattern |
| `grep` | Search file contents by regex |
| `web.fetch` | Fetch URL and convert to text |
| `web.search` | Search the web via DuckDuckGo |
| `schedule.add` | Add a scheduled task (cron/date/interval) |
| `schedule.remove` | Remove a scheduled task |
| `schedule.list` | List scheduled tasks |
| `agent.spawn` | Spawn a sub-agent for complex tasks |
| `project.analyze` | Analyze workspace language and structure |
| `git.status` | Show git working tree status |
| `git.diff` | Show git diff (staged/unstaged) |
| `git.log` | Show recent git commits |
| `git.commit` | Create git commit (requires confirmation) |
| `skill.install` | Install a skill from URL |
| `done` | Signal task completion |

## Skills

Cub supports a three-level skill discovery system:

| Priority | Location | Scope |
|----------|----------|-------|
| 1 (highest) | `.agent/skills/` | Project-specific |
| 2 | `~/.agent/skills/` | User-global |
| 3 (lowest) | Built-in | Ships with cub |

### Creating a Skill

```
.agent/skills/my-skill/
  SKILL.md          # Required: frontmatter + instructions
```

SKILL.md format:

```markdown
---
name: my-skill
description: What the skill does and when to use it.
metadata:
  channel: discord    # optional, for channel-specific skills
---

Instructions for the agent when this skill is activated.
```

Skills are activated via `$name` hint syntax in user input (e.g., `$review check this code`).

The agent can also create skills at runtime via `skill.create` tool, enabling self-evolution.

### Built-in Skills

| Skill | Type | Description |
|-------|------|-------------|
| `cub` | regular | Delegate sub-tasks to a child cub process |
| `gh` | regular | GitHub CLI operations: PRs, issues, repos |
| `commit` | regular | Git commit workflow with conventional commits |
| `review` | regular | Code review checklist and structured findings |
| `skill-creator` | regular | Guide for creating new skills |
| `skill-installer` | regular | Install community skills |
| `discord` | channel | Discord message formatting and behavior guidelines |
| `telegram` | channel | Telegram formatting and inline keyboard guidelines |

## Self-Evolving Agent

Cub is designed to learn and improve over time:

- **skill.create** — the agent creates reusable skills from successful workflows
- **agents.update** — modifies workspace AGENTS.md to evolve behavior rules
- **memory.save** — persists useful patterns and facts across sessions
- **startup protocol** — `.agent/startup.md` injects startup instructions into each session

## AGENTS.md

Place an `AGENTS.md` file in your workspace root to inject custom instructions into the system prompt. This is useful for project-specific coding conventions, tool preferences, or domain knowledge.

The agent can update this file via `agents.update` to refine its own behavior.

## Shell Mode

Type `,sh` in the interactive CLI to toggle shell mode. In shell mode:

- The prompt changes from `>` to `$`
- All input is sent directly to bash as shell commands
- Type `,sh` again to return to normal chat mode

## Channels

### Discord Bot

```bash
# Add to .env:
CUB_DISCORD_ENABLED=true
CUB_DISCORD_TOKEN=your_bot_token
CUB_DISCORD_ALLOW_CHANNELS=["channel_id"]
CUB_DISCORD_ALLOW_FROM=["user_id"]    # optional

# Run:
cub message
```

### Telegram Bot

```bash
# Add to .env:
CUB_TELEGRAM_ENABLED=true
CUB_TELEGRAM_TOKEN=your_bot_token
CUB_TELEGRAM_ALLOW_CHATS=["chat_id"]
CUB_TELEGRAM_ALLOW_FROM=["user_id"]   # optional

# Run:
cub message
```

Both channels can run simultaneously. A systemd service file (`cub.service`) is included for persistent deployment.

## Build

```bash
moon fmt --check             # format check
moon check --target native   # type check (strict)
moon build --target native   # build binary
moon test --target native    # run tests
```

Binary: `_build/native/debug/build/main/main.exe`

## Acknowledgments

Cub would not exist without [Bub](https://github.com/psiace/bub) by [@psiace](https://github.com/psiace). The architecture, the design philosophy, and the "tape-first" insight all originate from Bub and its underlying [republic](https://github.com/psiace/bub) framework. Thank you for showing that a coding agent can be predictable, inspectable, and recoverable.

## License

[Apache 2.0](./LICENSE)
