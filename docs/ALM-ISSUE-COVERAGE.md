# AnyLanguageModel issue coverage

Mapping of huggingface/AnyLanguageModel's reported failures (open + closed)
to ServerFoundationModels parity-suite coverage. Every "covered" row is asserted by
test code that runs byte-identical against Apple's FoundationModels and
ServerFoundationModels on the same local on-device model.

| ALM issue | Failure mode | Our coverage |
|---|---|---|
| #160 (open) | Unbounded array schemas force fixed counts → fabricated items, token budget blowups | `unboundedArrayGeneration` — unguided array decodes with sensible count, no padding |
| #155 / #123 (open) | Array of nested `@Generable` breaks structured generation ($ref without $defs) | `generableDeepNesting` (two array layers), `generableRecursiveType` ($defs emitted correctly) |
| #146 (closed) | Enum stored property without `@Guide` silently yields placeholders | `unguidedEnumProperty` — no annotations anywhere, valid case decoded |
| #94 (open) | Nested wrapper types return placeholder values from the system model | `wrapperTypeDecoding` — distinct, non-placeholder items |
| #103 (open) | Transcript not observable while streaming | `transcriptObservableDuringStreaming` — prompt entry visible mid-stream |
| #114 (open) | No context window management/trimming | `historyTransformInjection` + profile `.historyTransform` (suffix trim) |
| #86 / #52 (closed) | Full transcript not sent → model has no memory | `transcriptContinuation` ("otter" recall), `historyTransformInjection` |
| #45 (closed) | Non-streaming respond doesn't append `.response` entry | `plainTextResponse` asserts entry sequence |
| #43 (closed) | Tool calling for the system model | `toolCalling` + `sessionPropertiesReachTools` (native execution relayed through the bridge) |
| #124 (closed) | Malformed tool-call request bodies | exercised by every tool test through both executors |
| #122 (closed) | Reading/modifying transcript entries | `Transcript.history` get/set, `replaceSubrange`, `transcriptCodableAndHistory` |
| #105 (open) | `GeneratedContent` coding ergonomics | `GeneratedContent` JSON round-trip tests + `Transcript: Codable` |
| #74 (closed) | Memberwise initializer not generated | macro generates it; used by every fixture |
| #62 (closed) | `availability` incorrect | bridge reports Apple's real availability; gates the whole suite |
| #77 / #76 (closed) | Sendable/concurrency build failures | package builds under `swiftLanguageMode(.v6)` |
| #104 (open) | No control over $defs/$ref inlining | design default: fully inline, $defs only for genuine recursion (tested) |
| #127 (closed) | Linux URLSession use-after-free | n/a on macOS; Linux CI will exercise the chat-completions path |
| #113 (open) | Session memory bloat | not asserted (resource profile, not behavior) — tracked |
| #137/#89/#112/#70/#47/#51/#41/#157/#152/#144/#135/#78 | MLX/Llama/CoreML/trait specifics | n/a — backends AnyLanguageModel ships that we don't |
