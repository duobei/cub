# Postmortem: Orphan tool_result (API 400)

**Date:** 2026-02-23
**Severity:** P1 — blocks all multi-turn tool use in affected session
**Symptom:** `API error (400): invalid params, tool result's tool id(call_function_kdh3yhh4itco_1) not found`

## Timeline

1. User sends message via Telegram → model calls `fs_write` with large HTML/CSS content
2. Tool executes (with fallback empty args), result stored in tape
3. User sends next message → cub rebuilds message history from tape → MiniMax returns 400
4. Auto-recovery handoff fires, retries — same 400 (bad entry survives compaction if after anchor)

## Root Cause

Streaming truncation + write-read asymmetry across paired tape entries.

### Chain of events

**1. Model output truncated during streaming**

MiniMax streams `fs_write` tool call. The `arguments` field is 2430 bytes of JSON containing an entire Astro page (HTML + CSS). Streaming is cut off mid-string — the JSON has no closing `"` or `}`:

```json
{"content": "---\nimport Layout from '../../layouts/Layout.astro';\n... line-height:
```

**2. `run_tools` stores bad data to tape**

```
@json.parse(arguments)  → fails (unterminated string)
  catch → fallback to empty {}
    → tool executes with {} → returns "Error: missing path"
      → tape stores BOTH entries:
          tool_call  { id: "call_X", arguments: "<truncated>" }
          tool_result { tool_call_id: "call_X", content: "Error: ..." }
```

The tool_call entry retains the *original* truncated arguments verbatim.

**3. `select_messages` filters asymmetrically on read**

Next API call rebuilds messages from tape:

```
tool_call entry:
  → normalize_tool_calls → validate_tool_call
    → @json.parse(arguments) → FAILS → call FILTERED OUT
    → assistant message built WITHOUT this call (or not built at all)

tool_result entry:
  → tool_call_id = "call_X" → message built with this id
  → but no assistant message contains "call_X"
  → API sees orphan tool_call_id → 400
```

```
Write path:  tool_call(bad args) + tool_result(id=X)  ← both stored
Read path:   tool_call → REJECT   tool_result(id=X) → EMIT  ← orphan!
```

## Why it wasn't caught earlier

- Normal tool calls have valid JSON arguments — `validate_tool_call` always passes
- Only triggers when model output is truncated (long content + token limit)
- Only manifests on the *next* turn — the turn that wrote the bad entry succeeds fine
- The tool_call_id pairing *looks correct* when inspecting the tape entries in isolation

## Fix

`src/tape/context.mbt` — couple tool_result lifetime to tool_call acceptance:

```moonbit
// Before: tool_results emitted regardless of assistant message
match pending_assistant_msg {
    Some(msg) => messages.push(msg)
    None => ()                          // ← no break
}
append_tool_result_entry(...)           // ← always runs

// After: no assistant message → drop results too
match pending_assistant_msg {
    Some(msg) => {
        messages.push(msg)
        append_tool_result_entry(...)   // ← only with assistant
    }
    None => ()                          // ← results also dropped
}
```

Additionally, `append_tool_result_entry` now filters individual results by `tool_call_id` against accepted calls — handles the case where *some* calls in a batch are valid and others aren't.

Two tests added covering both scenarios (all-filtered and partial-filtered).

## Lesson

When write-path is lenient and read-path is strict, ensure filtering is **symmetric** across paired entries. The tape stored tool_call and tool_result as independent entries, but the API requires them to be a matched pair. The read path must enforce the same pairing.
