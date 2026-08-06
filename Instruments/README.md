# Profiling with Instruments (Xcode 27)

ServerFoundationModels emits [`os_signpost`](https://developer.apple.com/documentation/os/ossignposter)
intervals for every model request and tool run, so you can profile a run on a
Foundation Models **events timeline** in Instruments — the same way you'd
profile Apple's on-device `FoundationModels`.

## What gets emitted

All signposts are emitted under the subsystem **`com.serverfoundationmodels`**
(see `Sources/ServerFoundationModels/Profiling.swift`, `FMSignpost`):

| Category | Interval | Metadata on the timeline |
|---|---|---|
| `ModelRequest` | one per HTTP request (start → stream fully consumed) | `model`, `session`, time-to-first-token (ms), input/output tokens, success |
| `ToolRun` | one per tool execution (in and around the session's tool loop) | `tool`, `session` |

Model executors emit `ModelRequest` through `FMSignpost`; the session's
tool-call loop emits `ToolRun`.

Emission is compiled in only where `os` is available (Apple platforms) and
compiles to nothing on Linux, so the call sites carry no runtime cost off-Apple.

## Seeing it — no custom package required

The intervals already show up in Instruments' built-in **os_signpost**
instrument:

1. Product ▸ Profile (⌘I), choose the **Blank** template.
2. Add the **os_signpost** instrument.
3. In its recording options, set the subsystem filter to
   `com.serverfoundationmodels` (or leave it to see everything).
4. Record. Each request and tool run appears as an interval you can inspect.

## The custom instrument (nicer timeline)

`ServerFoundationModels.instrpkg` renders the same signposts as two dedicated,
labelled lanes (**Model Requests** and **Tool Runs**) with the metadata as
columns, instead of raw signpost messages.

To install it, add it to an **Instruments Package** target in an Xcode project
and build (the built package registers the "Foundation Models (Server)"
instrument), or drop it into your app target's Instruments Package build phase.
The subsystem/category/name strings in the `.instrpkg` mirror `FMSignpost`
exactly — if you change one, change both.

## Detecting KV-cache invalidations

Apple's guidance is that the only reliable way to learn a model's caching
behaviour is to measure it. The `ModelRequest` interval carries input/output
token counts and time-to-first-token; a request that re-sends a prefix which
*should* have been cached shows up as an unexpectedly high TTFT with no cache
benefit. (A dedicated cache-invalidation event is a natural follow-up once a
provider surfaces cached-token counts.)
