---
name: resume
description: Bring the team back after team-resume started you on the machine taking the team over. Use when your first prompt names a resume report (tasks/resume-<date>.json) and this skill.
---

# Resume

`team-resume` has taken the lease here, enabled the heartbeat, made each open task's worktrees on this machine and written the report your first prompt names; the workers are yours to bring back.
Never resume while GitHub is unreachable: say so to Daniel and wait.

1. **Read.** Read the report and run `team-snapshot`.
   Each task in the report has `stowed` (its latest `stowed`: the machine left, its time, the roles whose sessions were live), `worktrees` (where each is now, `moved` from where, and `archive`, null when no scratch was restored) and `failures` (each worktree not made here, with the reason).
2. **Catch up on Discord.** Messages sent while no coordinator listened are never delivered to you, only readable.
   For `#coordinator` and each open task's thread (`thread` in `team-state T<n> --json`), read the history with the Discord plugin's `fetch_messages` back to your own last message there; it reads at most 100 messages, so tell Daniel when your last message is further back.
   Log and answer anything Daniel asked that has no answer, before anything else.
3. **Relaunch.** For each task whose `stowed` names roles, for each role:
   - its last brief: the newest `tasks/T<n>/brief*.md` whose first line is `# T<n> brief (<role>)`, other than a `brief-resume-*.md`;
   - the brief: `team-brief T<n> resume --name resume-<role> --force --set role=<role> --set brief=<that brief> --set from="the handoff from <machine> at <stowed time>"` (`--project <name>` for a task in two projects);
   - the launch: `team-worker T<n> <role> <worktree> -- "Read your brief at <path>"`, with each `--toolkit` of the role's last launch, the worktree being the report's.
   A task with failures is relaunched only once its worktrees are made: fix what the reason names (a salvage push or a dirty slot is Daniel's word), run `team-open --task T<n> --resume <project>`, then relaunch.
4. **Log.** `team-log T<n> resumed` for each task paused for the handoff (its workers' `paused reason=stowed`), once its workers run again.
5. **Post.** In `#coordinator`: each task that resumed (roles relaunched, worktrees moved), and each that did not, with the reason and what it waits on.
6. **Clean up.** Delete the report once everything in it runs again.
