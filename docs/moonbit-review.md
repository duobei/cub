# MoonBit 体验报告：从零构建一个 Coding Agent

## 项目背景

用 MoonBit 重写了一个 tape-first coding agent（cub），原项目 bub 是 Python 实现。最终产出：单二进制文件，13 个包，Discord/Telegram 集成，MCP 协议，WASM 插件系统，255 个单元测试，零 C FFI。

## 好的部分

**模式匹配是一等公民。** JSON 解析几乎不需要额外库，直接对 `Json` 类型做嵌套匹配：

```moonbit
match json {
  { "choices": [{ "delta": { "content": String(c), .. }, .. }, ..], .. } =>
    process(c)
  _ => ()
}
```

这种写法比 Python 的 `json["choices"][0]["delta"].get("content", "")` 加一堆 try/except 干净很多。`..` 通配忽略无关字段，编译器保证类型安全。

**枚举 + 结构体的表达力。** `pub(all) enum` 和 `struct` 的组合用起来很自然，derive 支持 `Show`、`Eq`、`Compare` 等常用 trait，减少了大量样板代码。

**`moon test` 体验好。** snapshot 测试（`inspect()`）是默认方式，第一次运行自动生成期望值，后续 diff 对比。写测试基本上就是 `inspect(f(x), content="expected")`，简洁。

**编译速度。** 增量编译几乎瞬间完成。`moon check --deny-warn` 能在亚秒级给出类型检查结果，开发循环很快。

**`moonbitlang/async` 做到了 zero FFI。** 文件系统、HTTP、进程、socket、stdio 全部用纯 MoonBit 实现的异步运行时，没有一行 C 绑定。对于 native 后端来说，这个库的完成度已经足够支撑一个完整的网络应用。

## 痛点

### 语法陷阱

**整数字面量与方法调用冲突。** `1.to_json()` 被解析为 `(1.0).to_json()`（浮点数），必须写 `(1).to_json()` 或提取到变量。这个坑踩过多次，编译器不报错，运行时才发现数据不对。

**字符串插值的限制。** `"\{expr}"` 内不能包含 `"`、`{`、`\` 字符。像 `"\{arr.join(", ")}"` 会编译失败，必须先 `let s = arr.join(", ")` 再 `"\{s}"`。对于复杂表达式这个限制频繁碰到。

**`String.replace` 只替换第一个匹配。** 没有 `replace_all`，写 HTML escape 时 `<` 只转义了第一个。需要自己写循环逐字符替换。

**`Json` 构造器是只读的。** 不能写 `Json::Null` 或 `Json::Array(items)`，得用 `@json.parse("null")` 或 `items.to_json()`。文档没有提及这个限制，只能靠编译错误发现。

**`method` 是保留字。** 用 JSON-RPC 时想用 `method` 做字段名，编译不过。要换成 `rpc_method` 之类的名字。

### 测试体系

**`_test.mbt` 是黑盒测试。** 只能访问 `pub` 的内容，不能 `pub(all)` 的 struct 也不能在测试里构造。如果想测试内部逻辑，要么把函数改成 `pub`（污染 API），要么放弃测试。没有白盒测试选项。

**`is-main: true` 的包不能有测试文件。** main 包里的辅助函数（parse_cli_args、extract_channel_id 等）完全无法被单元测试覆盖，除非重构到单独的包里。

**`async fn` 做 handler 但不做 async 操作会报 `unused_async` 警告。** 测试里经常需要 `handler=fn(_args) { "ok" }` 这种 mock，如果类型签名要求 `async`，就需要确认 MoonBit 是否允许非 async 函数自动提升（实测可以，但文档没提）。

### 工具链

**`moon fmt` 强制 `///|` 注释。** 每个 `pub fn`、`struct`、`enum`、`test` 前面都必须有 `///|` 标记，否则 format check 失败。初期不知道这个规则，批量修复了很多文件。

**错误信息偶尔不够精确。** 类型不匹配时，如果涉及泛型或闭包，错误信息指向的位置有时不是真正出错的地方。

**没有 LSP 级别的 rename/refactor 支持。** 重命名一个被多处引用的函数只能靠全局搜索替换。

### 生态

**只有 native target 可用。** `moonbitlang/async` 是唯一可用的 I/O 库，但它只支持 native。wasm/wasm-gc/js target 编译可过但运行时无法工作。这意味着 MoonBit 目前不适合写需要跨平台的库。

**标准库偏薄。** 没有正则表达式，没有 URL 解析，没有 base64（需要自己写或找社区包）。JSON 支持内建但构造 API 不直观（如上述只读构造器问题）。

**社区包数量有限。** 遇到问题基本只能看源码和自己摸索，Stack Overflow 和社区论坛几乎找不到答案。

## 最希望改进的点

**1. JSON 构造 API。** 这是日常开发中最高频的痛点。目前构造一个 JSON 对象要写：

```moonbit
let m : Map[String, Json] = {}
m["key"] = "value".to_json()
m["count"] = (1).to_json()  // 不能写 1.to_json()
Json::object(m)
```

希望能有字面量语法，或者至少让 `Json::Null`、`Json::Array()` 可以直接构造，不用绕 `@json.parse("null")`。

**2. 白盒测试。** 当前 `_test.mbt` 只能做黑盒测试，测不到 `pub` 以下的函数。为了测试不得不把内部函数改成 `pub`，污染了模块 API。希望有类似 Rust `#[cfg(test)]` 的机制，或者允许同包内的测试文件访问私有成员。

**3. `String` 补全。** `replace_all`、`contains` 返回位置、正则支持 — 现在做字符串处理经常要自己写循环。`String.replace` 只替换第一个匹配是个反直觉的默认行为。

**4. main 包可测试。** `is-main: true` 的包不能放 `_test.mbt`，意味着 CLI 解析、参数校验这些逻辑要么拆包要么放弃测试。希望 main 包也能有测试。

**5. 错误信息带上下文。** 类型不匹配涉及闭包/泛型时，报错位置经常偏移。尤其是 `async fn` 作为参数传递时，错误指向调用处而不是闭包体内实际出错的位置。

## 比较好的实践

**1. 用 `inspect()` 做断言而不是 assert。** snapshot 测试是 MoonBit 的强项，第一次跑自动生成期望值，之后 diff 检测回归。比手写 assert 快很多：

```moonbit
test "router resolves alias" {
  inspect(@core.resolve_internal_name("tool"), content="tool.describe")
  inspect(@core.resolve_internal_name("unknown"), content="unknown")
}
```

**2. 模式匹配优先于字段访问。** 处理 JSON 时不要用 `.get()` 链，直接用嵌套模式匹配 + `..` 通配。编译器会保证分支覆盖：

```moonbit
// 好
match json {
  { "choices": [{ "message": { "content": String(c), .. }, .. }, ..], .. } => c
  _ => ""
}

// 不好
json["choices"].as_array()[0]["message"]["content"].as_string()
```

**3. `fn` 自动提升为 `async fn`。** 当类型签名要求 `async (Json) -> String` 时，传 `fn(_args) { "ok" }` 也能编译通过。利用这个特性写测试 mock 可以避免 `unused_async` 警告，不需要真的做 async 操作。

**4. `--deny-warn` 从第一天就开。** 把 `moon check --target native --deny-warn` 放进 CI。MoonBit 的 warning 经常指向真实问题（unused import、unused async、unreachable pattern），deny-warn 强制处理这些问题不会累积成技术债。

**5. 把字符串插值的复杂表达式提取到变量。** 养成习惯，避免在 `"\{...}"` 里写含 `"`、`{`、`\` 的表达式：

```moonbit
// 好
let names = missing.join(", ")
"missing fields: \{names}"

// 编译失败
"missing fields: \{missing.join(\", \")}"
```

**6. 用 `pub(all)` 还是 `pub` 要想清楚。** `pub enum` 外部只能匹配不能构造，`pub(all) enum` 外部可以构造。如果是纯内部类型对外只暴露函数，用 `pub`；如果外部需要创建实例（比如配置、消息类型），用 `pub(all)`。

**7. 一个包一个职责，但不要过度拆分。** cub 有 13 个包，每个包 1-4 个文件。粒度太细会导致循环依赖问题（MoonBit 不允许循环 import），太粗又失去封装。按"谁依赖谁"画 DAG，保持单向依赖。

## 与 Python（bub）的对比

| 维度 | Python (bub) | MoonBit (cub) |
|------|-------------|---------------|
| 启动时间 | ~200ms（含依赖加载） | <10ms |
| 二进制分发 | 需要 Python + venv | 单文件 6MB |
| 内存占用 | ~50MB | ~6MB |
| 类型安全 | 运行时发现 | 编译时发现 |
| JSON 处理 | 字典操作，简洁但脆弱 | 模式匹配，冗长但安全 |
| 异步 | asyncio，生态成熟 | moonbitlang/async，功能够用 |
| 开发速度 | 快，但调试多 | 慢，但运行时错误少 |
| 生态 | pip install 万物 | 基本靠自己写 |

## 总结

MoonBit 作为一门年轻语言，在类型系统、模式匹配、编译速度上已经达到了生产可用的水平。native 后端的性能和资源占用明显优于 Python。但语法陷阱多（整数字面量、字符串插值、只读构造器），测试体系有结构性限制（黑盒-only、main 包不可测），标准库和生态还在早期阶段。

适合的场景：对启动速度/内存敏感的 CLI 工具、需要单二进制分发的后端服务、愿意接受"自己造轮子"的项目。

不适合的场景：需要跨平台 target（wasm/js）的项目、需要丰富第三方库的项目、团队不愿意踩坑的生产环境。
