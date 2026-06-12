# LinuxFoundation

A drop-in, open-source re-implementation of Apple's **FoundationModels** framework
(macOS/iOS 27 SDK surface) that runs anywhere Swift runs — including Linux.
Switching is one import line:

```diff
- import FoundationModels
+ import LinuxFoundation
```

Apple's on-device model doesn't exist off Apple platforms, so the built-in
`ChatCompletionsLanguageModel` drives any OpenAI-compatible endpoint instead
(Ollama, vLLM, llama-server, LM Studio, OpenRouter, ...), and the SDK 27
`LanguageModel` / `LanguageModelExecutor` protocols let any third-party model
package plug in — exactly as they do against Apple's framework.

```swift
import LinuxFoundation

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
| `LinuxFoundationParityTests` | `LinuxFoundation` (this package) | `qwen3.5:9b` via Ollama |

Scenarios assert library behavior — transcript entry sequences, structured output
decoding, schema (`anyOf`, typed properties) enforcement, the tool-call loop
(`toolCalls`/`toolOutput` entries), cumulative streaming snapshots, transcript
continuation — never exact model strings.

```sh
# Apple oracle (macOS 27 + Xcode beta, Apple Intelligence enabled)
swift test --filter AppleFoundationModelsParityTests

# This library (any platform, local model server running)
swift test --filter LinuxFoundationParityTests
```

Both currently pass 14/14. The Apple run defines correct behavior; this library
must match it, test for test.

Environment overrides for the LinuxFoundation side: `PARITY_BASE_URL` (default
`http://localhost:11434`), `PARITY_MODEL` (default `qwen3.5:9b`).

> Note: if the checkout lives in an iCloud-synced folder (Desktop/Documents),
> build outside it — `swift test --scratch-path /tmp/linuxfoundation-build` —
> or codesign fails on the file-provider metadata iCloud stamps onto bundles.

## Ground truth

`reference/FoundationModels-macOS27.swiftinterface` — the full public interface
of Apple's framework from the macOS 27 SDK (~600 declarations). It is the parity
spec; the design document lives in `docs/superpowers/specs/`.

## Status

Early. Implemented and parity-tested so far: `LanguageModelSession`
(respond/stream/tools/transcript), `GeneratedContent`, `GenerationSchema` +
`DynamicGenerationSchema`, `Transcript`, `Prompt`/`Instructions` builders, the
SDK 27 `LanguageModel`/`LanguageModelExecutor` contract, and
`ChatCompletionsLanguageModel`. Next: the `@Generable`/`@Guide` macro package,
typed `respond(generating:)`, full `GenerationOptions`/capabilities surface,
attachments, `DynamicInstructions`, Linux CI.
