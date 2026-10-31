# {{task}} brief (planner): {{title}}

Path: {{path}}; you are the planner: a detailed spec and tickets.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}` from `origin/{{base}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git).

## Read first

- The high-level plan: `{{plan}}`.
{{read}}{{ui}}

## Deliver, in `{{task_dir}}/`

1. `spec.md`, following `~/.claude/skills/to-spec/SKILL.md` (read and follow it; do not stop to check seams with the user: choose them and state them).
2. `tickets/NN-<slug>.md`, following `~/.claude/skills/to-tickets/SKILL.md` the same way (skip its quiz), each with `Blocked by:` and a `- [ ]` acceptance list, and small enough for one fresh builder who reads only `spec.md`, that ticket and the files it names.
   With more than eight tickets, or when another open or queued task waits on files this one changes, group them into phases in `spec.md`: each phase ends in its own PR that leaves `{{base}}` working, and the phase that changes the files others wait on comes first.
3. `scope.txt`, every path the tickets change, one repository path per line: a file, or a directory ending in `/` that covers everything under it, with no leading `/`, no `.` or `..` and no glob; the coordinator puts it to Daniel with the plan, whose approval may let the PR merge with no second ask when it changes nothing outside it.
4. Send `{{task}} DONE {{task_dir}}/spec.md` to `coordinator`.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Markdown: one sentence per line; never the em dash, use "-"; refer to Daniel with they/them.
