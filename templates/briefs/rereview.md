# {{task}} brief (reviewer): re-review {{title}} at its new head

Path: {{path}}; you are the reviewer of a PR that was reviewed before.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}} against `{{base}}`, reviewed at `{{reviewed}}`, now at head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, and `review.md` with the last review's findings.
Since the last review: {{since}}

## Check

1. Every blocking finding in `{{task_dir}}/review.md` is fixed at `{{head}}`, or the PR records Daniel's decision to keep it.
2. Review what changed since the last review, `git diff {{reviewed}} {{head}}`, and the commit messages of `origin/{{base}}..{{head}}`.
3. Wait for the checks on `{{head}}` to finish (`gh pr checks {{pr}} --watch`); every one must pass.

## Deliver

- Add the result to `{{task_dir}}/review.md` under a heading naming `{{head}}`, write the same result alone to `{{task_dir}}/rereview.md`, and post that as one PR comment with this exact command, the only comment your settings allow: `{{team_bin}}/team-review-comment {{pr}} {{task_dir}}/rereview.md`.
- The status on the PR's head, with this exact command, the only status your settings allow: `{{team_bin}}/team-review-status {{pr}} <success|failure> "<one line, at most 140 characters>"`.
  It sets the status on the head the PR has now, and prints it: if that is not `{{head}}`, the PR moved under your review, so tell the coordinator.
- Send `{{task}} DONE pass {{pr}}` or `{{task}} DONE findings {{task_dir}}/review.md` to `coordinator`.

## Rules

Never the em dash; refer to Daniel with they/them.
