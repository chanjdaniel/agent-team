---
name: resume
description: Bring the team back after team-resume started you on the machine taking the team over. Use when your first prompt names a resume report (tasks/resume-<date>.json) and this skill.
---

# Resume

`team-resume` has taken the lease here, enabled the heartbeat, made each open task's worktrees on this machine and written the report your first prompt names; the workers are yours to bring back.
Never resume while GitHub is unreachable: say so to Daniel and wait.

1. **Read.** Read the report and run `team-snapshot`.
   Each task in the report has `stowed` (its latest `stowed`: the machine left, its time, the roles whose sessions were live), `crashed` (null, or the machine that stopped without a handoff since the task's last launch, the `checkpoint` it resumes from and the `roles` to relaunch), `worktrees` (where each is now, `moved` from where, `archive`, null when no scratch was restored, and `snapshot`, whether the checkpoint's uncommitted changes were applied and why not, after a crash or for a worktree the handoff found with uncommitted changes, null otherwise) and `failures` (each worktree not made here, with the reason).
2. **Catch up on Discord.** Messages sent while no coordinator listened are never delivered to you, only readable.
   For `#coordinator` and each open task's thread (`thread` in `team-state T<n> --json`), read the history with the Discord plugin's `fetch_messages` back to your own last message there; it reads at most 100 messages, so tell Daniel when your last message is further back.
   Log and answer anything Daniel asked that has no answer, before anything else.
3. **Relaunch.** For each task whose `crashed` is null and whose `stowed` names roles, for each role:
   - its last brief: the newest `tasks/T<n>/brief*.md` whose first line is `# T<n> brief (<role>)`, other than a `brief-resume-*.md`;
   - the brief: `team-brief T<n> resume --name resume-<role> --force --set role=<role> --set brief=<that brief> --set from="the handoff from <machine> at <stowed time>" --set snapshot=<what became of them>` (`--project <name>` for a task in two projects), the snapshot as for a crash below, "there were none" when the worktree's `snapshot` is null;
   - the launch: `team-worker T<n> <role> <worktree> -- "Read your brief at <path>"`, with each `--toolkit` of the role's last launch, the worktree being the report's.

   For each task whose `crashed` is not null, for each role of `crashed.roles` (its latest launch since the task's last `stowed` that no `done`, `review` or `ticket-done` ended), the same, but the brief is the crash one, which tells the worker what may be missing:
   `team-brief T<n> resume-crash --name resume-<role> --force --set role=<role> --set brief=<that brief> --set machine=<crashed.machine> --set checkpoint=<crashed.checkpoint> --set snapshot=<what became of it>`, the snapshot being the worktree's `snapshot`: "applied as uncommitted changes in your worktree", "there were none" when its `parent` is null (a clean checkpoint, or none at all), or "not applied: <its reason>; they are on `origin/wip/T<n>`".
   A null `checkpoint` is `checkpoint="an unknown time: no checkpoint of the task was found"`.
   Never relaunch an ops session: `ops` is in neither `stowed.roles` nor `crashed.roles`, since an ops session runs only on Daniel's request; a production question that went unanswered on the old machine is Daniel's to ask again, so name it in your post.
   A task with failures is relaunched only once its worktrees are made: fix what the reason names (a salvage push or a dirty slot is Daniel's word), run `team-open --task T<n> --resume <project>`, then relaunch.
4. **Log.** `team-log T<n> resumed` for each task paused for the handoff (its workers' `paused reason=stowed`), once its workers run again.
5. **Post.** In `#coordinator`: each task that resumed (roles relaunched, worktrees moved, for a crash the checkpoint it resumed from, and whether each snapshot was applied), and each that did not, with the reason and what it waits on.
6. **Clean up.** Delete the report once everything in it runs again.
