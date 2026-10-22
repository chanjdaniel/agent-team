## Deliver as one pull request

1. Open one PR from `{{branch}}` to `{{base}}`: `gh pr create --repo {{repo}} --base {{base}} --head {{branch}}`, titled as a Conventional Commit, its body opening with the task's goal: "{{task}}: {{goal}}"
2. Wait for its checks (`gh pr checks <full url> --watch`); fix a failure on the branch and push again until every check passes.
3. Then send `{{task}} PR <full url>` to `coordinator`.
