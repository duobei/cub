# Architecture

## Design Philosophy

**Tape as truth.** All agent state lives in an append-only JSONL tape — messages, tool calls, tool results, events, anchors. There is no hidden state, no in-memory-only context, no implicit branching. The tape is the single source of truth, and any session can be replayed or inspected from the log alone.

**Anchors, not branches.** When context grows too large or the task pivots, Cub writes an anchor entry that summarizes the current state and marks a resumption point. Subsequent context selection starts from the last anchor instead of replaying the full history. This makes handoff explicit — no silent context truncation.

**Router-first control flow.** Every user message and every assistant response passes through the same router. The router detects `,commands` before the LLM sees them, matches `$skill` hints to expand skill prompts, and strips `<think>` blocks from thinking models. The LLM only receives what the router decides to forward.

**Tools are data, not code paths.** Each tool is a `(name, schema, handler)` triple registered in a flat registry. The agent loop doesn't know what tools exist — it calls the registry by name. Adding a tool (builtin, MCP, extension, or auto-crystallized skill) is just a `registry.register()` call. Progressive disclosure shows the model only the tool names it needs, expanding full schemas on demand.

**Learn without tokens.** After each task, heuristic analysis of the tape extracts patterns (anti-patterns from failures, effective patterns from short completions, tool usage frequencies) without any LLM call. Similar learnings reinforce rather than duplicate. Confidence decays over time, and patterns reinforced 3+ times auto-crystallize into reusable skills.

**Zero FFI, fully async.** All I/O — file system, HTTP, process spawning, stdin, sockets — uses `moonbitlang/async`. No C glue code, no platform-specific stubs. The binary is pure MoonBit native.

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

## Self-Evolution Pipeline

Cub evolves its behavior through a four-stage pipeline that requires zero LLM tokens:

```
Task Completes
  → Extract (heuristic tape analysis)
    → Deduplicate (Jaccard similarity ≥ 0.6, reinforce counter++)
      → Decay (confidence × 0.905^weeks, prune < 0.1)
        → Crystallize (reinforced ≥ 3 → auto-generate SKILL.md)
```

### 1. Extraction (`extract_learnings_from_tape`)

After each task, the tape is scanned from the last anchor forward. Tool call entries are collected and analyzed by three detectors:

| Detector | Trigger | Learning Type |
|----------|---------|---------------|
| Failure | Task ended with error | `anti_pattern` — records step count + tools used + truncated error |
| Efficiency | Task succeeded in ≤ 3 steps | `heuristic` — records tool combination that worked |
| Repetition | Same tool called 5+ times consecutively (excluding bash/fs.read/grep) | `preference` — records the repeated tool pattern |

No LLM is called. Pattern detection is purely rule-based on tape structure.

### 2. Dedup-as-Reinforcement (`add_learning`)

Before storing a new learning, all existing learnings are checked for similarity using Jaccard word overlap (threshold ≥ 0.6) or substring containment. If a similar learning exists:
- Its `reinforced` counter increments (instead of creating a duplicate)
- Its `last_used` timestamp updates
- If `reinforced` reaches 3, the content is returned as a crystallization candidate

Each learning is stored in `~/.cub/learnings.json` as:

```json
{
  "type": "heuristic",
  "content": "Efficient: completed in 2 steps via fs.read, fs.edit",
  "confidence": 0.7,
  "reinforced": 1,
  "last_used": 1708000000000,
  "created_at": 1708000000000
}
```

### 3. Confidence Decay (`decay_learnings`)

On each session start, all learnings undergo time-based decay:

- Decay rate: `confidence × 0.905^weeks` (approximation of `e^(-0.1×weeks)`)
- Entries below 0.1 confidence are pruned entirely
- Recent/frequently-used learnings resist decay via `last_used` timestamp

### 4. Memory Recall (`render_learnings`)

High-confidence learnings (≥ 0.3) are injected into the system prompt, sorted by confidence descending, with type-based tags:

- `anti_pattern` → `[avoid]`
- `heuristic` → `[effective]`
- `preference` → `[pattern]`

### 5. Skill Crystallization (`crystallize_skill`)

When a learning is reinforced 3+ times, it auto-generates a `SKILL.md` at `.agent/skills/auto-{name}/SKILL.md`. The skill name is derived from the 3 most meaningful words in the learning content (skipping stop words). Existing skills are never overwritten.

### 6. Skill Tracking (`update_skill_stats`)

Every expanded skill is tracked in `~/.cub/skill_stats.json`:

```json
{
  "commit": { "uses": 12, "successes": 11, "failures": 1, "total_steps": 48 }
}
```

This enables future quality-of-service decisions (e.g., deprecating consistently failing skills).

## Extension Hot-Loading

The agent can create new tools at runtime and use them immediately — no restart, no human intervention. This is the capability backbone of self-evolution: when the agent encounters a task that existing tools cannot efficiently handle, it builds a purpose-specific tool on the spot and registers it into the same session's tool registry. Combined with the learning pipeline, this closes the autonomy loop — the agent observes patterns, extracts knowledge, and when reinforced enough, materializes that knowledge as executable tools.

### tool.create Pipeline

The `tool.create` tool handles the full lifecycle in one step:

**Script tools:**
```
tool.create(name, type="script", code, description)
  → mkdir .agent/tools/
    → write {name}.sh + chmod +x
      → write {name}.json manifest
        → registry.register("ext.{name}", handler)  ← hot-registered
```

**WASM plugins:**
```
tool.create(name, type="wasm", code, description)
  → scaffold MoonBit project:
      {plugin_dir}/moon.mod.json
      {plugin_dir}/cmd/main/moon.pkg   (import json+env, is-main: true)
      {plugin_dir}/cmd/main/main.mbt   (strip_pkg_declarations applied)
      {plugin_dir}/plugin.json          (manifest)
    → moon build --target wasm (180s timeout, absolute path for systemd)
      → find_wasm_file (search _build/ candidates)
        → registry.register("ext.{name}", handler)  ← hot-registered
```

Key details:
- **`strip_pkg_declarations`** — user code may contain `import {}` or `options()` blocks that belong in `moon.pkg`, not `.mbt` files. These are auto-stripped before writing `main.mbt`.
- **Absolute paths** — systemd's PATH lacks `~/.moon/bin`, so `moon` and `moonrun` are invoked via absolute paths (`$HOME/.moon/bin/moon`).
- **`wasm` target** — uses `wasm` (not `wasm-gc`) for portability. Runs via `moonrun`.

### Extension Execution

Both script and WASM tools run as child processes with a 30-second timeout:

- **Script** — `@process.collect_output(path, [args_json])`
- **WASM** — `@process.collect_output(moonrun, [wasm_path, "--", args_json])`

Arguments are passed as a single JSON string. Output is captured from stdout.

### Discovery on Startup

Extensions are discovered at startup from four directories (workspace overrides global):

1. `{workspace}/.agent/tools/` — workspace scripts
2. `{workspace}/.agent/plugins/` — workspace WASM
3. `~/.cub/tools/` — global scripts
4. `~/.cub/plugins/` — global WASM

Each is registered as `ext.{name}` in the tool registry, deduplicated by name (first wins).

## Error Recovery

- **Consecutive tool failures** — counter tracks failures; ≥3 warns the model, ≥5 aborts the loop
- **Timeout retry** — on timeout, retries once with 2× the original timeout
- **API retry with backoff** — exponential backoff (1s → 2s → 4s), retries 429/5xx, skips 400/401/403
- **Confidence decay** — learnings decay at `0.905^weeks`, auto-pruned below 0.1

## Limitations & Roadmap

### Native-only target

Cub currently only compiles to `--target native`. The `wasm`, `wasm-gc`, and `js` targets are blocked because `moonbitlang/async` (the sole I/O dependency) only supports native — its runtime relies on native async primitives (epoll, kqueue) that have no WASM/JS equivalent yet.

Upstream tracking: [moonbitlang/async#233](https://github.com/nicball/async/issues/233). A related proposal for abstracting I/O primitives: [moonbitlang/async#201](https://github.com/nicball/async/issues/201).

Once upstream adds WASM support, Cub can compile to browser or edge runtimes with no code changes — the codebase has zero C FFI and no platform-specific stubs.
