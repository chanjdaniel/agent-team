# 01: `team-log` takes comma lists and pairs, and stores `sent_back` as numbers

Phase 1.

**What to build:** the coordinator types list and object fields as the worker messages write them.
A contract-typed list field takes a comma list (`commits=a0017cce,9e0e3990`, `sent_back=5,6`, `guarded=ci,settings`, `none` for the empty list) besides JSON, and an object field takes `key:value` pairs (`findings=blocking:0,correctness:1,security:0,real-data:0,note:2`) besides JSON.
The contract gains a list-of-whole-numbers type, which `sent_back` takes, so it is always stored as numbers.
`team-log --check` flags each line from `strict_from` on whose `sent_back` holds a string, and `team-log --fix-sent-back` converts them once, as the spec's "`team-log` typing" says.

**Blocked by:** None

**Waits for:** T171 merged (it changes `team-log`'s review checks and the `review` contract).

**Files:** `bin/team-log`, `bin/lib/ledger-contract.json`, `bin/lib/ledger.jq`, `tests/team-log.bats`, `roles/coordinator.md` (the message table's DONE row).

- [ ] `commits=a,b`, `sent_back=5,6`, `guarded=ci,settings` and `sent_back=none` log as lists; an empty item (`5,,6`) is refused naming it.
- [ ] `findings=blocking:0,...` logs the same object as its JSON form, and T171's finding kinds hold for both forms.
- [ ] `sent_back=["5",6]` and `sent_back=5,6` both store `[5,6]`; `sent_back=5a` is refused naming `5a`; nothing is logged on a refusal.
- [ ] `team-log --check` on a fixture ledger with a string `sent_back` names that line and the conversion; a clean ledger still passes.
- [ ] `team-log --fix-sent-back` on a fixture ledger changes exactly the string lines (a byte comparison of every other line), prints the count, takes the ledger's lock, and refuses a non-numeric string with nothing changed.
- [ ] `team-log --help` documents both forms, the new type and `--fix-sent-back`.
- [ ] `tests/run` passes.
