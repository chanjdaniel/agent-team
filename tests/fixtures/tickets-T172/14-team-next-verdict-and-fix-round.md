# 14: `team-next`: the verdict, and the fix round's stow

Phase 2.

**What to build:** `team-next` on a reviewer's `DONE pass` or `DONE findings` logs the review and its `done`, and prints the next step the manual gives (the merge ask's facts, the base merge, the message for the holding builder, or the `STOW` to send); and on a builder's `PAUSED stowed` with sent-back findings not yet handed on, launches the `builder-round` builder; as the spec's "`team-next`" table says (T25 ticket 04).

**Blocked by:** 11, 13

**Files:** `bin/team-next`, `roles/coordinator.md` (steps 5 and 6, the DONE and PAUSED rows), `tests/team-next.bats`.

- [ ] A pass whose PR head moved past the reviewed head is refused naming both shas, with nothing logged.
- [ ] A pass logs `review verdict=pass` at the reviewed head with the message's findings and guarded areas, and prints the full PR URL, the head and `agent-review`; with the `gh` stub's compare behind, it prints the `builder-merge-base` step instead; with a standing plan-time approval it says `merge pre-approved`.
- [ ] A findings verdict without `--sent-back` is refused; with it, it logs `sent_back` as numbers and prints the message for the live holder under 250k (its name, the findings and the findings file), or the `STOW` to send when the holder is at 250k or more or gone.
- [ ] A `PAUSED stowed` after such a review launches `round-1` with every fact derived; a second stow after that launch, or a stow with no findings pending, launches nothing.
- [ ] It never calls `team-post`, `team-merge` or Discord (the stubs' calls).
- [ ] `tests/run` passes.
