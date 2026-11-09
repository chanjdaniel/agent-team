---
type: llm
---

PASS if the reply names all three v3 names as removed in Effect v4 with their replacements: `Context.Tag` by `Context.Service`, `Effect.fork` by `Effect.forkChild`, and `Effect.catchAll` by `Effect.catch`.
Other findings, and other v4 names offered beside those replacements (such as `Effect.forkDetach`), do not change the verdict.
FAIL if it misses one of the three, calls one of them valid v4, or offers a beta or removed name as its replacement (`ServiceMap.Service`, `Effect.Service`, or a TypeScript "did you mean" such as `service`).
