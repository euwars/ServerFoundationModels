# apple/foundation-models-utilities compatibility

Proof run, 2026-06-12: the upstream package builds against LinuxFoundation
with `import FoundationModels` → `import LinuxFoundation` (plus the new
`FoundationModels::` module-selector spellings), and its complete test
suite — Skills, history modifiers (rolling window, summarize, drop completed
tool calls), chat-completions request/SSE/error/usage handling — passes:
**92/92**.

Live integration: its `ChatCompletionsLanguageModel`, driven by
LinuxFoundation's `LanguageModelSession`, against vLLM (`qwen3-moe`,
Qwen3-30B-A3B) at `http://10.0.0.200:8000/v1` — the package's own Live test
passes:

```sh
FMU_TEST_ENDPOINT=http://10.0.0.200:8000/v1 FMU_TEST_MODEL=qwen3-moe \
  swift test --filter ChatCompletionsTests.Live
```

The LinuxFoundation parity suite also runs against that endpoint
(`PARITY_BACKEND=chat-completions PARITY_BASE_URL=http://10.0.0.200:8000
PARITY_MODEL=qwen3-moe`): **41/41** after enabling the server's tool parser
(vllm 0.22.1, restarted with `--enable-auto-tool-choice --tool-call-parser
hermes`; full command in ~/vllm-tools.log's header on the host). Every
behavior scenario — tool loop, structured output, recursive schemas, typed
streaming, session properties, dynamic profiles — holds against a remote
open model, not just Apple's on-device one.

## Semantics this exercise locked in (now load-bearing in LinuxFoundation)

- Dynamic profiles re-resolve **every generation round**, so tools that
  mutate state mid-loop (skill activation) refresh the next request's
  instructions; `onPrompt` fires once per prompt.
- Profile results **persist into the stored transcript**: the refreshed
  instructions entry (carrying active tool definitions) is entry zero, and
  history modifications survive across turns.
- History modifiers work by rewriting `@SessionProperty(\.history)` inside
  `onPrompt` callbacks; callbacks run with the session's properties bound
  task-locally and the session adopts the rewritten history.
- DynamicInstructions text concatenates with **no implicit separator**;
  authors add explicit newlines.
- Streamed `updateUsage` events are running totals: latest report per round
  wins; rounds sum per turn.
- Tools declared inline in DynamicInstructions bodies
  (`DynamicInstructionsBuilder.buildExpression<T: Tool>`) register for the
  request.

## Upstream bugs found (reproduce against Apple's framework too)

1. `ChatCompletionsLanguageModel` always encodes `"tools"` — an empty array
   when no tools are enabled. vLLM rejects `"tools": []` (400). Fix: omit
   the field when empty.
2. It always encodes `"tool_choice"`, which vLLM rejects when `tools` is
   absent. Fix: omit `tool_choice` when no tools are enabled.

Both patched in the local proof checkout (`/tmp/fmu-lf`); worth reporting
upstream.

## Known cross-import note

LinuxFoundation ships its own `ChatCompletionsLanguageModel` (so Linux works
without extra packages). Code importing both modules disambiguates with a
typealias or module selector.
