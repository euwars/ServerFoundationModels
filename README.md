# ServerFoundationModels

[![CI](https://github.com/euwars/ServerFoundationModels/actions/workflows/ci.yml/badge.svg)](https://github.com/euwars/ServerFoundationModels/actions/workflows/ci.yml)

A drop-in, open-source re-implementation of Apple's **FoundationModels**
framework (macOS/iOS 27 SDK surface) that runs anywhere Swift runs —
including Linux. Switching is one import line:

```diff
- import FoundationModels
+ import ServerFoundationModels
```

Sessions, `@Generable`/`@Guide` macros, guided generation, tools, streaming,
transcripts, profiles, dynamic instructions — the complete SDK 27 public
API, verified signature-for-signature against Apple's interface.

## Installation

```swift
.package(url: "https://github.com/euwars/ServerFoundationModels.git", from: "0.1.0")
```

For a zero-line switch, alias the module so even the import stays untouched:

```swift
.product(name: "ServerFoundationModels", package: "ServerFoundationModels",
         moduleAliases: ["ServerFoundationModels": "FoundationModels"])
```

The NIO transport (swift-nio + async-http-client) is the default. For a
dependency-light build on URLSession, opt out with `traits: []`.

## Quick start

Apple's on-device model doesn't exist off Apple platforms, so the built-in
`ChatCompletionsLanguageModel` drives any OpenAI-compatible endpoint
(Ollama, vLLM, llama-server, LM Studio, OpenRouter, ...):

```swift
import ServerFoundationModels

let model = ChatCompletionsLanguageModel(
    name: "qwen3.5:9b",
    url: URL(string: "http://localhost:11434")!
)
let session = LanguageModelSession(model: model)
let answer = try await session.respond(to: "How many folds make a paper crane?")
```

Structured output works exactly as on Apple platforms:

```swift
@Generable(description: "A craft project idea")
struct CraftIdea {
    @Guide(description: "Short title for the idea")
    var title: String
    @Guide(.range(15...240))
    var minutes: Int
}

let idea = try await session.respond(to: "Suggest a craft idea.", generating: CraftIdea.self)
```

So do tools, streaming (`session.streamResponse`), transcripts, and
profiles. On Apple platforms, `SystemLanguageModel` bridges to the real
on-device model. Third-party model packages built for Apple's
`LanguageModel`/`LanguageModelExecutor` protocols plug in unmodified.

## How parity is proven

The claim "just replace the import" is enforced by five independent gates,
all in CI:

1. **Signature diff** — every public declaration in Apple's vendored
   macOS 27 `.swiftinterface` (818 checked) must exist here with a
   matching signature: currently **0 gaps**.
2. **One test suite, two libraries** — `TestScenarios/ParityScenarios.swift`
   compiles into two targets via symlink: identical code and assertions,
   one importing Apple's framework (run against the on-device model), one
   importing this package. The Apple run defines correct behavior.
3. **Deterministic differential tests** — a scripted mock model pins exact
   transcript shapes, streaming snapshots, tool loops, and error paths.
4. **Wire-level capture** — a loopback server proves instructions, tool
   schemas, `@Guide` bounds, and generation options actually leave in the
   HTTP request.
5. **Third-party corpus** — real packages written against Apple's
   framework (apple/foundation-models-utilities, Anthropic's
   FoundationModels adapter) build and pass their own test suites with
   only the import swapped.

```sh
swift test                                          # this library
swift test --filter AppleFoundationModelsParityTests  # Apple oracle (macOS 27)
```

## Production

Concurrency-stress- and soak-tested on Linux against live model servers;
works inside Vapor and Hummingbird handlers (smoke apps in
`integration/`). Typed error mapping (`rateLimited` with reset date,
`contextSizeExceeded`), task cancellation propagates into in-flight HTTP,
and optional [swift-log](https://github.com/apple/swift-log) diagnostics
(silent by default, never logs prompt or response content):

```swift
model.logger = Logger(label: "llm")
```

See [docs/PRODUCTION.md](docs/PRODUCTION.md) for transports, transcript
growth strategies, and timeout/retry policy, and the rest of
[docs/](docs/) for the parity guarantees in detail.

## Requirements

- Swift 6.2+ (Linux: `swift:6.2` Docker image or newer)
- Apple platforms: macOS 27 / iOS 27 SDK (Xcode 27 beta) for the
  `SystemLanguageModel` bridge and the Apple-oracle test target
