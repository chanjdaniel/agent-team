# Vendored bats-core

The team home's tests run on this copy, so no machine and no CI run installs bats.

- Source: https://github.com/bats-core/bats-core
- Tag: `v1.14.0` (released 2026-07-21), commit `eb7f42f8d608ac693d7a4b67474f6714ea68cfc5`
- Archive: https://github.com/bats-core/bats-core/archive/refs/tags/v1.14.0.tar.gz
- Archive SHA-256: `bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177`
- Licence: MIT, kept in `LICENSE.md` with `AUTHORS`.

Only the runtime is kept: `bin/`, `lib/` and `libexec/`, unchanged.
Everything else in the archive (docs, man pages, bats' own tests, Docker files, installers) is left out.

To upgrade, pick the latest release that is at least two weeks old, check the archive against its SHA-256, replace `bin/`, `lib/`, `libexec/`, `LICENSE.md` and `AUTHORS`, and update this file:

```sh
curl -fsSLO https://github.com/bats-core/bats-core/archive/refs/tags/<tag>.tar.gz
sha256sum <tag>.tar.gz
```
