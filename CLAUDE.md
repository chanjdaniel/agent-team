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
    - `capacity.jq`: `team-capacity`'s settings of `capacity.json`, the worktrees held, a reading of the machine's load and the team's use per task, the cost samples and estimates, the reservations and the admission rule, the stow and resume plans, and their texts.
    - `chrome.sh`: the one lookup of a machine's Chrome, its executable and its app, which `team-doctor`'s `chrome` line and `team-tickets --graph` both take.
    - `code`: the paths every tracked path matches.
    - `command_text.py`: the text of a Bash command that runs as code, each heredoc's body left out unless a shell may read it, and a shell's `-c` string and what is piped into a shell where a command starts read as code, for `bin/hooks/command-guard`; `team-tokens` takes its heredoc rule.
    - `data-check`: the one scan the CI's `data` job and the records' hook refuse with.
    - `doctor.d/`: `team-doctor`'s checks, one file each, which it sources in the order of their names (a new check is a new file, its number between its neighbours').
    - `drills.jq`: the drills module, the one place that says what a line of the team home's `drills.jsonl` is, when a drill is due and how `team-drill status` shows it.
    - `drills.json`: the drill registry, each drill's name, what it is, who runs it (`coordinator`, or `daniel` when it needs them present) and the code it proves, with the one age past which a drill is due.
    - `gate-claude-settings.json`: the settings the gate's Claude takes with `--settings`, its commit attribution off, since it loads no user settings.
    - `gate-config.awk`: reads and sets the one key the team writes in Daniel's no-mistakes config (`agent_path_override`'s opencode), and reads `agent_args_override`'s list for one agent.
    - `guarded`: the short list, one extended regular expression per line with its area, `@<project>` or `@own` for one project's line, any changed path of which brings a merge on the default word, the approved plan, back to Daniel for the per-head word, read by `team-merge` from its own checkout.
    - `health.jq`: the health module, the one place that says what unhealthy means: the fold of each heartbeat run into the health record, the ledger's one-pass scan, every health threshold, and the view `team-timers health` prints, its problems and its line in markup and plain text.
    - `ledger-contract.json` and `ledger.jq`: the ledger contract and its jq.
    - `lifecycle.json`: the task lifecycle's table, its statuses, phases, start states, what each kind may follow and does, the park causes and what ends each, and the `lifecycle_from` cutover, which `ledger.jq` imports.
    - `messages.jq`: reads a worker's message into the events the coordinator's message table gives it, for `team-log --from-message`.
    - `notice.jq`: the notice module, the one lifecycle of every notice of a standing problem the heartbeat posts in `#coordinator`: the notice record `notices.json`, the table of each source's rules, the judging, its outcomes and the move from the old records.
    - `notices.sh`: the notice record's reads and locked writes, and the move of each old record into it, sourced after `team.sh` by `team-timers` and `team-uptime`.
    - `opencode-gate`: the gate's opencode wrapper, which `team-bootstrap` installs in `~/.no-mistakes/bin` and Daniel's no-mistakes config names on an opencode gate.
    - `outbound.py`: whether a Bash command's `curl` or `wget` sends a request body or a file to a literal host outside the team's own local ones, directly or through a proxy, read by `command_text.py`'s `simple_commands`, for `bin/hooks/command-guard`.
    - `prices.json`: each model's list prices per million tokens with the date read and the source, the weights `team-tokens` gives each reply.
    - `probe.json`: the refusal probe's data, each attempt `team-load-check --probe` has a worker role make and the layer that should refuse it, every deny rule of the worker roles' settings sorted into a family, and their PreToolUse hooks, each with an attempt or the reason it has none.
    - `reading.sh`: one reading of the machine's load (its memory, its processes by directory and descent, the team's stacks), which `team-capacity sample` takes.
    - `records`: the team home's paths, which no tracked path matches.
    - `records-rewrite/`: `team-records-rewrite`'s drop list, message expression, S02 callback and `verify.py`.
    - `review-app`: the reviewer App's id and slug, one `id=<n>` and one `slug=<s>` line, a committed constant; with no such file the App is off and agent-team merges on the per-head word alone.
    - `session-activity`: how long each live session's transcripts have gone unwritten, and the tool calls still running in a quiet one, for `team-sweep`'s stalled finding.
    - `stack.jq`: `team-stack`'s owner classes, Docker's sizes, the reaper's rules and the `stack.json` settings, with the keys no longer read since the level's budget admits a stack.
    - `stow.sh`: `team-stow`'s steps, which `team-handoff` takes through `team-stow`: each task's branches checked and pushed, its `stowing` logged, its sessions stopped, its ops session ended, its `stowed` logged, or its `stow-failed` when a later step refuses it or the run stops.
    - `ticket_graph.py`: draws a task's ticket list, as `team-tickets --json` prints it, as the self-contained HTML page of its dependency graph that `team-tickets --html` writes.
    - `time.jq`: `team-time`'s split of each task's time into phases, and its counts.
    - `tools.jq`: turns `tools.lock` into each tool's pin and install command for a machine.
    - `tools.lock`: the tools `team-doctor` checks, pinned or with a minimum, and their source per OS (for treehouse and no-mistakes, a GitHub release with each archive's checksum, or a fork's commit).
    - `uptime.jq`: `team-uptime`'s rules, the counting of each production check, when one is down, its outages judged as notices through `notice.jq`, each post's text, and the status line.
    - `vendor/git-filter-repo/`: git filter-repo 2.47.0, vendored with its MIT license.
    - `workers.jq`: `team-time`'s worker lifetimes, from each launch to its done, pr or ticket-done, review, replacement, stow or close, with their averages by role, path, project, model and toolkits, the longest, the running, and the classes and breakdown of their time rows.
    - `working-set.awk`: a cgroup's working set, its `memory.current` less the reclaimable page cache, the one measure of memory use `team-capacity`, `team-heavy` and `team-level` read a cgroup by.
- `coordinator.settings.json`: the coordinator's own settings: Discord, its hooks and its denials.
- `LICENSE`: the Apache License 2.0; vendored bats-core and git filter-repo keep their own.
- `plugins/coordinator-skills/`: skills loaded only into the coordinator by `bin/claude-coordinator`.
- `README.md`, `SETUP.md`: what a stranger reads first, with the sentence Daniel types on a new machine, and the agent's entry point for "set up as host".
- `roles/`: the role prompts each session's system prompt is appended with, one per role, the coordinator's included; `team-worker` follows a planner's, builder's or reviewer's with its project's root `CLAUDE.md` and `AGENTS.md` as `origin/<base>` has them.
- `servers/`: the MCP servers the toolkits and sessions run, the MCP client `ui-capture` speaks with, the `chrome-devtools-axi` client the browser toolkit's test runs, and the packages the effect toolkit's tests check its skill, hook and Foldkit DevTools server against.
  - `install`: puts them in the gitignored `servers/node_modules/`, as `team-bootstrap` does while `team-doctor`'s `servers` line fails.
  - `package.json` and `package-lock.json`: the packages and their pins, among them:
    - `@effect/platform-browser`: the Effect browser platform `foldkit` takes as a peer, for the effect toolkit's fixture Foldkit app.
    - `@effect/tsgo`: Effect's language service on TypeScript 7, whose `effect-tsgo` the effect toolkit's test runs its post-edit hook and the `effect-v4` skill's check against.
    - `@foldkit/devtools-mcp`: Foldkit's DevTools MCP server, the version released with the `foldkit` that the Foldkit app the team builds pins, which the effect toolkit's wrapper starts confined to the session's worktree.
    - `@foldkit/vite-plugin`: the Vite plugin whose relay `@foldkit/devtools-mcp` reaches, for the fixture app's dev servers.
    - `chrome-devtools-axi`: the client the browser toolkit's test runs, since CI's runner has no global install; sessions run the one `tools.lock` pins, at the same version.
    - `chrome-devtools-mcp`: the sessions' MCP server, which their settings name by `CHROME_DEVTOOLS_AXI_MCP_PATH`.
    - `effect`: the Effect version whose exports the effect toolkit's test holds the `effect-v4` skill's trap table to.
    - `foldkit`: the Foldkit version that app pins, the framework of the effect toolkit's fixture app.
    - `typescript`: TypeScript 7, which `effect-tsgo diagnostics` needs installed beside it, though `@effect/tsgo` declares no peer.
    - `vite`: the Vite version that app pins, which runs the fixture app's dev servers.
- `settings/`: worker settings: `worker.json` shared, one file per role layered on it; with the user settings, all a planner, builder or reviewer loads (`--setting-sources user`), none of its worktree's `.claude/`.
- `sops/`: standing procedures.
  - `docker.md`: the team's Docker stacks: labels, owner classes, the wrapper contract, `team-stack`'s subcommands, instances, admission, the idle sweep, the reaper, `team-janitor`'s daily report, the heartbeat's steps, the close teardown and the agents' rules.
  - `drills.md`: the drills, live runs of the paths the team's portability and guards rest on: the record in `drills.jsonl`, who runs one, and each drill's runbook, its steps, who takes each, its duration, what passes and how it is recorded.
  - `frontend-patterns.md`: rules that hold beyond one project for a UI's dev-only component library, combobox, large list, dialog, realistic fixture and bundle growth, each with its why.
  - `knowledge-graph.md`: a project's knowledge graph.
  - `machine-setup.md`: a new machine, driven by `SETUP.md`.
  - `merging.md`: merging on the per-head word and the default word, the approved plan: their events, the order `team-merge` tries them, what each holds a PR to, the plan approval, the short list, the withdrawals, what never merges, the coordinator's steps and the retired words.
  - `model-trials.md`: trialling a cheaper model on one role of one project, or a setup change that claims to save tokens: the registry's `models`, the effort check, the paired reviews, a toolkit's arm, the measures and their sources, the baseline by PR size and the note to Daniel.
  - `platform-gotchas.md`: general rules about the tools the team runs on, which every brief but the ops one points at in the code checkout, never the team home; the retro proposes keeping it short, and each change Daniel approves lands through a PR on this repository.
  - `portability.md`: moving the team between machines.
  - `records-rewrite.md`: the cutover that rewrites the records repository's history with `team-records-rewrite`, each step Daniel's or the coordinator's.
  - `resources.md`: the team's resources: its systemd user slice and each task's, `team-capacity install`, the placement of worker sessions and the gate in it, the checked assumptions, the readings per task, the learned costs, heavy runs' scopes, and the doctor's `resources` line.
- `templates/`: the task plan and the worker briefs `team-open` and `team-brief` render.
- `tests/`: the bats suite, one `.bats` file per script (a long one split by topic, as `team-doctor-*.bats`).
  - `tests/bootstrap-drill`: runs `team-bootstrap` on a fresh runner for the by-hand Bootstrap workflow, and ends with the record line `team-drill import` reads from the job's log.
  - `tests/bootstrap-drill.bats`: runs `tests/bootstrap-drill` on a stub `team-bootstrap`.
  - `tests/compaction-drill`: run by hand by the coordinator, since it starts a real Claude session; it compacts a coordinator-shaped session in a sandbox team home built from `tests/fixtures/compaction-drill/`, checks it still knows each task's wait and every current item, and records its run.
  - `tests/compaction-drill.bats`: dry-runs `tests/compaction-drill` on a stub `claude`.
  - `tests/drill.bats`: the two-machine drill (handoff, steal, crash, outage, and the records rewrite's cutover on one machine).
  - `tests/helpers/`: the helpers, with `docker.bash`, the opt-in stub `docker`.
  - `tests/shards`: splits the bats files into `tests/run bats --shard`'s shards by their seconds in `tests/timings.tsv`, and `tests/shards update` rewrites those from a CI run's shard jobs.
  - `tests/task-life.bats`: a whole task's life across the scripts.
  - `tests/timings.tsv`: each bats file's seconds in one CI run, on Linux and macOS, which `tests/shards` weighs it by.
  - `tests/toolkits/`: the toolkits' Node tests.
  - `tests/vendor/`: bats-core, vendored.
- `toolkits/`: plugin directories a worker loads with `team-worker --toolkit <name>`: MCP config (`.mcp.json`) and the roles a server starts for when not every one (`mcp-roles.json`), skills, hooks (`hooks/hooks.json`), docs, scripts, and the skills' evals (`claude plugin eval`, on MCP mocks).
  - `browser/`: its session-start hook prints a banner for a UI task's builder and reviewer, whose `ui-check` skill captures and judges the screens a UI change touches.
  - `codegraph/`: for a setup trial's builders and reviewers, a session-start hook that, in a worktree with a `.codegraph/` directory, builds or syncs that worktree's CodeGraph index and prints a banner to locate code with `codegraph explore` first; no MCP server.
  - `coordinator/`: the coordinator's MCP servers and the claude.ai connectors it keeps, no worker's, the only ones `claude-coordinator` lets it load (its README says how the others are denied and how one is added).
  - `effect/`: for an Effect project's planner, builder and reviewer, the `effect-v4` skill (the installed `effect`'s sources, the v3 and beta traps, the check), a hook giving Effect's findings on each TypeScript file edited, and, but for a planner, Foldkit's DevTools server, held to the worktree.
  - `spec-review/`: the `spec-review` skill, which has two fresh, read-only reader agents read a task's spec and tickets in parallel, as a stranger and as its builder, and writes their findings to `spec-review.md` for the spec's author to sort.

`.scratch/task/` is the task directory of a task on this repo, ignored by git.

## The team home

The team home is the records the scripts read and write: a git checkout of a private repository of its own, never part of this repo.
It holds:

| Path | What it holds |
| - | - |
| `ledger.jsonl` | The append-only record of every task's events |
| `level.jsonl` | The team's resource level and mode, one line per change (`team-level`), committed with the ledger so a level holds across restarts and handoffs |
| `drills.jsonl` | Each run of a drill, one line per run (`team-drill`): what ran, on which machine, code commit and Claude Code version, and its verdict, appended and never rewritten |
| `waiting.md` | What waits on Daniel, every open ask, PR ready to merge and interview, numbered, as `team-inbox` last wrote it from the ledger |
| `waiting.json` | The same list with each item's number and key and the latest post, which `team-inbox` reads to keep each number while its item stands |
| `projects.toml` | The project registry, read only through `bin/team-project`, whose `--help` documents every key |
| `tasks/` | Each task's plan, briefs and archived scratch; history, kept as written |
| `projects/` | Each project's planning (Conventioner's backlog) |
| `memory/` | Each registered project's Claude Code auto memory, `memory/<project>/`, which every machine and worktree of it shares once `team-config apply` points the project at it (a worker of it through `team-worker`'s settings), and the coordinator's, `memory/coordinator/`, the team home's own while it is no project's primary checkout |
| `machine/` | What a machine needs to run the team, beyond the tools `bin/lib/tools.lock` pins: `claude/`, the Claude user config every machine shares (instructions, settings, skills, plugins), which `team-config` applies and captures; `secrets.json`, every secret file a machine needs, never a value, which `team-secrets` checks and restores from 1Password, described for Daniel in `secrets.md` |
| `usage/` | Each machine's Claude usage, `usage/<machine>/<YYYY-MM-DD>.jsonl`, one line per assistant reply (token counts, model, session, never content), and `usage/<machine>/time/<YYYY-MM-DD>.jsonl`, one row per launched worker session and day of where its time went (durations and tool or command names only), which `team-tokens export` writes from that machine's transcripts at each checkpoint and handoff, so they outlive Claude Code's 30-day transcript cleanup |
| `manual-steps.md` | The steps only Daniel can take |

- The scripts find it as `TEAM_HOME` when set, else the first line of `~/.config/agent-team/home` (a path relative to `$HOME`, or absolute); the library and `team-project` find it the same way, and refuse to start when neither names a directory, naming the fix (`echo agent-team-records > ~/.config/agent-team/home`), never falling back to the code checkout.
- Code never comes from the team home, and records never go into this repo: `bin/lib/records` lists the records paths, and the `pre-push` hook (below) keeps a tree holding any of them away from every repository but the team home's origin.

## Pull requests only

- The code repository changes only through pull requests to `dev`, and nothing is committed on `main`, which a release fast-forwards from `dev`.
- GitHub holds the rule: `dev`'s protection requires a pull request, refuses force pushes and deletion, and applies to administrators.
- Once `dev`'s protection pins it, `dev` also requires `agent-review` as the reviewer App's check run, which `team-review-check` posts, signed with the App's key `~/.config/agent-team/review-app.pem` (mode 600, restored by `team-secrets`, denied to the workers' and the coordinator's `Read` and Bash), and which `team-merge` requires on the head of every agent-team PR while `bin/lib/review-app` names the App; `team-doctor`'s `review app` line holds the key, the id and the pin together, and `sops/merging.md` says what the App proves and Daniel's steps to set it up.
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

- `tests/run` runs shellcheck (0.11.0) on every shell script in `bin/`, `tests/`, `servers/` and `toolkits/`, then the whole bats suite, then the toolkit tests; `tests/run shellcheck`, `tests/run bats` and `tests/run toolkits` run one part each, as the CI jobs do; `tests/run bats --shard <k>/<n>` runs one shard of the bats files, as CI's `test-shards` and `macos-shards` jobs do, whose `test` and `macos` jobs keep the required ids.
  Its bats files run in parallel, one bats per file and as many at once as `TEAM_JOBS` says when set, else as the team's CPU budget allows when a team home is found (`team-capacity jobs`, 3 at minor on 12 cores), else as there are CPUs (CI, a fresh clone), so every file must stay independent of the others; its last line is the wall time and the most files it ran at once.
  `team-checks` gives the commands it runs `TEAM_JOBS` from `team-capacity jobs` unless it is set.
  `tests/shards` splits them by each file's seconds in CI (`tests/timings.tsv`, a file it lacks weighed by its bytes), so refresh the timings with `tests/shards update` when the shards' times drift apart, and a removed bats file takes its row with it, as `tests/repo.bats` holds.
  Every part but `shellcheck` alone and a shard's `--list` runs under the machine's heavy-run lock (`bin/team-heavy`, which `team-checks` takes for the local checks too), so two suites on one machine queue instead of overlapping, each in a process group (and on Linux a scope) of its own that leaves a cost sample, and the sandbox clears `TEAM_HEAVY_HELD`, `AGENT_TEAM_TASK` and `TEAM_JOBS` so the tests take their own.
- A PR to `dev` is checked on GitHub: `.github/workflows/ci.yml` runs its jobs (`shellcheck`, `test`, `macos`, `toolkits`, `data` and `zizmor`, with the shard jobs `test-shards` and `macos-shards` that `test` and `macos` wait for) on every PR to `dev` and to `main` and by hand (`workflow_dispatch`).
  `dev`'s protection and `projects.toml`'s `required_checks` for `agent-team` require each job by its id, so renaming a job changes a required check, and `team-merge` merges only with every one passed on the PR's exact head.
  `tests/repo.bats` holds the jobs but the shard jobs to the registry fixture's `required_checks`, and each shard job to the job that waits for it, and no workflow runs on a push, a schedule or `pull_request_target`.
  The `zizmor` job audits the workflows offline with zizmor, pinned by version and sha256 as gitleaks is, and fails on any finding; an accepted one is ignored on its own line as `# zizmor: ignore[<audit>] <reason>`, which `tests/repo.bats` holds, with no zizmor config to ignore more.
  `.github/workflows/zizmor-online.yml` runs the same zizmor on the same triggers with the run's read-only token, for its online audits (an impostor commit, a known-vulnerable action, ref confusion); it is never a required check, since it depends on GitHub's API, and `tests/repo.bats` holds its triggers and its zizmor pin to `ci.yml`'s.
  A project that still lists `local_checks` in `projects.toml` has them run through `bin/team-checks`, in a fresh detached worktree of the head: by `team-merge` before it merges, and by builders and reviewers on the head they deliver or review; `agent-team` lists none, so for it `team-checks` says so and passes.
  The Bootstrap workflow (`.github/workflows/bootstrap.yml`) runs only by hand: `team-bootstrap` on a fresh macOS runner and in an Arch container, which installs real tools.
- The toolkit tests are `node --test` files in `tests/toolkits/`, run after `servers/install`: each starts a toolkit's server exactly as its `.mcp.json` declares, with `op` stubbed and a throwaway MongoDB in Docker (for `vercel-read`, a fake of Vercel's API on the loopback instead), and speaks MCP to it over stdio (`tests/toolkits/helpers/` documents the helpers).
  Each test file's header comment says what it checks and against what.
  No test reaches 1Password or production: the test `PATH` refuses to start if a real `op` is on it.
- One file: `tests/vendor/bats-core/bin/bats tests/<name>.bats`; one test: add `-f '<part of its name>'`.
  A toolkit test file: `node --test tests/toolkits/<name>.test.mjs`; one test: add `--test-name-pattern '<part of its name>'`.
- Tests run the real scripts in a sandbox (`load helpers/common`, then `sandbox` in `setup`): `TEAM_HOME` and `HOME` are temporary, `claude`, `gh`, `curl`, `op`, `systemctl`, `launchctl`, `busctl` and `systemd-run` are stubs, and git is real.
  The sandbox's `TEAM_CGROUP_ROOT` holds the cgroup tree and `/proc` that `team-capacity place` and `check` read, empty until a test writes them, so no test moves the machine's processes; `team-capacity sample` reads the machine through its seams, which the sandbox sets to an idle one (`TEAM_MEMINFO` 24 GiB available of 32, `TEAM_READING_PROCS` no process, `TEAM_READING_CPUS` 12) and a test may rewrite or unset.
  The sandbox's `TEAM_SYSTEM_ROOT` puts the library's system tool directories (treehouse's `/usr/local/bin` on Arch) inside it, so a PATH a test trims never gets the machine's own tools back on it.
  The sandbox refuses a TMPDIR under `/home` or `/Users` (a job's own tmp under HOME, say), whose paths the ledger reads as a machine's HOME: run the tests with one outside them, as the default is.
  `tests/helpers/common.bash` documents the helpers.
- macOS assesses each new executable file on its first run, about a quarter of a second each, so a test never writes or copies an executable it could share: `stub_command`, `copy_bin` and the doctor's version stubs hard-link a read-only copy made once per run (`shared` in `tests/helpers/common.bash`).
- No test reads the records of the checkout it runs in, so the suite passes on the code alone: a test that needs a real-shaped registry or secrets manifest copies it from `tests/fixtures/`, and `team-doctor`'s `records` line checks the team home's real ledger, registry and secrets description.
- CI's runner has jq 1.7.1, so keep to jq 1.7 features.
- A jq program that includes a module of `bin/lib` also includes, after it, every module that one includes, directly or not (`include "workers"; include "time"; include "ledger";`), which `tests/repo.bats` holds.
  jq 1.8.2, Homebrew's on the `macos-shards` jobs, loads a module before the ones it includes unless the program loaded them first, and frees the definitions that only another module calls, so a call into one reads freed memory and may fail an assertion ("Unknown function type"); jq fixed it after 1.8.2 (jqlang/jq#3620), and a program's includes load last first.
- Scripts and tests run on Linux and macOS: on macOS `bin/lib/platform.sh` (sourced by the library and the test helpers) puts Homebrew's GNU coreutils, findutils, sed, grep and `flock` first on `PATH`, so GNU forms are fine and BSD-only ones are not.
  CI's `macos-shards` jobs run `tests/run bats` in three shards on macOS runners, and its `macos` job passes only when every shard did, with the rest of CI: on every PR to `dev` and to `main`, and by hand.
- Repo invariants are tests too: every executable in `bin/` answers `--help` with its header, every `bin/team-*` script is named in `roles/coordinator.md`, which stays at most 120 lines, no tracked Markdown or template outside the records (`bin/lib/records`, kept as written) has an em dash, and the Layout above stays a list, one thing per line of at most 300 characters, alphabetical within each list.
- Every PreToolUse hook entry, in `settings/*.json`, `coordinator.settings.json` and a toolkit's `hooks/hooks.json`, sets `"onFailure": "block"` and a whole-number `timeout` from 1 to 120 seconds beside its `command`, which `tests/repo.bats` holds, so a guard hook that fails or hangs blocks the call; `team-doctor`'s `guard hooks` line runs `scratch-only-edits`, `command-guard` and `lease-fence` on a harmless Bash call, since a guard that always fails then blocks every call it sees.

## Script conventions

- Bash 5 (the library refuses older), `set -euo pipefail`, then the library: `source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"`; `bin/lib/team.sh`'s header lists what it provides.
- The header (the comment block under the shebang) is the script's usage and its `--help`, which the library prints; exact commands live there and nowhere else.
- The team home is found as "The team home" says; `TEAM_HOME` is not exported, so pass it to a sibling script explicitly.
- The code checkout is the directory above `bin/` (`~/agent-team`): code (roles, settings, templates, plugins, hooks, toolkits) comes from the script's own checkout, never from the team home.
  In settings files and a toolkit's `.mcp.json`, `@TEAM_CODE@` names the code checkout, `@TASK_DIR@` the team home's `tasks/T<n>/` and `@WORKTREE@` the session's worktree by its real path; `team-worker` fills them in, and `claude-coordinator` fills `@TEAM_CODE@`.
- Exit codes: 0 done, 1 refused or a check failed (`die`), 2 a malformed command line (`usage_error`), 75 try again later.
- The ledger changes only through the library's `ledger_append`, which checks each event against `bin/lib/ledger-contract.json` and that the script is its kind's writer, or one of them, and, under the ledger's lock, a `refusing_writers` script's event against the task's state by `bin/lib/lifecycle.json`; a new kind or field goes in the contract first.
  A kind the contract marks `"push": true` (Daniel's word or an outside fact) is committed and pushed the moment it is logged by the library's `ledger_push`, which each of its writers calls once after its last event, as `tests/repo.bats` holds.
- The registry is read only through `team-project`; a new key goes in its key lists and in its header, which documents every key.
- A script reaches Discord's API only through `discord_api` and GitHub through `gh`, but for the reviewer App's calls, which go through `review_app_api` and `curl`, since `gh` takes a token only from its environment or its login; and it never prints a secret.

## Markdown

- One sentence per line; keep normal Markdown structure.
- The plain dash "-", never the em dash.
- Daniel is "they".
