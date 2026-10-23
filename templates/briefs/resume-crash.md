# {{task}} brief ({{role}}): resume {{title}} after a crash

Path: {{path}}; you are the {{role}}, resuming the task from the checkpoint of {{checkpoint}}: {{machine}} stopped without a handoff.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`, made on this machine from what was pushed and that checkpoint.
Task directory: `{{task_dir}}/` in the worktree, restored from the task's archive as that checkpoint left it.

## What may be missing

The checkpoint is the last of the task that {{machine}} saved.
Up to 15 minutes of work before {{machine}} stopped may be missing, and so may any no-mistakes run that was in flight, with whatever it would have pushed or reported.
The uncommitted changes of that checkpoint: {{snapshot}}.
Check before you build on any of it.

## Do

1. Read your brief `{{brief}}`: your work and how to deliver it are still what it says.
2. Then `{{task_dir}}/handoff.md` if it exists: it is from an earlier stow, older than the checkpoint.
3. Check what is here against what your brief, the tickets and the build notes say is done: `git status`, `git diff` and `git log origin/{{base}}..HEAD`; a ticket ticked off whose work is not here is not done.
4. Continue from there.

## Rules

Never the em dash; refer to Daniel with they/them.
