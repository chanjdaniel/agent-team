# 17: The team's `autoMode` block, proven by a load check

Phase 3.

**What to build:** an `autoMode` block in `settings/worker.json` whose `environment` lines state the team's facts (T25 report section 4.5, brought up to date as the spec's "Phase 3" says), merged by `team-worker` with any role's lines as it merges permission lists, and shown by `team-load-check` as the launched worker sees it (T25 ticket 10).
The lines are Daniel's to approve at the PR.

**Blocked by:** 16

**Files:** `settings/worker.json`, `bin/team-worker`, `bin/team-load-check`, `tests/team-worker.bats`, `tests/team-load-check.bats`, `tests/repo.bats`.

- [ ] The generated `tasks/T<n>/settings.<role>.json` holds the shared lines plus the role's, `"$defaults"` once per list.
- [ ] A load check shows the worker's effective `autoMode` holding the team lines; if a `--settings` file's `autoMode` is not read, the ticket stops and reports it with the output instead.
- [ ] No line grants an action ("is allowed", "may", "can"); a test greps for those words.
- [ ] `claude auto-mode critique`'s output on the block is in the build note.
- [ ] `tests/run` passes.
