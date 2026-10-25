# {{task}} brief (reviewer): review {{title}}

Path: {{path}}; you are the reviewer.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}} against `{{base}}`, head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, `build-notes/`.{{ui}}

## Check, beyond what every review covers

{{checks}}

## Deliver

- Local checks: {{local_checks}}.
  Run each from the worktree's root on `{{head}}` and say in `{{task_dir}}/review.md` whether it passed; a failure is **blocking**, and they set no GitHub status.
- Write your findings to `{{task_dir}}/review.md`, each with its file and line and marked **blocking** or **note**; the PR comment is that file, posted with this exact command, the only comment your settings allow: `{{team_bin}}/team-review-comment {{pr}} {{task_dir}}/review.md`.
- The status on the head you reviewed, with this exact command, the only status your settings allow: `{{team_bin}}/team-review-status {{pr}} {{head}} <success|failure> "<one line, at most 140 characters>"`.
  It sets the status on `{{head}}`, the head you reviewed, and refuses when the PR has moved past it: then set nothing and tell the coordinator.
- Send `{{task}} DONE pass {{pr}}` or `{{task}} DONE findings {{task_dir}}/review.md` to `coordinator`.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
