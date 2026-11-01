# 07: `builder-round` reads its findings file, and the fix and deliver briefs need no `--set`

Phase 1.

**What to build:** `builder-round` names `{{findings_file}}` where it named `review.md`, and `team-brief` derives `findings` (the latest review's `sent_back`), `findings_file` (the newest of `review.md` and `rereview*.md`), `pr` (the latest `pr` event, or `none` before a gated project's gate) and `goal` (the first sentence of the plan's `## Goal`), for `builder-round` and, for `goal`, `builder-deliver`, as the spec's "Briefs" says.

**Blocked by:** 01, 06

**Files:** `bin/team-brief`, `templates/briefs/builder-round.md`, `tests/team-brief.bats`, `roles/coordinator.md` (steps 4 and 5 lose their `--set` lists).

- [x] `team-brief T<n> builder-round` with a review whose `sent_back` is `[3,5]` and a newer `rereview.md` renders "findings 3 and 5 in `.scratch/task/rereview.md`".
- [x] `team-brief T<n> builder-deliver` takes the goal from a fixture plan's `## Goal`; a plan with none is refused naming `--set goal=`.
- [x] A `--set` of any of the four wins; with no review, `findings` is refused naming `--set findings=`.
- [x] `tests/run` passes (shellcheck, the bats suite and the toolkit tests, 8m 27s).

## Found along the way

- The derivation is generic, as ticket 05's is: `findings` fills `verify`'s too (the manual's step 5 lost `verify --set findings=`), and `goal` fills `builder-fix`'s, whose refusal now says why when the plan has no goal.
- `builder-round`'s `pr` of `none` is the only template-specific rule: on any other template, or a direct-PR project, no `pr` event is refused as before.
- `templates/briefs/verify.md` still names `review.md` for the notes sent back, though a rereview's findings land in `rereview.md` as well; left as is, outside this ticket.
- The refusal's "nothing to derive them from" list sorted whole entries, which put `findings_file (` before `findings (` in some locales; it now follows the sorted key list.
