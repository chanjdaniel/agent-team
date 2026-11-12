## Deliver as one pull request

1. Bring the branch up to date with the base: `git fetch origin`; if `git merge-base --is-ancestor origin/{{base}} HEAD` fails, merge `origin/{{base}}` with a merge commit (`git merge origin/{{base}}`, never a rebase), resolve any conflict, re-run what the conflicts touched, and push (under a Disclosure section, not before step 3's review passes).
   A conflict whose resolution is a judgment call on behaviour goes to `coordinator` as `{{task}} QUESTION <the conflict> | options: ...`.
2. Find what your branch made false: for each file, command, flag, setting and path it adds, renames or removes (`git diff --stat origin/{{base}}...HEAD`), `git grep` its name in the repository's Markdown, `CLAUDE.md`, `AGENTS.md` and script headers, and fix every line that no longer holds, in the same PR.
3. Under a Disclosure section in a public repository, push nothing yet: send `{{task}} DONE review-ready <the full sha of HEAD>` to `coordinator`, then wait, since the reviewer reads your local head and the team reviews its wording before anything goes public.
   Fix each finding the coordinator sends you on the branch, pushing nothing; once they are fixed, or the coordinator says the review passed, go on with the push, the checks and the PR.
4. Run the project's local checks ({{local_checks}}) on the head you push with `{{team_bin}}/team-checks {{project}} <full sha>`, which runs them as `team-merge` does, in a fresh detached worktree of that head; fix the branch and push again until all pass on one head.
   They set no GitHub status: their result goes in the PR body.
5. Open one PR from `{{branch}}` to `{{base}}`: `gh pr create --repo {{repo}} --base {{base}} --head {{branch}}`, titled as a Conventional Commit, its body opening with what this PR changes, in words a reader of the repository can follow, with no task, ticket, phase or retro number (the task's goal is "{{goal}}": on a phase, say this phase's part of it alone and name the others as their own PRs), then a line naming the local checks that passed and the head they passed on.{{captures}}
6. Send `{{task}} PR <full url>` to `coordinator` and stop: the delivery ends there, with no wait on the PR's GitHub checks, since the coordinator's script waits on them once the review passes, and a red check comes back to you from the coordinator as a fix round, as a review's findings do.

Never run a command that needs `sudo`; send `{{task}} BLOCKED <the command> needs sudo` to `coordinator` instead.
