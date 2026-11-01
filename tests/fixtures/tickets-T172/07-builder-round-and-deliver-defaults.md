# 07: `builder-round` reads its findings file, and the fix and deliver briefs need no `--set`

Phase 1.

**What to build:** `builder-round` names `{{findings_file}}` where it named `review.md`, and `team-brief` derives `findings` (the latest review's `sent_back`), `findings_file` (the newest of `review.md` and `rereview*.md`), `pr` (the latest `pr` event, or `none` before a gated project's gate) and `goal` (the first sentence of the plan's `## Goal`), for `builder-round` and, for `goal`, `builder-deliver`, as the spec's "Briefs" says.

**Blocked by:** 01, 06

**Files:** `bin/team-brief`, `templates/briefs/builder-round.md`, `tests/team-brief.bats`, `roles/coordinator.md` (steps 4 and 5 lose their `--set` lists).

- [ ] `team-brief T<n> builder-round` with a review whose `sent_back` is `[3,5]` and a newer `rereview.md` renders "findings 3 and 5 in `.scratch/task/rereview.md`".
- [ ] `team-brief T<n> builder-deliver` takes the goal from a fixture plan's `## Goal`; a plan with none is refused naming `--set goal=`.
- [ ] A `--set` of any of the four wins; with no review, `findings` is refused naming `--set findings=`.
- [ ] `tests/run` passes.
