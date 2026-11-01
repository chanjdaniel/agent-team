---
name: handoff
description: Hand the team off to another machine, or to this one for a restart, on Daniel's word. Use when Daniel says "hand off" or "shut down", or asks to move the team to the laptop, the PC or any other machine.
---

# Hand off

The machine being left stows everything, releases the lease, and retires you; the other machine's `team-resume` brings the team back.
Never hand off while GitHub is unreachable: say so to Daniel and wait.

## The same-machine case: "shut down"

On Daniel's "shut down" (the PC goes down for a while and the team comes back on it), follow the steps below with three changes:

- Step 1 asks nothing about `team-resume --wait`, since no other machine takes the team: run `team-handoff --check` alone.
- Step 5 runs `team-handoff --here`: the stacks are stopped, their data kept for the restart, instead of taken down.
- Step 6's final post is still what it printed from `Released at`, whose first line now tells Daniel to run `team-resume` here after the restart.

The level recorded in `level.jsonl` holds across the restart; `team-resume` then brings back what it allows, as the `resume` skill says.

## Steps

1. **Check.** Before anything is stowed, ask Daniel whether `team-resume --wait` is running on the machine taking the team and has printed "this machine is ready", and wait for the yes.
   Its doctor and its check of the two checkouts run before its wait, so it is the other machine's preflight: what it refuses is fixed there while the team still runs here.
   On a no, tell Daniel to start it there first and stop until they say it is ready.
   Then run `team-handoff --check`.
   Exit 1 means this machine does not hold the lease, 75 that GitHub is unreachable: tell Daniel the reason it printed and stop.
2. **Stow yourself.** Follow the `stow` skill's walk through the conversation, so nothing you know lives only here.
3. **Post.** In `#coordinator`: the handoff has started, and what is in flight (each open task, its phase and live workers, from `team-snapshot`).
4. **STOW the workers.** Send `T<n> STOW` to each live worker and log each `T<n> PAUSED stowed` as `paused reason=stowed`.
   Wait up to 10 minutes for every answer; a worker that has not answered by then is stopped by the handoff as it stands, before its checkpoint, which keeps its uncommitted work as `wip/<project>/T<n>` on the team home's origin for `team-resume` to apply on the other machine (untracked files that may hold a secret stay here, and the handoff names them).
   Name each one that did not answer in the final post.
   Never send `STOW` to an ops session (`T<n>-ops`): it is never carried over, and `team-handoff` ends it with `team-ops-end`, deleting its transcript and answer file.
   If its answer had not reached Daniel yet, say so in the final post: Daniel asks again on the other machine.
5. **Run.** `team-handoff`.
   It stops and removes the workers' sessions (an ops session ended by `team-ops-end`), checkpoints, pushes the task branches, logs `stowed` per open task, captures the Claude config, commits and pushes the team home, disables the heartbeat, releases the lease, and prints the final message: the release line, then what config it captured and any it refused (a `settings.json` with an `env` key, a skill holding a dotenv-like file), which stay for Daniel to review.
   A failure stops it before the release with the reason: fix what it names (a diverged branch goes back to its builder's word, or Daniel's), then run `team-handoff` again, which picks up where it stopped.
   Exit 75: GitHub went away; wait, then run it again.
6. **Post the final message.** What `team-handoff` printed from `Released at` to its end goes in `#coordinator` word for word, with any worker that did not answer STOW.
7. **Retire.** Run `team-handoff --retire` and end your turn: a few seconds later it stops and removes this session.
