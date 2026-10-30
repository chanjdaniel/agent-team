# {{task}} brief (builder): fix review findings on {{title}}

Path: {{path}}; you are a fresh builder taking over the task's PR for one fix round, since the builder before you held a long context and stowed.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}}, against `{{base}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git): `spec.md`, `tickets/`, `build-notes/`, `review.md` and the stowed builder's `handoff.md`.

## Do

1. Read `{{task_dir}}/spec.md`, every note in `{{task_dir}}/build-notes/`, `{{task_dir}}/handoff.md`, and findings {{findings}} in `{{task_dir}}/review.md`.
2. `git fetch origin`; your branch must hold the PR's head (`git merge-base --is-ancestor <the PR's head> HEAD`), else send `{{task}} BLOCKED <what differs>` to `coordinator`.
3. Fix each finding on the branch, test-first where it changes behaviour, and delete `{{task_dir}}/handoff.md` once its work is done.
4. Then deliver as below; the PR exists, so where a step opens one, push to it instead.

{{> delivery}}

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
