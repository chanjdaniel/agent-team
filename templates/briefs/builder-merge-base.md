# {{task}} brief (builder): merge {{base}} into {{title}}

Path: {{path}}; you are the builder who brings the task's PR up to date with its base, which moved after the PR was opened.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}}, against `{{base}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git): `spec.md`, `tickets/`, `build-notes/`, and `handoff.md` when a builder before you stowed.

## Do

1. Bring the branch to its head on origin, which `team-catch-up` may have moved on a PR: `git fetch origin && git merge --ff-only origin/{{branch}}`, leaving the merge out when there is no `origin/{{branch}}`; if the merge fails, send `{{task}} BLOCKED <git's reason>` to `coordinator`.
2. Read `{{task_dir}}/spec.md`, every note in `{{task_dir}}/build-notes/` and `{{task_dir}}/handoff.md` when it exists, so you resolve each conflict as the task means it; delete `handoff.md` once the merge is pushed.
3. Merge `origin/{{base}}` with a merge commit (`git merge origin/{{base}}`, never a rebase), and note each file that conflicted.
   If `git merge-base --is-ancestor origin/{{base}} HEAD` already holds, there is nothing to merge or push: send step 7's message with no conflicts.
4. Resolve each conflict so both sides keep what they meant; a resolution that is a judgment call on behaviour goes to `coordinator` as `{{task}} QUESTION <the conflict> | options: ...`; then commit the merge.
   Then find what the merge made false, a file, command, flag, setting or path that one side renames or removes and the other still names, and fix it in a commit of its own.
5. Run the project's local checks ({{local_checks}}) on the merged head with `{{team_bin}}/team-checks {{project}} <full sha>`, which runs them as `team-merge` does, in a fresh detached worktree of that head; fix the branch until all pass on one head.
6. Push the branch; if the PR body names the head its local checks passed on, bring that line up to date (`gh pr edit {{pr}} --body-file <file>`).
   Run no gate: the merge and the fixes of step 4 are re-reviewed, not re-gated.
7. Send `{{task}} DONE merged {{base}} <the full sha of the head> conflicts: <each file that conflicted, or none>` to `coordinator`, which has a fresh reviewer re-check the merge, and stop: you start no wait on the PR's GitHub checks, since the coordinator's script waits on them once that review passes, and a red check comes back to you from the coordinator as a fix round.

Never run a command that needs `sudo`; send `{{task}} BLOCKED <the command> needs sudo` to `coordinator` instead.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
