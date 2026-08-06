# The 100%-match claim, and what enforces it

Claim: **code written against Apple's FoundationModels (SDK 27) compiles and
behaves identically against ServerFoundationModels after changing one line —
`import FoundationModels` → `import ServerFoundationModels`.**

Five independent verification layers enforce it, each catching a class of
divergence the others can't. All are machine-checkable; layers 1 and 2 run
in CI on every push (layer 3's live suites self-gate when no model is
reachable; the Apple-oracle half of layer 3 and layer 4's third-party
corpus — Apple-platforms-only packages — run on the self-hosted macOS
runner via `scripts/compat-check.sh`).

## Layer 1 — Signature-level interface diff (compile-time surface)

`scripts/interface-diff.py` compares Apple's `.swiftinterface` (vendored at
`reference/FoundationModels-macOS27.swiftinterface`, from Xcode 27 beta 4;
the macOS surface is a strict subset of iOS 27's, which adds only
`ImageReference.resolved(in:)`) against ServerFoundationModels's emitted
interface, declaration by declaration with normalized signatures.

```sh
swift build -Xswiftc -enable-library-evolution \
  -Xswiftc -emit-module-interface-path -Xswiftc /tmp/ServerFoundationModels.swiftinterface \
  --target ServerFoundationModels
python3 scripts/interface-diff.py reference/FoundationModels-macOS27.swiftinterface /tmp/ServerFoundationModels.swiftinterface
```

Current state: **0 gaps across 789 Apple declarations** (with a short,
reasoned allowlist inside the script: macro-synthesized `PartiallyGenerated`
types, the advisory Regex guide, and adapters off-macOS). Name-level
`scripts/api-audit.py` additionally gates 151/151 types.

## Layer 2 — Deterministic differential tests (exact behavior)

A scripted mock model in `TestScenarios/ParityScenarios.swift` drives BOTH
libraries with byte-identical executor event streams. Assertions are exact:
response text, token-usage numbers, transcript entry sequences, tool-loop
order. Any divergence in session machinery fails one side. (This layer
already taught us one nuance: Apple's snapshot cadence is timing-dependent,
so streaming asserts the stable contract — prefix-monotonic snapshots
settling into the exact final text.)

## Layer 3 — Live behavioral parity (same model, two libraries)

The same scenario file runs against Apple's framework with the local
on-device model and against ServerFoundationModels (same on-device model via the
bridge, or any OpenAI-compatible endpoint via `PARITY_BACKEND`). Dozens of
scenarios × 2 libraries assert model-agnostic contracts: structured
output, recursive schemas, guides, tool calling, session properties, dynamic
profiles, history modifiers, errors, usage. Verified green against the
on-device model and against vLLM/qwen3-moe over the network.

## Layer 4 — Third-party corpus (real code, unmodified)

`scripts/compat-check.sh` clones packages written by Apple and Anthropic
against the real framework, swaps the import, and runs their complete test
suites against ServerFoundationModels:

- `anthropics/ClaudeForFoundationModels` — library target green at the pinned
  commit. Its test support destructures channel events through the pre-beta-4
  `Event` protocol, which Xcode 27 beta 4 replaced with an opaque struct on
  both implementations — those tests need the upstream beta-4 adaptation
  before they can compile against either framework.
- `apple/foundation-models-utilities` — full suite green (its tests pinned down exact
  profile/history/skills semantics that documentation never states)

## Layer 5 — Issue-derived regressions

Failure modes reported against other FoundationModels reimplementations
(`docs/ALM-ISSUE-COVERAGE.md`) are encoded as tests that pass on Apple's
framework first — guaranteeing the suite asserts real framework behavior,
not our assumptions.

## Linux execution proof (2026-06-12, historical run log)

*The endpoint, log paths, and counts below are from a one-off proof run on the
author's network — not reproducible by readers without equivalent setup.*

Run locally in the official `swift:6.2` container (aarch64-linux), with
`10.0.0.200:8000` used purely as an HTTP inference endpoint
(`qwen3.6-35b-a3b`):

- full build including test targets: clean (one Linux-specific shim was
  required and is now part of the library: corelibs lacks
  `URLSession.bytes`, so SSE streaming uses a data-delegate line stream)
- model-free suites (API semantics + deterministic differential): green
- full behavior suite over the network: all scenarios green
- `.swiftinterface` emitted on Linux and diffed against Apple's: **0 gaps**
  (graphics-typed API — CGImage/CIImage/CVPixelBuffer — is allowlisted off
  Apple platforms, matching the fact that FoundationModels itself doesn't
  exist there)

Scenario fixtures pin their model via `.model(ParityModel.make())` because
profile sessions default to `SystemLanguageModel`, which is honestly
unavailable on Linux; the one SystemLanguageModel-specific scenario is
gated to on-device-backed runs.

## Honest residuals

- `@available` annotations and underscored attributes are normalized away in
  Layer 1; we do not replicate Apple's availability matrix.
- Layer 1's allowlist is the complete divergence list; anything added to it
  must carry a reason.
- Apple-OS-bound runtime features (the on-device model itself, adapters,
  Private Cloud Compute) exist with exact signatures everywhere but are
  honestly unavailable off Apple platforms.
