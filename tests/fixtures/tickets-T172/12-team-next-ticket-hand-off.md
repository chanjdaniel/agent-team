# 12: `team-next`: the ticket hand-off in one command

Phase 2.

**What to build:** `bin/team-next T<n> [options] -- '<the worker's message>'`, with its common checks, logging through `team-log --from-message`, resume and output as the spec's "`team-next`" says, and its first hand-off: a builder's `DONE <NN> <sha>... <line>` launches the next ready ticket's builder, or the deliverer when every ticket is done (T25 ticket 02).
Every other message is logged with "no hand-off" until tickets 13 and 14.

**Blocked by:** 03, 05, 07, 10

**Waits for:** T171 merged (both edit `roles/coordinator.md`).

**Files:** a new `bin/team-next`, `roles/coordinator.md` (step 4 and the DONE row), `tests/team-next.bats`.

- [ ] Refused with nothing changed (no ledger line, no brief, no `claude` call), each reason named: a closed or held task, an unanswered ask, no `plan-approved`, an unknown ticket, a ticket already handed off, a sha the worktree's `HEAD` does not hold, a `--next` that is not ready, tickets left of which none is ready.
- [ ] A ticket with a `Waits for:` line is chosen only by `--next`.
- [ ] It logs `ticket-done` and the builder's `done` once, renders `build-<NN>` and launches a builder in the task's worktree with the latest builder launch's toolkits, and prints the session's name and id.
- [ ] With every ticket done it renders `builder-deliver` with the plan's goal and launches the deliverer.
- [ ] A run whose launch failed (the `claude` stub fails once) finishes on the rerun without logging again; a rerun after the launch is refused as already handed off.
- [ ] Any other message is logged and reported as having no hand-off.
- [ ] The manual's step 4 names `team-next` and stays at most 120 lines; `team-next --help` prints the header.
- [ ] `tests/run` passes.
