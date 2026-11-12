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
   Keep each probe a ticket cites as text in `work/probes/`, and what a probe's run leaves (a test's `TMPDIR`, a build) in a directory of its own, so the task's archive keeps the probes at its close: at most 200 files, none over 1 MiB, and no image, video or build output (`archive_left_out` in `{{team_code}}/bin/lib/team.sh` is the list).
3. Send `{{task}} DONE {{task_dir}}/report.md` to `coordinator`.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never read or print secrets (`.env` values, tokens).
Markdown: one sentence per line; never the em dash, use "-"; refer to Daniel with they/them.
