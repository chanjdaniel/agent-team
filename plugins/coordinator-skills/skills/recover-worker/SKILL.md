---
name: recover-worker
description: The recovery ladder for a stuck worker. Use when a worker is silent, idle without reporting, waiting for input it should not need, or reports the same failure twice, or when team-sweep names a silent or waiting-input session.
---

# Recover a worker

Climb the ladder one rung at a time, and stop at the rung that frees the worker.
Run `team-state T<n>` first, so you act on the task's state, not on the last message you remember.

1. **Read its log.** `claude logs <session id>` shows what the worker last did and where it stands.
   Often the answer is there: a prompt it is waiting on, a question it asked in the wrong place, a finished step it never reported.
2. **Send one line.** SendMessage to the worker's name with the one thing it needs: the answer, the next step, or "report where you stand with the protocol's kind".
   Check the sweep watch (`team-sweep --wait`) is running, arming it if not, and give the worker the time to act: its finding was there when you re-armed the watch, so the watch wakes you if it still stands 30 minutes later.
3. **Stop and respawn.** `claude stop <session id>`, then add a "Progress so far" section at the top of its brief in `tasks/T<n>/`: what is done (commits, ticked boxes), what is left, and what went wrong.
   Launch a fresh worker with the same `team-worker` command and brief.
   Log why: `team-log T<n> blocked reason="<what stuck it>"` before the stop; the launch clears it.
4. **Escalate.** When a second respawn fails the same way, run `team-log T<n> failed reason="<evidence>"` and send Daniel FAILED in the task's thread: what the task needed, what each attempt did, and the log lines that show it.

A low context reading is not a reason to intervene: a worker compacts and goes on.
A worker that is busy and logging progress is working, however long it takes.
