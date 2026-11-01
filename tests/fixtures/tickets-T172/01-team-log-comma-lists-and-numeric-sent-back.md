# 01: `team-log` takes comma lists and pairs, and stores `sent_back` as numbers

Phase 1.

**What to build:** the coordinator types list and object fields as the worker messages write them.
A contract-typed list field takes a comma list (`commits=a0017cce,9e0e3990`, `sent_back=5,6`, `guarded=ci,settings`, `none` for the empty list) besides JSON, and an object field takes `key:value` pairs (`findings=blocking:0,correctness:1,security:0,real-data:0,note:2`) besides JSON.
The contract gains a list-of-whole-numbers type, which `sent_back` takes, so it is always stored as numbers.
`team-log --check` flags each line from `strict_from` on whose `sent_back` holds a string, and `team-log --fix-sent-back` converts them once, as the spec's "`team-log` typing" says.

**Blocked by:** None

**Waits for:** T171 merged (it changes `team-log`'s review checks and the `review` contract).

**Files:** `bin/team-log`, `bin/lib/ledger-contract.json`, `bin/lib/ledger.jq`, `tests/team-log.bats`, `roles/coordinator.md` (the message table's DONE row).

- [x] `commits=a,b`, `sent_back=5,6`, `guarded=ci,settings` and `sent_back=none` log as lists; an empty item (`5,,6`) is refused naming it.
- [x] `findings=blocking:0,...` logs the same object as its JSON form, and T171's finding kinds hold for both forms.
- [x] `sent_back=["5",6]` and `sent_back=5,6` both store `[5,6]`; `sent_back=5a` is refused naming `5a`; nothing is logged on a refusal.
- [x] `team-log --check` on a fixture ledger with a string `sent_back` names that line and the conversion; a clean ledger still passes.
- [x] `team-log --fix-sent-back` on a fixture ledger changes exactly the string lines (a byte comparison of every other line), prints the count, takes the ledger's lock, and refuses a non-numeric string with nothing changed.
- [x] `team-log --help` documents both forms, the new type and `--fix-sent-back`.
- [x] `tests/run` passes (on 0a8087cc, 6m 44s).

## Found along the way

- `before` takes the new whole-numbers type too (`numbers` in the contract), since a reviewer's DONE writes `before=3,5` as a comma list, which as strings `before_problems` would refuse; `--fix-sent-back` converts its strings as well (the real ledger holds none).
- The pairs form follows T171's finding kinds (`note-change`, `note-before`), not the ticket's older `note:2` example, as the spec's last typing bullet says.
- A list or object value that starts with `[` or `{` is read only as JSON, so `commits=1234567` is now `["1234567"]` and `findings=3` is refused as no `key:value` pair; the existing tests that used those as wrong-type examples now use JSON of the wrong shape.
- `merge-preapproved`'s `scope` takes a comma list too, checked as its JSON form is; `roles/coordinator.md` line 41 still says "as a JSON list", which still works.
- Once this merges, `team-doctor`'s `records` line fails on the real ledger's 40 string `sent_back` lines until `team-log --fix-sent-back` runs, as the spec's Further Notes plan; a dry run on a copy of the real ledger changed exactly those 40 lines and left it meeting the contract.
