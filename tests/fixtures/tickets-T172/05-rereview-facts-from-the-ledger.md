# 05: `team-brief` derives a rereview's facts and writes each brief's record

Phase 1.

**What to build:** `team-brief T<n> rereview` (and T171's `verify`) renders with no `--set` at all: `reviewed` from the latest review, `pr` and `head` from the latest `pr` event or GitHub when the PR moved, and the derived `since`, the caller's own `since` added after it.
Every brief `team-brief` writes gets its record, `brief[-<name>].json`, with its template, project and filled values.
All as the spec's "Briefs" says, including the fetch, the rewritten-branch case and the merges' conflicted files.

**Blocked by:** None

**Waits for:** T171 merged (it changes `templates/briefs/rereview.md` and adds `verify.md`).

**Files:** `bin/team-brief`, `templates/briefs/rereview.md`, `templates/briefs/verify.md`, `tests/team-brief.bats`, `roles/coordinator.md` (step 5's rereview words).

- [ ] With a `review` and a `pr` in the ledger and a worktree whose branch has two own commits, one clean merge of `origin/<base>` and one conflicted merge since the reviewed head, the rendered `since` names each commit's short sha and subject, each merge with its conflicted files or "no conflicts", the sent-back numbers, and the base's commits as not to review.
- [ ] A build note changed after the review is named; one older is not.
- [ ] A reviewed head that is not an ancestor of the head gives the `git range-diff` line instead of a commit list.
- [ ] The `gh` stub's newer head wins over the ledger's, said on stderr; an unreadable GitHub is refused naming `--set head=`; an unreachable fetch is exit 75; nothing is written on either.
- [ ] A `--set` of a derived key wins; `--set-file since=` is added under "The coordinator adds:".
- [ ] Every rendered brief has its `.json` record, replaced with `--force`, holding exactly the non-fact placeholders' values.
- [ ] `team-brief --help` documents the derived keys and the record.
- [ ] `tests/run` passes.
