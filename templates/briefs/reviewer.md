# {{task}} brief (reviewer): review {{title}}

Path: {{path}}; you are the reviewer.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}} against `{{base}}`, head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, `build-notes/`.

## Check, beyond what every review covers

{{checks}}

## Deliver

- Write your findings to `{{task_dir}}/review.md`, each with its file and line and marked **blocking** or **note**; the PR comment is that file, posted with this exact command, the only comment your settings allow: `{{team_bin}}/team-review-comment {{pr}} {{task_dir}}/review.md`.
- The status on the PR's head, with this exact command, the only status your settings allow: `{{team_bin}}/team-review-status {{pr}} <success|failure> "<one line, at most 140 characters>"`.
  It sets the status on the head the PR has now, and prints it: if that is not `{{head}}`, the PR moved under your review, so tell the coordinator.
- Send `{{task}} DONE pass {{pr}}` or `{{task}} DONE findings {{task_dir}}/review.md` to `coordinator`.

## Rules

Never the em dash; refer to Daniel with they/them.
