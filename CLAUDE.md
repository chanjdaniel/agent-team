# The agent team's home

This repo is the home of Daniel's agent team: the scripts that run a task's life, the prompts and settings each session starts with, and the team's records.
The team's own work on it goes through a task and a PR to `dev`, like any project's.

## Layout

| Path | What it holds |
| - | - |
| `bin/` | The team's commands, `team-*` and `claude-coordinator`; `bin/lib/` is the shared library, the ledger contract and its jq, and `records`, the paths a direct commit on `dev` may touch; `bin/hooks/` the sessions' hooks, and `bin/hooks/git/` git's |
| `tests/` | The bats suite, one `.bats` file per script plus `task-life.bats`, a whole task's life across them, with `tests/helpers/` and bats-core vendored in `tests/vendor/`; `tests/toolkits/` the toolkits' Node tests |
| `roles/` | The role prompts each session's system prompt is appended with, one per role, the coordinator's included |
| `settings/` | Worker settings: `worker.json` shared, one file per role layered on it |
| `coordinator.settings.json` | The coordinator's own settings: Discord, its hooks and its denials |
| `plugins/coordinator-skills/` | Skills loaded only into the coordinator by `bin/claude-coordinator` |
| `toolkits/` | Plugin directories a worker loads with `team-worker --toolkit <name>`: MCP config (`.mcp.json`), skills, docs, scripts |
| `servers/` | The MCP servers the toolkits run, pinned by `package-lock.json`; `servers/install` puts them in the gitignored `servers/node_modules/` |
| `templates/` | The task plan and the worker briefs `team-open` and `team-brief` render |
| `projects.toml` | The project registry, read only through `bin/team-project` |
| `ledger.jsonl` | The append-only record of every task's events |
| `tasks/` | Each task's plan, briefs and archived scratch; history, kept as written |
| `manual-steps.md` | The steps only Daniel can take |
| `sops/`, `projects/` | Standing procedures, and each project's planning (Conventioner's backlog) |

`.scratch/task/` is a team-home task's own task directory, ignored by git.

## Direct commits on dev

- A commit straight to `dev` may touch records only, the paths `bin/lib/records` lists: `ledger.jsonl`, `tasks/`, `manual-steps.md`, `projects/`, `memory/` and `machine/`.
  Everything else reaches `dev` through a PR, and nothing is committed on `main`, which a release fast-forwards from `dev`.
- Git runs `bin/hooks/git/` as the team home's hooks once the primary checkout has `git -C ~/agent-team config core.hooksPath bin/hooks/git`, which every worktree shares, each running its own checkout's hooks.
  Its `pre-commit` (and `pre-merge-commit`) refuses a commit on `dev` that touches anything else, naming each path, and every commit on `main`.
  Its `pre-push` catches what those never see (a cherry-pick, a revert, `git am`, a fast-forward merge): a push to `dev` may only fast-forward it with commits that touch records only, and a push to `main` may only fast-forward it to a commit already on `origin/dev`.
- The `Dev records` workflow runs `bin/team-records-check` on every push to `dev` that changes more than records: a commit that is neither records only nor a PR's merge fails it.
- Every session is denied skipping the hooks (`--no-verify`, `git commit -n`) and touching `core.hooksPath`, so the setup line above is Daniel's to run.
  Those deny rules are a speed bump, never the guarantee: git accepts too many spellings for a deny list to cover, so the hooks and the `Dev records` workflow are what hold the rule.

## Tests and shellcheck

- `tests/run` runs shellcheck (0.11.0) on every shell script in `bin/`, `tests/`, `servers/` and `toolkits/`, then the whole bats suite, then the toolkit tests; `tests/run shellcheck`, `tests/run bats` and `tests/run toolkits` run one part each; CI runs the three parts as its three jobs.
- The toolkit tests are `node --test` files in `tests/toolkits/`, run after `servers/install`: each starts a toolkit's server exactly as its `.mcp.json` declares, with `op` stubbed and a throwaway MongoDB in Docker, and speaks MCP to it over stdio (`tests/toolkits/helpers/` documents the helpers).
  No test reaches 1Password or production: the test `PATH` refuses to start if a real `op` is on it.
- One file: `tests/vendor/bats-core/bin/bats tests/<name>.bats`; one test: add `-f '<part of its name>'`.
  A toolkit test file: `node --test tests/toolkits/<name>.test.mjs`; one test: add `--test-name-pattern '<part of its name>'`.
- Tests run the real scripts in a sandbox (`load helpers/common`, then `sandbox` in `setup`): `TEAM_HOME` and `HOME` are temporary, `claude`, `gh` and `curl` are stubs, and git is real.
  `tests/helpers/common.bash` documents the helpers.
- CI's runner has jq 1.7.1, so keep to jq 1.7 features.
- Repo invariants are tests too: every executable in `bin/` answers `--help` with its header, every `bin/team-*` script is named in `roles/coordinator.md`, which stays at most 120 lines, and no tracked Markdown outside `tasks/` and `projects/` (history, kept as written) has an em dash.

## Script conventions

- Bash, `set -euo pipefail`, then the library: `source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"`; `bin/lib/team.sh`'s header lists what it provides.
- The header (the comment block under the shebang) is the script's usage and its `--help`, which the library prints; exact commands live there and nowhere else.
- `TEAM_HOME` (the ledger, `tasks/`, `projects.toml`) is the directory above `bin/` unless set, and is not exported: pass it to a sibling script explicitly.
  Code (roles, settings, templates, plugins, hooks) comes from the script's own checkout, beside `bin/`, never from `TEAM_HOME`.
- Exit codes: 0 done, 1 refused or a check failed (`die`), 2 a malformed command line (`usage_error`), 75 try again later.
- The ledger changes only through the library's `ledger_append`, which checks each event against `bin/lib/ledger-contract.json` and the script named as its kind's writer; a new kind or field goes in the contract first.
- The registry is read only through `team-project`; a new key goes in its key lists and in the comment block of `projects.toml`.
- A script reaches Discord only through `discord_api` and GitHub through `gh`, and never prints a secret.

## Markdown

- One sentence per line; keep normal Markdown structure.
- The plain dash "-", never the em dash.
- Daniel is "they".
