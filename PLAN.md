# Cub — MoonBit 版 Bub 实现计划

## 目标

用 MoonBit 重写 bub，MVP 里程碑：**Discord channel 能收发消息，LLM agent loop 能跑，带基础工具**。

## 设计哲学

参考 [被缚的普罗米修斯](https://psiace.me/zh/posts/prometheus-bound/) 和 [重新发明打孔纸带](https://psiace.me/zh/posts/reinvent-the-punch-tape/) 的核心理念：

1. **单一永续线程** — 会话不分叉、不回滚，只向前追加
2. **Append-only 日志** — 事实一旦写入不修改，保证可验证、可回溯
3. **锚点（Anchor）驱动** — 通过 handoff 产生锚点标记阶段切换，不删除也不总结历史，只告诉系统"从哪里开始算"
4. **按需读取** — 状态从持续负担变为可选资源，"任务出现 → 构造上下文 → 完成 → 结束"
5. **最小化工具集** — 框架只提供推理核心，其余由 AI 自由裁量

## 项目信息

- 名称：`cub`
- 仓库：`duobei/cub`（独立仓库）
- 语言：MoonBit（native backend）
- 关键依赖：`moonbitlang/async`（HTTP, WebSocket, process, fs）

## 架构映射

```
Python bub                    MoonBit cub
─────────────────────────────────────────────
config/settings.py        →   config/         环境变量加载
tape/store.py             →   tape/           JSONL append-only store
tape/service.py           →   tape/           handoff, anchors, search
core/agent_loop.py        →   core/           forward-only loop
core/model_runner.py      →   core/           LLM 调用 + tool call 处理
core/router.py            →   core/           输入路由（逗号命令解析）
tools/registry.py         →   tools/          工具注册 + 分发
tools/builtin.py          →   tools/          bash, fs, web, tape, done
channels/base.py          →   channels/       channel trait
channels/discord.py       →   channels/       Discord Gateway + REST
skills/loader.py          →   skills/         SKILL.md 发现和加载
app/runtime.py            →   app/            session 管理 + supervisor
cli/app.py                →   main/           CLI 入口
republic (LLM client)     →   llm/            OpenAI-compatible API 客户端
```

## 项目结构

```
cub/
├── moon.mod.json                # 模块定义，依赖 moonbitlang/async
├── src/
│   ├── config/
│   │   ├── moon.pkg.json
│   │   └── settings.mbt         # Settings 结构体，从环境变量加载
│   ├── tape/
│   │   ├── moon.pkg.json
│   │   ├── types.mbt            # TapeEntry, AnchorSummary
│   │   ├── store.mbt            # FileTapeStore (JSONL append-only 读写)
│   │   └── service.mbt          # TapeService (handoff/anchors/search)
│   ├── llm/
│   │   ├── moon.pkg.json
│   │   ├── client.mbt           # OpenAI-compatible chat API 客户端
│   │   └── types.mbt            # ChatMessage, ToolCall, ChatResponse
│   ├── tools/
│   │   ├── moon.pkg.json
│   │   ├── registry.mbt         # ToolRegistry (注册/分发/schema)
│   │   ├── builtin.mbt          # bash, fs.read, fs.write, fs.edit
│   │   ├── web.mbt              # web.fetch, web.search
│   │   └── tape_tools.mbt       # tape.info, tape.handoff, tape.anchors
│   ├── core/
│   │   ├── moon.pkg.json
│   │   ├── agent_loop.mbt       # AgentLoop (handle_input → route → model → result)
│   │   ├── model_runner.mbt     # ModelRunner (step loop + tool call + recovery)
│   │   └── router.mbt           # InputRouter (逗号命令解析 + 执行)
│   ├── channels/
│   │   ├── moon.pkg.json
│   │   ├── base.mbt             # Channel trait 定义
│   │   └── discord.mbt          # Discord Gateway (WebSocket) + REST API
│   ├── skills/
│   │   ├── moon.pkg.json
│   │   └── loader.mbt           # SKILL.md 发现、frontmatter 解析
│   ├── app/
│   │   ├── moon.pkg.json
│   │   └── runtime.mbt          # AppRuntime, SessionRuntime
│   └── main/
│       ├── moon.pkg.json
│       └── main.mbt             # CLI 入口
└── README.md
```

## 分阶段实施

### Phase 1: 骨架 + Tape（~Day 1-2）

1. **初始化项目** — `moon new cub`，配置 `moon.mod.json` 依赖
2. **config** — Settings 结构体，从环境变量读取（BUB_MODEL, BUB_API_KEY, BUB_DISCORD_TOKEN 等）
3. **tape/types** — TapeEntry 结构体（id, kind, payload, meta）
4. **tape/store** — FileTapeStore：JSONL 文件读写、append（严格 append-only，不修改已写入条目）
5. **tape/service** — TapeService：handoff（产生锚点，标记阶段切换）、anchors（查询锚点列表）、search、info。不实现 fork/merge——用 handoff 替代分叉，用追加新事实替代回滚

### Phase 2: LLM 客户端 + Tool 系统（~Day 3-4）

6. **llm/types** — ChatMessage, ToolCall, ToolFunction, ChatResponse 类型
7. **llm/client** — OpenAI-compatible API 客户端：
   - POST /chat/completions
   - 支持 tool_calls 解析
   - 支持 OpenRouter（X-Title, HTTP-Referer headers）
8. **tools/registry** — ToolRegistry：
   - register(name, description, schema, handler)
   - execute(name, args) → Result
   - model_tools() → JSON schema 列表
9. **tools/builtin** — 基础工具：
   - `bash` — @process.run 执行 shell 命令
   - `fs.read` — @fs.read_text_file
   - `fs.write` — @fs.write_text_file
   - `done` — 信号完成

### Phase 3: Agent Loop（~Day 5-6）

10. **core/router** — InputRouter：逗号命令检测和执行
11. **core/model_runner** — ModelRunner：
    - step loop（max_steps 限制）
    - 发送 chat completion → 解析 tool_calls → 执行 → 继续
    - 错误恢复（context_length_exceeded → handoff）
12. **core/agent_loop** — AgentLoop：
    - handle_input → route_user → model_runner.run → LoopResult

### Phase 4: Discord Channel（~Day 7-8）

13. **channels/discord** — Discord 适配器：
    - WebSocket 连接 Discord Gateway（wss://gateway.discord.gg）
    - 处理 IDENTIFY, HEARTBEAT, DISPATCH 事件
    - MESSAGE_CREATE 事件 → get_session_prompt
    - REST API 发送消息（POST /channels/{id}/messages）
    - 权限过滤（allow_from, allow_channels）
14. **channels/base** — Channel trait

### Phase 5: 集成 + Runtime（~Day 9-10）

15. **app/runtime** — AppRuntime + SessionRuntime：
    - session 管理（session_id → SessionRuntime）
    - graceful shutdown
16. **skills/loader** — SKILL.md 发现和加载（简单 frontmatter 解析）
17. **main/main** — CLI 入口：
    - `cub chat` — 交互式 CLI
    - `cub message` — 长驻运行（Discord polling）
18. **集成测试** — 端到端验证：Discord 收到消息 → LLM 响应 → Discord 回复

## 关键技术决策

1. **LLM 协议** — 直接用 OpenAI-compatible HTTP API，不依赖 republic 库
2. **Discord** — 直接实现 Gateway WebSocket + REST，不用第三方库（MoonBit 没有）
3. **JSON** — 使用 MoonBit 内置 JSON 支持（@json 包）
4. **Tape 存储** — 保持 JSONL 格式，严格 append-only；不实现 fork/merge，用 handoff + anchor 管理阶段切换
5. **Tool schema** — 手动构造 JSON schema（MoonBit 没有 Pydantic 式反射）
6. **YAML 解析** — SKILL.md frontmatter 用简单的手写解析器，不引入 YAML 库

## MVP 验收标准

- [ ] `cub message` 启动后连接 Discord Gateway
- [ ] 收到 Discord 消息后触发 agent loop
- [ ] agent 能调用 LLM（OpenRouter）获取响应
- [ ] agent 能执行 bash / fs.read / fs.write 工具
- [ ] agent 回复发送回 Discord channel
- [ ] tape 正确记录所有交互（JSONL 文件）
- [ ] 支持 `done` 工具停止 agent loop
- [ ] 支持逗号命令（`,help`, `,tools`, `,tape.info`）
