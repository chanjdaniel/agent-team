## Deliver through no-mistakes

1. Bring the branch up to date with the base: `git fetch origin`; if `git merge-base --is-ancestor origin/{{base}} HEAD` fails, merge `origin/{{base}}` with a merge commit (`git merge origin/{{base}}`, never a rebase), resolve any conflict and re-run what the conflicts touched.
   A conflict whose resolution is a judgment call on behaviour goes to `coordinator` as `{{task}} QUESTION <the conflict> | options: ...`.
2. Find what your branch made false: for each file, command, flag, setting and path it adds, renames or removes (`git diff --stat origin/{{base}}...HEAD`), `git grep` its name in the repository's Markdown, `CLAUDE.md`, `AGENTS.md` and script headers, and fix every line that no longer holds, in the same PR.
3. Push the branch (under a Disclosure section, not before the review passes: the reviewer reads your local head) and send `{{task}} DONE review-ready <the full sha of HEAD>` to `coordinator`, then wait: the team reviews that head before the gate runs, so the gate runs once.
   Fix each finding the coordinator sends you on the branch and push; once they are fixed, or the coordinator says the review passed, go on.
4. Run `/no-mistakes` with this intent: "{{task}}: {{goal}}" (under a Disclosure section, put in its terms, since the gate drafts the PR's title and body from it)
5. The PR must target `{{base}}`; if the gate opens it against another branch, retarget it to `{{base}}` and close any duplicate.
6. When the gate returns checks-passed, repeat step 1; if it merged anything, go back to step 4, so every required check passes on the new head.
   The gate leaves Playwright to CI, so its result arrives with CI's `e2e` checks: treat a red `e2e` as the gate's red.
7. Then send `{{task}} PR <full url>` to `coordinator`.

At each gate run's end (it pushed, went red, was aborted, or was stopped once its PR's checks were green), send `{{task}} DONE gate run=<its id> head=<the full sha it ran on> outcome=<pushed|red|aborted|stopped-green> minutes=<each step's minutes from no-mistakes axi status --run <its id>, as one JSON object>` to `coordinator`, with `cause=<review|notes|gate-finding|load|tooling|base-merge|other>` when the run repeats an earlier one on the same PR.

Never run a command that needs `sudo`; send `{{task}} BLOCKED <the command> needs sudo` to `coordinator` instead.
