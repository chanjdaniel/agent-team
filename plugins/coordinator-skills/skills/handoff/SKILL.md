---
name: handoff
description: Hand the team off to another machine on Daniel's word. Use when Daniel says "hand off", or asks to move the team to the laptop, the PC or any other machine.
---

# Hand off

The machine being left stows everything, releases the lease, and retires you; the other machine's `team-resume` brings the team back.
Never hand off while GitHub is unreachable: say so to Daniel and wait.

1. **Check.** Run `team-handoff --check`.
   Exit 1 means this machine does not hold the lease, 75 that GitHub is unreachable: tell Daniel the reason it printed and stop.
2. **Stow yourself.** Follow the `stow` skill's walk through the conversation, so nothing you know lives only here.
3. **Post.** In `#coordinator`: the handoff has started, and what is in flight (each open task, its phase and live workers, from `team-snapshot`).
4. **STOW the workers.** Send `T<n> STOW` to each live worker and log each `T<n> PAUSED stowed` as `paused reason=stowed`.
   Wait up to 10 minutes for every answer; a worker that has not answered by then is stopped by the handoff as it stands, before its checkpoint, which keeps its uncommitted work as `wip/T<n>` for `team-resume` to apply on the other machine (untracked files that may hold a secret stay here, and the handoff names them).
   Name each one that did not answer in the final post.
   Never send `STOW` to an ops session (`T<n>-ops`): it is never carried over, and `team-handoff` ends it with `team-ops-end`, deleting its transcript and answer file.
   If its answer had not reached Daniel yet, say so in the final post: Daniel asks again on the other machine.
5. **Run.** `team-handoff`.
   It stops and removes the workers' sessions (an ops session ended by `team-ops-end`), checkpoints, pushes the task branches, logs `stowed` per open task, captures the Claude config, commits and pushes the team home, disables the heartbeat, releases the lease, and prints the final message: the release line, then what config it captured and any it refused (a `settings.json` with an `env` key, a skill holding a dotenv-like file), which stay for Daniel to review.
   A failure stops it before the release with the reason: fix what it names (a diverged branch goes back to its builder's word, or Daniel's), then run `team-handoff` again, which picks up where it stopped.
   Exit 75: GitHub went away; wait, then run it again.
6. **Post the final message.** What `team-handoff` printed from `Released at` to its end goes in `#coordinator` word for word, with any worker that did not answer STOW.
7. **Retire.** Run `team-handoff --retire` and end your turn: a few seconds later it stops and removes this session.
