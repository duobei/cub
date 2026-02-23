# Skills

Cub supports a three-level skill discovery system:

| Priority | Location | Scope |
|----------|----------|-------|
| 1 (highest) | `.agent/skills/` | Project-specific |
| 2 | `~/.agent/skills/` | User-global |
| 3 (lowest) | Built-in | Ships with cub |

## Creating a Skill

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

The agent can also create skills at runtime via `skill.create` tool, or auto-crystallize them from repeated learnings (see [Self-Evolving Agent](#self-evolving-agent)).

## Built-in Skills

| Skill | Type | Description |
|-------|------|-------------|
| `cub` | regular | Delegate sub-tasks to a child cub process |
| `gh` | regular | GitHub CLI operations: PRs, issues, repos |
| `commit` | regular | Git commit workflow with conventional commits |
| `review` | regular | Code review checklist and structured findings |
| `skill-creator` | regular | Guide for creating new skills |
| `skill-installer` | regular | Install community skills |
| `git` | regular | Git operations: status, diff, log, commit |
| `project-analyze` | regular | Analyze project language, framework, build commands |
| `discord` | channel | Discord message formatting and behavior guidelines |
| `telegram` | channel | Telegram formatting and inline keyboard guidelines |

## Self-Evolving Agent

Cub is designed to learn and improve over time through a zero-token self-evolution system.

### Learning & Memory

- **Learning extraction** — after each task, heuristic analysis of the tape detects anti-patterns (failures), efficient completions (≤3 steps), and repeated tool usage patterns. No LLM calls required.
- **Dedup-as-reinforcement** — similar learnings increment a `reinforced` counter instead of duplicating, tracking how often a pattern recurs.
- **Confidence decay** — learnings decay over time (`0.905^weeks`), pruning stale knowledge below 0.1 confidence.
- **Memory recall** — high-confidence learnings (≥0.3) are injected into the system prompt with `[avoid]`, `[effective]`, or `[pattern]` tags.

### Skill Evolution

- **Skill tracking** — `skill_stats.json` records uses, successes, failures, and total steps per expanded skill.
- **Skill crystallization** — when a learning is reinforced 3+ times, it auto-generates a `SKILL.md` in `.agent/skills/auto-*/`, turning recurring patterns into reusable skills.
- **skill.create** — the agent creates reusable skills from successful workflows.
- **skill.install** — install community skills from URL.

### Workspace Adaptation

- **agents.update** — modifies workspace AGENTS.md to evolve behavior rules
- **memory.save** — persists useful patterns and facts across sessions
- **startup protocol** — `.agent/startup.md` injects startup instructions into each session

## AGENTS.md

Place an `AGENTS.md` file in your workspace root to inject custom instructions into the system prompt. This is useful for project-specific coding conventions, tool preferences, or domain knowledge.

The agent can update this file via `agents.update` to refine its own behavior.
