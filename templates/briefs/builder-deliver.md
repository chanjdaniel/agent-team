# {{task}} brief (builder): deliver {{title}}

Path: {{path}}; you are the builder who delivers: every ticket is done and pushed on `{{branch}}`.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git): `spec.md`, `tickets/`, `build-notes/`.

## Do

1. Read `{{task_dir}}/spec.md` and every note in `{{task_dir}}/build-notes/`; every ticket's boxes are ticked, or the ticket says why not.
2. `git fetch origin`; the branch must merge cleanly with `origin/{{base}}` (`git merge-tree --write-tree origin/{{base}} HEAD` exits 0), else send `{{task}} BLOCKED {{base}} moved: <the conflicting files>` and stop.

{{> delivery}}

## Rules

Never the em dash; refer to Daniel with they/them.
