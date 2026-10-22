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

- Add the result to `{{task_dir}}/review.md` under a heading naming `{{head}}`, and post it as one PR comment: `gh pr comment {{pr}} --body-file <file>`.
- The status on the head: `gh api repos/{{repo}}/statuses/{{head}} -f state=<success|failure> -f context=agent-review -f description="<one line>"`.
- Send `{{task}} DONE pass {{pr}}` or `{{task}} DONE findings {{task_dir}}/review.md` to `coordinator`.

## Rules

Never the em dash; refer to Daniel with they/them.
