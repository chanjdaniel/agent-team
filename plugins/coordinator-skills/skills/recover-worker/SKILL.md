---
name: recover-worker
description: The recovery ladder for a stuck worker. Use when a worker is silent, idle without reporting, waiting for input it should not need, or reports the same failure twice, or when team-sweep names a silent, waiting-input or stalled session.
---

# Recover a worker

Climb the ladder one rung at a time, and stop at the rung that frees the worker.
Run `team-state T<n>` first, so you act on the task's state, not on the last message you remember.

When one stop the ledger did not see ended several sessions at once (the usage limit, a crash, a reboot), first log each stopped task's park with when it began, the limit message's time when you have it, else the task's last event before the stop: `team-log T<n> paused cause=limit reason="usage limit: <what stopped it>" since=<ISO time>`, with `cause=shutdown` for a crash or a reboot.
The relaunch then clears it, and `team-time` counts the stop as the usage limit (or the machine off), not as work, by its cause.

1. **Read its log.** `claude logs <session id>` shows what the worker last did and where it stands.
   Often the answer is there: a prompt it is waiting on, a question it asked in the wrong place, a finished step it never reported.

On a `stalled` finding, take the stalled rung before rung 2.
The finding names the tool call the worker waits on, whether it runs in the background or in a subagent, and for how long.

- **A call in the background** (the worker's turn has ended): send the worker one line naming the command and what it waits on; a message wakes the session.
- **A call in the foreground** (it holds the turn): find that command's process among the descendants of the session's `pid` from `claude agents --json` (`ps -A -o pid=,ppid=,args=` lists each process with its parent), kill that exact pid and no other, then send the worker one line saying why.
- **A CI wait** (a worker's `team-ci-wait`, run by hand): it always ends, naming a stuck check, and the PR's checks are the coordinator's own wait, `team-next T<n> --ci`, which reruns a stuck check itself: free the worker's wait as above and tell it to go on with its brief.
- **No tool call running**: the session is stuck inside Claude Code, so go on with rung 2.

When the worker stays stuck, the ladder goes on from rung 2.

2. **Send one line.** SendMessage to the worker's name with the one thing it needs: the answer, the next step, or "report where you stand with the protocol's kind".
   Check the sweep watch (`team-sweep --wait`) is running, arming it if not, and give the worker the time to act: its finding was there when you re-armed the watch, so the watch wakes you if it still stands 30 minutes later.
3. **Stop and respawn.** `claude stop <session id>`, then add a "Progress so far" section at the top of its brief in `tasks/T<n>/`: what it did that the ledger does not hold (ticked boxes, uncommitted work, the step it was on), what is left, and what went wrong; the tickets done and the reviews are the ledger's, which `team-state T<n>` reads.
   Launch a fresh worker with the same `team-worker` command and brief.
   Log why: `team-log T<n> blocked reason="<what stuck it>"` before the stop; the launch clears it.
4. **Escalate.** When a second respawn fails the same way, run `team-log T<n> failed reason="<evidence>"` and send Daniel FAILED in the task's thread: what the task needed, what each attempt did, and the log lines that show it.

A ticket builder of a parallel phase (`T<n>-builder-NN`) is recovered in its own ticket worktree, on its ticket's brief, while the other tickets build on: rung 3 logs `team-log T<n> blocked reason="<what stuck it>" session=<its 8-character session id>`, the id the sweep names it by and `team-state T<n> --json`'s workers carry, which parks its ticket alone, and launches `team-worker T<n> builder <its ticket worktree> -- "Read your brief at <the path of tasks/T<n>/brief-build-NN.md>"`, the worktree the one `team-state T<n> --json` lists with its `ticket` and `returned` false.
On the sweep's `ticket-gone` (its session is gone with its ticket not done), run `team-next T<n> --fill` first, which relaunches one whose launch was on another machine (a crash) itself and names any other: take rung 3 at once for that one, writing the brief's "Progress so far" from its ticket worktree (`git log` and `git status` there).

A low context reading is not a reason to intervene: a worker compacts and goes on.
A worker that is busy and logging progress is working, however long it takes.
