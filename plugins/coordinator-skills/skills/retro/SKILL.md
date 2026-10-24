---
name: retro
description: Run the team's retro from opening to close. Use when team-sweep reports a retro due, or team-retro status says one is.
---

# Run a retro

A retro is a small task of path `retro`: a planner reads the ledger's evidence since the last retro and writes ranked proposals, and Daniel decides each one.
The retro itself changes nothing; what Daniel approves becomes its own work.

1. **Open.** Run `team-retro status`, and go on only when it says the retro is due.
   Run `team-open agent-team retro research retro-<YYYY-MM-DD> "Retro <YYYY-MM-DD>"`, fill the plan's goal ("proposals from the ledger since <since>, per the retro brief"), and post its outline in the thread as for any task.
   Exit 75 means the pool is full: tell Daniel in `#coordinator` once which tasks hold the slots; the sweep's finding stays until a slot frees, and you open the retro then.
2. **Brief and launch.** Run `team-brief T<n> retro`, then `team-worker T<n> planner <worktree> -- "Read your brief at <path>"`, the path being what `team-brief` printed.
3. **Relay.** On `T<n> DONE <path>`, log `team-log T<n> done role=planner session=<id> report=<path>`, then read the report.
   Post its proposals in the retro's thread, one line each: its number, the change, and its evidence in a phrase.
   Log the ask with `team-log T<n> asked id=retro text="<each proposal's number and title>"`.
4. **Record the answer.** Daniel answers per number; log `team-log T<n> answered id=retro answer="<the answer>"`.
   A change to the schedule in it (a new cadence, or stop) is logged on the same task: `team-log T<n> retro-schedule every_hours=<hours, 0 to stop> discord_message=<id>`.
5. **Act.** Commit approved changes to records (the paths `~/agent-team/bin/lib/records` lists) on `dev` directly.
   Every other approved change becomes one follow-up task, `team-open agent-team small <type> <slug> <title>` (or the project's own task, for a project's file), whose plan lists the approved proposals by number and points at the retro's report.
   A rejected proposal needs nothing more: the `answered` event and the archived report keep the next retro from proposing it again.
6. **Close.** Run `team-close T<n>`: it archives the report to `tasks/T<n>/scratch/report.md`, where the next retro reads it.
   Post the outcome in the thread: what Daniel approved, and the follow-up task.
