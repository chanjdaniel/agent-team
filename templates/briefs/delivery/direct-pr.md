## Deliver as one pull request

1. Bring the branch up to date with the base: `git fetch origin`; if `git merge-base --is-ancestor origin/{{base}} HEAD` fails, merge `origin/{{base}}` with a merge commit (`git merge origin/{{base}}`, never a rebase), resolve any conflict, re-run what the conflicts touched, and push.
   A conflict whose resolution is a judgment call on behaviour goes to `coordinator` as `{{task}} QUESTION <the conflict> | options: ...`.
2. Find what your branch made false: for each file, command, flag, setting and path it adds, renames or removes (`git diff --stat origin/{{base}}...HEAD`), `git grep` its name in the repository's Markdown, `CLAUDE.md`, `AGENTS.md` and script headers, and fix every line that no longer holds, in the same PR.
3. Run the project's local checks ({{local_checks}}) on the head you push with `{{team_bin}}/team-checks {{project}} <full sha>`, which runs them as `team-merge` does, in a fresh detached worktree of that head; fix the branch and push again until all pass on one head.
   They set no GitHub status: their result goes in the PR body.
4. Open one PR from `{{branch}}` to `{{base}}`: `gh pr create --repo {{repo}} --base {{base}} --head {{branch}}`, titled as a Conventional Commit, its body opening with the task's goal: "{{task}}: {{goal}}", then a line naming the local checks that passed and the head they passed on.
5. If `gh pr checks <full url>` lists any GitHub checks, wait for them (`--watch`); fix a failure on the branch and push again until every check passes.
6. Repeat step 1; if it merged anything or you pushed again, go back to step 3 and bring the PR body's local checks line up to date (`gh pr edit <full url> --body-file <file>`), so every required check passes on the new head.
7. Then send `{{task}} PR <full url>` to `coordinator`.

Never run a command that needs `sudo`; send `{{task}} BLOCKED <the command> needs sudo` to `coordinator` instead.
