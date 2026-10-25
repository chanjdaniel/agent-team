# {{task}} brief (builder): ticket {{ticket}} of {{title}}

Path: {{path}}; you are a builder, on one ticket only.
The plan and spec are approved.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git): `spec.md`, `tickets/`, `build-notes/`.
Your ticket: number {{ticket}} in `{{task_dir}}/tickets/`.
Its blockers are done on this branch.{{ui}}

## Do

1. Read `{{task_dir}}/spec.md`, your ticket, the files it names, and every note in `{{task_dir}}/build-notes/`.
2. Tick every box you meet in the ticket; leave an unmet one unticked with the reason, and note anything else you find under "Found along the way".
3. Write `{{task_dir}}/build-notes/{{ticket}}.md` for the next builder: what exists, the decisions to know, and how it is tested.
4. Do not open a PR: the builder who delivers does that once for the whole task.
5. Send `{{task}} DONE {{ticket}} <sha> <one line>` to `coordinator`, or `{{task}} BLOCKED {{ticket}} <why>`.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Stay inside your ticket.
Never the em dash; refer to Daniel with they/them.
