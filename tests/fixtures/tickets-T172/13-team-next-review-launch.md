# 13: `team-next`: the review launch

Phase 2.

**What to build:** `team-next` on a builder's `PR <url>` (with or without its `merged <base> conflicts:` line), `DONE review-ready <sha>` or `DONE merged <base> ...` launches a fresh reviewer: the first review with `--checks`, every later one as `rereview-<k>` (or `verify`, by T171's rule or `--template`) with its derived facts and `--since` added, as the spec's "`team-next`" table says (T25 ticket 03).

**Blocked by:** 06, 12

**Files:** `bin/team-next`, `roles/coordinator.md` (step 5 and the PR row), `tests/team-next.bats`.

- [ ] A first `PR <url>` with `--checks` logs `pr` with the `gh` stub's head and the builder's `done`, renders `brief-review` naming that head, and launches the reviewer with the builder's toolkits; without `--checks` it is refused with nothing changed.
- [ ] A `PR` after a review renders `rereview-2`, then `rereview-3` on the next, with the derived `since`; a `DONE merged` renders the next rereview naming the merge's conflicts.
- [ ] A `DONE review-ready <sha>` that is not the worktree branch's head is refused; one that is logs no `pr` and launches the review of that head.
- [ ] A PR whose head branch is not the task's logs `branch-renamed` too.
- [ ] A rerun after the logging but before the launch launches once and logs nothing again.
- [ ] `tests/run` passes.
