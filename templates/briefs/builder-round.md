# {{task}} brief (builder): fix review findings on {{title}}

Path: {{path}}; you are a fresh builder taking over the task for one fix round, since the builder before you held a long context and stowed.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}}, against `{{base}}` (none on a first review before the PR: a gated project's, before its gate opens it, or a Disclosure task's, before its first push).
Task directory: `{{task_dir}}/` in the worktree (excluded from git): `spec.md`, `tickets/`, `build-notes/`, the reviews' findings and the stowed builder's `handoff.md`.{{ui}}

## Do

1. Bring the branch to its head on origin, which `team-catch-up` may have moved on a PR: `git fetch origin && git merge --ff-only origin/{{branch}}`, leaving the merge out when there is no `origin/{{branch}}`; if the merge fails, send `{{task}} BLOCKED <git's reason>` to `coordinator`.
2. Your branch must hold what the stowed builder pushed (`! git rev-parse -q --verify origin/{{branch}} || git merge-base --is-ancestor origin/{{branch}} HEAD`, which passes with no `origin/{{branch}}`: a Disclosure task's builder pushes nothing before its review passes, and its stow commits here), else send `{{task}} BLOCKED <what differs>` to `coordinator`.
3. Read `{{task_dir}}/spec.md`, every note in `{{task_dir}}/build-notes/`, `{{task_dir}}/handoff.md`, and findings {{findings}} in `{{findings_file}}`.
4. Fix each finding on the branch as narrowly as it asks, test-first where it changes behaviour; a fix that would reach shapes the finding did not name goes to `coordinator` as `{{task}} QUESTION` first, and delete `{{task_dir}}/handoff.md` once its work is done.
   Answer a finding with a test plan as your role says: its test first, run before you change the code, and a note in `{{task_dir}}/build-notes/` saying whether it failed.
5. Then deliver as below; when the PR exists, push to it where a step opens one and bring the PR body's local checks line up to the head you pushed (`gh pr edit <full url> --body-file <file>`), and when it is none, the delivery opens it as it says.
   The delivery ends at the `PR` it sends (on a gated project, once the gate's run, its ci step skipped, or the base's merge after it has pushed), with no wait on the PR's GitHub checks and nothing more pushed: the next review reads the head you pushed, and a red check comes back to you from the coordinator as another fix round.

{{> delivery}}

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
