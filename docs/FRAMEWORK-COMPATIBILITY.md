# Server framework compatibility (production Linux)

Proof, 2026-06-12, `swift:6.2` container with `10.0.0.200:8000` as a pure
HTTP inference endpoint (`qwen3.6-35b-a3b`). Smoke servers live in
`integration/`; each builds LinuxFoundation as a path dependency and serves
`GET /ask?q=` whose handler runs a `LanguageModelSession` against the
remote model. Runners: `scripts/integration-hummingbird.sh`,
`scripts/integration-vapor.sh` (mount repo at /src in a swift container).

| Framework | Result | Notes |
|---|---|---|
| Hummingbird 2 | ✅ build + health + live LLM response ("ready") | works out of the box |
| Vapor 4 | ✅ build + health + live LLM response ("ready") | needs the toolchain workaround below |

## The Vapor-on-Swift-6.2 workaround (upstream, not ours)

Current swift-nio releases enable `MemberImportVisibility` and their
`_NIOFileSystem` target (pulled by Vapor, not by Hummingbird) fails to
compile on the Swift 6.2.x Linux toolchain — **reproducible with bare Vapor
and zero LinuxFoundation involvement**, across nio versions and on both
swift:6.2.4 and 6.2.3 images. Until NIO/toolchain reconcile, build Vapor
apps with:

```sh
swift build -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility
```

## Why coexistence is clean

- LinuxFoundation's default build has no NIO dependency, so it imposes
  nothing on a host app's NIO version resolution.
- With the `AsyncHTTPClient` trait enabled, it shares the host's NIO event
  loops via `HTTPClient.shared` — no second runtime.
- The library is strict-Swift-6 (`Sendable`-clean), holds no main-actor
  assumptions, and sessions are safe to create per-request in handlers.
