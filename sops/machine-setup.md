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
- Three settings are Daniel's call even where you could write them: the team home's `core.hooksPath` (every team session is denied it), `autoMode.environment` (what auto mode's classifier believes about this machine), and a `team-config apply` that replaces a file or skill changed on this machine.
- Every stage is idempotent and skips what the doctor already passes, so re-running is the answer to any interruption.
- GitHub unreachable: stop and say so; carry on from the same stage once it answers.
- The same step failing twice: stop and give Daniel the failing doctor lines (they never hold a secret) and the last lines of `~/.local/state/agent-team/bootstrap.log`.

## 2. Stages

Each stage after the first is one `~/agent-team/bin/team-bootstrap` run; read its lines (each prefixed by its stage) before the next.
`team-bootstrap` with no `--stage` runs every stage in order and stops at the first step that is Daniel's, which is the quickest way to see where a half-set-up machine stands.

| # | Stage | Who | Done when |
| - | - | - | - |
| 1 | git, gh, GitHub login, the team home cloned | agent, Daniel logs in | `SETUP.md` stage 1's checks pass |
| 2 | Preflight and the machine's name | agent, Daniel names it | `machine: named this machine <name>` or `done` |
| 3 | OS packages | agent; Daniel's terminal on Arch | `packages: done` |
| 4 | Tools at their pins | agent; Daniel's terminal for `sudo` | `tools: done` |
| 5 | Projects | agent | `projects: done` |
| 6 | Claude config, plugins and the heartbeat | agent, Daniel restarts the session | `config: done` and `heartbeat: done` |
| 7 | Daniel's steps | Daniel, one at a time | `check` lists no `Daniel <n>:` line |
| 8 | Verification and the summary | agent | `team-doctor` has no FAIL and `team-load-check` passes |
| 9 | Taking the team (only when Daniel says so) | Daniel decides, agent runs | the coordinator runs here and is pinned |

### Stage 1: git, gh and the team home

`SETUP.md`, stage 1: on macOS the Xcode Command Line Tools and Homebrew, then git, gh and Homebrew's Bash 5, the GitHub login (`gh auth login --web`, then `gh auth setup-git`), and the clone of `https://github.com/chanjdaniel/agent-team.git` at `~/agent-team`.

### Stage 2: preflight and the machine's name

1. `~/agent-team/bin/team-bootstrap --stage preflight`: the OS is Arch or macOS, on macOS the Xcode tools and Homebrew are there, and jq, git and Python 3.11 are installed.
   On Arch, missing ones stop it with Daniel's `sudo` command (stage 3 says how to ask).
2. Ask Daniel for the machine's team name (`laptop`, `home-pc`, or a new one in lower-case kebab case; never the hostname), then `~/agent-team/bin/team-bootstrap --name <name> --stage machine`.
   The name goes in `~/.config/agent-team/machine` and is what the lease and the ledger call this machine.

### Stage 3: OS packages

`~/agent-team/bin/team-bootstrap --stage packages`: every failing tool line whose fix is an OS package.

- macOS: `brew install` (no password), plus `brew install --cask docker-desktop`; when Homebrew's GNU tools were missing, the run starts itself again under them.
- Arch: one `pacman -S --needed` for all of them needs `sudo`, so without a terminal the stage stops with `packages: Daniel: in your own terminal run ~/agent-team/bin/team-bootstrap --stage packages, ...`.
  Ask Daniel to paste exactly that command in their own terminal, where `sudo` asks for their password, then run the stage again yourself.

### Stage 4: tools

`~/agent-team/bin/team-bootstrap --stage tools`: everything else `bin/lib/tools.lock` pins for this OS: Claude Code, nvm with Node and the global npm tools, Bun, the treehouse and no-mistakes release archives (each checked against its SHA-256), and on Arch the 1Password CLI.

- On Arch, treehouse and `op` install with `sudo`: the same stop and the same request as stage 3, with `--stage tools`.
- `~/.local/bin` and `~/.no-mistakes/bin` get one `export PATH=...  # team-bootstrap` line each in `~/.zshrc` or `~/.bashrc` (by `$SHELL`); for another shell, ask Daniel to add them.
- A Claude Code newer than its pin is a WARN and is left alone.

### Stage 5: projects

`~/agent-team/bin/team-bootstrap --stage projects`: each project in `projects.toml` cloned from `https://github.com/<repo>.git` to its registry path (treehouse names its pool from that exact origin, so the registry's slots hold here), its task directory added to `.git/info/exclude`, and `no-mistakes init` for a no-mistakes project.

- It needs the GitHub login from stage 1; a missing one stops it, and stage 1's step 4 is the fix.
- A folder already in a project's way is Daniel's: show the doctor's line and ask whether to move it.
- Treehouse pools start cold; the first lease warms a slot.
  Dev data is never copied: a task seeds its own.

### Stage 6: Claude config, plugins and the heartbeat

1. `~/agent-team/bin/team-bootstrap --stage config`: the marketplaces and plugins of `machine/claude/plugins.txt`, then `team-config apply` (the shared `CLAUDE.md`, `AGENTS.md`, `settings.json` and skills copied into `~/.claude`, and each project's auto memory pointed at `~/agent-team/memory/<project>`), then the Discord plugin turned off in user settings.
   When a file or skill already differs here, apply is skipped and listed: show Daniel `~/agent-team/bin/team-config diff --full` and ask which they want.
   On a new machine that is almost always `~/agent-team/bin/team-config apply` (whatever it replaces goes to `~/.claude/backups/`); `team-config capture` instead keeps this machine's version, for a records commit on `dev`.
2. `~/agent-team/bin/team-bootstrap --stage heartbeat`: the heartbeat stays disabled; `team-resume` enables it when this machine takes the lease.
3. When the config changed, ask Daniel to restart the session: exit, run `claude` in `~/agent-team`, and say "set up as host" again.
   The new session starts at `SETUP.md`, whose checks pass, and carries on here at stage 7.

### Stage 7: Daniel's steps

`~/agent-team/bin/team-bootstrap --stage check` runs the doctor and prints Daniel's remaining steps in order, one `check: Daniel <n>: <check>: <fix> (<reason>)` line each.
Take them one at a time, in that order: ask for the first, wait for Daniel's word, run `--stage check` again, and ask for the next.
Section 3 says where each one is done.
Done when `check` lists no `Daniel <n>:` line.

### Stage 8: verification and the summary

1. `~/agent-team/bin/team-doctor`: no FAIL; a WARN is fine when its reason is stated (the lease held by another machine is one).
2. `~/agent-team/bin/team-load-check`: it runs the doctor first, then a throwaway planner that proves isolation, toolkits and the edit hook.
   If it fails on "Workspace not trusted", ask Daniel to run `claude` once in `~/agent-team/.claude/load-check/wt` in their own terminal and accept the trust dialog, then run it again.
3. Give Daniel one summary, here in the conversation: the bootstrap's `summary:` line in plain words, any WARN left, and what comes next.
   On a standby: "This machine is ready as a standby; to move the team here, say 'hand off' to the coordinator on <holder>, then tell me to resume here."

### Stage 9: taking the team (only when Daniel says so)

- Another machine holds the lease: Daniel says "hand off" to the coordinator there (Discord), and you run `~/agent-team/bin/team-resume --wait` here, which waits for the release.
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
| `sudo` stages (Arch: preflight, packages, tools) | 2 to 4 | own terminal: the `team-bootstrap --stage <stage>` it names | password |
| Choosing apply or capture when config differs | 6 | the conversation | whose config wins |
| Restarting the session after the config changed | 6 | exit, `claude` in `~/agent-team` | a session cannot reload itself |
| Claude Code login, if the doctor fails it | 7 | own terminal: `claude auth login --claudeai` (browser) | account login |
| Docker access | 7 | macOS: open Docker Desktop, accept its license; Arch: own terminal, `sudo systemctl enable --now docker.service`, then `sudo usermod -aG docker $USER` and a new login if the doctor then says permission denied | GUI or `sudo` |
| 1Password app: install, sign in, CLI integration (and on Arch, unlock with system authentication) | 7 | macOS: `brew install --cask 1password`; Arch: the native AUR package; then the app's Settings > Developer > Integrate with 1Password CLI | account login, app settings |
| `team-secrets restore` | 7 | own terminal: `~/agent-team/bin/team-secrets restore` | Touch ID or system authentication; values never reach an agent |
| Trust, once per project root (the team home included) | 7 | own terminal: `claude` in the root, accept, `/exit` | interactive dialog |
| Chrome | 7 | macOS: `brew install --cask google-chrome`; Arch: `google-chrome` from the AUR, or `sudo pacman -S --needed chromium` | browser sign-in, `sudo` on Arch |
| The dev guard | 7 | this session: `! git -C ~/agent-team config core.hooksPath bin/hooks/git` | every team session is denied `core.hooksPath` |
| `autoMode.environment` | 7 | Daniel's own edit of `~/.claude/settings.json` (`claude auto-mode defaults` shows the form) | it is what auto mode's classifier trusts about this machine |
| "hand off" on the old machine, or the steal | 9 | Discord; own terminal for `team-resume --steal` | the lease is Daniel's call |
| Pinning the coordinator | 9 | `claude agents`, Ctrl+T | an agent-view keystroke, no CLI |

On a fresh machine, Daniel meets them in this order (recorded from `team-bootstrap` in a scratch `$HOME` with every installer stubbed, 2026-10-23):

- macOS: Command Line Tools dialog, Homebrew, GitHub login, the name, (restart), Docker Desktop's license, the 1Password app, `team-secrets restore`, trust for each project root, Chrome, the dev guard, `autoMode.environment`.
- Arch: git and gh, GitHub login, the name, `team-bootstrap --stage packages` and then `--stage tools` in their terminal, (restart), the Docker daemon (and the `docker` group), the 1Password app, `team-secrets restore`, trust for each project root, Chrome, the dev guard, `autoMode.environment`.

## 4. macOS differences

| Topic | Arch (home PC) | macOS (laptop) |
| - | - | - |
| Package manager | `pacman`, with `sudo` | Homebrew (`/opt/homebrew` on Apple silicon), after the Xcode Command Line Tools; no `sudo` |
| Shell | Bash 5 is `/bin/bash` | `/bin/bash` is 3.2; the scripts refuse it and need Homebrew's `bash` first on `PATH` |
| Userland | GNU | `bin/lib/platform.sh` puts Homebrew's GNU coreutils, findutils, sed, grep and `flock` first on `PATH` for every script, and refuses with the `brew install` line when one is missing |
| Python | the OS's 3.11 or newer | Homebrew's (macOS's own `python3` is too old for `tomllib`) |
| Docker | the daemon, enabled with `sudo`, and the `docker` group | Docker Desktop (`brew install --cask docker-desktop`), opened once to accept its license |
| treehouse | `/usr/local/bin`, with `sudo` | `~/.local/bin` |
| 1Password CLI | 1Password's zip into `/usr/local/bin` with the `onepassword-cli` group, with `sudo` | `brew install 1password-cli` |
| 1Password unlock | system authentication (PolKit); the native AUR app, not Snap or Flatpak | Touch ID |
| rc file the bootstrap writes `PATH` lines to | `~/.bashrc` | `~/.zshrc` |
| Heartbeat | systemd user units `agent-team-heartbeat.{service,timer}` in `~/.config/systemd/user/`, `Persistent=true` | LaunchAgents `agent-team.heartbeat` (missed runs happen on wake) and `agent-team.caffeinate` (`caffeinate -i` while the heartbeat is enabled, so the Mac does not idle-sleep) in `~/Library/LaunchAgents/` |
| Claude Code login | `~/.claude/.credentials.json` | the macOS Keychain |
| Home path | `/home/<user>` | `/Users/<user>`; recorded paths under either are read as the same path under this `$HOME` |
| Filesystem | case-sensitive | APFS, case-insensitive by default; no repo has case-only name clashes today |
| Release archives | `linux-amd64` | `darwin-arm64` or `darwin-amd64` |

## 5. When something fails

- Run `team-bootstrap` again; it resumes where the doctor first fails.
- A FAIL line names its fix; when the fix is Daniel's, ask for it in one request as section 3 says.
- `--dry-run` says what each stage would run, and Daniel's steps, changing nothing.
- The same step failing twice, or GitHub unreachable: the rules in section 1.
