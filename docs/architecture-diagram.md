# Cub Architecture Diagram

## System Overview

```
                              ┌─────────────────────────────────┐
                              │           Entry Point            │
                              │         src/main/main.mbt        │
                              │                                  │
                              │  main() → parse_cli_args()       │
                              │         → load_settings()        │
                              │         → AppRuntime::new()      │
                              └──────────┬──────────────────────┘
                                         │
                 ┌───────────┬───────────┼───────────┬───────────┐
                 ▼           ▼           ▼           ▼           ▼
            ┌────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌────────┐
            │  chat  │ │ message │ │   run   │ │  serve  │ │version │
            │ (REPL) │ │(channel)│ │(single) │ │  (MCP)  │ │        │
            └───┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └────────┘
                │           │           │           │
                ▼           ▼           ▼           ▼
         InteractiveCli  Channel    runtime     McpServer
           ::run()      Manager   .handle()    ::run_stdio()
                        ::run()
```

## Channel Layer

```
┌──────────────────────────────────────────────────────────────────┐
│                      ChannelManager::run()                       │
│                      src/channels/manager.mbt                    │
├─────────────────────────────┬────────────────────────────────────┤
│                             │                                    │
│  ┌──────────────────────┐   │   ┌────────────────────────────┐   │
│  │   Discord Channel    │   │   │    Telegram Channel        │   │
│  │   discord.mbt        │   │   │    telegram.mbt            │   │
│  │                      │   │   │                            │   │
│  │  WebSocket Gateway   │   │   │  HTTP Long Polling         │   │
│  │  wss://gateway.      │   │   │  api.telegram.org/bot.../  │   │
│  │  discord.gg/?v=10    │   │   │  getUpdates?timeout=30     │   │
│  │                      │   │   │                            │   │
│  │  - Heartbeat loop    │   │   │  - Photo → file_id → URL  │   │
│  │  - IDENTIFY/RESUME   │   │   │  - Document → Attachment   │   │
│  │  - Max 2000 chars    │   │   │  - PDF → pdftotext extract │   │
│  │  - Typing indicator  │   │   │  - Markdown → HTML         │   │
│  │  - Exponential       │   │   │  - Max 4096 chars          │   │
│  │    backoff reconnect │   │   │  - Typing indicator        │   │
│  └──────────┬───────────┘   │   └──────────────┬─────────────┘   │
│             │               │                  │                 │
│             └───────┬───────┘──────────────────┘                 │
│                     ▼                                            │
│          ChannelMessage {                                        │
│            channel: "discord" | "telegram"                       │
│            session_id: "discord:{id}" | "telegram:{id}"          │
│            prompt: "channel: $discord\n{metadata JSON}"          │
│            attachments: [image_urls...]                          │
│            documents: [{url, filename, content_type}...]         │
│          }                                                       │
└─────────────────────────────┬────────────────────────────────────┘
                              │
                              ▼
                    handler(ChannelMessage)
                     ├─ rate limit check
                     ├─ session queue (if busy)
                     ├─ process_documents()
                     │   ├─ text files → HTTP GET → embed
                     │   ├─ PDF → curl | pdftotext → embed
                     │   └─ binary → [Attachment: name]
                     ├─ runtime.handle_input()
                     └─ send response back
```

## Application Layer

```
┌──────────────────────────────────────────────────────────────────┐
│                    AppRuntime                                     │
│                    src/app/runtime.mbt                            │
│                                                                  │
│  ┌────────────┐  ┌──────────────┐  ┌────────────────────────┐   │
│  │  Settings   │  │ FileTapeStore │  │  McpClient[]           │   │
│  │  (config)   │  │  (disk I/O)   │  │  (external tools)      │   │
│  └────────────┘  └──────────────┘  └────────────────────────┘   │
│                                                                  │
│  sessions: Map[String, SessionRuntime]                           │
│                                                                  │
│  get_session(id) ──► lazy create ──┐                             │
│                                    ▼                             │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │                   SessionRuntime                           │   │
│  │                                                            │   │
│  │  ┌──────────┐ ┌────────────┐ ┌───────────┐ ┌───────────┐ │   │
│  │  │   Tape   │ │  Tool      │ │  Model    │ │  Agent    │ │   │
│  │  │ Service  │ │ Registry   │ │  Runner   │ │  Loop     │ │   │
│  │  └──────────┘ └────────────┘ └───────────┘ └───────────┘ │   │
│  │  ┌──────────┐ ┌────────────┐ ┌───────────┐               │   │
│  │  │  Input   │ │ Progressive│ │ LLMClient │               │   │
│  │  │  Router  │ │  ToolView  │ │ (+vision  │               │   │
│  │  │          │ │            │ │  +fast)   │               │   │
│  │  └──────────┘ └────────────┘ └───────────┘               │   │
│  └───────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

## Core Layer — Agent Loop & Model Runner

```
┌──────────────────────────────────────────────────────────────────┐
│                AgentLoop::handle_input(text, image_urls)          │
│                src/core/agent_loop.mbt                            │
│                                                                  │
│  1. InputRouter::route_user(text)                                │
│     ├─ parse_comma_command()                                     │
│     │   └─ ",bash", ",gpt", ",handoff", ",skills", ",reset"...  │
│     ├─ execute_command() → immediate_output                      │
│     └─ detect_hints() → expand tools                             │
│                                                                  │
│  2. If enter_model:                                              │
│     └─ ModelRunner::run(model_prompt, image_urls)                │
│                                                                  │
│  3. post_task_fn() → extract_learnings_from_tape()               │
│                                                                  │
│  Return: LoopResult { immediate_output, assistant_output, error } │
└──────────────────────┬───────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│              ModelRunner::run(prompt, image_urls)                 │
│              src/core/model_runner.mbt                            │
│                                                                  │
│  Loop (max_steps = 100):                                         │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Step N                                                      │  │
│  │                                                             │  │
│  │  select_llm(prompt, image_urls)                             │  │
│  │  ├─ has images + vision model? → llm_vision                 │  │
│  │  ├─ tool continuation + fast model? → llm_fast              │  │
│  │  └─ default → llm                                           │  │
│  │                                                             │  │
│  │  LLMClient::chat(messages, tools, system_prompt)            │  │
│  │  ├─ Stream SSE → on_chunk (think-block filter)              │  │
│  │  └─ Return ChatResponse { text, tool_calls, finish_reason } │  │
│  │                                                             │  │
│  │  If tool_calls:                                             │  │
│  │  ├─ validate_tool_call() → filter invalid                   │  │
│  │  ├─ ToolRegistry::execute(name, kwargs)                     │  │
│  │  │   ├─ confirm_fn() if requires_confirmation               │  │
│  │  │   └─ handler(kwargs) → result string                     │  │
│  │  ├─ Append tool_call + tool_result to tape                  │  │
│  │  └─ Continue: "[system: tools executed, ...]"               │  │
│  │                                                             │  │
│  │  If API 400: auto-handoff + retry once                      │  │
│  │  If exit_requested: break                                   │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

## Tape Layer — Persistent History

```
┌──────────────────────────────────────────────────────────────────┐
│                         TapeService                               │
│                         src/tape/service.mbt                      │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ TapeEntry (JSONL record)                                    │  │
│  │                                                             │  │
│  │  { id: Int,                                                 │  │
│  │    kind: "message"|"tool_call"|"tool_result"|"anchor"|      │  │
│  │          "event",                                           │  │
│  │    payload: Json,                                           │  │
│  │    meta: { ts: epoch_ms, ... } }                            │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Operations:                                                     │
│  ├─ read_entries()     load all entries from JSONL               │
│  ├─ append_event()     audit trail (loop.step.start/finish)      │
│  ├─ handoff()          create anchor + compact + switch tape     │
│  ├─ reset()            archive + bootstrap fresh                 │
│  ├─ search()           cross-tape substring search               │
│  ├─ anchors()          list anchor summaries                     │
│  └─ info()             tape stats                                │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ FileTapeStore (src/tape/store.mbt)                          │  │
│  │                                                             │  │
│  │  File: {workspace}/.cub/tapes/{fnv1a_hash}__{name}.jsonl    │  │
│  │                                                             │  │
│  │  TapeFile::read()     incremental JSONL parse               │  │
│  │  TapeFile::append()   auto-increment ID + timestamp          │  │
│  │  TapeFile::compact()  keep last anchor + entries after        │  │
│  │                                                             │  │
│  │  scan_existing()      startup: discover all workspace tapes  │  │
│  │  search_all()         cross-tape: substring match            │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘

Tape Timeline (single JSONL file):
┌────────┬────────┬──────────┬──────────┬─────────┬────────┬──────┐
│message │message │tool_call │tool_result│ anchor  │message │ ...  │
│(user)  │(asst)  │(bash)    │(output)   │(handoff)│(user)  │      │
└────────┴────────┴──────────┴──────────┴─────────┴────────┴──────┘
                                          ▲
                                          │ compact() removes
                                          │ everything before here
```

## Context Selection for LLM

```
select_messages(tape_entries, budget) → messages[]

┌─────────────────────────────────────────────────────────────┐
│                     Token Budget                             │
│                     (default: 128K)                          │
│                                                              │
│  ┌─────────────┐                                             │
│  │ system_prompt│  AGENTS.md + runtime_contract + learnings  │
│  │ (always)     │  + workspace memory + skill expansions     │
│  └─────────────┘                                             │
│  ┌─────────────┐                                             │
│  │ anchor state │  Last anchor's task/summary/decisions       │
│  │ (if exists)  │                                            │
│  └─────────────┘                                             │
│  ┌─────────────┐                                             │
│  │ recent msgs  │  message + tool_call + tool_result          │
│  │ (fill budget)│  ← newest first, stop when budget full     │
│  └─────────────┘                                             │
│                                                              │
│  Auto-handoff at 90% budget → LLM summarize → new anchor    │
└─────────────────────────────────────────────────────────────┘
```

## Tool Ecosystem

```
┌──────────────────────────────────────────────────────────────────┐
│                      ToolRegistry                                 │
│                      src/tools/registry.mbt                       │
│                                                                  │
│  ┌─ Builtin Tools ────────────────────────────────────────────┐  │
│  │  bash        Execute shell commands                         │  │
│  │  fs.read     Read file                                      │  │
│  │  fs.write    Write file                                     │  │
│  │  fs.list     List directory                                 │  │
│  │  fs.edit     Edit file (tool.create)                        │  │
│  │  grep        Search files                                   │  │
│  │  http.get    HTTP requests                                  │  │
│  │  schedule    Schedule tasks                                 │  │
│  │  agent       Spawn child agent                              │  │
│  │  done        Signal completion                              │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Tape Tools ───────────────────────────────────────────────┐  │
│  │  memory.read / memory.save    Workspace MEMORY.md           │  │
│  │  agents.read / agents.update  AGENTS.md (identity/prefs)    │  │
│  │  tape.info / tape.search      Tape introspection            │  │
│  │  tape.handoff                 Context handoff               │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ MCP Tools ────────────────────────────────────────────────┐  │
│  │  External tools via JSON-RPC 2.0 stdio                      │  │
│  │  Config: {workspace}/.cub/servers.json                      │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Extension Tools ──────────────────────────────────────────┐  │
│  │  Scripts:  .agent/tools/*.sh  (subprocess)                  │  │
│  │  WASM:     .agent/plugins/*/plugin.json  (WASM runtime)     │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Progressive Disclosure:                                         │
│  └─ Tools revealed based on task context, not all at once        │
└──────────────────────────────────────────────────────────────────┘
```

## Self-Evolution Pipeline

```
After each agent loop completes:

┌────────────┐    ┌──────────────────┐    ┌───────────────────┐
│ Tape        │───►│ extract_learnings │───►│ learnings.json    │
│ (entries)   │    │ (~300 token LLM)  │    │ (.cub/learnings)  │
└────────────┘    └──────────────────┘    └────────┬──────────┘
                                                    │
                                                    ▼
                                          ┌───────────────────┐
                                          │ crystallize_skill  │
                                          │ (LLM refine)       │
                                          │                    │
                                          │ When to use        │
                                          │ What to do         │
                                          │ What to avoid      │
                                          └────────┬──────────┘
                                                    │
                                                    ▼
                                          .agent/skills/auto-*/
                                              SKILL.md

Skill Discovery (three-level, first-match wins):
  1. {workspace}/.agent/skills/*/SKILL.md   (workspace)
  2. {HOME}/.agent/skills/*/SKILL.md        (global)
  3. Builtin: cub, gh, skill-creator, discord, telegram...
```

## LLM Layer

```
┌──────────────────────────────────────────────────────────────────┐
│                       LLMClient                                   │
│                       src/llm/client.mbt                          │
│                                                                  │
│  Model Spec: "provider:model"                                    │
│  e.g. "openrouter:qwen/qwen3-coder-next"                        │
│                                                                  │
│  Providers:                                                      │
│  ├─ openai      (api.openai.com)        ✓ vision                │
│  ├─ openrouter  (openrouter.ai/api)     ✓ vision                │
│  ├─ ollama      (localhost:11434)        ✓ vision                │
│  ├─ deepseek    (api.deepseek.com)      ✗ vision                │
│  └─ minimax     (api.minimax.chat)      ✗ vision                │
│                                                                  │
│  chat(messages, tools, system_prompt, image_urls)                │
│  ├─ build_request_body()                                         │
│  │   ├─ Inject system_prompt                                     │
│  │   ├─ strip_image_parts() for non-vision providers             │
│  │   └─ max_tokens / max_completion_tokens                       │
│  ├─ POST {api_base}/chat/completions                             │
│  │   ├─ Stream SSE → on_chunk (filter <think> blocks)            │
│  │   └─ Retry: exponential backoff on 429/503                    │
│  └─ Return ChatResponse { text, tool_calls, finish_reason }      │
│                                                                  │
│  Multi-Model:                                                    │
│  ├─ llm         default (general purpose)                        │
│  ├─ llm_vision  image understanding (if configured)              │
│  └─ llm_fast    cheap/fast for tool continuation                 │
└──────────────────────────────────────────────────────────────────┘
```

## End-to-End Data Flow

```
User sends message (Discord/Telegram/CLI)
         │
         ▼
  ┌──────────────┐
  │ Channel Layer │  Extract text, photos, documents
  └──────┬───────┘
         │ ChannelMessage
         ▼
  ┌──────────────┐
  │  Main Layer   │  Rate limit, queue, process_documents
  └──────┬───────┘
         │ (prompt, image_urls)
         ▼
  ┌──────────────┐
  │  App Runtime  │  Get/create session
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │  Agent Loop   │  Route input → commands or model
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐     ┌──────────────┐
  │ Model Runner  │────►│  LLM Client  │  Stream to provider API
  │  (loop)       │◄────│  (response)  │
  └──────┬───────┘     └──────────────┘
         │
         │ tool_calls?
         ▼
  ┌──────────────┐
  │ Tool Registry │  Execute: bash, fs, grep, http, mcp, wasm...
  └──────┬───────┘
         │ results
         ▼
  ┌──────────────┐
  │    Tape       │  Append all entries (message, tool_call,
  │   (JSONL)     │  tool_result, anchor, event)
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ Self-Evolve   │  Extract learnings → crystallize skills
  └──────┬───────┘
         │
         ▼
  Response sent back to user
```

## File Structure

```
src/
├── main/main.mbt          Entry point, CLI dispatch, channel handler
├── app/runtime.mbt         Session lifecycle, component wiring
├── channels/
│   ├── base.mbt            ChannelMessage, Attachment types
│   ├── manager.mbt         Multi-channel coordination
│   ├── discord.mbt         WebSocket Gateway
│   └── telegram.mbt        HTTP long polling
├── core/
│   ├── agent_loop.mbt      AgentLoop, post-task learning
│   ├── router.mbt          InputRouter, command parsing
│   ├── model_runner.mbt    ModelRunner, tool loop, runtime contract
│   └── types.mbt           LoopResult, ModelTurnResult, etc.
├── tape/
│   ├── types.mbt           TapeEntry definitions
│   ├── store.mbt           FileTapeStore, JSONL I/O
│   ├── service.mbt         TapeService, handoff, search
│   └── context.mbt         Context selection, token budget
├── llm/
│   ├── client.mbt          LLMClient, streaming, retry
│   └── types.mbt           ChatResponse, ToolCallInfo
├── tools/
│   ├── registry.mbt        ToolRegistry
│   ├── types.mbt           Tool, ToolDescriptor
│   ├── builtin.mbt         register_builtin_tools()
│   ├── tools_bash.mbt      bash tool
│   ├── tools_fs.mbt        fs.read/write/list/edit, grep
│   ├── tools_web.mbt       http.get
│   ├── tools_agent.mbt     agent (child process)
│   └── progressive.mbt     Progressive tool disclosure
├── skills/loader.mbt       Skill discovery, crystallization
├── mcp/
│   ├── client.mbt          MCP client (JSON-RPC 2.0 stdio)
│   ├── server.mbt          MCP server (`cub serve`)
│   └── types.mbt           McpServerConfig, McpTool
├── ext/
│   ├── loader.mbt          Extension discovery (scripts + WASM)
│   └── types.mbt           ExtType, ExtManifest
├── config/settings.mbt     Settings, env loading (CUB_* prefix)
├── cli/interactive.mbt     REPL, history, session switch
└── log/log.mbt             Structured logging

Data Paths:
  {workspace}/.cub/tapes/      Tape JSONL files
  {workspace}/.cub/learnings.json
  {workspace}/.cub/servers.json  MCP config
  {workspace}/.agent/skills/     Auto-crystallized skills
  {workspace}/.agent/tools/      Script extensions
  {workspace}/.agent/plugins/    WASM plugins
  {workspace}/AGENTS.md          Runtime-generated identity
```
