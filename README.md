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

## Usage

```
cub [options]              interactive chat (default)
cub chat [session_id]      interactive chat
cub message                run Discord channel
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
| `,tape.info` | Show tape status |
| `,handoff` | Create a tape handoff (stage transition) |
| `,anchors` | List anchor points |
| `,tape.search <query>` | Search tape entries |
| `,tape.reset` | Reset the tape |
| `,skills.list` | List available skills |
| `,skills.describe <name>` | Show skill details |
| `,sh` | Toggle shell mode (input goes directly to bash) |
| `,quit` | Exit the session |

### Built-in Tools

| Tool | Description |
|------|-------------|
| `bash` | Execute shell commands with timeout |
| `fs.read` | Read file content (with offset/limit) |
| `fs.write` | Write file content (creates parent dirs) |
| `fs.edit` | Find and replace text in files |
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

### Built-in Skills

| Skill | Type | Description |
|-------|------|-------------|
| `cub` | regular | Delegate sub-tasks to a child cub process |
| `gh` | regular | GitHub CLI operations: PRs, issues, repos |
| `commit` | regular | Git commit workflow with conventional commits |
| `review` | regular | Code review checklist and structured findings |
| `skill-creator` | regular | Guide for creating new skills |
| `discord` | channel | Discord message formatting and behavior guidelines |

## AGENTS.md

Place an `AGENTS.md` file in your workspace root to inject custom instructions into the system prompt. This is useful for project-specific coding conventions, tool preferences, or domain knowledge.

## Shell Mode

Type `,sh` in the interactive CLI to toggle shell mode. In shell mode:

- The prompt changes from `>` to `$`
- All input is sent directly to bash as shell commands
- Type `,sh` again to return to normal chat mode

## Discord Bot

```bash
# Add to .env:
BUB_DISCORD_ENABLED=true
BUB_DISCORD_TOKEN=your_bot_token
BUB_DISCORD_ALLOW_CHANNELS=["channel_id"]

# Run:
cub message
```

A systemd service file (`cub.service`) is included for persistent deployment.

## Build

```bash
moon check --target native   # type check
moon build --target native   # build binary
```

Binary: `_build/native/debug/build/main/main.exe`

## Acknowledgments

Cub would not exist without [Bub](https://github.com/psiace/bub) by [@psiace](https://github.com/psiace). The architecture, the design philosophy, and the "tape-first" insight all originate from Bub and its underlying [republic](https://github.com/psiace/bub) framework. Thank you for showing that a coding agent can be predictable, inspectable, and recoverable.

## License

[Apache 2.0](./LICENSE)
