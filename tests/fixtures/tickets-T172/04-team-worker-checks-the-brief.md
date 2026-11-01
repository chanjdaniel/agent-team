# 04: `team-worker` refuses a missing brief and logs the brief it launches with

Phase 1.

**What to build:** `team-worker` refuses a prompt that names a `brief*.md` path that does not exist or cannot be read, or that says "your brief" and names none, before it launches anything; and the launch event gains an optional `brief`, the brief's file name without `.md`, when the prompt names one under the task's `tasks/T<n>/`, as the spec's "Briefs" says.

**Blocked by:** None

**Files:** `bin/team-worker`, `bin/lib/ledger-contract.json`, `tests/team-worker.bats`.

- [ ] `-- "Read your brief at "` (the empty path the failed pipe gave) and `-- "Read your brief at ~/x/tasks/T1/brief-nope.md."` are refused, exit 1, naming the path or its absence, with no `claude` call and no ledger line.
- [ ] A prompt naming an existing brief launches as before and logs `brief: "brief-rereview-3"`; one naming none (an ops prompt with the brief's text) logs no `brief`.
- [ ] `~/` and `$HOME` forms and trailing punctuation are handled; a brief of another task's directory launches but logs no `brief`.
- [ ] `team-log --check` accepts the new field; `team-worker --help` says both.
- [ ] `tests/run` passes.
