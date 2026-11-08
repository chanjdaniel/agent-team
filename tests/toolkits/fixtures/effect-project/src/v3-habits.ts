// Code a session with v3 or early-v4-beta habits writes, checked against effect 4.1.2: each line
// below is a habit the language service or the compiler names.
import { Context, Effect, Schema } from "effect"

// v3: Context.Tag with the id first
export class Clock3 extends Context.Tag("Clock3")<Clock3, { readonly now: Effect.Effect<number> }>() {}

// v3: Effect.Service with effect and dependencies
export class Repo3 extends Effect.Service<Repo3>()("Repo3", {
  effect: Effect.succeed({ get: Effect.succeed(1) })
}) {}

// early beta: Schema.TaggedErrorClass
export class BetaError extends Schema.TaggedErrorClass<BetaError>()("BetaError", { message: Schema.String }) {}

// v3: catchAll, fork and either
export const caught = Effect.fail("x").pipe(Effect.catchAll(() => Effect.succeed(0)))
export const forked = Effect.gen(function*() {
  const fiber = yield* Effect.fork(Effect.succeed(1))
  const either = yield* Effect.either(Effect.fail("y"))
  return [fiber, either]
})
