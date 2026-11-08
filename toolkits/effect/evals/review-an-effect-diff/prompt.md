---
description: A reviewer asked to review an Effect diff fires the skill, and names the v3 habits with their v4 replacements.
tags: [effect]
model: claude-opus-5-5
max_turns: 15
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

Review this diff to our Effect-TS app, which runs `effect` 4.1.2, and list your findings, each with its fix:

```diff
--- a/src/Billing.ts
+++ b/src/Billing.ts
@@ -1,6 +1,14 @@
 import { Context, Effect } from "effect"
+
+export class Billing extends Context.Tag("Billing")<Billing, {
+  readonly charge: (cents: number) => Effect.Effect<void, string>
+}>() {}
+
+export const chargeOrRefund = (cents: number) =>
+  Effect.gen(function*() {
+    const billing = yield* Billing
+    const fiber = yield* Effect.fork(billing.charge(cents))
+    return fiber
+  }).pipe(Effect.catchAll(() => Effect.succeed(undefined)))
```
