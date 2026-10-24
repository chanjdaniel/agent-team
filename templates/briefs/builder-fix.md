# {{task}} brief (builder): {{title}}

Path: {{path}}; you are the builder, then you deliver.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}` from `origin/{{base}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git), for your spec, tickets and notes.

## Read first

- The high-level plan: `{{plan}}`.
{{read}}

## Do

1. Write the spec and tickets yourself in `{{task_dir}}/` if the work needs more than one commit; a small fix needs one or two tickets at most.
2. Commit types for this task: {{commits}}.

{{> delivery}}

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash in docs; refer to Daniel with they/them.
