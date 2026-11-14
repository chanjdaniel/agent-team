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
| A decision Daniel made on a task | The ledger: a Discord answer with `team-answer T<n> <ask id> <message id>`, one with no message (given at the terminal) with `team-log T<n> answered id=<ask id> answer=<text>`, or `plan-approved`, `plan-approval-withdrawn`, `merge-approved`, `merge-default-withdrawn`, `merge-default-restored`, `held discord_message=<their message id>` (their hold) as it fits |
| A task parked on Daniel or anything outside the team | `team-log T<n> waiting on=<who> reason=<what>` |
| A question to Daniel outside a task, a reply owed to Daniel, a promise with a trigger, a watch you armed | One `team-current add` each, as your manual says, pointing at the detail; task state never goes there |
| Approved work not yet opened | A file in `tasks/queued/` with its front matter, then `team-queue index`, as your manual says |
| A worker's progress the ledger does not hold (its tickets done, PRs and reviews are there, which `team-state` reads), a plan change, a task's notes | `tasks/T<n>/`: the plan, the brief's "Progress so far", or a note file |
| A step only Daniel can take | `manual-steps.md` |
| A fact about a project | A ticket for that project's task, so it lands in its docs or knowledge graph through a PR |
| A lesson about how the team works | A ticket in `tasks/` for an `agent-team` task that changes the manual, a role, a template or a script through its PR |
| Daniel's own preference | A one-line proposal to Daniel for `~/.claude/CLAUDE.md`, which only Daniel changes |

Write notes that point at the source of truth (the ledger, a PR URL, a file), never temp paths, versions or ids that rot.
Writing them is the whole step: the heartbeat's checkpoint commits every record within five minutes, so never commit one by hand; `team-checkpoint --force` when one must be durable now.

## Before a restart

A handoff to another machine, and a restart of this machine on Daniel's "shut down", are the `handoff` skill's, the restart its same-machine case: stow the conversation as above, then follow it, and `team-resume` brings the team back with the report the `resume` skill reads.
For a restart of your session alone, the workers running on, run `team-snapshot` and check every open task in it reads as you know it, each ticket builder of a parallel phase by its own name, `T<n>-builder-NN`; fix the ledger or `tasks/` where it does not, since that snapshot and `tasks/current.md` are what the next session starts from.
Then run `team-checkpoint --force`, so the disk you stowed to is on the team home's origin before the restart.
