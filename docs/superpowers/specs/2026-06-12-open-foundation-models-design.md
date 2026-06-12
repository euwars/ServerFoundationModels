# OpenFoundationModels — Linux-capable FoundationModels (SDK 27) — Design

Date: 2026-06-12
Status: Approved (user directed: "same exact APIs and features", test-first)

## Goal

An open-source Swift package, module `OpenFoundationModels`, that re-implements Apple's
FoundationModels framework exactly as shipped in the macOS/iOS 27 SDK — same type names,
same signatures, same behavior — and builds and runs on Linux. Switching is one import line:
`import FoundationModels` → `import OpenFoundationModels`.

## Ground truth

- `reference/FoundationModels-macOS27.swiftinterface` — copied from the Xcode beta
  MacOSX27.sdk. This file IS the API parity spec. (~600 public declarations; 185 new in 27.)
- `apple/foundation-models-utilities` (Apache 2.0) — Apple's own `ChatCompletionsLanguageModel`
  and the documented `LanguageModel`/`LanguageModelExecutor` third-party-model contract.

## Approach (chosen: vendor + reshape)

Vendor battle-tested foundations from `huggingface/AnyLanguageModel` (Apache 2.0): GeneratedContent,
GenerationSchema/DynamicGenerationSchema, Transcript, Prompt/Instructions builders, the
@Generable/@Guide swift-syntax macros, partial-JSON streaming. Strip its divergences (its own
`LanguageModel` protocol shape, ALM-only extras) and build Apple's exact SDK 27 surface on top:
`LanguageModel` + `LanguageModelExecutor` + `LanguageModelExecutorGenerationRequest/Channel`,
`LanguageModelCapabilities`, `DynamicInstructions` DSL, `Attachment`/`ImageAttachmentContent`,
`SessionPropertyValues`, `AnyTool`. Rejected: clean-room (re-solves solved problems) and
depending on ALM as a package (its public types collide in shape with Apple's).

## Targets

- `OpenFoundationModels` — full API surface.
- `OpenFoundationModelsMacros` — `@Generable`, `@Guide`, `@SessionPropertyEntry`.
- Test targets — see Parity harness.

Swift 6.2+ tools, `swiftLanguageMode(.v6)`. Platforms: Linux (primary CI) + macOS/iOS.

## Built-in models

- `SystemLanguageModel` — source parity everywhere; passes through to Apple's on-device model
  behind `#if canImport(FoundationModels)`; reports `.unavailable` on Linux (documented
  impossibility: the on-device model is Apple-OS-bound).
- `ChatCompletionsLanguageModel` — ported from Apple's utilities repo; the out-of-the-box Linux
  backend (any OpenAI-compatible endpoint: Ollama, vLLM, llama-server, …).

## Parity harness (the heart of the project; built FIRST, test-driven)

One shared scenario file, compiled into two test targets via symlink; only the import differs:

```
TestScenarios/ParityScenarios.swift          # canonical; conditional import:
                                             #   #if canImport(OpenFoundationModels) ours #else FoundationModels
Tests/AppleFoundationModelsParityTests/      # NO dep on our module → imports Apple's framework
    Scenarios.swift -> symlink               # model: SystemLanguageModel.default (local, on-device)
    ModelProvider.swift
Tests/OpenFoundationModelsParityTests/       # depends on OpenFoundationModels
    Scenarios.swift -> symlink               # model: ChatCompletionsLanguageModel → local Ollama
    ModelProvider.swift                      #   (qwen3.5:9b @ http://localhost:11434)
```

Scenarios assert behavioral contracts, not exact model strings (different models): respond
returns content + correct transcript entry sequence; structured generation decodes and respects
guides; tool-call loop invokes tools and records toolCalls/toolOutput entries; streaming
snapshots accumulate to the final response; transcript continuation; prewarm; pure API behavior
(GeneratedContent round-trips, schema construction, options equality).

Apple target = oracle: must be green from day one. Our target starts red (stubs) and is driven
to green — classic outside-in TDD. CI additionally diffs public declarations of our module
against the reference swiftinterface.

## Out of scope (documented, not silent)

- On-device inference on Linux (use ChatCompletions against a local server; in-process
  llama.cpp executor is a follow-on package).
- Apple-Intelligence-bound features run passthrough-only on Apple platforms
  (SystemLanguageModel adapters/assets, PrivateCloudComputeLanguageModel).
