# 05: `team-brief` derives a rereview's facts and writes each brief's record

Phase 1.

**What to build:** `team-brief T<n> rereview` (and T171's `verify`) renders with no `--set` at all: `reviewed` from the latest review, `pr` and `head` from the latest `pr` event or GitHub when the PR moved, and the derived `since`, the caller's own `since` added after it.
Every brief `team-brief` writes gets its record, `brief[-<name>].json`, with its template, project and filled values.
All as the spec's "Briefs" says, including the fetch, the rewritten-branch case and the merges' conflicted files.

**Blocked by:** None

**Waits for:** T171 merged (it changes `templates/briefs/rereview.md` and adds `verify.md`).

**Files:** `bin/team-brief`, `templates/briefs/rereview.md`, `templates/briefs/verify.md`, `tests/team-brief.bats`, `roles/coordinator.md` (step 5's rereview words).

- [x] With a `review` and a `pr` in the ledger and a worktree whose branch has two own commits, one clean merge of `origin/<base>` and one conflicted merge since the reviewed head, the rendered `since` names each commit's short sha and subject, each merge with its conflicted files or "no conflicts", the sent-back numbers, and the base's commits as not to review.
- [x] A build note changed after the review is named; one older is not.
- [x] A reviewed head that is not an ancestor of the head gives the `git range-diff` line instead of a commit list.
- [x] The `gh` stub's newer head wins over the ledger's, said on stderr; an unreadable GitHub is refused naming `--set head=`; an unreachable fetch is exit 75; nothing is written on either.
- [x] A `--set` of a derived key wins; `--set-file since=` is added under "The coordinator adds:".
- [x] Every rendered brief has its `.json` record, replaced with `--force`, holding exactly the non-fact placeholders' values.
- [x] `team-brief --help` documents the derived keys and the record.
- [x] `tests/run` passes.

## Found along the way

- `verify` still needs `--set findings=`: `findings` is ticket 07's derived key, and its derivation will cover `verify` too, since a derived default applies wherever its template uses it.
- The derivation of `reviewed`, `pr` and `head` applies to every template, so `reviewer`, `builder-merge-base` and `builder-round` now fill `pr` (and `reviewer` its `head`) from the ledger and GitHub when not set; ticket 07 keeps `builder-round`'s `none` before a gated project's gate.
- `templates/briefs/verify.md` needed no change: it uses no `since`.
