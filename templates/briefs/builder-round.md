# {{task}} brief (builder): fix review findings on {{title}}

Path: {{path}}; you are a fresh builder taking over the task for one fix round, since the builder before you held a long context and stowed.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}}, against `{{base}}` (none on a gated project's first review, before its gate opens the PR).
Task directory: `{{task_dir}}/` in the worktree (excluded from git): `spec.md`, `tickets/`, `build-notes/`, the reviews' findings and the stowed builder's `handoff.md`.{{ui}}

## Do

1. Read `{{task_dir}}/spec.md`, every note in `{{task_dir}}/build-notes/`, `{{task_dir}}/handoff.md`, and findings {{findings}} in `{{findings_file}}`.
2. `git fetch origin`; your branch must hold what the stowed builder pushed (`git merge-base --is-ancestor origin/{{branch}} HEAD`), else send `{{task}} BLOCKED <what differs>` to `coordinator`.
3. Fix each finding on the branch, test-first where it changes behaviour, and delete `{{task_dir}}/handoff.md` once its work is done.
   Answer a finding with a test plan as your role says: its test first, run before you change the code, and a note in `{{task_dir}}/build-notes/` saying whether it failed.
4. Then deliver as below; when the PR exists, push to it where a step opens one, and when it is none, the delivery opens it as it says.
   When every one of findings {{findings}} is a plain `note` and the PR exists, send `{{task}} PR <full url>` as soon as the fix is pushed, its local checks pass on that head and the PR body's local checks line names that head (`gh pr edit <full url> --body-file <file>`), and stop there: skip the delivery's wait for the PR's GitHub checks and every step after it, and push nothing more, since the `verify` reviewer waits for those checks while it reads, so the run and the reading overlap, and reviews the head you pushed; a failed check comes back to you from it as a `blocking` finding; on a gated project the gate's run, CI included, goes as the delivery says.

{{> delivery}}

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
