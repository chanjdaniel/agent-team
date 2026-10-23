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
   Wait up to 10 minutes for every answer; a worker that has not answered by then is stopped by the handoff as it stands, and the checkpoint keeps its uncommitted work as `wip/T<n>`.
   Name each one that did not answer in the final post.
5. **Run.** `team-handoff`.
   It checkpoints, pushes the task branches, logs `stowed` per open task, captures the Claude config, stops and removes the workers' sessions, commits and pushes the team home, disables the heartbeat, releases the lease, and prints the final message.
   A failure stops it before the release with the reason: fix what it names (a diverged branch goes back to its builder's word, or Daniel's), then run `team-handoff` again, which picks up where it stopped.
   Exit 75: GitHub went away; wait, then run it again.
6. **Post the final message.** What `team-handoff` printed last goes in `#coordinator` word for word, with any worker that did not answer STOW.
7. **Retire.** Run `team-handoff --retire` and end your turn: a few seconds later it stops and removes this session.
