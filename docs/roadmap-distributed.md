# Cub 分布式路线图：从单体到集群

> "减少假设，提供最小能力，让行为涌现。"

## 愿景

把 cub 从单机 agent 演进为去中心化集群：

1. **跨平台运行** — 服务器、桌面、浏览器，任何环境都能存活
2. **集群协作** — 多个 cub 通过 P2P 互联，视为一个整体
3. **自主治理** — 集群成员自行协商扩缩、合并、进化
4. **能力涌现** — 只提供原语，协作策略和专长分化由 LLM 驱动

**不是"生物繁殖"，是"去中心化分布式系统"** — 单体和集群只是规模不同，本质一样。

---

## 当前架构

### I/O 分层

```
Layer 3 — 平台 I/O
  src/platform/ — facade 封装 @fs/@http/@websocket/@process
  全部依赖 moonbitlang/async，仅支持 native target

Layer 2 — 服务抽象
  AppRuntime, TapeService, ToolRegistry, ChannelManager, McpClient

Layer 1 — 纯计算（可移植）
  core/ — Router, AgentLoop, ModelRunner, CommandDetector
  tape/types, tools/types, llm/types, log/, skills/
```

### 已完成

| 组件 | 状态 |
|------|------|
| platform/ I/O 抽象 | done — facade 模式，21 个文件已迁移 |
| genome/ 格式 | done — identity.md + skills/ + manifest.json + cost.json |
| cost.balance | done — token 用量跟踪 + 格式化输出 |
| P2P WebSocket 传输 | done — server/client, JSON 信封协议 |
| HMAC-SHA256 签名 | done — 纯 MoonBit SHA-256 + HMAC, 消息认证 |
| 连接去重 | done — 确定性规则，每对 peer 仅一条连接 |
| P2P 集成测试 | done — 5 个 async 测试覆盖握手/拒绝/去重/消息 |

### 阻塞因素

- `moonbitlang/async` 只支持 native target（issue #233）
- WASM/JS target 编译可过但运行时 abort()

---

## Phase 1：单体能力完善

**目标**：一个 cub 能自主运作，具备自我认知和学习能力。

### 已完成

- Tape 系统 — 追加式记忆，锚点上下文管理
- Skill 系统 — 三级发现，LLM 结晶，自动创建
- Genome — 统一知识表示，迁移工具
- Cost tracking — token 消耗追踪
- 多 Channel — Discord, Telegram, CLI, MCP
- 上下文保持 — thin-context hint, reset 摘要, auto-handoff 修复

### 待做

- [ ] 自主目标设定 — cub 在空闲时主动研究和学习
- [ ] 健康自检 — 能力清单、状态报告

---

## Phase 2：简单协作（2-3 个 Cub）

**目标**：少量 cub 点对点互联，共享知识，分发任务。

### 已完成

- P2P 消息协议 — JSON 信封 `{from, to, type, payload, ts, hmac}`
- WebSocket 传输 — server + client，指数退避重连
- 身份认证 — genome ID 交换 + HMAC-SHA256 签名
- 连接去重 — 字典序规则，自动合并双向连接
- 手动发现 — `CUB_P2P_PEERS` 地址列表

### 待做

- [ ] **skill 同步** — 集群成员之间交换 skill，LLM 决定是否采纳
- [ ] **任务委派** — 一个 cub 把子任务发给更适合的 peer
- [ ] **peer.list 工具** — 注册为 tape tool，LLM 可查询在线 peer
- [ ] **mDNS 本地发现** — 局域网内自动发现，无需手动配置

### 消息协议

```json
{
  "from": "cub-id",
  "to": "cub-id",
  "type": "string",       // 自由定义，不枚举
  "payload": { ... },     // 任意 JSON
  "ts": 1709016600000,
  "hmac": "hex-string"    // HMAC-SHA256(secret, body_without_hmac)
}
```

cub 用 LLM 自行决定发什么消息、如何响应。我们只保证消息能送达。

---

## Phase 3：DHT 集群

**目标**：大规模 cub 网络，去中心化发现和通信。

### DHT 作为集群"神经系统"

- **服务发现** — Kademlia 路由，O(log N) 查找
- **成员通信** — 通过 DHT 路由消息
- **知识同步** — 分布式 skill/genome 传播

### 前置条件

- [ ] Ed25519 签名（纯 MoonBit，~2000 行）
- [ ] 大整数 XOR 距离计算
- [ ] UDP NAT 穿透（STUN/hole punching）或中继

### 任务

- [ ] 简化版 Kademlia — k-bucket 路由表、迭代节点查找
- [ ] UDP 发现层 — moonbitlang/async 已有 UDP 支持
- [ ] WebSocket 保持为数据通道，DHT 只做 peer 发现

### DHT 局限

| 问题 | 影响 |
|------|------|
| 最终一致 | 非强一致，可能短暂不一致 |
| 查找延迟 | 每步有网络延迟 |
| NAT 穿透 | 防火墙后节点难以直连 |
| 分区风险 | 网络分裂时可能失联 |

**优先级**：低 — 当前 2-10 节点规模用手动配置足够，DHT 在 >50 节点时才有意义。

---

## Phase 4：浏览器运行

**前提**：moonbitlang/async 支持 wasm/js target（跟踪 issue #233）

### Browser 平台实现

| 能力 | 浏览器实现 |
|------|-----------|
| Storage | IndexedDB + OPFS |
| HttpClient | fetch() API |
| Executor | 不支持 |
| P2P | WebRTC DataChannel（需 signaling server） |

### 功能裁剪

保留：LLM 对话、Tape 持久化、Skill 系统、Web 工具
不支持：bash 执行、MCP server/client、文件系统工具

---

## Phase 5：集群治理

**目标**：集群具备自主治理能力，以下行为全部由 LLM 驱动涌现。

### 最小原语集

| # | 原语 | 说明 | 状态 |
|---|------|------|------|
| 1 | `genome/` 格式 | 统一知识表示：identity + skills + manifest | done |
| 2 | P2P transport | cub 之间的消息通道（WebSocket + HMAC） | done |
| 3 | `cost.balance` | 跟踪自身资源消耗（token、算力） | done |
| 4 | `peer.list` | 发现和列出网络中的其他 cub | todo |
| 5 | `cluster.scale(n)` | 启动 n 个新 cub 实例，复制 genome | todo |
| 6 | `cluster.consolidate(peers)` | 收集 peer 的 genome，LLM 融合为一 | todo |
| 7 | `genome.migrate(target)` | 将 genome 迁移到另一个主机/环境 | todo |

### Genome 格式

```
.cub/genome/
  ├─ identity.md          身份、偏好、人格
  ├─ skills/              结晶后的技能
  ├─ pending.json         未结晶的经验
  ├─ skill_stats.json     技能使用统计
  ├─ cost.json            资源消耗记录
  └─ manifest.json        元数据：id, generation, parents, born, lineage
```

迁移 = `cp -r .cub/genome/`。整个知识包 < 1MB。

### 不设计的部分

以下行为我们**不写代码**，cub 用已有能力（LLM + genome + P2P）自然涌现：

- **任务分发与协作** — cub 能通讯就能自己协商分工
- **专长分化** — 不同环境自然产生不同 skills
- **治理策略** — 扩缩、合并、投票，让 cub 自己谈
- **经济行为** — 有 cost.balance 就能自己算账
- **安全隔离** — 断粮即隔离，不需要治理协议
- **知识选择** — cub 有 LLM 就能判断哪个 skill 值得采纳

---

## 里程碑

```
Phase 1: 单体完善          ✓ done
Phase 2: 简单协作          ◐ P2P + HMAC done, skill 同步/任务委派 todo
Phase 3: DHT 集群          ○ 未来，>50 节点时再做
Phase 4: 浏览器运行        ○ 等 moonbitlang/async wasm 支持
Phase 5: 集群治理          ○ 7 个原语，已完成 3 个
```

### 设计哲学

```
减少假设，提供最小能力，让行为涌现。

我们建造的：7 个原语（genome, transport, cost, peers, scale, consolidate, migrate）
cub 涌现的：协作策略、专长分化、经济行为、治理规则

    ┌───────────────────────────────────────┐
    │                                       │
    ▼                                       │
  单体 → 协作 → 集群 → 治理 → 进化 ────────┘
  (unit)  (P2P)  (DHT)  (LLM-driven)
```

---

cub 的定位：**去中心化分布式 AI agent** — 提供最小能力原语，让集体智能自然涌现。
