# 03: `team-log --from-message` reads a worker's message whole

Phase 1.

**What to build:** `team-log T<n> --from-message '<message>' [--from <session>] [--sent-back <list>] [--print]` parses one worker message into its events and logs them, or with `--print` prints them as JSON lines and logs nothing.
The parser is a jq module in `bin/lib/` that every kind in the spec's table goes through, with the role and session rules the spec gives; a `PR` message reads the PR's head and head branch with `gh`.
`CLAUDE.md`'s Layout lists the new module.

**Blocked by:** 01, 04, 05

**Waits for:** T171 merged (the reviewer's DONE line and the finding kinds are T171's).

**Files:** `bin/team-log`, a new `bin/lib/messages.jq`, `bin/lib/ledger.jq`, `CLAUDE.md`, `roles/coordinator.md` (the message table's intro line), `tests/team-log.bats`; the message formats in `roles/*.md` and `templates/briefs/`.

- [x] One test per row of the spec's message table, each message copied from the format its role prompt or template gives, logs exactly the events the table names.
- [x] A review's `head` comes from the reviewer's latest launch's brief record when there is one (the launch's `brief` and that brief's record, tickets 04 and 05), else the message's own head for a pass on a head, else it is refused naming `head=`.
- [x] The role comes from the kind, else `--from`, else the only launch with no report since; two candidates are refused naming both.
- [x] A message for another task, an unparseable one and a malformed part are refused naming what was expected, with nothing logged.
- [x] `--print` logs nothing and prints what a run without it logs; `--sent-back` is refused on any message but `DONE findings`.
- [x] A jq program that includes the module also includes every module it includes, as `tests/repo.bats` holds.
- [x] `tests/run` passes.
