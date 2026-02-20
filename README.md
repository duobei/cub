# Cub

> Cub it. Build it.

Cub is a native coding agent CLI written in [MoonBit](https://www.moonbitlang.com/), inspired by and paying tribute to [Bub](https://github.com/psiace/bub).

Where Bub pioneered the tape-first, anchor-driven agent architecture in Python, Cub carries that vision forward as a native reimplementation — faster startup, single binary, zero runtime dependencies.

## Design

Inherited from Bub's philosophy:

1. **Append-only tape** — all context is a linear, inspectable log. No hidden state.
2. **Anchor & handoff** — explicit stage transitions instead of implicit branching.
3. **Strict command boundary** — only lines starting with `,` are commands.
4. **Unified routing** — the same model routes both user input and assistant output.

## Quick Start

```bash
moon build --target native
cp env.example .env
# edit .env with your API key
./target/main
```

Minimal `.env`:

```bash
CUB_MODEL=openrouter:qwen/qwen3-coder-next
OPENROUTER_API_KEY=your_key_here
```

## Build

```bash
moon check --target native   # type check
moon build --target native   # build binary
```

## Acknowledgments

Cub would not exist without [Bub](https://github.com/psiace/bub) by [@psiace](https://github.com/psiace). The architecture, the design philosophy, and the "tape-first" insight all originate from Bub and its underlying [republic](https://github.com/psiace/bub) framework. Thank you for showing that a coding agent can be predictable, inspectable, and recoverable.

## License

[Apache 2.0](./LICENSE)
