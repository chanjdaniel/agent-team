# {{task}} brief (reviewer): review {{title}}

Path: {{path}}; you are the reviewer.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`; review `origin/{{base}}...{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, `build-notes/`.{{ui}}

## Check, beyond what every review covers

{{checks}}

## Deliver

- Local checks: {{local_checks}}.
  Run them on `{{head}}` with `{{team_bin}}/team-checks {{project}} {{head}}`, which runs them as `team-merge` does, in a fresh detached worktree of that head, and say in `{{task_dir}}/review.md` whether it passed; a failure is **blocking**, and they set no GitHub status.
{{> review}}

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
