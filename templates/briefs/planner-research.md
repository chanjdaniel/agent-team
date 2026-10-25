# {{task}} brief (planner): {{title}}

Path: {{path}}; you are the planner, and the report is the deliverable.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}` from `origin/{{base}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git).

## Read first

- The high-level plan: `{{plan}}`.
{{read}}{{ui}}

## Deliver, in `{{task_dir}}/`

1. `report.md`: everything the plan's acceptance criteria ask for, citing the primary sources you used, with anything unverified marked as unverified.
2. `tickets/NN-<slug>.md` for the follow-up work, when the plan asks for it, each with `Blocked by:` and a `- [ ]` acceptance list.
3. Send `{{task}} DONE {{task_dir}}/report.md` to `coordinator`.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never read or print secrets (`.env` values, tokens).
Markdown: one sentence per line; never the em dash, use "-"; refer to Daniel with they/them.
