# Production guidance (Linux servers)

How to run ServerFoundationModels under sustained load, and what the library
does (and deliberately does not do) for you.

## Bring a provider

This package is the FoundationModels surface only. Models plug in through
the `LanguageModel` / `LanguageModelExecutor` protocols — either a provider
package (e.g.
[euwars/OpenrouterForFoundationModels](https://github.com/euwars/OpenrouterForFoundationModels)
with its `ServerFoundationModels` trait) or your own executor. Transport
concerns — HTTP clients, SSE parsing, retries at the wire level — belong to
the provider; the library's session machinery handles everything above the
executor: guided generation, the tool loop, transcripts, streaming
snapshots, cancellation, and typed errors.

## Logging

Diagnostics integrate with [swift-log](https://github.com/apple/swift-log)
and are **silent by default** (no-op handler). Prompt, instruction, and
response content is never logged at any level.

## Sessions and concurrency

- `LanguageModelSession` is single-conversation state: one request at a
  time per session (a second concurrent `respond` refuses, matching
  Apple). For server workloads create a session per request/conversation —
  sessions are cheap; share what is expensive (HTTP clients) inside the
  provider.
- Concurrent sessions are safe and stress-tested (8 parallel sessions ×
  multiple rounds in `concurrentSessionsStress`, run with
  `PARITY_STRESS=1`).
- Cancellation: cancelling the `Task` running `respond`/`streamResponse`,
  or abandoning a `ResponseStream` iterator, cancels the in-flight
  executor work. No detached work survives the caller.

## Errors

Executors surface failures through the typed taxonomy:
`LanguageModelError.rateLimited` (with `resetDate`),
`.contextSizeExceeded`, `.refusal`, and `LanguageModelTransportError`
carrying status code and body for everything else. The library does not
retry: retrying a generation is a policy decision (idempotency, cost);
wrap `respond` with your own retry on `.rateLimited` honoring `resetDate`,
and on transient `LanguageModelTransportError` (5xx).

## Transcript growth

A session's transcript grows without bound: every prompt, response,
tool-call round, and re-resolved profile instructions entry is persisted,
and providers typically resend it every round. For long-lived
conversations this means:

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

## Memory

- Streaming snapshots are accumulated as a single growing string per
  round, not retained per-delta; memory per in-flight round is bounded by
  the response size.
- The dominant long-run memory consumer is the transcript (see above) —
  bounding it bounds the process.
