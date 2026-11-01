# 15: The coordinator's manual and skills in the `team-next` era

Phase 2.

**What to build:** one pass over `roles/coordinator.md` and `plugins/coordinator-skills/` so that each worker report maps to one command (`team-next`, or `team-log --from-message` where there is no hand-off), current items go through `team-current`, records through the checkpoint, and progress comes from `team-state`; the old hand sequences go, and the manual ends shorter than it was before this phase (T25 ticket 09).
`tests/task-life.bats` gains one task driven through `team-next` from its first ticket to the merge ask.

**Blocked by:** 02, 08, 09, 14

**Files:** `roles/coordinator.md`, `plugins/coordinator-skills/skills/*/SKILL.md`, `tests/coordinator-manual.bats`, `tests/task-life.bats`, `CLAUDE.md` (if a command it names changed).

- [ ] The message table names, for `DONE`, `PR` and `PAUSED stowed`, the `team-next` call, and `team-log --from-message` for the rest.
- [ ] No step tells the coordinator to commit records by hand, to edit `current.md` by hand, or to write a since file for facts the ledger holds.
- [ ] Every `bin/team-*` is named in the manual, which is at most 115 lines.
- [ ] The task-life test runs two tickets, the deliver, a review with findings, the holder's fix, a rereview and the pass through `team-next` alone, and checks the ledger it leaves.
- [ ] `team-load-check --context` for the coordinator and each worker role on `dev` and on the phase's head is in the PR body, and the starting context still loads.
- [ ] `tests/run` passes.
