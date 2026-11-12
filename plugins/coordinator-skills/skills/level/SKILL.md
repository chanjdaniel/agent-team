---
name: level
description: Set the team's resource level on Daniel's word, and stow or relaunch tasks to fit it. Use when Daniel says "level full", "level minor", "level none", "auto", "manual" or "shut down" in #coordinator, or team-sweep reports a level-stow, level-resume or level-launch finding.
---

# Level

The team runs at one of three levels, each a share of this machine: full (90%), minor (30%) and none (0%); `sops/resources.md` says how each is held.
In manual mode the level holds until Daniel changes it; in automatic mode the heartbeat picks it from what Daniel's own programs use.
`team-level` records each change in the team home's `level.jsonl`, so the level holds across restarts and handoffs.
You stay up at every level, outside the share.

## Daniel's word

1. **Record.** On Daniel's "level full", "level minor", "level none", "auto" or "manual" in `#coordinator`, run `team-level <word> --message <id>`, the id being their message's.
   It records the change in `level.jsonl`, applies the limits, and prints one line, "Resources: manual, minor (30%): 9.2 GiB and 3.6 cores for the team; 6.1 GiB reserved; T171 and T174 stow."
2. **Acknowledge.** Post that line in `#coordinator` word for word, with any line it said on stderr about a limit it could not set.
3. **Stow.** When the line names tasks to stow, stow them as "Stowing tasks" says, with `--stop-runs`: Daniel asked for the room now, so a running test or gate stops.
   "Nothing needs to stow" ends it; "what must stow is unknown" means `team-capacity plan` failed: post its reason (on stderr) and wait for the sweep's `level` finding.

"Shut down" is not a level: follow the `handoff` skill's same-machine case.

## The sweep's findings

- `level-stow` ("level: over budget at minor (30%): stow T174, then T171", newest task first) comes once `team-capacity plan` confirms the team is over budget, in two readings in a row or in one since the level changed, a drop automatic mode made included: stow the tasks it names as "Stowing tasks" says, without `--stop-runs`, so a running test or gate finishes first.
- `level-resume` ("level: T171 fits again: relaunch its builder") names one task at a time, the earliest stowed of those that fit, whether the level or a handoff stowed it (one the `resume` skill could not relaunch): relaunch it as "Relaunching a task" says, and once it is launched the next finding names the next.
  It never names a task on hold: Daniel's hold (`held discord_message=<their message id>`) and an ask no launch went past hold it wherever they were logged, and to keep a stowed task stowed otherwise, log `waiting on=<who>` after its stow; `resumed id=<that park>` lifts it (Daniel's hold only with `discord_message=` of their word), the ask's answer ends its hold, and `level-resume` then names it once it fits.
- `level-launch` ("level: T5 has room again: launch its reviewer, refused for room at <time>") names a task whose launch `team-worker` refused with 75, which logs that refusal itself (`paused cause=room role=<role>`, with its line), one task at a time: run the same `team-worker` command again, with the brief you wrote for it; a 75 again logs its own `paused`, and the next `level-launch` names it again.
  For a ticket builder of a parallel phase (its `paused` names a `brief-build-NN` brief, and `team-state T<n>` lists ticket NN's worktree), run `team-next T<n> --fill` instead, never by role: it launches each ticket ready under the cap, and its own 75 says which tickets wait for room.
  It never names a task on hold either: Daniel's hold and an ask no launch went past hold it wherever logged, and `waiting on=<who>` after the refusal keeps it unlaunched; `resumed id=<that park>` lifts it.
- `level` (an error) is `team-capacity`'s: fix what it names, or take it to Daniel.

## Stowing tasks

1. **STOW.** First run `team-stow <tasks> --begin`, which logs each task's `stowing`, so a compaction or restart before step 4 does not plan the same stow again; then send `T<n> STOW` to each live worker of the named tasks (`team-state T<n>` lists them), each ticket builder `T<n>-builder-NN` among them, but never to an ops session (`T<n>-ops`), which `team-stow` ends.
2. **Stop runs.** For Daniel's manual change only, run `team-stow <tasks> --stop-runs` right after: it stops each task's heavy run and aborts its active gate run, so a worker blocked in one returns and reads the STOW.
3. **Wait.** Wait up to 10 minutes for each `T<n> PAUSED stowed`, logging each with `team-log T<n> --from-message '<the message>'`, never `team-next`, which would launch a fix round's builder.
4. **Run.** `team-stow <tasks>`: it stops the tasks' sessions and stacks, checkpoints, pushes their branches and logs one `stowed` per task, with cause level.
   A worker that had not answered is stopped as it stands; the checkpoint keeps its uncommitted work.
   Exit 1 names each task it refused (a diverged branch, a session that would not stop), each logged `stow-failed`: fix what it names, then run it again, which stows only what is left.
   Exit 75: GitHub is unreachable or another `team-stow` runs; run it again once that clears.
5. **Post.** In each task's thread: stowed for the level, and who did not answer STOW.

## Relaunching a task

A ticket builder of a parallel phase (a builder whose last launch has a `ticket` in `team-state T<n> --json`'s workers) is relaunched with `team-next T<n> --fill`, never by role: it relaunches each stowed ticket builder in its own ticket worktree on its resume brief, then launches each ticket ready under the cap; its 75 is step 2's, and step 3 follows once it has run.

1. **Brief.** For each role the `level-resume` finding names: its last brief, the newest `tasks/T<n>/brief*.md` whose first line is `# T<n> brief (<role>)`, other than a `brief-resume-*.md`; then `team-brief T<n> resume --name resume-<role> --force --set role=<role> --set brief=<that brief> --set from="the stow for the level at <the stowed time>" --set snapshot="none: your worktree stayed in place, as you left it"`, or for a task a handoff stowed the `from` and `snapshot` the `resume` skill gives it.
2. **Launch.** `team-worker T<n> <role> <worktree> -- "Read your brief at <path>"`, with each `--toolkit` of the role's last launch.
   It refuses a task on Daniel's hold, one with an open ask unless `--past-ask <id>` names it, and a feature task's build before its plan, each with its reason, starting nothing.
   Exit 75 means the level's budget has no room for it after all (`team-capacity admit`), and `team-worker` has logged its `paused cause=room` itself: leave it for the next `level-resume` (or, once a launch followed the stow, `level-launch`).
3. **Log.** `team-log T<n> resumed all=true` once the task's roles run again, which ends every park but Daniel's hold and an ask's wait, and say so in its thread.
