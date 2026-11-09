// Effect v4 GA code the language service finds nothing in.
import { Context, Effect } from "effect"

export class Clock extends Context.Service<Clock, { readonly now: Effect.Effect<number> }>()("app/Clock") {}

export const program = Effect.gen(function*() {
  const clock = yield* Clock
  return yield* clock.now
})
