# 08: `team-checkpoint` commits every records path, every 5 minutes

Phase 2.

**What to build:** the heartbeat's checkpoint commits everything `bin/lib/records` lists (plans, briefs and their records, since and checks files, `tasks/queued/`, `projects/`, `projects.toml`, `machine/`, `manual-steps.md`, besides what it commits today), through one library function that `team-handoff` uses too, and it is due every 5 minutes, so every heartbeat run makes one; as the spec's "Checkpoint" says (T25 ticket 07, T170 proposal 6).
The manual and the stow skill drop hand commits of records: `team-checkpoint --force` when one must be durable now.

**Blocked by:** None

**Waits for:** T171 merged (both edit `roles/coordinator.md`).

**Files:** `bin/lib/team.sh`, `bin/team-checkpoint`, `bin/team-handoff`, `bin/team-timers` (its header's 15 minutes), `roles/coordinator.md` (lines 15 and 97), `plugins/coordinator-skills/skills/stow/SKILL.md`, `plugins/coordinator-skills/skills/retro/SKILL.md`, `tests/team-checkpoint.bats`, `tests/team-handoff.bats`, `tests/team-timers.bats`.

- [ ] A checkpoint with a changed `tasks/T1/plan.md`, a new brief and its record, a new `tasks/queued/x.md`, a changed `projects/p/backlog/s.md` and a changed `manual-steps.md` commits them all with the ledger as `chore: checkpoint`.
- [ ] A staged path outside the records is never committed and stays staged; ignored files (`tasks/T1/settings.builder.json`, `tasks/T1/ui/`) stay out.
- [ ] A handoff commits the same set (its test adds `manual-steps.md` and `projects/`).
- [ ] A checkpoint 5 minutes after the last runs; one 3 minutes after says it is not due; the heartbeat's run makes one each time it is due.
- [ ] One real checkpoint's time with the open tasks of the moment is in the build note.
- [ ] The manual names no hand commit of records and stays at most 120 lines; the stow and retro skills say the same.
- [ ] `tests/run` passes.
