# 11: `team-state` and `team-snapshot` say where each task is

Phase 2.

**What to build:** team-state's JSON gains `progress` (tickets done of total, the brief each live worker is on, the review count and the latest review's verdict, head and sent-back findings), and its pr part `behind_by`; the text line shows them, so `team-snapshot`'s digest carries every open task's progress, as the spec's "Progress in `team-state`" says.

**Blocked by:** 04, 10

**Files:** `bin/lib/ledger.jq`, `bin/lib/team.sh` (`pr_part`), `bin/team-state`, `bin/team-snapshot`, `tests/team-state.bats`, `tests/team-snapshot.bats`, `tests/session-digest.bats`.

- [ ] A fixture task with 7 tickets, 3 `ticket-done` and a live builder launched on `brief-build-04` shows `tickets 3/7` and `on build-04`.
- [ ] A task whose latest review sent back 5 and 6 shows `review <k> findings, sent back 5, 6`.
- [ ] The `gh` stub's compare says 16 behind: `16 behind dev`; an unreadable compare leaves `behind_by` null and the line without it.
- [ ] A task with no tickets, no review and no PR prints as it does on `dev`.
- [ ] `--json` keeps `schema: team-state/1` and every existing field; both headers document the new ones.
- [ ] `tests/run` passes.
