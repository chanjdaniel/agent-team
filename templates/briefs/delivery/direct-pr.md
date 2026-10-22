## Deliver as one pull request

1. Bring the branch up to date with the base: `git fetch origin`; if `git merge-base --is-ancestor origin/{{base}} HEAD` fails, merge `origin/{{base}}` with a merge commit (`git merge origin/{{base}}`, never a rebase), resolve any conflict, re-run what the conflicts touched, and push.
   A conflict whose resolution is a judgment call on behaviour goes to `coordinator` as `{{task}} QUESTION <the conflict> | options: ...`.
2. Open one PR from `{{branch}}` to `{{base}}`: `gh pr create --repo {{repo}} --base {{base}} --head {{branch}}`, titled as a Conventional Commit, its body opening with the task's goal: "{{task}}: {{goal}}"
3. Wait for its checks (`gh pr checks <full url> --watch`); fix a failure on the branch and push again until every check passes.
4. Repeat step 1; if it merged anything, go back to step 3, so every required check passes on the new head.
5. Then send `{{task}} PR <full url>` to `coordinator`.

Never run a command that needs `sudo`; send `{{task}} BLOCKED <the command> needs sudo` to `coordinator` instead.
