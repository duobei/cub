# Cub 长期规划：浏览器运行 + P2P 通讯 + 分布式协作

## 愿景

把 cub 从单机 agent 进化为分布式 agent 网络：
- 每个 cub 可以运行在服务器、桌面、或浏览器中
- cub 之间可以 P2P 通讯，交换知识和协作完成任务
- 多个 cub 组成分布式网络，形成集体智能

## 当前架构分析

### I/O 分层

```
Layer 3 — 平台 I/O（13 个文件，9 个包）
  @fs, @http, @websocket, @process, @socket, @stdio
  全部依赖 moonbitlang/async，仅支持 native target

Layer 2 — 服务抽象
  AppRuntime, TapeService, ToolRegistry, ChannelManager, McpClient
  通过 Layer 3 实现 I/O

Layer 1 — 纯计算（可移植）
  core/ — Router, AgentLoop, ModelRunner, CommandDetector
  tape/types — TapeEntry, context selection
  tools/types — ToolRegistry, ProgressiveToolView
  llm/types — ChatResponse, ToolCallInfo
  log/ — println-based logging
  skills/ — frontmatter parser, skill metadata
```

### 阻塞因素

- `moonbitlang/async` 只支持 native target（issue #233）
- WASM/JS target 编译可过但运行时 abort()
- 无 WebRTC/P2P 库可用

---

## Phase 1：I/O 抽象层（前置条件）

**目标**：将 cub 的 I/O 操作从直接调用 `@fs`/`@http` 改为通过 trait 抽象

### 1.1 定义 Platform trait

```
// src/platform/types.mbt

trait Storage {
  async read(path: String) -> String
  async write(path: String, content: String) -> Bool
  async append(path: String, content: String) -> Bool
  async exists(path: String) -> Bool
  async list(path: String) -> Array[String]
}

trait HttpClient {
  async get(url: String, headers: Map[String,String]) -> (Int, String)
  async post(url: String, body: String, headers: Map[String,String]) -> (Int, String)
  async post_stream(url: String, body: String, headers: Map[String,String],
                    on_chunk: (String) -> Unit) -> (Int, String)
}

trait Executor {
  async run(command: String, args: Array[String], timeout_ms: Int) -> (Int, String, String)
}
```

### 1.2 Native 实现

用现有的 `@fs`/`@http`/`@process` 实现上述 trait，行为不变。

### 1.3 逐步迁移

把 13 个有平台依赖的文件从直接调用改为通过 trait 调用：
- tape/store.mbt: `@fs` → `Storage`
- llm/client.mbt: `@http` → `HttpClient`
- tools/tools_bash.mbt: `@process` → `Executor`
- ...

**产出**：cub 功能不变，但所有 I/O 通过 trait 分发。

---

## Phase 2：浏览器运行

**前提**：moonbitlang/async 支持 wasm/js target（跟踪 issue #233）

### 2.1 Browser 平台实现

为 Phase 1 的 trait 提供浏览器实现：

| Trait | 浏览器实现 |
|-------|-----------|
| Storage | IndexedDB + OPFS |
| HttpClient | fetch() API |
| Executor | 不支持 / WebVM (可选) |

### 2.2 编译与部署

```
moon build --target wasm    # 编译为 WASM
# 或
moon build --target js      # 编译为 JS
```

输出为静态文件，可部署到任何 CDN。

### 2.3 浏览器 UI

轻量 Web UI：
- Chat 界面（消息输入/输出）
- Tape 浏览器（查看对话历史）
- 工具面板（查看/管理工具和插件）
- 设置页（API key、模型选择）

### 2.4 功能裁剪

浏览器版不支持：
- bash 执行（无 OS 进程）
- MCP server/client（无 stdio）
- 文件系统工具（用 OPFS 替代，受限于浏览器沙箱）

核心能力保留：
- LLM 对话（通过 fetch）
- Tape 持久化（通过 IndexedDB）
- Skill 系统
- Web 工具（fetch URL）

**产出**：cub 可以作为静态网页运行，零基础设施。

---

## Phase 3：P2P 通讯

**目标**：两个 cub 实例之间可以直接通讯

### 3.1 通讯协议

定义 cub-to-cub 消息协议（基于 JSON）：

```
// 消息类型
enum CubMessage {
  Ping                           // 心跳
  Query(topic: String)           // 向对方查询信息
  Reply(topic: String, content: String)  // 回复查询
  TaskRequest(task: String)      // 请求对方执行任务
  TaskResult(id: String, result: String) // 任务结果
  KnowledgeShare(entries: Array[TapeEntry]) // 知识共享
}
```

### 3.2 传输层

两种传输方案，按环境选择：

**服务端 cub（native）**：
- WebSocket server/client — 已有 `@websocket` 支持
- 直连或通过中继服务器

**浏览器 cub（wasm/js）**：
- WebRTC DataChannel — 真正的 P2P，无需中转服务器
- 需要 signaling server 做初始握手（可用现有 WebSocket）
- 备选：WebSocket 通过中继服务器

### 3.3 发现机制

cub 实例之间如何找到对方：
- **本地网络**：mDNS / UDP 广播
- **互联网**：中心化注册服务 或 DHT（分布式哈希表）
- **手动**：配置对方地址

### 3.4 身份与信任

- 每个 cub 实例有唯一 ID（基于密钥对）
- 首次连接需要用户确认（信任 on first use）
- 通讯加密（TLS 或 WebRTC 内置加密）

**产出**：两个 cub 可以互相发现、建立连接、交换消息。

---

## Phase 4：分布式协作网络

**目标**：多个 cub 组成网络，协作完成复杂任务

### 4.1 知识网络

- 每个 cub 有自己的 tape（本地知识）
- `tape.search` 扩展为网络搜索：先搜本地，再广播到网络
- 知识按相关性和信任度排序
- 隐私控制：每个 cub 可以选择共享哪些 tape

### 4.2 任务分发

```
用户 → cub-A: "翻译这个项目的文档为中英日三语"
         ↓
cub-A 分析任务，拆分为 3 个子任务
         ↓
    ┌────┼────┐
    ↓    ↓    ↓
 cub-A  cub-B cub-C
  (中)   (英)  (日)
    ↓    ↓    ↓
    └────┼────┘
         ↓
cub-A 汇总结果，返回给用户
```

- 任务拆分由 LLM 决定
- 子任务通过 P2P 消息分发
- 结果通过 tape 同步回来

### 4.3 专长声明

每个 cub 可以声明自己的专长：
- 通过 AGENTS.md 描述能力
- 通过 learnings 积累的技能
- 通过安装的 WASM 插件

任务分发时优先匹配专长：
```
cub-A (MoonBit expert) + cub-B (Python expert) + cub-C (DevOps expert)
```

### 4.4 共识与冲突解决

多个 cub 修改同一资源时：
- 乐观锁：基于 tape 的版本向量
- 冲突时由发起者的 LLM 做合并决策
- 类似 git 的 merge 模型

**产出**：cub 网络可以协作完成单个 cub 无法独立完成的任务。

---

## 实施优先级

```
Phase 1: I/O 抽象层        ← 现在可以开始，不依赖上游
Phase 2: 浏览器运行        ← 等 moonbitlang/async wasm 支持
Phase 3: P2P 通讯          ← Phase 1 完成后可以开始（native 先行）
Phase 4: 分布式协作        ← Phase 3 完成后
```

### 里程碑

| 里程碑 | 依赖 | 预期 |
|--------|------|------|
| M1: Platform trait 定义 | 无 | Phase 1.1 |
| M2: Native 实现 + 迁移 | M1 | Phase 1.2-1.3 |
| M3: cub-to-cub 协议设计 | 无 | Phase 3.1 |
| M4: WebSocket P2P (native) | M2 + M3 | Phase 3.2 |
| M5: 网络任务分发 | M4 | Phase 4.2 |
| M6: Browser 实现 | M2 + async#233 | Phase 2 |
| M7: WebRTC P2P (browser) | M6 | Phase 3.2 |
| M8: 完整分布式网络 | M5 + M7 | Phase 4 |

---

cub 的定位：**分布式 AI agent 网络的节点**，而非单机应用。
