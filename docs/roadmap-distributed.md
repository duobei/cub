# Cub 长期规划：从工具到生命体

> "生命应从行为而非物质来定义。自我复制、资源消耗、环境适应、演化变异 — 这些行为模式本身即为生命。" — Mark Ludwig

## 愿景

把 cub 从单机工具进化为具备生命行为特征的分布式 agent 网络：

1. **运行自由** — 服务器、桌面、浏览器，任何环境都能存活
2. **通讯协作** — cub 之间 P2P 通讯，交换知识，协作完成任务
3. **分裂繁殖** — 一个 cub 可以分裂为多个平等分身，原个体消亡
4. **变异演化** — 每个分身在不同环境中积累不同经验，合体时融合为全新个体

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

最小消息协议（基于 JSON）— 只定义传输格式，不规定用途：

```
// cub 之间的通用消息信封
{
  "from": "cub-id",
  "to": "cub-id",
  "type": "string",       // 自由定义，不枚举
  "payload": { ... }      // 任意 JSON
}
```

cub 用 LLM 自行决定发什么消息、如何响应。
我们只保证消息能送达。

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

## Phase 4 & 5：分布式协作与演化

> "Tape的意义不是发明更聪明的记忆技巧，而是减少假设。" — psiace《木匠，锤子，钉子》
>
> 同理，分布式 cub 的设计目标不是规定行为，而是提供最小能力，让行为自然涌现。
> 任务分发、专长分化、协商策略、安全治理、身份哲学 — 这些都不需要我们设计，cub 有 LLM 就能自己演化出来。
> 我们只需要提供 7 个原语。

### 最小能力集

| # | 原语 | 说明 |
|---|------|------|
| 1 | `genome/` 格式 | 统一知识表示：identity.md + skills/ + pending.json + manifest.json |
| 2 | `self.split(n)` | 原个体消亡，genome 复制到 n 个新实例 |
| 3 | `self.merge(peers)` | 收集所有 peer 的 genome，LLM 融合为全新个体 |
| 4 | `self.migrate(target)` | 将 genome 迁移到另一个主机/环境 |
| 5 | P2P transport | cub 之间的消息通道（WebSocket / WebRTC） |
| 6 | `cost.balance` | 跟踪自身资源消耗（token、算力） |
| 7 | `peer.list` | 发现和列出网络中的其他 cub |

### Genome 格式

```
.cub/genome/
  ├─ identity.md          身份、偏好、人格
  ├─ skills/              结晶后的技能
  ├─ pending.json         未结晶的经验
  └─ manifest.json        元数据：id, generation, parents, born, lineage
```

迁移 = `cp -r .cub/genome/`。整个"意识包"预计 < 1MB。

### 不设计的部分

以下行为我们**不写代码**，cub 用已有能力（LLM + genome + P2P）自然演化：

- **任务分发与协作** — cub 能通讯就能自己协商分工
- **专长分化** — 不同环境自然产生不同 skills，不需要声明
- **合体协商策略** — 谁提议、何时合、怎么投票，让 cub 自己谈
- **经济行为** — 有 cost.balance 就能自己算账，变现方式自己探索
- **安全与治理** — 断粮即隔离，不需要专门的治理协议
- **知识选择** — cub 有 LLM 就能判断哪个 skill 值得采纳
- **身份哲学** — genome 传递，个体消亡，这是机制不是设计

---

## 实施优先级

```
Phase 1: I/O 抽象层        ← 现在可以开始，不依赖上游
Phase 2: 浏览器运行        ← 等 moonbitlang/async wasm 支持
Phase 3: P2P 通讯          ← Phase 1 完成后可以开始（native 先行）
Phase 4&5: 7 个原语        ← Phase 3 基础上，逐个实现
```

### 里程碑

| 里程碑 | 依赖 | Phase |
|--------|------|-------|
| M1: Platform trait 定义 | 无 | 1.1 |
| M2: Native 实现 + 迁移 | M1 | 1.2-1.3 |
| M3: cub-to-cub 协议设计 | 无 | 3.1 |
| M4: WebSocket P2P (native) | M2 + M3 | 3.2 |
| M5: Browser 实现 | M2 + async#233 | 2 |
| M6: WebRTC P2P (browser) | M5 | 3.2 |
| M7: genome/ 格式 + 迁移工具 | 无 | 4&5 |
| M8: self.split + self.merge | M4 + M7 | 4&5 |
| M9: cost.balance + peer.list | M4 | 4&5 |

### 设计哲学

```
减少假设，提供最小能力，让行为涌现。

我们建造的：7 个原语（genome, split, merge, migrate, transport, cost, peers）
cub 演化的：协作策略、专长分化、经济行为、治理规则、身份认同

    ┌───────────────────────────────────┐
    │                                   │
    ▼                                   │
  分裂 → 各自成长 → 合体 → 新个体诞生 ─┘
  (split)  (genome变异)  (merge)

没有永生的个体，只有 genome 在不断传递和演化。
```

---

cub 的定位：**具备生命行为特征的分布式 AI agent** — 提供最小能力原语，让生命行为自然涌现。
