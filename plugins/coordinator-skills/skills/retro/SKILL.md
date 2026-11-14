---
name: retro
description: Run the team's retro from opening to close. Use when team-sweep reports a retro due, or team-retro status says one is.
---

# Run a retro

A retro is a small task of path `retro`: a planner reads the ledger's evidence since the last retro and writes ranked proposals, and Daniel decides each one.
The retro itself changes nothing; what Daniel approves becomes its own work.

1. **Open.** Run `team-retro status`, and go on only when it says the retro is due.
   Run `team-open agent-team retro research retro-<YYYY-MM-DD> "Retro <YYYY-MM-DD>"`, fill the plan's goal ("proposals from the ledger since <since>, per the retro brief"), and post its outline in the thread as for any task.
   Exit 75 naming no room means the level has no room for a builder: tell Daniel in `#coordinator` once, with its reason, and open the retro once there is room; exit 75 naming the pool's lock means another open held it 10 minutes: run it again.
2. **Brief and launch.** Run `team-brief T<n> retro`, then `team-worker T<n> planner <worktree> -- "Read your brief at <path>"`, the path being what `team-brief` printed.
3. **Relay.** On `T<n> DONE <path>`, run `team-next T<n> -- '<the message>'`, which logs the planner's done with its report and has no hand-off, then read the report.
   Write the question to a file (`mktemp`): a first line asking Daniel to decide the retro's proposals by number, then the report's "What the last changes did" rows, one line each: the change, its verdict and its counts in a phrase.
   Then its proposals, one line each: its number, the change, and its evidence in a phrase.
   After them, one line from the report's Worker time: the builders' median and 90th-percentile lifetime and the top three sinks with their hours.
   Put it with `team-ask T<n> retro --file <file>`, which posts it in the retro's thread, pings Daniel in `#coordinator` and logs the ask and its wait.
4. **Record the answer.** Daniel answers per number; take each message of theirs on it with `team-answer T<n> retro <message id>`, which checks the message is theirs, logs it as the answer, clears the wait and prints its text.
   A change to the schedule in it (a new cadence, or stop) is logged on the same task: `team-log T<n> retro-schedule every_hours=<hours, 0 to stop> discord_message=<id>`.
5. **Act.** Make approved changes to records (the paths `~/agent-team/bin/lib/records` lists) in place, never committing them by hand: the heartbeat's checkpoint commits them on `dev`, or `team-checkpoint --force` at once.
   Once they are made, log them on the retro itself: `team-log T<n> retro-change retro=T<n> proposals="<their numbers>"`.
   Every other approved change becomes one follow-up task, `team-open agent-team small <type> <slug> <title>` (or the project's own task, for a project's file), whose plan lists the approved proposals by number and points at the retro's report.
   Right after opening it, log what it builds, a project's own task too: `team-log T<new> retro-change retro=T<n> proposals="<their numbers>"`.
   `team-retro digest` reads these to tell the next retro when each change landed, so it can judge what each did.
   A rejected proposal needs nothing more: the `answered` event and the archived report keep the next retro from proposing it again.
   Then read `team-queue list`'s waiting items: delete each whose work is no longer wanted, for the checkpoint to commit, and end the `waits:` of each whose wait no longer stands.
6. **Close.** Run `team-close T<n>`: it archives the report to `tasks/T<n>/scratch/report.md`, where the next retro reads it.
   Post the outcome in the thread: what Daniel approved, and the follow-up task.
