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

### Quick start — xAI (Grok)

`XAILanguageModel` talks to xAI's Responses API (`/v1/responses`) with
native `previous_response_id` chaining, `prompt_cache_key` prefix caching,
and inline-output replay for tool-heavy parents (ported from production
xAI integrations):

```swift
import ServerFoundationModels

let state = XAIConversationState()
let model = XAILanguageModel(
    name: .grok4_3,
    auth: .apiKey(ProcessInfo.processInfo.environment["XAI_API_KEY"]!),
    conversationState: state,
    serverTools: [.webSearch]
)
let session = LanguageModelSession(model: model, instructions: "You are concise.")
let answer = try await session.respond(to: "What is ServerFoundationModels?")
```

Use one `XAIConversationState` per `LanguageModelSession`. Multi-agent
models (`.grok4_20MultiAgent`) are supported but not threadable via
`previous_response_id` — the executor replays stored output items instead.

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

## Linux verification (container)

Reproducible Linux checks run inside the official `swift:6.2` image. The
container wrapper keeps a **persistent `.build` volume** and bind-mounts your
repo directly (no `cp -a` copy) so the second run is much faster on macOS /
OrbStack:

```sh
# Full verify (first run ~5–10 min cold; warm ~1–2 min)
bash scripts/linux-container-verify.sh

# Fast dev loop — debug build + XAI unit tests only
LINUX_VERIFY_QUICK=1 bash scripts/linux-container-verify.sh

# Docker uses container nproc for -j, 4g shm for parallel C++ builds, no --cpus cap by default
# Raise OrbStack Settings → CPUs if builds look idle; optional explicit cap:
SWIFT_BUILD_JOBS=20 LINUX_VERIFY_CPUS=20 bash scripts/linux-container-verify.sh

# Interactive shell with warm cache
bash scripts/linux-container-shell.sh
bash scripts/linux-container-shell.sh swift test --filter XAIWireFormatTests

# Optional: pre-warm dependency layers into a custom image
docker build -f docker/linux-verify/Dockerfile.deps -t sfm-linux-deps .
LINUX_VERIFY_IMAGE=sfm-linux-deps bash scripts/linux-container-verify.sh
```

On a Linux host (or inside the container): `bash scripts/linux-verify.sh`

CI runs the same XAI unit-test filter in the `linux` job (`.github/workflows/ci.yml`).

## Requirements

- Swift 6.2+ (Linux: `swift:6.2` Docker image or newer)
- Apple platforms: macOS 27 / iOS 27 SDK (Xcode 27 beta) for the
  `SystemLanguageModel` bridge and the Apple-oracle test target
