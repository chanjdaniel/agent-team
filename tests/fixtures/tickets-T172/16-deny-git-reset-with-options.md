# 16: Workers are denied `git reset` with an option before `--hard`

Phase 3.

**What to build:** `settings/worker.json` gains `Bash(git reset * --hard*)` beside `Bash(git reset --hard*)`, so `git reset -q --hard` is denied as the bare form is (T25 ticket 11's remaining half; T37 built the migration rule's half).

**Blocked by:** 15

**Files:** `settings/worker.json`, `tests/repo.bats`.

- [ ] `tests/repo.bats`'s matching model denies `git reset -q --hard`, `git reset --quiet --hard HEAD~1` and `git reset --hard`, and allows `git reset --soft HEAD~1`, `git reset -- file` and `git status`.
- [ ] `team-load-check` passes for each worker role.
- [ ] `tests/run` passes.
