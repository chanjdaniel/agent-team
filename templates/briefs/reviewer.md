# {{task}} brief (reviewer): review {{title}}

Path: {{path}}; you are the reviewer.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}} against `{{base}}`, head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, `build-notes/`.

## Check, beyond what every review covers

{{checks}}

## Deliver

- Write your findings to `{{task_dir}}/review.md`, each with its file and line and marked **blocking** or **note**; the PR comment is that file: `gh pr comment {{pr}} --body-file {{task_dir}}/review.md`.
- The status on the head: `gh api repos/{{repo}}/statuses/{{head}} -f state=<success|failure> -f context=agent-review -f description="<one line>"`.
- Send `{{task}} DONE pass {{pr}}` or `{{task}} DONE findings {{task_dir}}/review.md` to `coordinator`.

## Rules

Never the em dash; refer to Daniel with they/them.
