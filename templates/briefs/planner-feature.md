# {{task}} brief (planner): {{title}}

Path: {{path}}; you are the planner: a detailed spec and tickets.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}` from `origin/{{base}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git).

## Read first

- The high-level plan: `{{plan}}`.
{{read}}

## Deliver, in `{{task_dir}}/`

1. `spec.md`, following `~/.claude/skills/to-spec/SKILL.md` (read and follow it; do not stop to check seams with the user: choose them and state them).
2. `tickets/NN-<slug>.md`, following `~/.claude/skills/to-tickets/SKILL.md` the same way (skip its quiz), each with `Blocked by:` and a `- [ ]` acceptance list, and small enough for one fresh builder who reads only `spec.md`, that ticket and the files it names.
3. Send `{{task}} DONE {{task_dir}}/spec.md` to `coordinator`.

## Rules

Read `{{team_home}}/sops/platform-gotchas.md` before your first command.
Markdown: one sentence per line; never the em dash, use "-"; refer to Daniel with they/them.
