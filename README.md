# ServerFoundationModels

A drop-in, open-source re-implementation of Apple's **FoundationModels** framework
(macOS/iOS 27 SDK surface) that runs anywhere Swift runs — including Linux.
Switching is one import line:

```diff
- import FoundationModels
+ import ServerFoundationModels
```

Apple's on-device model doesn't exist off Apple platforms, so the built-in
`ChatCompletionsLanguageModel` drives any OpenAI-compatible endpoint instead
(Ollama, vLLM, llama-server, LM Studio, OpenRouter, ...), and the SDK 27
`LanguageModel` / `LanguageModelExecutor` protocols let any third-party model
package plug in — exactly as they do against Apple's framework.

```swift
import ServerFoundationModels

let model = ChatCompletionsLanguageModel(
    name: "qwen3.5:9b",
    url: URL(string: "http://localhost:11434")!
)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "How many folds make a paper crane?")
```

## Proof of parity: one test suite, two libraries

The test suite is the contract. `TestScenarios/ParityScenarios.swift` is a single
source file compiled into **two** test targets via symlink — identical test code,
identical assertions, only the import differs:

| Target | Imports | Local model under test |
|---|---|---|
| `AppleFoundationModelsParityTests` | `FoundationModels` (Apple) | Apple on-device `SystemLanguageModel` |
| `ServerFoundationModelsParityTests` | `ServerFoundationModels` (this package) | `qwen3.5:9b` via Ollama |

Scenarios assert library behavior — transcript entry sequences, structured output
decoding, schema (`anyOf`, typed properties) enforcement, the tool-call loop
(`toolCalls`/`toolOutput` entries), cumulative streaming snapshots, transcript
continuation — never exact model strings.

```sh
# Apple oracle (macOS 27 + Xcode beta, Apple Intelligence enabled)
swift test --filter AppleFoundationModelsParityTests

# This library (any platform, local model server running)
swift test --filter ServerFoundationModelsParityTests
```

Both currently pass 14/14. The Apple run defines correct behavior; this library
must match it, test for test.

Environment overrides for the ServerFoundationModels side: `PARITY_BASE_URL` (default
`http://localhost:11434`), `PARITY_MODEL` (default `qwen3.5:9b`).

> Note: if the checkout lives in an iCloud-synced folder (Desktop/Documents),
> build outside it — `swift test --scratch-path /tmp/server-foundation-models-build` —
> or codesign fails on the file-provider metadata iCloud stamps onto bundles.

## Ground truth

`reference/FoundationModels-macOS27.swiftinterface` — the full public interface
of Apple's framework from the macOS 27 SDK (~600 declarations). It is the parity
spec; the design document lives in `docs/superpowers/specs/`.

## Status

Implemented and parity-tested (46 scenario runs, both libraries, same
on-device model): `LanguageModelSession` (respond / typed
`respond(generating:)` / stream / tools / transcript / profiles),
`@Generable`/`@Guide` macros for structs and String-raw enums with
recursion-safe inline schemas (`$defs` only where genuinely recursive — no
dangling `$ref`s), `GeneratedContent`, `GenerationSchema` +
`DynamicGenerationSchema` + `GenerationGuide`, `Transcript`,
`Prompt`/`Instructions` builders, `DynamicInstructions` DSL,
`LanguageModelSession.DynamicProfile` + `Profile` + modifiers
(`.model/.temperature/.historyTransform/...`), `SystemLanguageModel`
(bridged to Apple's on-device model on Apple platforms),
`ChatCompletionsLanguageModel`, `ImageReference`/`Attachment` types, and
`PrivateCloudComputeLanguageModel` (source parity).

Proven against real third-party model packages: Anthropic's
[ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels)
builds against ServerFoundationModels with only the import swapped, and its entire
unit test suite (78 tests — event translation, request building, error
mapping, executor behavior) passes unmodified. The public executor surface
this exercises: entry-addressed channel events (Response/Reasoning/ToolCalls
with append/replace/update actions), `LanguageModelCapabilities` capability
sets, Apple's full `LanguageModelError` taxonomy, `GenerationSchema`
Codable, sampling/tool-calling modes, reasoning signatures and metadata,
and session/response `usage`.

Next: attachment delivery to executors (multimodal requests), session
properties (`@SessionPropertyEntry`), executor caching per configuration,
Linux CI (PARITY_BACKEND=chat-completions path), and an interface-diff gate
against `reference/FoundationModels-macOS27.swiftinterface`.
