# Commands & Tools

## Built-in Commands

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

## Built-in Tools

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
| `skill.install` | Install a skill from URL |
| `done` | Signal task completion |

## Shell Mode

Type `,sh` in the interactive CLI to toggle shell mode. In shell mode:

- The prompt changes from `>` to `$`
- All input is sent directly to bash as shell commands
- Type `,sh` again to return to normal chat mode
