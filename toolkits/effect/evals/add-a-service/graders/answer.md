---
type: llm
---

PASS if the reply's code defines the service with `Context.Service`, the error with `Schema.TaggedError` (or says why `Data.TaggedError` was chosen), and the layer with `Layer.effect` or `Layer.succeed`.
FAIL if it uses a v3 or early-beta name: `Context.Tag`, `Context.GenericTag`, `Effect.Tag`, `Effect.Service`, `ServiceMap.Service`, `Schema.TaggedErrorClass`, a generated `.Default` layer, or a `dependencies` option.
