---
name: stow
description: Move every decision and lesson still held only in this conversation to its home on disk. Use before a compaction, a restart, or a handoff to another session or machine.
---

# Stow

Your conversation is a cache that a compaction or a restart throws away.
Stow is done when a fresh coordinator, reading only the disk, would take the same next step on every open task.

## Walk the conversation since the last stow

For each decision, answer, wait and lesson in it, write it to its one home:

| What | Its home |
| - | - |
| A decision Daniel made on a task | The ledger: `team-log T<n> answered id=<ask id> answer=<text>`, or `plan-approved`, `merge-approved`, `merge-preapproved`, `merge-preapproval-withdrawn`, `held` as it fits |
| A task parked on Daniel or anything outside the team | `team-log T<n> waiting on=<who> reason=<what>` |
| A question to Daniel outside a task, a reply owed to Daniel, a promise with a trigger, approved work not yet opened, a watch you armed | One `team-current add` each, as your manual says, pointing at the detail; task state never goes there |
| A worker's progress, a plan change, a task's notes | `tasks/T<n>/`: the plan, the brief's "Progress so far", or a note file |
| A step only Daniel can take | `manual-steps.md` |
| A fact about a project | A ticket for that project's task, so it lands in its docs or knowledge graph through a PR |
| A lesson about how the team works | A ticket in `tasks/` for a team-home task that changes the manual, a role, a template or a script |
| Daniel's own preference | A one-line proposal to Daniel for `~/.claude/CLAUDE.md`, which only Daniel changes |

Write notes that point at the source of truth (the ledger, a PR URL, a file), never temp paths, versions or ids that rot.
Writing them is the whole step: the heartbeat's checkpoint commits every record within five minutes, so never commit one by hand; `team-checkpoint --force` when one must be durable now.

## Before a restart

A handoff to another machine is the `handoff` skill's: stow the conversation as above, then follow it.
For a restart on this machine, run `team-snapshot` and check every open task in it reads as you know it; fix the ledger or `tasks/` where it does not.
Write `tasks/handoff-<date>.md`: how to start the coordinator again, each task in flight with how to resume it, and what waits on Daniel.
Then run `team-checkpoint --force`, so the disk you stowed to is on the team home's origin before the restart.
The next coordinator deletes it once everything in it is running again.
