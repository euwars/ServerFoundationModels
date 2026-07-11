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
  soak-tested (opt-in local runs via `PARITY_STRESS`/`PARITY_SOAK`), and proven
  inside Vapor and Hummingbird handlers.
- **Real providers.** Any OpenAI-compatible endpoint (`ChatCompletionsLanguageModel`)
  and a native **xAI Grok** provider (`XAILanguageModel`) with server-side web/X
  search, `previous_response_id` threading, and prompt-prefix caching.
- **Skills.** Let the model activate capability bundles (instructions + tools)
  on demand, mid-session, by calling an auto-generated tool.
- **Multi-agent ready.** Independent `Sendable` sessions over a pooled NIO client
  make code-orchestrated fan-out (plan → research → verify → synthesize) trivial —
  a live deep-research example ships in [`integration/`](integration/xai-deep-research/main.swift).

## Installation

```swift
.package(url: "https://github.com/euwars/ServerFoundationModels.git", from: "0.1.0")
```

Two library products, mirroring how Apple ships `FoundationModels` and
`FoundationModelsUtilities` as separate frameworks:

```swift
.target(name: "App", dependencies: [
    // Core SDK surface: sessions, @Generable, tools, transcripts, profiles,
    // the native xAI provider.
    .product(name: "ServerFoundationModels", package: "ServerFoundationModels"),
    // apple/foundation-models-utilities surface: the Chat-Completions provider
    // (Ollama / OpenRouter / vLLM / …) and Skills. Import only if you use them.
    .product(name: "ServerFoundationModelsUtilities", package: "ServerFoundationModels"),
])
```

The NIO transport (swift-nio + async-http-client) is the default. For a
dependency-light build on URLSession, opt out with `traits: []`.

> **Note — module aliasing.** A `moduleAliases: ["ServerFoundationModels":
> "FoundationModels"]` "zero-line switch" does **not** work: this package's own
> `SystemLanguageModel` does `import FoundationModels` for the Apple on-device
> bridge, and Swift forbids that name inside a package aliased *to*
> `FoundationModels` (even in inactive `#if` branches). To make a package
> written against Apple's `FoundationModels` build on this stack, swap its
> `import FoundationModels` line for `import ServerFoundationModels` — see
> [`forks/ClaudeForFoundationModels`](forks/ClaudeForFoundationModels) for a
> worked example.

## Quick start

Apple's on-device model doesn't exist off Apple platforms, so the built-in
`ChatCompletionsLanguageModel` drives any OpenAI-compatible endpoint
(Ollama, vLLM, llama-server, LM Studio, OpenRouter, ...):

```swift
import ServerFoundationModels
import ServerFoundationModelsUtilities   // ChatCompletionsLanguageModel lives here

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

## xAI (Grok)

`XAILanguageModel` conforms to the same `LanguageModel` protocol and drives
xAI's **Responses API** (`/v1/responses`) with native `previous_response_id`
chaining, `prompt_cache_key` prefix caching, SSE streaming, guided JSON, and
server-side tools. Everything below uses the ordinary `LanguageModelSession`
API — swap the model and it behaves like any other provider.

### Setup and authentication

```swift
import ServerFoundationModels

// Development: key in the process environment.
let model = XAILanguageModel(
    name: .grok4_3,
    auth: .apiKey(ProcessInfo.processInfo.environment["XAI_API_KEY"]!)
)

// Production: keep the key server-side; the app talks to your relay.
let proxied = XAILanguageModel(
    name: .grok4_3,
    auth: .proxied(headers: ["Authorization": "Bearer \(sessionToken)"]),
    baseURL: URL(string: "https://api.yourbackend.com/xai/responses")!,
    timeout: 120
)
```

### Models

| Model | `id` | Notes |
| --- | --- | --- |
| `.grok4_3` | `grok-4.3-latest` | default; threadable, vision, guided generation |
| `.grok4_1Fast` | `grok-4-1-fast-reasoning-latest` | lower latency |
| `.grok4_20MultiAgent` | `grok-4.20-multi-agent` | not threadable — replays stored output inline |

Any other deployment: `XAILanguageModel(name: XAIModel(id: "grok-…"), auth: …)`.

### Text and streaming

```swift
let session = LanguageModelSession(model: model, instructions: "You are concise.")

// One-shot
let reply = try await session.respond(to: "Summarize the Swift actor model in two sentences.")
print(reply.content)
print(reply.usage.input.totalTokenCount, reply.usage.output.totalTokenCount)

// Streaming — snapshots are cumulative, so print only what's new
var printed = ""
for try await snapshot in session.streamResponse(to: "List three uses of actors.") {
    print(snapshot.content.dropFirst(printed.count), terminator: "")
    printed = snapshot.content
}
```

### Structured output

```swift
@Generable
struct Company {
    @Guide(description: "Official company name") var name: String
    @Guide(.range(1900...2100)) var founded: Int
}

// Typed — decoded straight into your value
let company = try await session.respond(to: "Facts about xAI.", generating: Company.self).content
print(company.name, company.founded)

// Or a runtime GenerationSchema when the shape isn't known at compile time
let schema = GenerationSchema(type: Company.self, properties: [
    .init(name: "name", type: String.self),
    .init(name: "founded", type: Int.self),
])
let json = try await session.respond(to: "Facts about OpenAI.", schema: schema).content.jsonString
```

### Reasoning effort

`ContextOptions.reasoningLevel` maps to xAI's `reasoning_effort`
(`.light`→low, `.moderate`→medium, `.deep`→high, `.custom("…")` verbatim);
omit it to use the model's default.

```swift
let proof = try await session.respond(
    to: "Prove that the square root of 2 is irrational.",
    options: GenerationOptions(),
    contextOptions: ContextOptions(reasoningLevel: .deep)
)
```

### Server tools — web & X search, citations

Enable server-side tools per model. `.webSearch` also lets the model open
pages; `.xSearch` searches X (Twitter). Their activity is recorded in the
transcript as `XAIServerToolSegment` custom segments (Apple's
`Transcript.CustomSegment` pattern), updated in place as results and
citations arrive.

```swift
let model = XAILanguageModel(
    name: .grok4_3,
    auth: .apiKey(key),
    serverTools: [.webSearch, .xSearch]
)
let session = LanguageModelSession(model: model)
let reply = try await session.respond(to: "What shipped in Swift 6.2? Cite sources.")

for entry in session.transcript {
    guard case .response(let response) = entry else { continue }
    for case .custom(let custom) in response.segments {
        guard let activity = custom as? XAIServerToolSegment else { continue }
        switch activity.content {
        case .webSearch(let s):
            print("web:", s.query, "→", s.outcome?.hits.map(\.url) ?? [])
            for c in s.outcome?.citations ?? [] { print("  cite:", c.url, c.title ?? "") }
        case .xSearch(let s):
            print("X:", s.query)
        case .webFetch(let f):
            print("opened:", f.url)
        case .unrecognized(let a):
            print("future tool:", a.itemType)   // preserved verbatim for replay
        }
    }
}
```

Segments also stream incrementally during `streamResponse` (as
`updateCustomSegment` channel events) before the final transcript is written.

### Multi-turn conversations (threading)

One `XAIConversationState` lives per session (created for you by default).
It holds the `previous_response_id`, so follow-up turns send only the new
message instead of re-uploading the whole conversation.

```swift
let session = LanguageModelSession(model: model)   // its own conversation thread
_ = try await session.respond(to: "My name is Ada — remember it.")
let reply = try await session.respond(to: "What's my name?")   // threaded; not re-sent
```

Multi-agent models can't thread; the executor transparently replays stored
output items inline instead.

### Persisting and resuming a conversation

`Transcript` (including `XAIServerToolSegment`) round-trips through
`Codable`. Resume by loading it into a session with a fresh model — with no
live conversation state, the provider reconstructs prior assistant text and
server-tool activity as input ("fresh-mode replay").

```swift
let blob = try JSONEncoder().encode(session.transcript)          // save

let restored = try JSONDecoder().decode(Transcript.self, from: blob)   // later / elsewhere
let resumed = LanguageModelSession(
    model: XAILanguageModel(name: .grok4_3, auth: .apiKey(key), serverTools: [.webSearch]),
    transcript: restored
)
let reply = try await resumed.respond(to: "Based on your earlier search, summarize again.")
```

### Client-side tools (function calling)

Your own `Tool`s run in-process and compose with `serverTools`.

```swift
struct PaperSize: Tool {
    @Generable struct Arguments {
        @Guide(description: "Paper name, e.g. A4 or Letter") var name: String
    }
    let description = "Return paper dimensions in millimeters."
    func call(arguments: Arguments) async throws -> String {
        arguments.name == "A4" ? "210 x 297 mm" : "unknown size"
    }
}

let session = LanguageModelSession(model: model, tools: [PaperSize()])
let reply = try await session.respond(to: "How wide is A4 paper?")
```

### Error handling

Provider errors map to the framework's typed `LanguageModelError`.

```swift
do {
    let reply = try await session.respond(to: prompt)
} catch let error as LanguageModelError {
    switch error {
    case .rateLimited(let info):
        print("rate limited; retry after", info.resetDate ?? .now)
    case .contextSizeExceeded:
        print("prompt/transcript too large — trim history")
    default:
        print("model error:", error.localizedDescription)
    }
}
```

### Diagnostics

Optional [swift-log](https://github.com/apple/swift-log) output (silent by
default, never logs prompt or response content):

```swift
var model = XAILanguageModel(name: .grok4_3, auth: .apiKey(key))
model.logger = Logger(label: "xai")
```

## OpenRouter

`OpenRouterLanguageModel` is a first-class OpenRouter provider (in
`ServerFoundationModelsUtilities`). OpenRouter speaks the OpenAI
`/chat/completions` wire, so it reuses that proven engine — streaming, tool
calls, usage, and `url_citation` → `WebCitationSegment` all work — while giving
you typed access to the OpenRouter-specific surface a real pipeline depends on:

```swift
import ServerFoundationModels
import ServerFoundationModelsUtilities

let model = OpenRouterLanguageModel(
    model: "anthropic/claude-sonnet-4",
    apiKey: key,                                   // Bearer; prefer Keychain over the binary
    providerRouting: .init(order: ["anthropic", "google-vertex"],
                           allowFallbacks: false), // pin backends so a run can't drift
    serverTools: [.webSearch(engine: .native)],    // "native", not auto (auto silently falls back to Exa)
    reasoning: .init(effort: .high),
    appURL: "https://myapp.example", appTitle: "My App")   // OpenRouter attribution

let session = LanguageModelSession(model: model)
let answer = try await session.respond(to: "What shipped in Swift 6.2?")
```

- **Provider routing** (`order`/`only`/`ignore`/`allowFallbacks`/`sort`/…) is
  typed and lands in the request's `provider` object.
- **`reasoning`** (`effort`/`maxTokens`/`enabled`/`exclude`) is typed too;
  `extraBodyJSON` merges verbatim for anything not modelled (and overrides the
  typed fields on key collision).
- **Credit exhaustion** (HTTP 402, or 403 whose body says "key limit"/"credit")
  is terminal — it surfaces as `OpenRouterError.creditExhausted` so a fan-out
  run stops and says "add credit" instead of each worker re-discovering the dead
  key. Rate limits still map to `LanguageModelError.rateLimited` (honoring
  `Retry-After`), context overflow to `.contextSizeExceeded`.

## Skills

Give the model capability bundles it can turn on and off *itself*. A `Skill`
pairs a model-visible name and description with an instructions-and-tools payload
(or a one-shot prompt). `Skills` lists them and generates a tool the model calls
to toggle them — so the model reconfigures itself mid-session. `Skill`/`Skills`
live in `ServerFoundationModelsUtilities`:

```swift
import ServerFoundationModelsUtilities

struct AssistantProfile: LanguageModelSession.DynamicProfile {
    let activations: SkillActivations
    let key: String
    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Skills(activations: activations) {
                Skill(name: "style-guide", description: "Apply the writing style guide") {
                    "Keep phrasing literal; avoid idioms."      // prompt-based: preserves the prefix cache
                }
                Skill(name: "calendaring", description: "Read and modify the calendar",
                      allowsDeactivation: true) {
                    Instructions("Meetings start 5 minutes after the hour.")
                    // …plus this skill's own tools
                }
            }
        }
        .model(XAILanguageModel(name: .grok4_3, auth: .apiKey(key)))
    }
}

let session = LanguageModelSession(profile: AssistantProfile(activations: SkillActivations(), key: key))
```

When the model calls the generated `toggle_skill` tool, the skill's instructions
and tools are injected on the next round. Prompt-based skills attach as tool
output (cache-friendly); instructions-based skills raise priority at the cost of
a prompt-cache invalidation. Ported from `apple/foundation-models-utilities` and
adapted to the core API.

## Multi-agent deep research

Independent sessions are `Sendable` and share a pooled NIO client, so
*code-orchestrated* fan-out is trivial — and far more predictable than asking one
model to drive everything (known work-list → `withTaskGroup`; only reach for
tools when the model must decide what to invoke mid-reasoning). A complete,
runnable example ships in
[`integration/xai-deep-research`](integration/xai-deep-research/main.swift):
**Plan → parallel Research → adversarial Verify → Synthesize**.

```sh
XAI_API_KEY=… swift run XAIDeepResearchProbe "Compare vLLM, TGI, and llama.cpp in 2026"
```

```
Stage 1 PLAN:                 9.4s   → 4 research angles
Stages 2+3 RESEARCH+VERIFY:  62.7s   parallel   vs 221.8s serial   (3.5× via fan-out)
  ✗ DROPPED  key features             ← the verifier rejected an unsupported claim
Stage 4 SYNTHESIZE:          23.8s   → cited report
TOTAL:                       95.9s   (1 plan + 4 research + 4 verify + 1 synth)
```

Each stage tunes its own model and reasoning effort (wide + cheap to gather,
deep + skeptical to trust), passes typed `@Generable` data between stages, and
pipelines research → verify per angle so a slow verify never blocks the others.

## Profiling with Instruments (Xcode 27)

Every model request and tool run is emitted as an [`os_signpost`](https://developer.apple.com/documentation/os/ossignposter)
interval (subsystem `com.serverfoundationmodels`), so you can profile a run on a
Foundation Models **events timeline** — request latency, time-to-first-token,
token counts, and tool spans — the same way you'd profile Apple's on-device
model. Both `XAILanguageModel` and `ChatCompletionsLanguageModel` are
instrumented. They show up in Instruments' built-in **os_signpost** instrument;
a custom package that renders them as labelled lanes ships in
[`Instruments/ServerFoundationModels.instrpkg`](Instruments/). Emission compiles
to nothing off Apple platforms. See [`Instruments/README.md`](Instruments/README.md).

## Using packages written for Apple's FoundationModels

A provider package built against Apple's `FoundationModels` (e.g.
[anthropics/ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels))
runs on this stack with a one-line-per-file change: swap `import FoundationModels`
for `import ServerFoundationModels`. Our surface is signature-compatible, so the
bridge, executor, and its own tests compile unmodified.
[`forks/ClaudeForFoundationModels`](forks/ClaudeForFoundationModels) is a worked,
tested fork — every `.swift` source is upstream's, changed only at the import line.

## How parity is proven

The claim "just replace the import" is enforced by five independent gates.
Gates 1, 3, and 4 run in CI on every push. Gates 2 (the Apple-oracle suite)
and 5 (the third-party corpus, whose packages build only on Apple
platforms) run on a self-hosted macOS 27 runner via the same workflow.

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
swift test                                                    # this library
INCLUDE_APPLE_PARITY_TESTS=1 swift test --filter AppleFoundationModelsParityTests  # Apple oracle (Xcode 27)
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
- Command-Line Tools only (no full Xcode): set `SKIP_MACRO_TESTS=1` to skip
  the `@Generable`/`@Guide` macro test target
