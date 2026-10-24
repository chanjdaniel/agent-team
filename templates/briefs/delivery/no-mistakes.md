## Deliver through no-mistakes

1. Bring the branch up to date with the base: `git fetch origin`; if `git merge-base --is-ancestor origin/{{base}} HEAD` fails, merge `origin/{{base}}` with a merge commit (`git merge origin/{{base}}`, never a rebase), resolve any conflict and re-run what the conflicts touched.
   A conflict whose resolution is a judgment call on behaviour goes to `coordinator` as `{{task}} QUESTION <the conflict> | options: ...`.
2. Find what your branch made false: for each file, command, flag, setting and path it adds, renames or removes (`git diff --stat origin/{{base}}...HEAD`), `git grep` its name in the repository's Markdown, `CLAUDE.md`, `AGENTS.md` and script headers, and fix every line that no longer holds, in the same PR.
3. Run `/no-mistakes` with this intent: "{{task}}: {{goal}}"
4. The PR must target `{{base}}`; if the gate opens it against another branch, retarget it to `{{base}}` and close any duplicate.
5. When the gate returns checks-passed, repeat step 1; if it merged anything, go back to step 3, so every required check passes on the new head.
6. Then send `{{task}} PR <full url>` to `coordinator`.

Never run a command that needs `sudo`; send `{{task}} BLOCKED <the command> needs sudo` to `coordinator` instead.
