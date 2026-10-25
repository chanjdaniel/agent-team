# The agent team's code

This repo is the code of Daniel's agent team: the scripts that run a task's life, the prompts and settings each session starts with, the hooks, the toolkits and the tests.
The team's records live in the team home, a private repository of their own (see "The team home").
The team's own work on this repo goes through a task and a PR to `dev`, like any project's.

## Layout

| Path | What it holds |
| - | - |
| `bin/` | The team's commands, `team-*` and `claude-coordinator`; `bin/lib/` is the shared library, the ledger contract and its jq, `stack.jq` (`team-stack`'s owner classes and Docker's sizes), `tools.lock`, the tools `team-doctor` checks, pinned or with a minimum, and their source per OS (for treehouse and no-mistakes, a GitHub release with each archive's checksum, or a fork's commit), `tools.jq` (which turns `tools.lock` into each tool's pin and install command for a machine), `opencode-gate`, the gate's opencode wrapper, which `team-bootstrap` installs in `~/.no-mistakes/bin` and Daniel's no-mistakes config names, `records`, the paths a direct commit on `dev` may touch, and `code`, every other tracked path; `bin/hooks/` the sessions' hooks, and `bin/hooks/git/` git's |
| `tests/` | The bats suite, one `.bats` file per script (a long one split by topic, as `team-doctor-*.bats`) plus `task-life.bats`, a whole task's life across them, and `drill.bats`, the two-machine drill (handoff, steal, crash, outage), with `tests/helpers/` (`docker.bash`, the opt-in stub `docker`) and bats-core vendored in `tests/vendor/`; `tests/toolkits/` the toolkits' Node tests; `tests/bootstrap-drill` runs `team-bootstrap` on a fresh runner for the by-hand Bootstrap workflow |
| `roles/` | The role prompts each session's system prompt is appended with, one per role, the coordinator's included |
| `settings/` | Worker settings: `worker.json` shared, one file per role layered on it |
| `coordinator.settings.json` | The coordinator's own settings: Discord, its hooks and its denials |
| `plugins/coordinator-skills/` | Skills loaded only into the coordinator by `bin/claude-coordinator` |
| `toolkits/` | Plugin directories a worker loads with `team-worker --toolkit <name>`: MCP config (`.mcp.json`), skills, docs, scripts, and the skills' evals (`claude plugin eval`, on MCP mocks) |
| `servers/` | The MCP servers the toolkits run, pinned by `package-lock.json`; `servers/install` puts them in the gitignored `servers/node_modules/` |
| `templates/` | The task plan and the worker briefs `team-open` and `team-brief` render |
| `README.md`, `SETUP.md` | What a stranger reads first, with the sentence Daniel types on a new machine, and the agent's entry point for "set up as host" |
| `LICENSE` | The Apache License 2.0; vendored bats-core keeps its own |
| `sops/` | Standing procedures: `machine-setup.md` (a new machine, driven by `SETUP.md`), `portability.md` (moving the team between machines), `docker.md` (the team's Docker stacks: labels, owner classes, the wrapper contract, `team-stack`'s subcommands, admission, the idle sweep, the close teardown and the agents' rules), `knowledge-graph.md`, `platform-gotchas.md` (general rules about the tools the team runs on, which every brief but the ops one points at in the code checkout, never the team home; the retro proposes keeping it short, and each change Daniel approves lands through a PR on this repository) |

`.scratch/task/` is the task directory of a task on this repo, ignored by git.

## The team home

The team home is the records the scripts read and write: a git checkout of a private repository of its own, never part of this repo.
It holds:

| Path | What it holds |
| - | - |
| `ledger.jsonl` | The append-only record of every task's events |
| `projects.toml` | The project registry, read only through `bin/team-project`, whose `--help` documents every key |
| `tasks/` | Each task's plan, briefs and archived scratch; history, kept as written |
| `projects/` | Each project's planning (Conventioner's backlog) |
| `memory/` | Each registered project's Claude Code auto memory, `memory/<project>/`, which every machine and worktree of it shares once `team-config apply` points the project at it, and the coordinator's, `memory/coordinator/`, the team home's own while it is no project's primary checkout |
| `machine/` | What a machine needs to run the team, beyond the tools `bin/lib/tools.lock` pins: `claude/`, the Claude user config every machine shares (instructions, settings, skills, plugins), which `team-config` applies and captures; `secrets.json`, every secret file a machine needs, never a value, which `team-secrets` checks and restores from 1Password, described for Daniel in `secrets.md` |
| `manual-steps.md` | The steps only Daniel can take |

- The scripts find it as `TEAM_HOME` when set, else the first line of `~/.config/agent-team/home` (a path relative to `$HOME`, or absolute), else the directory above `bin/`; the library and `team-project` find it the same way, and refuse a setting that names no directory.
- Code never comes from the team home, and records never go into this repo: `bin/lib/records` lists the records paths, and the `pre-push` hook (below) keeps a tree holding any of them away from every repository but the team home's origin.

## Direct commits on dev

- A commit straight to `dev` may touch records only, the paths `bin/lib/records` lists: `ledger.jsonl`, `manual-steps.md`, `projects.toml`, `tasks/`, `projects/`, `memory/` and `machine/`.
  Everything else reaches `dev` through a PR, and nothing is committed on `main`, which a release fast-forwards from `dev`.
  Every tracked path that is not a record is code, listed in `bin/lib/code`, the paths the public repository will hold; `tests/repo.bats` checks that each tracked path is in exactly one of the two lists, so a new path is assigned in its PR.
- Git runs `bin/hooks/git/` as the code checkout's hooks once it has `git -C ~/agent-team config core.hooksPath bin/hooks/git`, which every worktree shares, each running its own checkout's hooks.
  Its `pre-commit` (and `pre-merge-commit`) refuses a commit on `dev` that touches anything else, naming each path, and every commit on `main`.
  Its `pre-push` catches what those never see (a cherry-pick, a revert, `git am`, a fast-forward merge): a push to `dev` may only fast-forward it with commits that touch records only, and a push to `main` may only fast-forward it to a commit already on `origin/dev`.
  On every remote and branch, it also refuses a push whose tip tree holds a records path unless the remote's URL is the team home's origin (a trailing `.git` or slash aside), so a checkout whose origin names another repository, the public one say, never takes the records there.
- GitHub runs no check on `dev` (CI policy B: the repo is private, and its Actions minutes are few), so what reaches `dev` without a local push is checked at each merge: `team-merge` runs `bin/team-records-check` over `dev` from the last merge it logged to the new one, and reports a commit that is neither records only nor a PR's merge.
- Every session is denied skipping the hooks (`--no-verify`, `git commit -n`) and setting, unsetting or overriding `core.hooksPath` (reading it stays allowed), so the setup line above is Daniel's to run.
  Those deny rules are a speed bump, never the guarantee: git accepts too many spellings for a deny list to cover, so the hooks and `team-merge`'s check are what hold the rule.

## Tests and shellcheck

- `tests/run` runs shellcheck (0.11.0) on every shell script in `bin/`, `tests/`, `servers/` and `toolkits/`, then the whole bats suite, then the toolkit tests; `tests/run shellcheck`, `tests/run bats` and `tests/run toolkits` run one part each, as the CI jobs do.
  Its bats files run in parallel, one bats per file and as many at once as there are CPUs, so every file must stay independent of the others; its last line is the wall time.
- A PR to `dev` is checked locally, never on GitHub (CI policy B): `projects.toml` gives `agent-team` `local_checks = ["tests/run"]`, which `team-merge` runs on the PR's exact head before it merges, and builders and reviewers run `tests/run` on the head they deliver or review.
  GitHub's CI (`.github/workflows/ci.yml`) runs only on a PR to `main` and by hand (`workflow_dispatch`).
  The Bootstrap workflow (`.github/workflows/bootstrap.yml`) runs only by hand: `team-bootstrap` on a fresh macOS runner and in an Arch container, which installs real tools.
- The toolkit tests are `node --test` files in `tests/toolkits/`, run after `servers/install`: each starts a toolkit's server exactly as its `.mcp.json` declares, with `op` stubbed and a throwaway MongoDB in Docker, and speaks MCP to it over stdio (`tests/toolkits/helpers/` documents the helpers); `mongo-helper.test.mjs` tests the throwaway MongoDB's own wait, and that its removal takes its anonymous volumes with it.
  No test reaches 1Password or production: the test `PATH` refuses to start if a real `op` is on it.
- One file: `tests/vendor/bats-core/bin/bats tests/<name>.bats`; one test: add `-f '<part of its name>'`.
  A toolkit test file: `node --test tests/toolkits/<name>.test.mjs`; one test: add `--test-name-pattern '<part of its name>'`.
- Tests run the real scripts in a sandbox (`load helpers/common`, then `sandbox` in `setup`): `TEAM_HOME` and `HOME` are temporary, `claude`, `gh`, `curl`, `op`, `systemctl` and `launchctl` are stubs, and git is real.
  The sandbox refuses a TMPDIR under `/home` or `/Users` (a job's own tmp under HOME, say), whose paths the ledger reads as a machine's HOME: run the tests with one outside them, as the default is.
  `tests/helpers/common.bash` documents the helpers.
- macOS assesses each new executable file on its first run, about a quarter of a second each, so a test never writes or copies an executable it could share: `stub_command`, `copy_bin` and the doctor's version stubs hard-link a read-only copy made once per run (`shared` in `tests/helpers/common.bash`).
- No test reads the records of the checkout it runs in, so the suite passes on the code alone: a test that needs a real-shaped registry or secrets manifest copies it from `tests/fixtures/`, and `team-doctor`'s `records` line checks the team home's real ledger, registry and secrets description.
- CI's runner has jq 1.7.1, so keep to jq 1.7 features.
- Scripts and tests run on Linux and macOS: on macOS `bin/lib/platform.sh` (sourced by the library and the test helpers) puts Homebrew's GNU coreutils, findutils, sed, grep and `flock` first on `PATH`, so GNU forms are fine and BSD-only ones are not.
  CI's `macos` job runs `tests/run bats` on a macOS runner, with the rest of CI: on a PR to `main` or by hand.
- Repo invariants are tests too: every executable in `bin/` answers `--help` with its header, every `bin/team-*` script is named in `roles/coordinator.md`, which stays at most 120 lines, and no tracked Markdown or template outside the records (`bin/lib/records`, kept as written) has an em dash.

## Script conventions

- Bash 5 (the library refuses older), `set -euo pipefail`, then the library: `source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"`; `bin/lib/team.sh`'s header lists what it provides.
- The header (the comment block under the shebang) is the script's usage and its `--help`, which the library prints; exact commands live there and nowhere else.
- The team home is found as "The team home" says; `TEAM_HOME` is not exported, so pass it to a sibling script explicitly.
- The code checkout is the directory above `bin/` (`~/agent-team`): code (roles, settings, templates, plugins, hooks, toolkits) comes from the script's own checkout, never from the team home.
  In settings files and a toolkit's `.mcp.json`, `@TEAM_CODE@` names the code checkout and `@TASK_DIR@` the team home's `tasks/T<n>/`; `team-worker` and `claude-coordinator` fill them in.
- Exit codes: 0 done, 1 refused or a check failed (`die`), 2 a malformed command line (`usage_error`), 75 try again later.
- The ledger changes only through the library's `ledger_append`, which checks each event against `bin/lib/ledger-contract.json` and the script named as its kind's writer; a new kind or field goes in the contract first.
- The registry is read only through `team-project`; a new key goes in its key lists and in its header, which documents every key.
- A script reaches Discord only through `discord_api` and GitHub through `gh`, and never prints a secret.

## Markdown

- One sentence per line; keep normal Markdown structure.
- The plain dash "-", never the em dash.
- Daniel is "they".
