# SOP: set up a machine for the team

From T7's draft (2026-10-21), rebuilt by T17 (2026-10-23) to the commands it built.
It covers Arch Linux (the home PC) and macOS (the laptop); section 4 lists every macOS difference.
Every command it names answers `--help` with its exact usage, which is the reference; this SOP says when to run each.

## 1. What it is for

A new or rebuilt machine ends this SOP as a host: `team-doctor` has no FAIL, `team-load-check` passes, and the machine can take the lease when Daniel wants the team there.
It does not move work in flight; that is `team-handoff` on the machine being left and `team-resume` on this one (`sops/portability.md`).

**Who performs it:** an interactive Claude Code session on the new machine, after Daniel says "set up as host".
That session starts at `SETUP.md`, which does stage 1 and says how to ask Daniel for each of their steps (in the session with `!`, in their own terminal, or in a browser or app), then follows this SOP.
The team itself (coordinator and workers) runs here only after stage 9, because it needs the lease.

**Rules for the agent:**

- Secrets reach this machine only through `team-secrets restore`, which Daniel runs in their own terminal; you check them with `team-secrets check`, which prints ids and verdicts only.
  Leave alone every secret file, credentials file, `~/.claude.json` and `~/.claude/channels/`: never read, print, copy or hash them, and never run `op`.
- The lease is Daniel's: run `team-resume` only when Daniel says the team should run here (stage 9); a steal is Daniel's alone, typed in their own terminal.
- Anything needing `sudo` or an admin password is Daniel's, in their own terminal; the bootstrap stops with the exact command.
- Three settings are Daniel's call even where you could write them: the code checkout's `core.hooksPath` (every team session is denied setting it), `autoMode.environment` (what auto mode's classifier believes about this machine), and a `team-config apply` that replaces a file or skill changed on this machine.
- Every stage is idempotent and skips what the doctor already passes, so re-running is the answer to any interruption.
- GitHub unreachable: stop and say so; carry on from the same stage once it answers.
- The same step failing twice: stop and give Daniel the failing doctor lines (they never hold a secret) and the last lines of `~/.local/state/agent-team/bootstrap.log`.

## 2. Stages

Each stage after the first is one `~/agent-team/bin/team-bootstrap` run; read its lines (each prefixed by its stage) before the next.
`team-bootstrap` with no `--stage` runs every stage in order and stops at the first step that is Daniel's, which is the quickest way to see where a half-set-up machine stands.

| # | Stage | Who | Done when |
| - | - | - | - |
| 1 | git, gh, GitHub login, the code checkout and the team home cloned, the team home's setting written | agent, Daniel logs in | `SETUP.md` stage 1's checks pass |
| 2 | Preflight and the machine's name | agent, Daniel names it | `machine: named this machine <name>` or `done`, and `machine: done: ~/.config/agent-team/home names ~/agent-team-records` |
| 3 | OS packages | agent; Daniel's terminal on Arch | `packages: done` |
| 4 | Tools at their pins | agent; Daniel's terminal for `sudo` | `tools: done` |
| 5 | Projects | agent | `projects: done` |
| 6 | Claude config, plugins and the heartbeat | agent, Daniel restarts the session | `config: done` and `heartbeat: done` |
| 7 | Daniel's steps | Daniel, one at a time | `check` lists no `Daniel <n>:` line |
| 8 | Verification and the summary | agent | `team-doctor` has no FAIL and `team-load-check` passes |
| 9 | Taking the team (only when Daniel says so) | Daniel decides, agent runs | the coordinator runs here and is pinned |

### Stage 1: git, gh and the two checkouts

`SETUP.md`, stage 1: on macOS the Xcode Command Line Tools and Homebrew, then git, gh and Homebrew's Bash 5, the GitHub login (`gh auth login --web`, then `gh auth setup-git`), the clone of the public `https://github.com/chanjdaniel/agent-team.git` at `~/agent-team` (the code checkout), the clone of the private `https://github.com/chanjdaniel/agent-team-records.git` at `~/agent-team-records` (the team home), and `agent-team-records` written to `~/.config/agent-team/home`.

### Stage 2: preflight and the machine's name

1. `~/agent-team/bin/team-bootstrap --stage preflight`: the OS is Arch or macOS, on macOS the Xcode tools and Homebrew are there, and jq, git and Python 3.11 are installed.
   On Arch, missing ones stop it with Daniel's `sudo` command (stage 3 says how to ask).
2. Ask Daniel for the machine's team name (`laptop`, `home-pc`, or a new one in lower-case kebab case; never the hostname), then `~/agent-team/bin/team-bootstrap --name <name> --stage machine`.
   The name goes in `~/.config/agent-team/machine` and is what the lease and the ledger call this machine.
3. The machine stage also reports the team home's setting, which stage 1 wrote: `~/.config/agent-team/home` holds the team home's path, relative to `$HOME` (or absolute), and is how every script, hook and session on this machine finds the team home; like the machine's name it is this machine's own and never moved.
   When it is missing, `~/agent-team/bin/team-bootstrap --home agent-team-records --stage machine` writes it (it can go with `--name` in one run).
   The bootstrap writes it once: a setting that names another checkout is left as it is, and a path with no checkout yet is refused until the clone is there.
   Until it is written, the doctor's `team home` line warns that the team home is the code checkout, which holds no records, and its fix clones `~/agent-team-records` first when it is missing; once the clone is there, stage 7 lists the setting among Daniel's steps.

### Stage 3: OS packages

`~/agent-team/bin/team-bootstrap --stage packages`: every failing tool line whose fix is an OS package.

- macOS: `brew install` (no password), plus `brew install --cask docker-desktop`; when Homebrew's GNU tools were missing, the run starts itself again under them.
- Arch: one `pacman -S --needed` for all of them needs `sudo`, so without a terminal the stage stops with `packages: Daniel: in your own terminal run ~/agent-team/bin/team-bootstrap --stage packages, ...`.
  Ask Daniel to paste exactly that command in their own terminal, where `sudo` asks for their password, then run the stage again yourself.

### Stage 4: tools

`~/agent-team/bin/team-bootstrap --stage tools`: everything else `bin/lib/tools.lock` pins for this OS: Claude Code, nvm with Node and the global npm tools (opencode, the gate's agent, among them), Bun, the treehouse release archive (checked against its SHA-256), no-mistakes built from Daniel's fork at its pinned commit (with stage 3's Go and make), and on Arch the 1Password CLI.
Then it installs the gate's opencode wrapper, `~/.no-mistakes/bin/opencode-gate`, from `bin/lib/opencode-gate`: it gives every opencode the gate starts the gate-only config, on Arch and macOS alike.
Last, `servers/install` puts the pinned MCP servers in `~/agent-team/servers/node_modules/` while the doctor's `servers` line fails: the toolkits' servers, and the `chrome-devtools-mcp` every session's `chrome-devtools-axi` runs.

- On Arch, treehouse and `op` install with `sudo`: the same stop and the same request as stage 3, with `--stage tools`.
- Every team script, the bootstrap included, and every session `team-worker` and `claude-coordinator` start, run with one `PATH` the library builds from `bin/lib/tools.lock`: the directories its tools install into that exist (`~/.local/bin`, nvm's directory of the pinned Node, `~/.bun/bin`, `~/.no-mistakes/bin`, and on macOS Homebrew's `python@3.12/libexec/bin`) go first, right after Homebrew's GNU tools, and on Arch `/usr/local/bin` comes last when `PATH` lacks it.
  So `team-doctor`, `team-load-check`, `team-resume` and the bootstrap's `check` give one verdict, whatever shell called them.
- `~/.local/bin` and `~/.no-mistakes/bin` get one `export PATH=...  # team-bootstrap` line each in `~/.zshrc` or `~/.bashrc` (by `$SHELL`), for Daniel's own shell, when it lacked them; for another shell, ask Daniel to add them.
- A Claude Code newer than its pin is a WARN and is left alone.
- `~/.no-mistakes/config.yaml` comes back with `team-secrets restore`, one of stage 7's steps, and the doctor's `opencode-gate` line fails until it runs the gate on the wrapper: `agent: opencode`, and `agent_path_override` naming the wrapper for `opencode` by this machine's full path (no-mistakes does not expand `~`), where a copy saved on another machine names that machine's.
  With `agent: auto` the gate would run on whichever agent no-mistakes finds first, Claude on a machine without opencode.
  This stage sets the `agent_path_override` key, which holds no credential, keeping the rest of the file byte for byte and its mode, and printing none of it; a missing file it leaves to the restore, and `agent: opencode` to Daniel, as one of stage 7's steps.
  So once Daniel has run the restore, run `~/agent-team/bin/team-bootstrap --stage tools` again before the next `--stage check`: `check` shows the `agent_path_override` failure among the doctor's FAILs with this fix, never as Daniel's step.
  Only a form the edit does not change (a flow mapping over several lines, or a scalar) stops it as Daniel's hand edit.

### Stage 5: projects

`~/agent-team/bin/team-bootstrap --stage projects`: each project in `projects.toml` cloned from `https://github.com/<repo>.git` to its registry path (treehouse names its pool from that exact origin, so the registry's slots hold here), its task directory added to `.git/info/exclude` (and the folder of a git pool's slots inside the checkout, `.claude/worktrees/` for the fork), and `no-mistakes init` for a no-mistakes project.

- It needs the GitHub login from stage 1; a missing one stops it, and stage 1's step 4 is the fix.
- A folder already in a project's way is Daniel's: show the doctor's line and ask whether to move it.
- Treehouse pools start cold; the first lease warms a slot.
  Dev data is never copied: a task seeds its own.
- Another clone of a project with the same folder name and origin (an older checkout elsewhere, say) shares its treehouse pool, and a slot that clone made is leased only to it.
  The doctor's `slots <project>` line names such a slot with how many are left for the team; what to do with the other clone is Daniel's.

### Stage 6: Claude config, plugins and the heartbeat

1. `~/agent-team/bin/team-bootstrap --stage config`: the marketplaces and plugins of `machine/claude/plugins.txt`, then `team-config apply` (the shared `CLAUDE.md`, `AGENTS.md`, `settings.json` and skills copied into `~/.claude`, and each project's auto memory pointed at the team home's `memory/<project>`, `~/agent-team-records/memory/<project>`, the team home's own at `memory/coordinator` once it is no project's primary checkout), then the Discord plugin turned off in user settings.
   When a file or skill already differs here, apply is skipped and listed: show Daniel `~/agent-team/bin/team-config diff --full` and ask which they want.
   On a new machine that is almost always `~/agent-team/bin/team-config apply` (whatever it replaces goes to `~/.claude/backups/`); `team-config capture` instead keeps this machine's version, for a records commit on `dev`.
2. `~/agent-team/bin/team-bootstrap --stage heartbeat`: the heartbeat stays disabled; `team-resume` enables it when this machine takes the lease.
3. When the config changed, ask Daniel to restart the session: exit, run `claude` in `~/agent-team`, and say "set up as host" again.
   The new session starts at `SETUP.md`, whose checks pass, and carries on here at stage 7.

### Stage 7: Daniel's steps

`~/agent-team/bin/team-bootstrap --stage check` runs the doctor and prints Daniel's remaining steps in order, one `check: Daniel <n>: <check>: <fix> (<reason>)` line each.
Take them one at a time, in that order: ask for the first, wait for Daniel's word, run `--stage check` again, and ask for the next.
After `team-secrets restore`, run `~/agent-team/bin/team-bootstrap --stage tools` before `--stage check`, so the restored `~/.no-mistakes/config.yaml` names this machine's gate wrapper (stage 4).
Section 3 says where each one is done.
When two or more roots are untrusted, `check` lists them as one step, `trust: in your own terminal run ~/agent-team/bin/team-bootstrap --stage trust`: that stage refuses unless it runs in a terminal, says which root is next, starts `claude` there for Daniel to accept its trust dialog and type `/exit`, probes that root again, and goes on to the next, saying any root still untrusted and exiting 1 if one is left.
Done when `check` lists no `Daniel <n>:` line.

### Stage 8: verification and the summary

1. `~/agent-team/bin/team-doctor`: no FAIL; a WARN is fine when its reason is stated (the lease held by another machine is one).
2. `~/agent-team/bin/team-load-check`: it runs the doctor first, then proves each treehouse project's pool, then runs a throwaway planner that proves isolation, toolkits and the edit hook.
   For each treehouse project it leases one slot through the project's lease command, checks the slot is clean after the pre-warm exactly as `team-open` would, and returns it, so a pre-warm that dirties a slot (as the laptop's did on 2026-10-24) fails here, before any handoff, with the project and the changed paths named.
   A cold slot's pre-warm can take minutes; run it in the background and wait for it to end.
   A `WARN lease <project>: no free slot` is fine on a busy machine: every slot is leased, and the line names the holders.
   The planner runs in `~/agent-team/.claude/worktrees/load-check`, a worktree of the code checkout made fresh for the run and removed at its end, so the code checkout's trust covers it and it needs no trust step of its own.
3. Give Daniel one summary, here in the conversation: the bootstrap's `summary:` line in plain words, any WARN left, and what comes next.
   On a standby: "This machine is ready as a standby; to move the team here, tell me to resume here: I start `team-resume --wait`, and once it says this machine is ready, you say 'hand off' to the coordinator on <holder>."

### Stage 9: taking the team (only when Daniel says so)

- Another machine holds the lease: first run `~/agent-team/bin/team-resume --wait` here, in the background; only then does Daniel say "hand off" to the coordinator there (Discord).
  It runs the doctor and checks that the team home and the code checkout can fast-forward before it waits, so it is the preflight: a FAIL or a refused checkout stops it with nothing changed while the old machine still runs the team, and you fix it and start it again.
  When it prints "this machine is ready: say 'hand off' to the coordinator there now", tell Daniel so; it then waits for the release and takes the team.
- No machine holds it: `~/agent-team/bin/team-resume`.
- The holder is dead or unreachable: Daniel runs `~/agent-team/bin/team-resume --steal` in their own terminal and types the holder's name.
- `team-resume` ends by starting the coordinator; ask Daniel to pin it in `claude agents` (Ctrl+T).
- Done when the coordinator posts on Discord from this machine.

## 3. What only Daniel does

| Step | Stage | Where | Why only Daniel |
| - | - | - | - |
| Xcode Command Line Tools (macOS) | 1 | the dialog `xcode-select --install` opens | GUI dialog |
| Homebrew (macOS) | 1 | own terminal | admin password |
| git and gh (Arch) | 1 | own terminal: `sudo pacman -S --needed git github-cli` | `sudo` |
| GitHub login | 1 | browser, with the code the agent relays | account login |
| The machine's name | 2 | the conversation | Daniel's naming |
| The team home's setting, when stage 7 lists it (stage 1 writes it, so only when that was skipped) | 7 | the conversation: Daniel says the team home is cloned at `~/agent-team-records`, then the agent runs `team-bootstrap --home agent-team-records` | where the records live is Daniel's layout |
| `sudo` stages (Arch: preflight, packages, tools) | 2 to 4 | own terminal: the `team-bootstrap --stage <stage>` it names | password |
| Choosing apply or capture when config differs | 6 | the conversation | whose config wins |
| Restarting the session after the config changed | 6 | exit, `claude` in `~/agent-team` | a session cannot reload itself |
| Claude Code login, if the doctor fails it | 7 | own terminal: `claude auth login --claudeai` (browser) | account login |
| Docker access | 7 | macOS: open Docker Desktop, accept its license; Arch: own terminal, `sudo systemctl enable --now docker.service`, then `sudo usermod -aG docker $USER` and a new login if the doctor then says permission denied | GUI or `sudo` |
| 1Password app: install, sign in, CLI integration (and on Arch, unlock with system authentication) | 7 | macOS: `brew install --cask 1password`; Arch: the native AUR package; then the app's Settings > Developer > Integrate with 1Password CLI | account login, app settings |
| `team-secrets restore` | 7 | own terminal: `~/agent-team/bin/team-secrets restore`; it fetches a secret that is missing, empty or off its mode (a file off its mode may be another machine's old copy, so it is replaced, the old one kept beside it as `<file>.bak-<date and time>`, mode 600) | Touch ID or system authentication; values never reach an agent |
| `~/.no-mistakes/config.yaml` running the gate on opencode, when restore did not bring it in | 7 | Daniel's own edit: `agent: opencode` (the tools stage sets `agent_path_override`'s `opencode` to the wrapper) | it is Daniel's own config file |
| Trust, once in the team home (`~/agent-team-records`, where the coordinator starts: the doctor's `trust team home` line) and once per project root (its `trust <project>` line) | 7 | own terminal: `~/agent-team/bin/team-bootstrap --stage trust`, which starts `claude` in each untrusted root in turn (accept, `/exit`); for a single root, `claude` there | interactive dialog |
| Chrome | 7 | macOS: `brew install --cask google-chrome`; Arch: `google-chrome` from the AUR, or `sudo pacman -S --needed chromium` | browser sign-in, `sudo` on Arch |
| The dev guard | 7 | this session: `! git -C ~/agent-team config core.hooksPath bin/hooks/git` | every team session is denied setting `core.hooksPath` |
| `autoMode.environment` | 7 | Daniel's own edit of `~/.claude/settings.json` (`claude auto-mode defaults` shows the form) | it is what auto mode's classifier trusts about this machine |
| "hand off" on the old machine, or the steal | 9 | Discord; own terminal for `team-resume --steal` | the lease is Daniel's call |
| Pinning the coordinator | 9 | `claude agents`, Ctrl+T | an agent-view keystroke, no CLI |

On a fresh machine, Daniel meets them in this order (recorded from `team-bootstrap` in a scratch `$HOME` with every installer stubbed, 2026-10-23):

- macOS: Command Line Tools dialog, Homebrew, GitHub login, the name, (restart), Docker Desktop's license, the 1Password app, `team-secrets restore`, trust for the team home and each project root (one `--stage trust` in their terminal), Chrome, the dev guard, `autoMode.environment`.
- Arch: git and gh, GitHub login, the name, `team-bootstrap --stage packages` and then `--stage tools` in their terminal, (restart), the Docker daemon (and the `docker` group), the 1Password app, `team-secrets restore`, trust for the team home and each project root (one `--stage trust` in their terminal), Chrome, the dev guard, `autoMode.environment`.

## 4. macOS differences

| Topic | Arch (home PC) | macOS (laptop) |
| - | - | - |
| Package manager | `pacman`, with `sudo` | Homebrew (`/opt/homebrew` on Apple silicon), after the Xcode Command Line Tools; no `sudo` |
| Shell | Bash 5 is `/bin/bash` | `/bin/bash` is 3.2; the scripts refuse it and need Homebrew's `bash` first on `PATH` |
| Userland | GNU | `bin/lib/platform.sh` puts Homebrew's GNU coreutils, findutils, sed, grep and `flock` first on `PATH` for every script, and refuses with the `brew install` line when one is missing |
| Python | the OS's 3.11 or newer | Homebrew's `python@3.12`, which the lock pins (macOS's own `python3` is too old for `tomllib`); its `python3` is only in the formula's `libexec/bin`, which the library puts first on every script's `PATH`, and the doctor's `tool python` line names the `python3` it found |
| Docker | the daemon, enabled with `sudo`, and the `docker` group | Docker Desktop (`brew install --cask docker-desktop`), opened once to accept its license |
| treehouse | `/usr/local/bin`, with `sudo` | `~/.local/bin` |
| 1Password CLI | 1Password's zip into `/usr/local/bin` with the `onepassword-cli` group, with `sudo` | `brew install 1password-cli` |
| 1Password unlock | system authentication (PolKit); the native AUR app, not Snap or Flatpak | Touch ID |
| rc file the bootstrap writes `PATH` lines to | `~/.bashrc` | `~/.zshrc` |
| Heartbeat | systemd user units `agent-team-heartbeat.{service,timer}` in `~/.config/systemd/user/`, `Persistent=true` | LaunchAgents `agent-team.heartbeat` (missed runs happen on wake) and `agent-team.caffeinate` (`caffeinate -i` while the heartbeat is enabled, so the Mac does not idle-sleep) in `~/Library/LaunchAgents/` |
| Claude Code login | `~/.claude/.credentials.json` | the macOS Keychain |
| Home path | `/home/<user>` | `/Users/<user>`; recorded paths under either are read as the same path under this `$HOME` |
| Filesystem | case-sensitive | APFS, case-insensitive by default; no repo has case-only name clashes today, and path case no longer matters for the registry: the scripts compare checkout paths by file identity, so `Documents/projects` in `projects.toml` names `~/Documents/Projects` |
| Release archives | `linux-amd64` | `darwin-arm64` or `darwin-amd64` |
| The gate's environment | the no-mistakes daemon is a systemd user unit; `~/.no-mistakes/bin/opencode-gate` sets opencode's environment, so the unit needs no drop-in | a LaunchAgent that no-mistakes rewrites on each start, keeping only `HOME`, `PATH` and proxy variables; the same wrapper sets opencode's environment |

## 5. When something fails

- Run `team-bootstrap` again; it resumes where the doctor first fails.
- A FAIL line names its fix; when the fix is Daniel's, ask for it in one request as section 3 says.
- `--dry-run` says what each stage would run, and Daniel's steps, changing nothing.
- The same step failing twice, or GitHub unreachable: the rules in section 1.
