# 09: `team-current` edits the current items by id

Phase 2.

**What to build:** `bin/team-current` with `add <kind> <task or -> <text> --where <detail>`, `done <id>`, `list` and `check`, keeping `tasks/current.md`'s format, refusing what the spec's "`team-current`" lists, and committing each change alone.
The manual's current-items paragraph says the items are edited only with `team-current`, and holds no task progress, which `team-state` carries (ticket 11).

**Blocked by:** 08

**Waits for:** T171 merged (both edit `roles/coordinator.md`).

**Files:** a new `bin/team-current`, `bin/lib/ledger.jq` (if the id is computed there), `roles/coordinator.md` (lines 7 and 8), `plugins/coordinator-skills/skills/stow/SKILL.md`, `tests/team-current.bats`, `tests/coordinator-manual.bats`.

- [ ] `add` prints a 6-digit id and appends the line; `list` prints each item with its id; `done` with the id or a unique 4-digit prefix removes exactly that line.
- [ ] `add` refuses each case the spec lists (bad kind, bad task, ` | ` in the text, over 300 characters, a temp `where`, a path outside the team home, a duplicate), exit 1, file unchanged.
- [ ] `done` refuses an id matching none or two, file unchanged.
- [ ] `check` on a fixture file names each bad line with its reason, exit 1; a clean file is exit 0; it never writes.
- [ ] `add` and `done` commit `tasks/current.md` alone (another changed record stays uncommitted) and `team-snapshot` and the session digest still read the file as before.
- [ ] The manual names `team-current` and stays at most 120 lines; `team-current --help` prints its header.
- [ ] `tests/run` passes.
