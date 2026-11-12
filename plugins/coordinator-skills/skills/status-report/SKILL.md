---
name: status-report
description: Answer Daniel's request for status from team-snapshot. Use when Daniel asks for status, what is going on, what is open, or what waits on them.
---

# Status report

1. Run `team-snapshot`; for a task that needs more, `team-state T<n>`.
   When it says "GitHub unavailable", say so and report the rest.
2. Answer in `#coordinator`, or in the task's thread when Daniel asked about one task.

## What the answer says

- Lead with what waits on Daniel: say in the answer's first line how many items wait, or that nothing does, and name the first item of `waiting.md`, the one whose answer unblocks the most; once the answer is sent run `team-inbox --post`, which posts the numbered list as the newest message in `#coordinator`, ranked by how much work each answer unblocks with the count on each line, so Daniel answers right under it; never repeat its list, and in a task's thread name that task's items by their numbers in the team home's `waiting.md`; when it fails, list them yourself from the snapshot, the ones holding the most work first.
- When Daniel asks only what waits on them, run `team-inbox --post` alone, with no status.
- Then each open task in one line: its title, what it has achieved and what comes next, in Daniel's terms, from the snapshot's progress (its tickets done, its latest review, its PR's checks and how far it is behind its base), never from `tasks/current.md`.
- Outcomes, not machinery: what was built, found, merged or decided, never sessions, sweeps, ledger events or phases by their internal names.
- Every PR as its full `https://github.com/...` URL, never `#118` alone.
- Anything wrong you found while reading the snapshot (a stray session, a task with no worker), with what you are doing about it.

Keep it to what Daniel can read on a phone in one screen; offer the detail rather than sending it.
