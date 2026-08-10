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

### Why it's good

- **Drop-in.** The full FoundationModels SDK 27 surface, verified
  signature-for-signature (**0 gaps**). Swap the import; your code, macros, and
  tools compile unchanged.
- **Runs anywhere.** Linux, servers, containers — concurrency-stress- and
  soak-tested (opt-in local runs via `PARITY_STRESS`/`PARITY_SOAK`).
- **Just the framework.** This package is the FoundationModels surface and
  nothing else. Models plug in through the same `LanguageModel` /
  `LanguageModelExecutor` protocols Apple ships — provider packages live in
  their own repositories.

## Installation

A complete minimal manifest for a server app (this package plus the
OpenRouter provider used in Quick start):

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "App",
    // Required when building on a Mac — this package's platform floor is
    // macOS 27, and SwiftPM refuses to link it into a lower-target consumer
    // ("requires minimum platform version 27.0"). Ignored on Linux.
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/euwars/ServerFoundationModels.git",
                 from: "0.1.0"),
        .package(url: "https://github.com/euwars/OpenrouterForFoundationModels.git",
                 from: "0.1.0", traits: ["ServerFoundationModels"]),
    ],
    targets: [
        .executableTarget(name: "App", dependencies: [
            .product(name: "ServerFoundationModels", package: "ServerFoundationModels"),
            .product(name: "OpenRouterForFoundationModels", package: "OpenrouterForFoundationModels"),
        ]),
    ]
)
```

> **Note — module aliasing.** A `moduleAliases: ["ServerFoundationModels":
> "FoundationModels"]` "zero-line switch" does **not** work: this package's own
> `SystemLanguageModel` does `import FoundationModels` for the Apple on-device
> bridge, and Swift forbids that name inside a package aliased *to*
> `FoundationModels` (even in inactive `#if` branches). To make a package
> written against Apple's `FoundationModels` build on this stack, swap its
> `import FoundationModels` line for `import ServerFoundationModels` — or gate
> the swap behind a package trait, as
> [euwars/OpenrouterForFoundationModels](https://github.com/euwars/OpenrouterForFoundationModels)
> and the
> [euwars/foundation-models-utilities](https://github.com/euwars/foundation-models-utilities)
> fork of Apple's utilities package do.

> **Build cost.** A clean build of this dependency takes seconds, not minutes.
> The only heavy dependency is swift-syntax (macro target), and on toolchains
> with published prebuilts — Linux: Swift 6.3.2 release (`swift:6.3.2` image;
> Ubuntu, Debian 12, RHEL UBI9, Amazon Linux 2, x86_64 + aarch64), macOS:
> Xcode 26.5 / Xcode 27 beta — SwiftPM downloads a prebuilt swift-syntax
> instead of compiling it (on by default; measured 21 s clean consumer build
> on Apple Silicon). On toolchains without a published manifest for the
> resolved swift-syntax version (e.g. `swift:6.2`), SwiftPM silently falls
> back to compiling swift-syntax from source — still correct, just slower.
> CI guards the prebuilt path via `scripts/consumer-prebuilts-check.sh`.

## Quick start

Apple's on-device model doesn't exist off Apple platforms, so bring a model
through a provider. Pick one:

- **Any OpenRouter-hosted model** —
  [OpenrouterForFoundationModels](https://github.com/euwars/OpenrouterForFoundationModels)
  (used below; compiles against this package via its `ServerFoundationModels`
  trait, on macOS and Linux alike).
- **Ollama, vLLM, or any OpenAI-compatible endpoint** —
  `ChatCompletionsLanguageModel` from
  [foundation-models-utilities](https://github.com/euwars/foundation-models-utilities).
- **Your own backend** — conform to `LanguageModel`/`LanguageModelExecutor`;
  implement one method (`respond(to:model:streamingInto:)`) and the session
  machinery — guided generation, tool loop, transcripts, streaming — is
  provided by this library.

```swift
import Foundation
import ServerFoundationModels
import OpenRouterForFoundationModels

let model = OpenRouterLanguageModel(
    name: "anthropic/claude-sonnet-4.5",
    auth: .apiKey(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? "")
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
on-device model.

## Profiling with Instruments (Xcode 27)

Every model request and tool run is emitted as an [`os_signpost`](https://developer.apple.com/documentation/os/ossignposter)
interval (subsystem `com.serverfoundationmodels`), so you can profile a run on a
Foundation Models **events timeline** — request latency, time-to-first-token,
token counts, and tool spans — the same way you'd profile Apple's on-device
model. They show up in Instruments' built-in **os_signpost** instrument;
a custom package that renders them as labelled lanes ships in
[`Instruments/ServerFoundationModels.instrpkg`](Instruments/). Emission compiles
to nothing off Apple platforms. See [`Instruments/README.md`](Instruments/README.md).

## Using packages written for Apple's FoundationModels

A provider package built against Apple's `FoundationModels` runs on this
stack with a one-line-per-file change: swap `import FoundationModels` for
`import ServerFoundationModels`. Our surface is signature-compatible, so the
bridge, executor, and its own tests compile unmodified. The cleanest pattern
is a package trait that flips the import — see
[euwars/OpenrouterForFoundationModels](https://github.com/euwars/OpenrouterForFoundationModels)
(any OpenRouter model) and
[euwars/foundation-models-utilities](https://github.com/euwars/foundation-models-utilities)
(Apple's utilities surface: the Chat-Completions provider for Ollama / vLLM /
any OpenAI-compatible endpoint, plus Skills) — both pass their full test
suites under either backend.

## How parity is proven

The claim "just replace the import" is enforced by four independent gates.
Gates 1 and 3 run in CI on every push; gates 2 and 4 run against live
models (self-hosted macOS 27 runner / `OPENROUTER_API_KEY`).

1. **Signature diff** — every public declaration in Apple's vendored
   macOS 27 `.swiftinterface` (874 checked, Xcode 27 beta 4) must exist here with a
   matching signature: currently **0 gaps**.
2. **One test suite, two libraries** — `TestScenarios/ParityScenarios.swift`
   compiles into two targets via symlink: identical code and assertions,
   one importing Apple's framework (run against the on-device model), one
   importing this package. The Apple run defines correct behavior.
3. **Deterministic differential tests** — a scripted mock executor pins exact
   transcript shapes, streaming snapshots, tool loops, and error paths.
4. **Live bridge smoke** — [`integration/openrouter-parity`](integration/openrouter-parity)
   drives this working tree through the OpenRouter bridge (built with its
   `ServerFoundationModels` trait) against a real model: respond, cumulative
   streaming, guided generation, and the tool loop.

```sh
swift test                                                    # this library
INCLUDE_APPLE_PARITY_TESTS=1 swift test --filter AppleFoundationModelsParityTests  # Apple oracle (Xcode 27)
OPENROUTER_API_KEY=<key> swift run --package-path integration/openrouter-parity    # live bridge smoke
```

## Production

Concurrency-stress- and soak-tested on Linux against live model servers.
Typed error mapping (`rateLimited` with reset date, `contextSizeExceeded`),
task cancellation propagates into in-flight executor work, and optional
[swift-log](https://github.com/apple/swift-log) diagnostics (silent by
default, never logs prompt or response content).

See [docs/PRODUCTION.md](docs/PRODUCTION.md) for transcript growth
strategies and timeout/retry policy, and the rest of [docs/](docs/) for the
parity guarantees in detail.

## Linux verification (container)

Reproducible Linux checks run inside the official `swift:6.2` image. The
container wrapper keeps a **persistent `.build` volume** and bind-mounts your
repo directly (no `cp -a` copy) so the second run is much faster on macOS /
OrbStack:

```sh
# Full verify (first run ~5–10 min cold; warm ~1–2 min)
bash scripts/linux-container-verify.sh

# Fast dev loop — debug build + offline suite only
LINUX_VERIFY_QUICK=1 bash scripts/linux-container-verify.sh

# Docker uses container nproc for -j, 4g shm for parallel C++ builds, no --cpus cap by default
# Raise OrbStack Settings → CPUs if builds look idle; optional explicit cap:
SWIFT_BUILD_JOBS=20 LINUX_VERIFY_CPUS=20 bash scripts/linux-container-verify.sh

# Interactive shell with warm cache
bash scripts/linux-container-shell.sh
bash scripts/linux-container-shell.sh swift test --filter SessionBehaviorTests

# Optional: pre-warm dependency layers into a custom image
docker build -f docker/linux-verify/Dockerfile.deps -t sfm-linux-deps .
LINUX_VERIFY_IMAGE=sfm-linux-deps bash scripts/linux-container-verify.sh
```

On a Linux host (or inside the container): `bash scripts/linux-verify.sh`.
With `OPENROUTER_API_KEY` set, the verify script adds the live bridge smoke.

## Requirements

- Swift 6.2+ (Linux: `swift:6.2` Docker image or newer; prefer `swift:6.3.2`
  for prebuilt swift-syntax — see the build-cost note under Installation)
- Apple platforms: macOS 27 / iOS 27 SDK (Xcode 27 beta) for the
  `SystemLanguageModel` bridge and the Apple-oracle test target
- Command-Line Tools only (no full Xcode): set `SKIP_MACRO_TESTS=1` to skip
  the `@Generable`/`@Guide` macro test target
