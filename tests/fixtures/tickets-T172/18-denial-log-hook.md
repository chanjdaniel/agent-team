# 18: A `PermissionDenied` hook logs each denial as `denied`

Phase 3.

**What to build:** `bin/hooks/denial-log`, a `PermissionDenied` hook in `settings/worker.json`, appends `denied` with the role and session, `what` the tool's name and `why` the bracketed rule label or `no verdict`, never the tool's input, as the spec's "Phase 3" says (T25 ticket 13); the contract adds it as a writer of `denied`.

**Blocked by:** 02, 17

**Files:** a new `bin/hooks/denial-log`, `settings/worker.json`, `bin/lib/ledger-contract.json`, `CLAUDE.md` (if the hooks list names each hook), `tests/denial-log.bats`.

- [ ] Fed a fixture `PermissionDenied` input, it appends one `denied` line with the label and no tool input; a session it cannot place on a task appends nothing.
- [ ] It exits 0 on any failure, and waits at most a second for a held ledger lock.
- [ ] A live load check provokes one harmless classifier denial and finds the line; whether a deny-rule refusal fires the hook too is in the build note.
- [ ] `team-log --check` accepts its lines.
- [ ] `tests/run` passes.
