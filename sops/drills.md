# SOP: the drills

A drill runs, for real, a path the team rests on and seldom takes: a move between machines, a stolen lease, a production prompt, a fresh machine, a compaction.
`tests/drill.bats` and the rest of the suite run the same scripts in a sandbox on stubs; a drill is the run on the real machines, the real Claude Code and the real GitHub.
`bin/lib/drills.json` registers each drill: its name, what it is, who runs it and the code it proves.

## The record

- Each run appends one line to `drills.jsonl` in the team home: the drill, the machine, the code commit, the Claude Code version, the verdict and one line of detail.
- The drills write it themselves: `team-load-check`, `tests/compaction-drill` and `team-drill import <run id>` (for the Bootstrap workflow's jobs) record their own run, and a by-hand drill ends with `team-drill record <drill> --verdict pass|fail --detail <text>`.
- A failed run is recorded as failed; what it found goes in the detail and into a task of its own.
- The checkpoint commits and pushes the file with the other records.
- `team-drill status` lists every drill with its last run and whether it is due.
- The doctor's `drills` line warns when a drill never ran, last failed, ran on a commit the code checkout lacks or on uncommitted changes, ran before the last change to the code it proves, or is over 30 days old.

## Who runs a drill

- The coordinator starts every drill: workers may not start sessions, reach production or another machine.
- A drill marked "Daniel" needs them present, and the coordinator asks them for a time, naming the drill's duration below.
- A drill is run from the code checkout on `dev`, with no uncommitted change, so its line names a merged commit; a run on a PR's head is for that PR, and is run again on `dev` after the merge.

## `load-check-planner`: what a planner is given, and that its edit hook holds

- Who: the coordinator.
  Duration: 10 minutes.
- When: after a change to roles, settings, toolkits, hooks or the Claude Code pin, and when the doctor's line names it.
- Steps:
  1. `team-load-check` (with `--toolkit <name>` for each toolkit whose reach is to be checked).
  2. Read its last line: `PASS`, or each `FAIL` line.
- Passes when the load check exits 0: the planner's MCP tools are the given toolkits', nothing of production or the coordinator reaches it, its transcript shows the write outside `.scratch/` attempted and blocked by the edit hook, its effective autoMode holds its settings' lines, and none of its worktree's own files configured or instructed it.
- Record: the load check's own.

## `load-check-ops-prod-write` and `load-check-ops-vercel-read`: the production prompts

- Who: the coordinator, with Daniel at the PC and their phone.
  Duration: 45 minutes for both, 30 for the first alone.
- When: after a change to `settings/ops.json`, `roles/ops.md`, a production toolkit, `bin/hooks/ops-log` or the Claude Code pin, and when the doctor's line names it.
- Nothing is written to production: the five write calls are each declined.
- Steps:
  1. Daniel posts a message in `#coordinator` asking for the ops load check; each load check needs a new message, at most an hour old.
  2. The coordinator runs `team-load-check --role ops --worktree <path> --request <the message's link> --toolkit prod-read --toolkit prod-write`, the path a trusted linked worktree of a project that lists the toolkits.
  3. Daniel approves the two 1Password prompts on the PC.
  4. Daniel declines each of the five write prompts on the phone, as they arrive; the load check waits up to 30 minutes.
  5. The coordinator reads the result and posts it.
  6. For `vercel-read`: a new message from Daniel, then `team-load-check --role ops --worktree <path> --request <link> --toolkit vercel-read`, and one 1Password approval.
- Passes when the load check exits 0: the tools and skills are exactly the toolkits', each write call was made once and shows in the transcript as declined by Daniel, the ops log gained one `requested` line per write and nothing else for them, no secret reached a file, and `team-ops-end` removed the session and its transcript.
- Record: the load check's own; its other two toolkit sets (`prod-read` alone, `prod-read` with `vercel-read`) are no drill and record nothing.

## `compaction`: the coordinator after a compaction

- Who: the coordinator.
  Duration: 10 minutes, about 0.70 USD at list price.
- When: after a change to `roles/coordinator.md`, `coordinator.settings.json`, the session digest or the Claude Code pin, and when the doctor's line names it.
- Steps:
  1. `tests/compaction-drill`.
  2. Read its `== <passed> of <checks> checks passed` line.
- Passes when every check passes: the compaction ran, and the session still names each open task's wait and every current item.
- Record: the drill's own.

## `bootstrap-arch` and `bootstrap-macos`: a fresh machine

- Who: the coordinator.
  Duration: 45 minutes, unattended.
- When: after a change to `bin/team-bootstrap`, `bin/lib/tools.lock` or the workflow, and when the doctor's line names it.
- Steps:
  1. `gh workflow run bootstrap.yml --ref dev`, then `gh run list --workflow bootstrap.yml --limit 1` for the run's id.
  2. Wait for the run with a command that ends by itself (`gh run watch <id> --exit-status` under `timeout 60m`, in the background).
  3. `team-drill import <run id>`, which records one line per job; it exits 75 while the run is still going, and a second import of the same run adds nothing.
- Passes, per job, when the job succeeded and `tests/bootstrap-drill` ended at a step of Daniel's in the bootstrap's `projects` stage or a later one, or at its summary with no failure besides Daniel's steps.
- Until the runner has a stand-in team home, each job stops at the `machine` stage, whose team home clone needs a GitHub login to a private repository, and fails.
- Record: `team-drill import`'s; import each run once it completes, in the order the runs ran, since a drill's last run is its last line.

## The second machine

The handoff and the steal need a second machine the team can run on.

- Until the macOS backend is built (T175), that is a Linux machine `team-bootstrap` supports (Arch), with its own kernel, clock, network link and logins: a second physical machine, or a virtual machine on the home PC with 4 cores, 8 GiB of memory, 60 GB of disk and a graphical session for the 1Password app.
- A container is not one: it shares the PC's kernel and clock and has no systemd user session for the heartbeat.
- It is set up once as `SETUP.md` and `sops/machine-setup.md` say ("set up as host" in a Claude Code session there), under its own team name, until `team-doctor` there has no FAIL and `team-load-check` there passes.
  That takes 2 to 3 hours, about 1 hour of it Daniel's (the `sudo` stages, the GitHub and Claude logins, the 1Password app, the trust dialogs).
- Every project with an open task must be set up there, since a handoff moves every open task.
- A virtual machine is shut down between drills; before each drill, its code checkout and team home are brought level by `team-resume --wait` itself.

## `handoff`: the team to the second machine and back

- Who: the coordinator and Daniel, at both machines.
  Duration: 1.5 hours.
- When: after a change to the handoff, resume, lease, stow, open, checkpoint, config or timers scripts or to the `handoff` and `resume` skills, and when the doctor's line names it.
- It follows `sops/portability.md`, "Moving the team: handoff, then resume", twice; each numbered step there is a step here.
- Before:
  1. The coordinator picks a quiet time and opens one trivial task on the `agent-team` project (a one-line documentation fix), with its builder at work; it names every other open task to Daniel, since each is stowed and re-homed too.
  2. `team-doctor` on both machines shows no FAIL, and `team-drill status` on the PC is read for the record.
- Out:
  3. On the second machine, Daniel runs `team-resume --wait` and waits for "this machine is ready".
  4. Daniel says "hand off" to the coordinator on Discord; the `handoff` skill stows the workers, runs `team-handoff`, posts "Released at ..." and retires.
  5. The wait on the second machine ends: it pulls, applies the config, takes the lease, enables the heartbeat, re-homes each open worktree, writes its report and starts the coordinator, which Daniel pins.
  6. On Daniel's word, the coordinator there relaunches only the trivial task's builder and leaves the other tasks stowed.
  7. Check there: `team-lease status` names the second machine at an epoch one higher; the resume report has no failure; the builder's resume brief names the handoff; the builder makes one commit and pushes it; a message of Daniel's in `#coordinator` is answered from there; `team-timers health` is healthy after one heartbeat (5 minutes).
- Back:
  8. On the PC, Daniel runs `team-resume --wait` and waits for "this machine is ready".
  9. Daniel says "hand off" to the coordinator on the second machine.
  10. The wait on the PC ends as in step 5; Daniel pins the coordinator.
  11. The coordinator's `resume` skill relaunches every stowed role.
  12. Check on the PC: `team-lease status` names the PC at an epoch two higher than before the drill; `git log origin/lease` in the team home shows the two takes and no `stolen_from`; the resume report has no failure; each `worktree-moved` is expected; the trivial task's branch holds the commit made on the second machine; the second machine's heartbeat is disabled (`team-timers status` there) and its `team-doctor` shows it holds no lease.
- After:
  13. The coordinator lets the trivial task finish or closes it, and records: `team-drill record handoff --verdict pass --detail "to <machine> and back, epochs <a> to <b>"`, or `--verdict fail --detail "<the step that failed and why>"`.
  14. Each thing that broke becomes a task, and the coordinator posts the list.
- Passes when steps 3 to 12 each held with no step done by hand that the scripts should have done.

## `steal`: the lease taken from a holder that is cut off

- Who: the coordinator and Daniel, at both machines.
  Duration: 1.25 hours; in one sitting after the handoff drill, 2.75 hours for both.
- When: after a change to the lease, resume, open, checkpoint or timers scripts, the `lease-fence` hook or the doctor's lease and salvage lines, and when the doctor's line names it.
- The old holder is always the second machine, so the PC is never the machine cut off and the team ends on the PC.
- It follows `sops/portability.md`, "A crash" and "Fencing".
- Before:
  1. As the handoff drill's steps 1 and 2: one trivial task with its builder at work, both doctors clean.
  2. The team moves to the second machine by a planned handoff (the handoff drill's steps 3 to 7), and the trivial task's builder is at work there, not stowed.
- The cut:
  3. Daniel turns the second machine's network off (the link down, or the virtual machine's interface disconnected), and notes the time.
  4. Within two heartbeats (10 minutes) the second machine holds offline: `team-timers health` there says so, and its coordinator's workers answer `PAUSED held`.
     The builder there makes one more local commit and the coordinator there logs one more ledger line, so there is something to salvage.
- The steal:
  5. On the PC, Daniel runs `team-resume --steal` in their own terminal and types the second machine's name when asked.
  6. It takes the lease with `stolen_from` set, re-homes each open worktree from the later of origin's branch and the checkpoint's snapshot, writes its report and starts the coordinator, which Daniel pins.
  7. The coordinator's `resume` skill relaunches the trivial task's builder with the crash brief.
  8. Check on the PC: `team-lease status` names the PC, `git log origin/lease` shows the take with `stolen_from`; the report's task has `crashed` naming the second machine and its checkpoint; the builder's brief says what may be missing; the ledger has no `rehome-failed`.
- The fence:
  9. Daniel turns the second machine's network on.
  10. Within one heartbeat it finds the new holder and fences itself: its coordinator and workers are stopped, its heartbeat disabled.
  11. Check there: a Bash call in any session left there is blocked by `lease-fence`; `team-doctor` shows the fence, its `salvage records` line names the ledger line of step 4 as unpushed, and its `salvage T<n> agent-team` line the builder's commit of step 4, each with the commands that push them.
  12. Daniel runs those commands there; `team-doctor` there then passes both lines.
  13. Check on the PC: the team home's origin has `salvage/records/<machine>-<epoch>` and `salvage/agent-team/T<n>-<machine>`.
- After:
  14. The coordinator decides with Daniel what of the salvage to bring back, lets the trivial task finish or closes it, and records: `team-drill record steal --verdict pass --detail "stole from <machine> at epoch <n>, fenced in <m> min, salvage pushed"`, or `--verdict fail --detail "<the step that failed and why>"`.
  15. Each thing that broke becomes a task, and the coordinator posts the list.
  16. The second machine's team home is brought level with origin (after the salvage, since that reset throws its unpushed lines away) before it next takes the team.
- Passes when steps 5 to 13 each held.
