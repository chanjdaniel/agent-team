# The agent team's code

This repo is the code of Daniel's agent team: the scripts that run a task's life, the prompts and settings each session starts with, the hooks, the toolkits and the tests.
The team's records live in the team home, a private repository of their own (see "The team home").
The team's own work on this repo goes through a task and a PR to `dev`, like any project's.

## Layout

One path per bullet and one thing per line, alphabetical within each list, so two PRs that add different things edit different lines.

- `bin/`: the team's commands, `team-*` and `claude-coordinator`.
  - `bin/hooks/`: the sessions' hooks.
    - `git/`: git's hooks for the code checkout.
    - `records-git/`: git's hooks for the team home.
  - `bin/lib/`: the shared library.
    - `code`: the paths every tracked path matches.
    - `data-check`: the one scan the CI's `data` job and the records' hook refuse with.
    - `doctor.d/`: `team-doctor`'s checks, one file each, which it sources in the order of their names (a new check is a new file, its number between its neighbours').
    - `gate-config.awk`: reads and sets the one key the team writes in Daniel's no-mistakes config (`agent_path_override`'s opencode).
    - `ledger-contract.json` and `ledger.jq`: the ledger contract and its jq.
    - `opencode-gate`: the gate's opencode wrapper, which `team-bootstrap` installs in `~/.no-mistakes/bin` and Daniel's no-mistakes config names.
    - `prices.json`: each model's list prices per million tokens with the date read and the source, the weights `team-tokens` gives each reply.
    - `records`: the team home's paths, which no tracked path matches.
    - `records-rewrite/`: `team-records-rewrite`'s drop list, message expression, S02 callback and `verify.py`.
    - `slots.jq`: `team-slots`'s settings of `slots.json`, the slots held and the room left for the reserved project and the others.
    - `stack.jq`: `team-stack`'s owner classes, Docker's sizes, the reaper's rules and the `stack.json` settings with their memory floor.
    - `time.jq`: `team-time`'s split of each task's time into phases, and its counts.
    - `tools.jq`: turns `tools.lock` into each tool's pin and install command for a machine.
    - `tools.lock`: the tools `team-doctor` checks, pinned or with a minimum, and their source per OS (for treehouse and no-mistakes, a GitHub release with each archive's checksum, or a fork's commit).
    - `vendor/git-filter-repo/`: git filter-repo 2.47.0, vendored with its MIT license.
- `coordinator.settings.json`: the coordinator's own settings: Discord, its hooks and its denials.
- `LICENSE`: the Apache License 2.0; vendored bats-core and git filter-repo keep their own.
- `plugins/coordinator-skills/`: skills loaded only into the coordinator by `bin/claude-coordinator`.
- `README.md`, `SETUP.md`: what a stranger reads first, with the sentence Daniel types on a new machine, and the agent's entry point for "set up as host".
- `roles/`: the role prompts each session's system prompt is appended with, one per role, the coordinator's included.
- `servers/`: the MCP servers the toolkits and sessions run, the MCP client `ui-capture` speaks with, and the `chrome-devtools-axi` client the browser toolkit's test runs.
  - `install`: puts them in the gitignored `servers/node_modules/`, as `team-bootstrap` does while `team-doctor`'s `servers` line fails.
  - `package.json` and `package-lock.json`: the packages and their pins, among them:
    - `chrome-devtools-axi`: the client the browser toolkit's test runs, since CI's runner has no global install; sessions run the one `tools.lock` pins, at the same version.
    - `chrome-devtools-mcp`: the sessions' MCP server, which their settings name by `CHROME_DEVTOOLS_AXI_MCP_PATH`.
- `settings/`: worker settings: `worker.json` shared, one file per role layered on it.
- `sops/`: standing procedures.
  - `docker.md`: the team's Docker stacks: labels, owner classes, the wrapper contract, `team-stack`'s subcommands, instances, admission, the idle sweep, the reaper, `team-janitor`'s daily report, the heartbeat's steps, the close teardown and the agents' rules.
  - `knowledge-graph.md`: a project's knowledge graph.
  - `machine-setup.md`: a new machine, driven by `SETUP.md`.
  - `model-trials.md`: trialling a cheaper model on one role of one project: the registry's `models`, the effort check, the paired reviews, the measures and their sources, the baseline by PR size and the note to Daniel that ends it.
  - `platform-gotchas.md`: general rules about the tools the team runs on, which every brief but the ops one points at in the code checkout, never the team home; the retro proposes keeping it short, and each change Daniel approves lands through a PR on this repository.
  - `portability.md`: moving the team between machines.
  - `records-rewrite.md`: the cutover that rewrites the records repository's history with `team-records-rewrite`, each step Daniel's or the coordinator's.
- `templates/`: the task plan and the worker briefs `team-open` and `team-brief` render.
- `tests/`: the bats suite, one `.bats` file per script (a long one split by topic, as `team-doctor-*.bats`).
  - `tests/bootstrap-drill`: runs `team-bootstrap` on a fresh runner for the by-hand Bootstrap workflow.
  - `tests/compaction-drill`: run by hand by the coordinator, since it starts a real Claude session; it compacts a coordinator-shaped session in a sandbox team home built from `tests/fixtures/compaction-drill/` and checks it still knows each task's wait and every current item.
  - `tests/compaction-drill.bats`: dry-runs `tests/compaction-drill` on a stub `claude`.
  - `tests/drill.bats`: the two-machine drill (handoff, steal, crash, outage, and the records rewrite's cutover on one machine).
  - `tests/helpers/`: the helpers, with `docker.bash`, the opt-in stub `docker`.
  - `tests/task-life.bats`: a whole task's life across the scripts.
  - `tests/toolkits/`: the toolkits' Node tests.
  - `tests/vendor/`: bats-core, vendored.
- `toolkits/`: plugin directories a worker loads with `team-worker --toolkit <name>`: MCP config (`.mcp.json`), skills, hooks (`hooks/hooks.json`), docs, scripts, and the skills' evals (`claude plugin eval`, on MCP mocks).
  - `browser/`: its session-start hook prints a banner for a UI task's builder and reviewer, whose `ui-check` skill captures and judges the screens a UI change touches.
  - `coordinator/`: the coordinator's MCP servers and the claude.ai connectors it keeps, no worker's, the only ones `claude-coordinator` lets it load (its README says how the others are denied and how one is added).

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
| `usage/` | Each machine's Claude usage, `usage/<machine>/<YYYY-MM-DD>.jsonl`, one line per assistant reply (token counts, model, session, never content), which `team-tokens export` writes from that machine's transcripts at each checkpoint and handoff, so it outlives Claude Code's 30-day transcript cleanup |
| `manual-steps.md` | The steps only Daniel can take |

- The scripts find it as `TEAM_HOME` when set, else the first line of `~/.config/agent-team/home` (a path relative to `$HOME`, or absolute); the library and `team-project` find it the same way, and refuse to start when neither names a directory, naming the fix (`echo agent-team-records > ~/.config/agent-team/home`), never falling back to the code checkout.
- Code never comes from the team home, and records never go into this repo: `bin/lib/records` lists the records paths, and the `pre-push` hook (below) keeps a tree holding any of them away from every repository but the team home's origin.

## Pull requests only

- The code repository changes only through pull requests to `dev`, and nothing is committed on `main`, which a release fast-forwards from `dev`.
- GitHub holds the rule: `dev`'s protection requires a pull request, refuses force pushes and deletion, and applies to administrators.
- Records never come here: every tracked path is code, listed in `bin/lib/code`, and none matches `bin/lib/records`; `tests/repo.bats` checks both, so a new path is listed as code in its PR.
- Git runs `bin/hooks/git/` as the code checkout's hooks once it has `git -C ~/agent-team config core.hooksPath bin/hooks/git`, which every worktree shares, each running its own checkout's hooks; they are the local guard, and need no team home.
  Its `pre-commit` (and `pre-merge-commit`) refuses every commit on `dev` and on `main`, and on any other branch a commit that adds or changes a records path, naming each.
  Its `pre-push` catches what those never see (a cherry-pick, a revert, `git am`, a fast-forward merge): it refuses every push to `dev`, and a push to `main` may only fast-forward it to a commit already on `origin/dev`.
  On every remote and branch, it also refuses a push whose tip tree holds a records path unless the remote's URL is the team home's origin (a trailing `.git` or slash aside), so the records never reach the code repository from a stale checkout.
- The records repository takes its one hook from here by absolute path, `git -C ~/agent-team-records config core.hooksPath ~/agent-team/bin/hooks/records-git`, which `team-doctor`'s `records hooks` line checks: its `pre-commit` refuses a records commit that adds an email address at a public provider or any image (a screenshot is never kept in git), naming each path, never the address.
- One scan, `bin/lib/data-check`, holds both data rules: that hook runs its `records` policy, and CI's `data` job its `code` policy (no email address outside the fixture domains, no image, no `node_modules/` path), after gitleaks over the PR's commits.
  A test that needs an address uses `example.com`, `example.invalid` or another fixture domain `bin/lib/data-check`'s header lists, and builds one at a real provider from a variable, so the file never holds one written out.
- Every session is denied skipping the hooks (`--no-verify`, `git commit -n`) and setting, unsetting or overriding `core.hooksPath` (reading it stays allowed), so the setup lines above are Daniel's to run.
  Those deny rules are a speed bump, never the guarantee: git accepts too many spellings for a deny list to cover, so the hooks and `dev`'s protection are what hold the rule.

## Tests and shellcheck

- `tests/run` runs shellcheck (0.11.0) on every shell script in `bin/`, `tests/`, `servers/` and `toolkits/`, then the whole bats suite, then the toolkit tests; `tests/run shellcheck`, `tests/run bats` and `tests/run toolkits` run one part each, as the CI jobs do.
  Its bats files run in parallel, one bats per file and as many at once as there are CPUs, so every file must stay independent of the others; its last line is the wall time.
  Every part but `shellcheck` alone runs under the machine's heavy-run lock (`bin/team-heavy`, which `team-checks` takes for the local checks too), so two suites on one machine queue instead of overlapping, and the sandbox clears `TEAM_HEAVY_HELD` so the tests take their own.
- A PR to `dev` is checked on GitHub: `.github/workflows/ci.yml` runs its jobs (`shellcheck`, `test`, `macos`, `toolkits`, `data` and `zizmor`) on every PR to `dev` and to `main` and by hand (`workflow_dispatch`).
  `dev`'s protection and `projects.toml`'s `required_checks` for `agent-team` require each job by its id, so renaming a job changes a required check, and `team-merge` merges only with every one passed on the PR's exact head.
  `tests/repo.bats` holds the jobs to the registry fixture's `required_checks`, and no workflow runs on a push, a schedule or `pull_request_target`.
  The `zizmor` job audits the workflows offline with zizmor, pinned by version and sha256 as gitleaks is, and fails on any finding; an accepted one is ignored on its own line as `# zizmor: ignore[<audit>] <reason>`, which `tests/repo.bats` holds, with no zizmor config to ignore more.
  `.github/workflows/zizmor-online.yml` runs the same zizmor on the same triggers with the run's read-only token, for its online audits (an impostor commit, a known-vulnerable action, ref confusion); it is never a required check, since it depends on GitHub's API, and `tests/repo.bats` holds its triggers and its zizmor pin to `ci.yml`'s.
  A project that still lists `local_checks` in `projects.toml` has them run through `bin/team-checks`, in a fresh detached worktree of the head: by `team-merge` before it merges, and by builders and reviewers on the head they deliver or review; `agent-team` lists none, so for it `team-checks` says so and passes.
  The Bootstrap workflow (`.github/workflows/bootstrap.yml`) runs only by hand: `team-bootstrap` on a fresh macOS runner and in an Arch container, which installs real tools.
- The toolkit tests are `node --test` files in `tests/toolkits/`, run after `servers/install`: each starts a toolkit's server exactly as its `.mcp.json` declares, with `op` stubbed and a throwaway MongoDB in Docker, and speaks MCP to it over stdio (`tests/toolkits/helpers/` documents the helpers); `mongo-helper.test.mjs` tests the throwaway MongoDB's own wait, which a container that exits ends at once with its exit code, that its removal takes its anonymous volumes with it, and that it runs tcmalloc on per-thread caches, so MongoDB 8.0 starts on the Linux 6.19 to 7.0.13 kernels whose rseq change its per-CPU caches break (SERVER-121912).
  `frontend.test.mjs` runs the frontend toolkit's scripts and server against a headless Chrome (the machine's, or `TEAM_CHROME`) on a local fixture page, never a window on the screen; that Chrome must be current enough for `open_devtools`, which `chrome-helper.test.mjs` checks fails at once on one too old.
  `browser.test.mjs` checks the browser toolkit's layout and runs its session-start hook as Claude Code runs a plugin's, under the user settings of today and the guarded ones; it also runs every `chrome-devtools-axi` command its `ui-check` skill names, headless on a fixture site in a named axi session of its own, and fails when the skill names one it does not run or its budget table's token figures do not match its image sizes.
  No test reaches 1Password or production: the test `PATH` refuses to start if a real `op` is on it.
- One file: `tests/vendor/bats-core/bin/bats tests/<name>.bats`; one test: add `-f '<part of its name>'`.
  A toolkit test file: `node --test tests/toolkits/<name>.test.mjs`; one test: add `--test-name-pattern '<part of its name>'`.
- Tests run the real scripts in a sandbox (`load helpers/common`, then `sandbox` in `setup`): `TEAM_HOME` and `HOME` are temporary, `claude`, `gh`, `curl`, `op`, `systemctl` and `launchctl` are stubs, and git is real.
  The sandbox's `TEAM_SYSTEM_ROOT` puts the library's system tool directories (treehouse's `/usr/local/bin` on Arch) inside it, so a PATH a test trims never gets the machine's own tools back on it.
  The sandbox refuses a TMPDIR under `/home` or `/Users` (a job's own tmp under HOME, say), whose paths the ledger reads as a machine's HOME: run the tests with one outside them, as the default is.
  `tests/helpers/common.bash` documents the helpers.
- macOS assesses each new executable file on its first run, about a quarter of a second each, so a test never writes or copies an executable it could share: `stub_command`, `copy_bin` and the doctor's version stubs hard-link a read-only copy made once per run (`shared` in `tests/helpers/common.bash`).
- No test reads the records of the checkout it runs in, so the suite passes on the code alone: a test that needs a real-shaped registry or secrets manifest copies it from `tests/fixtures/`, and `team-doctor`'s `records` line checks the team home's real ledger, registry and secrets description.
- CI's runner has jq 1.7.1, so keep to jq 1.7 features.
- Scripts and tests run on Linux and macOS: on macOS `bin/lib/platform.sh` (sourced by the library and the test helpers) puts Homebrew's GNU coreutils, findutils, sed, grep and `flock` first on `PATH`, so GNU forms are fine and BSD-only ones are not.
  CI's `macos` job runs `tests/run bats` on a macOS runner, with the rest of CI: on a PR to `main` or by hand.
- Repo invariants are tests too: every executable in `bin/` answers `--help` with its header, every `bin/team-*` script is named in `roles/coordinator.md`, which stays at most 120 lines, no tracked Markdown or template outside the records (`bin/lib/records`, kept as written) has an em dash, and the Layout above stays a list, one thing per line of at most 300 characters, alphabetical within each list.

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
