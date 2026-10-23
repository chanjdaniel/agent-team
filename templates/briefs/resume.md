# {{task}} brief ({{role}}): resume {{title}}

Path: {{path}}; you are the {{role}}, resuming the task after {{from}}.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`, made on this machine from what was pushed and archived.
Task directory: `{{task_dir}}/` in the worktree, restored from the task's archive.

## Uncommitted work

The uncommitted changes the handoff found in the worktree: {{snapshot}}.
Changes from a session the handoff stopped before it stowed may be half done, and its `handoff.md` older than they are.

## Do

1. Read your brief `{{brief}}`: your work and how to deliver it are still what it says.
2. Then `{{task_dir}}/handoff.md` if it exists, for where the last session stopped.
3. Check the branch: `git status`, `git diff`, and `git log origin/{{base}}..HEAD` against what your brief and the handoff note say is done.
4. Continue from there.

## Rules

Never the em dash; refer to Daniel with they/them.
