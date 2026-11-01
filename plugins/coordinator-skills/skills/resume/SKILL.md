---
name: resume
description: Bring the team back after team-resume started you on the machine taking the team over. Use when your first prompt names a resume report (tasks/resume-<date>-<time>.json) and this skill.
---

# Resume

`team-resume` has taken the lease here, enabled the heartbeat, made each open task's worktrees on this machine and written the report your first prompt names; the workers are yours to bring back.
Never resume while GitHub is unreachable: say so to Daniel and wait.

1. **Read.** Read the report and run `team-snapshot`.
   Each task in the report has `stowed` (its latest `stowed`: the machine left, its time, `roles`, its unfinished work, and `sessions`, the roles whose sessions the handoff stopped, for the record only), `crashed` (null, or the machine that stopped without a handoff since the task's last launch, the `checkpoint` it resumes from and the `roles` to relaunch), `worktrees` (where each is now, `moved` from where, `archive`, null when no scratch was restored, and `snapshot`, whether the checkpoint's uncommitted changes were applied and why not, after a crash or for a worktree the handoff found with uncommitted changes, null otherwise) and `failures` (each worktree not made here, with the reason).
   Each failure is also a `rehome-failed` in the ledger, with the first line of its reason, which `team-state T<n>` and `team-snapshot` show as "not re-homed: <project> on <machine>: <reason>" until `team-open --resume` makes the worktree.
   Each run of `team-resume` writes its own report, so an earlier run of the day may have left one: its failures are in the ledger, and this run tried each of them again.
2. **Catch up on Discord.** Messages sent while no coordinator listened are never delivered to you, only readable.
   For `#coordinator` and each open task's thread (`thread` in `team-state T<n> --json`), read the history with the Discord plugin's `fetch_messages` back to your own last message there; it reads at most 100 messages, so tell Daniel when your last message is further back.
   Log and answer anything Daniel asked that has no answer, before anything else.
3. **Relaunch.** First run `team-level`: the level recorded before the handoff or the shutdown still holds.
   At none, relaunch nothing and log no `resumed`: post in `#coordinator` that the team waits at none until Daniel raises the level, then go on with step 5; once the level allows, the sweep's `level-resume` findings name each stowed task to relaunch.
   Otherwise relaunch as below while each launch is admitted: a `team-worker` that exits 75 has no room in the level's budget, so log `team-log T<n> paused reason=<its line>` and leave that task and the ones after it to the sweep's `level-resume` findings, as the `level` skill says.
   A crashed task left waiting is no stowed one, so no `level-resume` names it: add a `next` item to `tasks/current.md` for it, and relaunch it as below once `team-level` shows room.

   For each task whose `crashed` is null, for each role of `stowed.roles` (never of `stowed.sessions`, which may hold a finished worker's session):
   - its last brief: the newest `tasks/T<n>/brief*.md` whose first line is `# T<n> brief (<role>)`, other than a `brief-resume-*.md`;
   - the brief: `team-brief T<n> resume --name resume-<role> --force --set role=<role> --set brief=<that brief> --set from="the handoff from <machine> at <stowed time>" --set snapshot=<what became of them>` (`--project <name>` for a task in two projects), the snapshot as for a crash below, "there were none" when the worktree's `snapshot` is null;
   - the launch: `team-worker T<n> <role> <worktree> -- "Read your brief at <path>"`, with each `--toolkit` of the role's last launch, the worktree being the report's.

   For each task whose `crashed` is not null, for each role of `crashed.roles` (its latest launch since the task's last `stowed` that no `done`, `review`, `ticket-done` or, for a builder, `pr` ended), the same, but the brief is the crash one, which tells the worker what may be missing:
   `team-brief T<n> resume-crash --name resume-<role> --force --set role=<role> --set brief=<that brief> --set machine=<crashed.machine> --set checkpoint=<crashed.checkpoint> --set snapshot=<what became of it>`, the snapshot being the worktree's `snapshot`: "applied as uncommitted changes in your worktree", "there were none" when its `parent` is null (a clean checkpoint, or none at all), or "not applied: <its reason>; they are on `team-home/wip/<project>/T<n>`".
   A null `checkpoint` is `checkpoint="an unknown time: no checkpoint of the task was found"`.
   Never relaunch an ops session: `ops` is in neither `stowed.roles` nor `crashed.roles`, since an ops session runs only on Daniel's request; a production question that went unanswered on the old machine is Daniel's to ask again, so name it in your post.
   Failures hold back a worker, not a task: a role whose worktree (its last launch's `project`) is in the task's `worktrees` is relaunched now, and one whose worktree is in `failures` waits for it: fix what the reason names (a salvage push or a dirty slot is Daniel's word), run `team-open --task T<n> --resume <project>`, then relaunch that role.
   A task with no role to relaunch has no unfinished worker: its next step comes from its state, as on any event; run `team-state T<n>`, read the stowed's `note` and the `.scratch/task/handoff.md` its last worker left in its worktree, and take the step the events table or the task's phase gives (a PR whose review found findings goes back to its builder, a passed review waits on Daniel's "merge it").
4. **Log.** `team-log T<n> resumed` for each task paused for the handoff (its workers' `paused reason=stowed`), once its workers run again.
5. **Post.** In `#coordinator`: each task that resumed (roles relaunched, worktrees moved, for a crash the checkpoint it resumed from, and whether each snapshot was applied), and each that did not, with the reason and what it waits on.
6. **Clean up.** Once everything in the report runs again, delete every report of the day, `tasks/resume-<date>-*.json`, the earlier runs' included: the ledger keeps each failure.
