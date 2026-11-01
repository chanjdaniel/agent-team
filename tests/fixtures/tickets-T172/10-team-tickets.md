# 10: Strict ticket lines and `team-tickets`

Phase 2.

**What to build:** `bin/team-tickets T<n> [--check] [--json]`, read-only, lists each ticket of the task's open worktrees as done, running, ready, waiting or blocked, from the ledger and the ticket files, with the strict `Blocked by:` and `Waits for:` lines the spec's "`team-tickets`" gives (T25 ticket 01, without `Touches:`).
The planner templates and `roles/planner.md` give the two formats.

**Blocked by:** 04

**Files:** a new `bin/team-tickets`, `templates/briefs/planner-feature.md`, `templates/briefs/planner-interview.md`, `roles/planner.md`, `roles/coordinator.md`, `tests/team-tickets.bats`.

- [ ] Over a fixture ticket set (this task's own tickets copied in), `team-tickets` prints one line per ticket with its state and, when blocked or waiting, what it waits on; `--json` prints the same as a list.
- [ ] `running` comes from a builder launch logged with `brief: "brief-build-NN"` and no `ticket-done` of NN since.
- [ ] `--check` refuses, naming file and line, a missing line, two `Blocked by:` lines, `Blocked by: None. Do it next`, a blocker that is no ticket, and a cycle; a clean set is exit 0.
- [ ] The bold and plain labels both parse.
- [ ] The planner templates and role give both formats; the manual names `team-tickets` and stays at most 120 lines.
- [ ] `tests/run` passes.
