# openrouter-parity — live bridge smoke

Drives the ServerFoundationModels **working tree** through
[OpenrouterForFoundationModels](https://github.com/euwars/OpenrouterForFoundationModels)
(built with its `ServerFoundationModels` trait) against a real OpenRouter
model, asserting the contracts the in-repo suite can only exercise against
the on-device model: plain respond, cumulative streaming, guided
generation, and the tool loop. Works on macOS and Linux.

```sh
OPENROUTER_API_KEY=<key> swift run --package-path integration/openrouter-parity
OPENROUTER_PARITY_MODEL=<id>   # optional; defaults to anthropic/claude-sonnet-4.5
```

This is deliberately its own package, not a target of the root manifest:
the bridge depends on ServerFoundationModels, so the root package can never
depend on it without a cycle. Here the local checkout overrides that
transitive dependency (SwiftPM's same-identity path override — the
"Conflicting identity" warning it prints is that mechanism working), so
every run exercises the working tree, not a released tag.

`scripts/linux-verify.sh` runs this smoke automatically when
`OPENROUTER_API_KEY` is set.
