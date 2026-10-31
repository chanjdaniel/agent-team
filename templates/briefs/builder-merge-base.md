# {{task}} brief (builder): merge {{base}} into {{title}}

Path: {{path}}; you are the builder who brings the task's PR up to date with its base, which moved after the PR was opened.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}}, against `{{base}}`.
Task directory: `{{task_dir}}/` in the worktree (excluded from git): `spec.md`, `tickets/`, `build-notes/`, and `handoff.md` when a builder before you stowed.

## Do

1. Read `{{task_dir}}/spec.md`, every note in `{{task_dir}}/build-notes/` and `{{task_dir}}/handoff.md` when it exists, so you resolve each conflict as the task means it; delete `handoff.md` once the merge is pushed.
2. `git fetch origin`, then merge `origin/{{base}}` with a merge commit (`git merge origin/{{base}}`, never a rebase), and note each file that conflicted.
   If `git merge-base --is-ancestor origin/{{base}} HEAD` already holds, there is nothing to merge: go to step 6 with no conflicts.
3. Resolve each conflict so both sides keep what they meant; a resolution that is a judgment call on behaviour goes to `coordinator` as `{{task}} QUESTION <the conflict> | options: ...`; then commit the merge.
   Then find what the merge made false, a file, command, flag, setting or path that one side renames or removes and the other still names, and fix it in a commit of its own.
4. Run the project's local checks ({{local_checks}}) on the merged head with `{{team_bin}}/team-checks {{project}} <full sha>`, which runs them as `team-merge` does, in a fresh detached worktree of that head; fix the branch until all pass on one head.
5. Push the branch; if the PR body names the head its local checks passed on, bring that line up to date (`gh pr edit {{pr}} --body-file <file>`).
   Wait for the PR's GitHub checks with `{{team_bin}}/team-ci-wait {{pr}} <the full sha you pushed>`, run with Bash `run_in_background`, and act on how it ended: exit 0, every check passed or the head has none; exit 1, fix each failed check it names and push again, back to step 4, follow a stuck check's message, or, on a head other than the one you pushed, do as its message says; exit 75, run it again, or report as its message says.
   Run no gate: the merge and the fixes of step 3 are re-reviewed, not re-gated.
6. Send `{{task}} DONE merged {{base}} <the full sha of the head> conflicts: <each file that conflicted, or none>` to `coordinator`, which has a fresh reviewer re-check the merge.

Never run a command that needs `sudo`; send `{{task}} BLOCKED <the command> needs sudo` to `coordinator` instead.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
