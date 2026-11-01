# 19: `team-run-approved` binds Daniel's OK to the exact script

Phase 3.

**What to build:** `asked` takes optional `script` and `sha256`, only together; `bin/team-run-approved T<n> <id>` runs that script only when the ask has an `answered`, the file still hashes the same, it lies under the task's worktree or `tasks/T<n>/`, and this machine holds the lease, capturing its output to `tasks/T<n>/runs/<id>.log` and logging `ran id= exit=`, as the spec's "Phase 3" says (T25 ticket 08, Daniel's A4).

**Blocked by:** 15

**Files:** a new `bin/team-run-approved`, `bin/lib/ledger-contract.json`, `bin/team-log`, `roles/coordinator.md`, `tests/team-run-approved.bats`, `tests/team-log.bats`.

- [ ] Refused with nothing run: no answer, a changed file (naming both hashes), a path outside the task, no lease.
- [ ] The log file and the `ran` event are written whatever the script's exit code, which is the command's own.
- [ ] `team-log asked` refuses `script` without `sha256` and a hash that is not 64 hex digits.
- [ ] The manual names it in one line and stays at most 120 lines.
- [ ] `tests/run` passes.
