# 02: A `denied` event that parks nothing

Phase 1.

**What to build:** a denial the worker went past is one event, `team-log T<n> denied role= what= why=`, which parks and clears nothing, and which `team-time` and `team-retro` count as a denial, as the spec's "`denied`" says.
Hard rule 2 in the manual says to log `denied` when the worker went on, and `blocked` when the denial stops the work.

**Blocked by:** 01

**Waits for:** T171 merged (both edit `roles/coordinator.md`).

**Files:** `bin/lib/ledger-contract.json`, `bin/lib/ledger.jq`, `bin/lib/time.jq`, `bin/team-time`, `bin/team-retro`, `roles/coordinator.md`, `tests/team-log.bats`, `tests/team-time.bats`, `tests/team-retro.bats`, `tests/team-state.bats`, `tests/team-sweep.bats`.

- [ ] `team-log T<n> denied role=builder what=... why=...` logs; a missing field is refused.
- [ ] A task whose latest event is `denied` has the phase it had before it, and `team-sweep` finds nothing new for it (tests on fixture ledgers).
- [ ] `team-time`'s denials count includes `denied` events beside the `blocked` ones classed `wait:denial`; its header says so.
- [ ] `team-retro`'s blocks list shows a `denied` event as a denial.
- [ ] The manual's hard rule 2 names `denied`; the manual stays at most 120 lines.
- [ ] `tests/run` passes.
