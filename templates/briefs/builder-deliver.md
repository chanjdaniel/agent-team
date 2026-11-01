# {{task}} brief (builder): deliver {{title}}

Path: {{path}}; you are the builder who delivers: {{tickets}} is done and pushed on `{{branch}}`.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git): `spec.md`, `tickets/`, `build-notes/`.

## Do

1. Read `{{task_dir}}/spec.md` and every note in `{{task_dir}}/build-notes/`; the boxes of {{tickets}} are ticked, or the ticket says why not.

{{> delivery}}

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
