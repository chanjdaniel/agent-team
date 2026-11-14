# Vendored bats-core

The team home's tests run on this copy, so no machine and no CI run installs bats.

- Source: https://github.com/bats-core/bats-core
- Tag: `v1.14.0` (released 2026-07-21), commit `eb7f42f8d608ac693d7a4b67474f6714ea68cfc5`
- Archive: https://github.com/bats-core/bats-core/archive/refs/tags/v1.14.0.tar.gz
- Archive SHA-256: `bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177`
- Licence: MIT, kept in `LICENSE.md` with `AUTHORS`.

Only the runtime is kept: `bin/`, `lib/` and `libexec/`, unchanged but for the one patched line below.
Everything else in the archive (docs, man pages, bats' own tests, Docker files, installers) is left out.

## The patched line

`libexec/bats-core/bats-exec-test`, in `bats_perform_test`: `declare -r BATS_killer_pid=$!` is `declare -gr BATS_killer_pid=$!`.

Why: `tests/run` gives every test a time limit through `BATS_TEST_TIMEOUT`, whose countdown is a background process that `bats_abort_timeout_countdown` kills once the test ends.
Upstream's `declare -r` inside a function makes the countdown's id a local, so a failing test's exit trap, which runs after `bats_perform_test` has returned, finds it empty and never kills the countdown.
The countdown holds the test's output open, so every failing test kept its file running until its whole limit ran out.
Reproduced on Bash 5.3 (T313): `BATS_TEST_TIMEOUT=600 bats` on a file holding only `@test "plain" { true; false; }` prints `not ok 1 plain` at once and then runs on for the 600 s, with `kill: (<pid>) - No such process` on stderr; with `-g` it ends at once.
`tests/repo.bats`' "tests/run's per-test limit never holds a failing test ..." fails without the patch.
Upstream's master still had the local `declare -r` on 2026-11-14.

On an upgrade, read the new release's `bats_perform_test`: drop the patch only if upstream sets `BATS_killer_pid` globally or no longer needs it, and keep it, reapplied, otherwise.

To upgrade, pick the latest release that is at least two weeks old, check the archive against its SHA-256, replace `bin/`, `lib/`, `libexec/`, `LICENSE.md` and `AUTHORS`, and update this file:

```sh
curl -fsSLO https://github.com/bats-core/bats-core/archive/refs/tags/<tag>.tar.gz
sha256sum <tag>.tar.gz
```
