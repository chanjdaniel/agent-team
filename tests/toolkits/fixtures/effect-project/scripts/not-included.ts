// A v3 habit in a file the fixture's tsconfig does not include, so the hook says nothing of it.
import { Effect } from "effect"

export const caught = Effect.fail("x").pipe(Effect.catchAll(() => Effect.succeed(0)))
