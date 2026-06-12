# Production guidance (Linux servers)

How to run ServerFoundationModels under sustained load, and what the library
does (and deliberately does not do) for you.

## Transports

| | Default (`AsyncHTTPClient` trait, on) | Opt-out (`traits: []`) |
|---|---|---|
| Stack | NIO pooled `HTTPClient.shared` | corelibs/Darwin URLSession |
| Dependencies | swift-nio + async-http-client | swift-log only |
| Best for | servers (Vapor/Hummingbird already carry NIO) | CLIs, dependency-light builds |

The NIO transport is the default. For a dependency-light build:

```swift
.package(url: "…/ServerFoundationModels.git", from: "0.1.0", traits: [])
```

Both transports stream SSE, propagate task cancellation into the HTTP
request, and map provider errors to the typed taxonomy (429 →
`LanguageModelError.rateLimited` with `resetDate` from `Retry-After`;
context-window 400/413 → `.contextSizeExceeded`; everything else →
`LanguageModelTransportError` carrying status code and body). The SSE
parser tolerates keep-alive comments, malformed frames, CRLF delimiters,
and streams that close without `[DONE]` (see `SSEEdgeCaseTests`).

## Logging

Transport diagnostics integrate with [swift-log](https://github.com/apple/swift-log)
and are **silent by default** (no-op handler). Assign a logger to see them:

```swift
var model = ChatCompletionsLanguageModel(name: "qwen3", url: endpoint)
model.logger = Logger(label: "llm")   // your app's configured logger
```

Emitted events: request lifecycle at `.debug` (model, host, tool count,
guided flag), HTTP error responses at `.warning` (status + truncated
provider body), skipped malformed SSE frames at `.debug` (size only).
Prompt, instruction, and response content is never logged at any level.

## Sessions and concurrency

- `LanguageModelSession` is single-conversation state: one request at a
  time per session (a second concurrent `respond` refuses, matching
  Apple). For server workloads create a session per request/conversation —
  sessions are cheap; the underlying HTTP transport is shared.
- Concurrent sessions are safe and stress-tested (8 parallel sessions ×
  multiple rounds in `concurrentSessionsStress`, run with
  `PARITY_STRESS=1`).
- Cancellation: cancelling the `Task` running `respond`/`streamResponse`,
  or abandoning a `ResponseStream` iterator, cancels the in-flight HTTP
  request. No detached work survives the caller.

## Transcript growth

A session's transcript grows without bound: every prompt, response,
tool-call round, and re-resolved profile instructions entry is persisted,
and the FULL transcript is sent to the provider on every round. For
long-lived conversations this means:

- request payloads (and provider token counts) grow linearly per round;
- you will eventually hit the model's context window, surfaced as
  `LanguageModelError.contextSizeExceeded`.

Strategies, in order of preference:

1. **Bound the conversation**: new session per logical task. Sessions are
   cheap to create.
2. **Window the history**: start a replacement session from a trimmed
   transcript — `Transcript` is `Codable` and `RandomAccessCollection`,
   so keep the `.instructions` entry plus the most recent N entries:

   ```swift
   let entries = Array(session.transcript)
   let trimmed = entries.prefix(1) + entries.suffix(20)
   let next = LanguageModelSession(model: model, transcript: Transcript(entries: Array(trimmed)))
   ```

3. **Summarize**: ask the model to summarize the conversation so far,
   then seed a fresh session with that summary in its instructions.
4. **React to overflow**: catch `.contextSizeExceeded` and apply 2 or 3.
   The session remains usable; the failed round is not recorded.

Token budgeting: `Response.usage` (and streamed `updateUsage` events)
report input/output token counts per round when the provider sends them —
watch `inputTokens.totalTokenCount` to know how close you are to the
window before overflow happens.

## Timeouts and retries

- Configure the per-request timeout via
  `ChatCompletionsLanguageModel.Configuration.timeout` (default 600 s —
  generation is slow; do not use generic 30 s HTTP defaults).
- The library does not retry. Retrying a generation is a policy decision
  (idempotency, cost); wrap `respond` with your own retry on
  `.rateLimited` honoring `resetDate`, and on transient
  `LanguageModelTransportError` (5xx).

## Memory

- Streaming snapshots are accumulated as a single growing string per
  round, not retained per-delta; memory per in-flight round is bounded by
  the response size.
- The dominant long-run memory consumer is the transcript (see above) —
  bounding it bounds the process.
