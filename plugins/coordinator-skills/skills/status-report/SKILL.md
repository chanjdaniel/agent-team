---
name: status-report
description: Answer Daniel's request for status from team-snapshot. Use when Daniel asks for status, what is going on, what is open, or what waits on them.
---

# Status report

1. Run `team-snapshot`; for a task that needs more, `team-state T<n>`.
   When it says "GitHub unavailable", say so and report the rest.
2. Answer in `#coordinator`, or in the task's thread when Daniel asked about one task.

## What the answer says

- Lead with what waits on Daniel: each pending ask with its question, and each PR ready to merge.
- Then each open task in one line: its title, what it has achieved and what comes next, in Daniel's terms.
- Outcomes, not machinery: what was built, found, merged or decided, never sessions, sweeps, ledger events or phases by their internal names.
- Every PR as its full `https://github.com/...` URL, never `#118` alone.
- Anything wrong you found while reading the snapshot (a stray session, a task with no worker), with what you are doing about it.

Keep it to what Daniel can read on a phone in one screen; offer the detail rather than sending it.
