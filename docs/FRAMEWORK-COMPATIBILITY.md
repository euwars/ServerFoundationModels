# Server framework compatibility (production Linux)

*Historical run log (2026-06-12): private endpoint `10.0.0.200:8000` is from
the author's one-off proof — not reproducible by readers without equivalent setup.*

Proof, 2026-06-12, `swift:6.2` container with `10.0.0.200:8000` as a pure
HTTP inference endpoint (`qwen3.6-35b-a3b`). The smoke servers used for this
run built ServerFoundationModels as a path dependency and served
`GET /ask?q=` whose handler ran a `LanguageModelSession` against the remote
model. (They were removed with the bundled providers in the core-only
restructuring; the findings below — especially the Vapor toolchain
workaround, which has nothing to do with this package — remain valid for
any consumer.)

| Framework | Result | Notes |
|---|---|---|
| Hummingbird 2 | ✅ build + health + live LLM response ("ready") | works out of the box |
| Vapor 4 | ✅ build + health + live LLM response ("ready") | needs the toolchain workaround below |

## The Vapor-on-Swift-6.2 workaround (upstream, not ours)

Current swift-nio releases enable `MemberImportVisibility` and their
`_NIOFileSystem` target (pulled by Vapor, not by Hummingbird) fails to
compile on the Swift 6.2.x Linux toolchain — **reproducible with bare Vapor
and zero ServerFoundationModels involvement**, across nio versions and on both
swift:6.2.4 and 6.2.3 images. Until NIO/toolchain reconcile, build Vapor
apps with:

```sh
swift build -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility
```

## Why coexistence is clean

- ServerFoundationModels's default build has no NIO dependency, so it imposes
  nothing on a host app's NIO version resolution.
- With the `AsyncHTTPClient` trait enabled, it shares the host's NIO event
  loops via `HTTPClient.shared` — no second runtime.
- The library is strict-Swift-6 (`Sendable`-clean), holds no main-actor
  assumptions, and sessions are safe to create per-request in handlers.
