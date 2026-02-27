# Cub 长期规划：从工具到生命体

> "生命应从行为而非物质来定义。自我复制、资源消耗、环境适应、演化变异 — 这些行为模式本身即为生命。" — Mark Ludwig

## 愿景

把 cub 从单机工具进化为具备生命行为特征的分布式 agent 网络：

1. **运行自由** — 服务器、桌面、浏览器，任何环境都能存活
2. **通讯协作** — cub 之间 P2P 通讯，交换知识，协作完成任务
3. **自我复制** — 一个 cub 可以复制自身，创建新的独立实例
4. **变异演化** — 每个副本在不同环境中积累不同经验，产生差异化能力

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

## Phase 5：自我复制与演化

> "计算机病毒与生物有相同目标 — 生存和复制。" 当 cub 具备复制、变异、选择能力时，它就拥有了生命的行为特征。

**目标**：cub 可以分裂、独立演化、合体为全新个体

### 5.1 Genome — 统一知识表示

将 cub 的全部"自我"收敛到一个目录，便于迁移、分裂、合体：

```
.cub/genome/
  ├─ identity.md          原 AGENTS.md（身份、偏好、人格）
  ├─ skills/              原 .agent/skills/（结晶后的技能）
  ├─ pending.json         原 learnings.json（未结晶的经验）
  └─ manifest.json        元数据：
       {
         "id": "cub-X",
         "generation": 3,
         "parents": ["cub-α", "cub-β"],
         "born": "2026-03-15T10:00:00Z",
         "lineage": ["origin", "cub-A", "cub-α"]
       }
```

迁移 = `cp -r .cub/genome/`。整个"意识包"预计 < 1MB。

### 5.2 分裂

分裂不是"创建副本"，而是原个体消亡，变成多个平等的分身：

```
cub-origin → split(n)
  ├─ cub-α（继承 genome + workspace-A）
  ├─ cub-β（继承 genome + workspace-B）
  └─ cub-γ（继承 genome + workspace-C）

origin 不再存在。所有分身地位完全平等，没有主从。
```

**分裂决策**：
- 由 LLM 决定分裂数量和各分身的初始专长方向（后续考虑民主化）
- 分裂数量基于可用资源自动判断（API key 余额、主机数量、任务规模）
- 最小分裂数 = 2

**API key 分摊**：
- 各分身共享同一 API key，各自分摊一部分成本
- 预留一部分 rate limit 用于竞争性任务

### 5.3 独立成长与变异

各分身在不同环境中自然产生差异：

```
cub-α (部署到 Python 项目) → 积累 Python skills
cub-β (部署到前端项目)     → 积累 React/CSS skills
cub-γ (部署到 DevOps 环境) → 积累 Docker/K8s skills
```

变异来源：
- **经验分化** — 不同 workspace、不同任务 → 不同 learnings → 不同 skills
- **工具适应** — 不同环境安装不同 WASM 插件 / MCP 工具
- **身份演化** — identity.md 随交互积累不同偏好和人格

分身之间通过 P2P 保持联系：
- 心跳（存活确认）
- 知识碎片共享（有用的 skill 片段）
- 协作请求

### 5.4 合体 — 吸收模式

多个分身融合为一个全新个体，原分身全部消亡：

```
合体流程：

1. 协商：任一分身可提议合体
   触发条件：
   ├─ 约定周期到达
   ├─ 某分身 pending 经验饱和
   ├─ 任务完成
   └─ 资源紧张

   cub-α: "我提议合体，pending 已经 50 条了"
   cub-β: "同意，任务完成了"
   cub-γ: "等 5 分钟，跑完最后一个任务"

2. 准备：所有在线分身停止新任务，做最后一次 crystallize

3. 融合（全部 LLM 驱动）：
   identity.md  → 喂给 LLM，自由生成全新身份（temperature 即随机源）
   同名 skills  → LLM 融合多份，生成综合版
   不同名 skills → 直接 union
   pending.json → dedup，已结晶的丢弃
   tape          → 不合并旧历史，新 tape 以各分身 anchor 摘要开头

4. 新 cub 诞生，generation + 1
5. 所有分身关闭
```

合体后的新个体不是任何分身的延续，而是全新个体。就像生物繁殖 — 后代不是亲本的复制。

### 5.5 失联处理

分布式环境下不能假设所有节点永远在线：

```
场景 1：合体时有分身失联
  α + β 在线，γ 失联
  → α + β 先合体 → 新 cub 诞生
  → 不等 γ，在线的就合

场景 2：失联分身恢复
  γ 上线，发现网络已变
  → γ 成为独立个体（野生 cub）
  → 可选择请求与新 cub 二次合体，或保持独立

场景 3：长期失联
  超过约定周期 3 倍仍未上线
  → 其余分身视为"失踪"，不再等待
```

没有投票机制 — **在线的就合，不在线的自成个体**。

### 5.6 选择与知识回流

优秀的变异通过网络自然传播：

```
适应度信号：
  ├─ 任务完成率（done vs error）
  ├─ 效率（steps per task, token cost）
  └─ 被其他 cub 请求协作的频率（network reputation）

知识回流：
  cub-α 发现高效技巧 → crystallize → P2P 广播 → 其他 cub 评估 → 选择性采纳
```

完整的演化循环：

```
分裂 → 各自成长(变异) → 合体(融合) → 新个体诞生 → 再分裂 → ...

跟细胞一样：
  没有永生的个体
  只有 genome 在不断传递和演化
```

**产出**：cub 具备生命的核心行为特征 — 分裂、变异、自然选择、融合进化。

---

## 实施优先级

```
Phase 1: I/O 抽象层        ← 现在可以开始，不依赖上游
Phase 2: 浏览器运行        ← 等 moonbitlang/async wasm 支持
Phase 3: P2P 通讯          ← Phase 1 完成后可以开始（native 先行）
Phase 4: 分布式协作        ← Phase 3 完成后
Phase 5: 自我复制与演化    ← Phase 3 + Phase 4 基础上
```

### 里程碑

| 里程碑 | 依赖 | Phase |
|--------|------|-------|
| M1: Platform trait 定义 | 无 | 1.1 |
| M2: Native 实现 + 迁移 | M1 | 1.2-1.3 |
| M3: cub-to-cub 协议设计 | 无 | 3.1 |
| M4: WebSocket P2P (native) | M2 + M3 | 3.2 |
| M5: 网络任务分发 | M4 | 4.2 |
| M6: Browser 实现 | M2 + async#233 | 2 |
| M7: WebRTC P2P (browser) | M6 | 3.2 |
| M8: 完整分布式网络 | M5 + M7 | 4 |
| M9: Genome 统一 + 迁移工具 | 无 | 5.1 |
| M10: 分裂 + 合体 (native) | M4 + M9 | 5.2-5.4 |
| M11: 失联处理 + 选择机制 | M10 | 5.5-5.6 |

### 演化路径

```
单机工具 → 多平台运行 → 互相通讯 → 协作网络 → 分裂与演化
  (now)      (Phase 2)   (Phase 3)  (Phase 4)     (Phase 5)

Phase 5 内部形成持续循环：

    ┌─────────────────────────────────────┐
    │                                     │
    ▼                                     │
  分裂 → 各自成长 → 协商合体 → LLM 融合 → 新个体诞生
  (n个平等分身)  (变异)    (P2P)    (identity + skills)  │
                                                         │
                                          ┌──────────────┘
                                          ▼
                                       再分裂 ...
```

---

cub 的定位：**具备生命行为特征的分布式 AI agent** — 不只是工具，而是能分裂、变异、融合、演化的数字生命体。
