# SOP: moving the team between machines

The method T6 designed, T7 revised and T17 built (2026-10-23), in short; the research is in `tasks/T6/report.md` and `tasks/T7/report.md`, and nothing here needs it.
Each command's `--help` is its exact reference; `tests/drill.bats` runs a handoff, a stale lease, a crash and an outage end to end through the real commands, two machines against local bare repos.
Setting up a machine is `sops/machine-setup.md`.

## Principles

- Exactly one machine runs the team at a time: the holder of the lease.
  No confirmed lease, no coordinator and no worker.
- Git is the transport and GitHub the meeting point; nothing moves by copying directories between machines.
- Every machine has the same layout under `$HOME`: the code checkout at `~/agent-team`, the team home at `~/agent-team-records`, the path `~/.config/agent-team/home` names (relative to `$HOME`), and each project at its registry path; a path recorded under any home directory (`/home/<name>/...`, `/Users/<name>/...`) means the same path under this machine's `$HOME`.
- Every script finds the team home the same way: `TEAM_HOME` when set (the tests, and a script calling a sibling), else `~/.config/agent-team/home`, else the directory above `bin/`; code (scripts, roles, settings, hooks, templates, plugins, toolkits) always comes from the code checkout.
- Conversations are a cache and never move: a resume rebuilds every session from the ledger, the briefs, the tickets, `handoff.md`, the branch and the archived scratch.
- Secrets never touch git, logs, Discord or transcripts.
- The home PC is the default holder; the laptop takes the team when Daniel travels, and hands it back after.
- No machine is started remotely: `team-resume` runs at the machine Daniel is at.

## What lives where

Two repositories hold the team, each checked out on every machine:

- **The code**, `chanjdaniel/agent-team`, public, at `~/agent-team`: the scripts, roles, settings, hooks, templates, plugins, toolkits and tests, and nothing from the records; changed only through merged PRs to `dev`.
- **The team home**, `chanjdaniel/agent-team-records`, private, at `~/agent-team-records`: the records (the ledger, the registry, `tasks/`, `projects/`, `memory/`, `machine/`, `manual-steps.md`), committed straight to `dev` by the scripts, and the `lease` branch; its origin also holds the work a project's origin must not see (`wip/<project>/T<n>` snapshots and `salvage/` branches), since a project's origin may be public.

| What | Where | Moved by |
| - | - | - |
| Scripts, roles, settings, hooks, templates, plugins, toolkits | the code checkout (`chanjdaniel/agent-team`), `dev` | git, through merged PRs: `team-merge` fast-forwards the code checkout after merging its own project, and `team-resume` on the machine taking over |
| Plans, briefs, the ledger, the registry | the team home (`chanjdaniel/agent-team-records`), `dev` | git |
| The lease | the team home's origin, orphan branch `lease`, one `lease.json` | `team-lease` |
| Each task's scratch (spec, tickets, notes, `handoff.md`) | `tasks/T<n>/scratch/` (`scratch-<project>/` for an added project) | `team-checkpoint`, `team-handoff`; restored by `team-open --resume` |
| Work in flight | each project's origin: the task branch; the team home's origin: `wip/<project>/T<n>` | workers' pushes; `team-checkpoint` |
| Claude user config (instructions, settings, skills, plugins) | `machine/claude/` | `team-config capture` (in a handoff), `team-config apply` (in a resume) |
| Auto memory | `memory/<project>/`, which every worktree of the project uses through `autoMemoryDirectory`, and `memory/coordinator/`, the team home's own once it is no project's primary checkout | `team-checkpoint`, `team-handoff` |
| Tool versions | `bin/lib/tools.lock` | read by `team-doctor` and `team-bootstrap` |
| Which secrets a machine needs (never a value) | `machine/secrets.json`, described in `machine/secrets.md` | read by `team-secrets` |
| Secret values | 1Password, the `agent-team` vault | `team-secrets restore` and `save`, in Daniel's own terminal only |
| This machine's name, its team home's path and its state (lease record, fence, offline flag, logs) | `~/.config/agent-team/machine`, `~/.config/agent-team/home`, `~/.local/state/agent-team/` | never moved |

`machine/`, `memory/`, `tasks/` and the ledger are records, committed straight to `dev` by the scripts.

## The lease

- `lease.json` holds the holder, an epoch, `held` or `released`, when it was taken and renewed, and `stolen_from`.
  The epoch rises by one each time the holder changes, and is the fencing token.
- Every change is a commit on the tip just read, pushed without force: a rejected push means another machine moved it first, so two machines racing end with one holder.
  `git log origin/lease` is its history.
- `team-lease take` takes a released lease; one another machine holds is refused, saying fresh or stale.
  Stale (not renewed for 60 minutes) changes only that message: taking it still needs `take --steal` and the holder's name typed on a terminal, which deny rules keep every team session from doing.
- `claude-coordinator` and `team-worker` (all but the load check's `T0`) refuse unless `team-lease check` confirms against origin that this machine holds it; offline, they refuse too.
- Team sessions run with `isolatePeerMachines`, so a message to a session on another machine asks first.

## The heartbeat

`team-timers enable` installs one job every 5 minutes on the holder (systemd on Arch, launchd on macOS, plus `caffeinate -i` on a Mac) running `team-timers run`: probe GitHub, renew the lease once the last renewal is 15 minutes old, and checkpoint once the last checkpoint is 15 minutes old.
It is enabled only on the holder: `team-resume` enables it, `team-handoff` disables it, and a run on a machine that does not hold the lease changes nothing.

## Checkpoints

`team-checkpoint` makes a dead machine lose at most 15 minutes:

- each open task's task directory is mirrored into its archive in the team home, less what has no place in its history, each named in the checkpoint's output: a directory holding a `.git` (a nested repository), a file over 1 MiB, and a path that may hold a secret, by the snapshot's rule below.
  `team-close` archives the same way, and `team-open --resume` leaves those paths in the worktree as they are;
- each worktree's work is kept on the team home's origin as `wip/<project>/T<n>`, pushed from the worktree to that origin's URL and never to the project's origin, which may be public (Conventioner's is): the branch head, or, with uncommitted changes, a snapshot commit on it built from a temporary index (untracked files included), never touching the worktree's files, index or stash;
- untracked files that may hold a secret are left out of the snapshot, each named in the checkpoint's output: a name starting with `.env` or ending with `.pem` or `.key`, or a path that a target in `machine/secrets.json` ends with.
  A secret has no place in git even in a private repository, and a project's `.gitignore` need not cover every `.env` variant a worker makes; such a file stays only on the machine it was made on;
- `tasks/*/scratch*/`, `memory/` and `ledger.jsonl` are committed as `chore: checkpoint` and pushed.

Nothing new means no commit and no push; `team-close` deletes the task's `wip/<project>/T<n>`, and the copy of it that `team-open --resume` fetched into the primary checkout.

## Fencing

A machine that finds another holder or a higher epoch (its renew, its heartbeat) fences itself: it writes `fenced`, stops its own coordinator and `T<n>-<role>` sessions, and disables its heartbeat.
The `lease-fence` hook blocks the coordinator's Discord replies, and its `git push`, `team-merge`, `team-open` and `team-close`, from the moment a fenced machine wakes, before any heartbeat runs (it checks the remote lease at most once a minute), and blocks workers' pushes.
So a coordinator left running on a machine that lost the lease (its fence's `claude stop` failed, or `team-handoff --retire` never ran) acts on nothing the holder's coordinator owns.
`team-doctor` on a fenced machine lists, per task worktree with work origin lacks, the command that pushes it to the team home's origin as `salvage/<project>/T<n>-<machine>`, for Daniel to run.
Like a snapshot, a salvage never goes to the project's origin, which may be public; `team-open --resume` names the same place for a branch here with commits origin's lacks.
A worktree whose head a salvage branch holds, with nothing uncommitted, is salvaged, and neither a salvage nor a snapshot ever counts as landed for `team-close`.
`team-lease take` (inside `team-resume`) clears the fence.

## Offline

- The probe is `git ls-remote` of the lease branch, 20 seconds at most; a network failure is tried again after 60 seconds, and a second one means offline.
  GitHub refusing the login is not offline: it is posted once and the doctor fails it.
- Offline, the holder keeps the lease and holds the team: the heartbeat posts the hold in `#coordinator` once, the hook blocks workers' pushes and `gh` with the hold message, and no worker starts, no coordinator starts, and no checkpoint, handoff, resume or take runs.
- The coordinator learns of it through its Monitor on `team-timers watch` (or a worker's `T<n> PAUSED offline`), sends `T<n> HOLD` to each live worker, and each commits locally, writes `handoff.md` and answers `T<n> PAUSED held`.
- The first probe that answers renews the lease, clears the flag and posts "GitHub back"; the coordinator sends `T<n> RESUME`.
  If another machine took the lease meanwhile, the renew fences this one instead.

## Moving the team: handoff, then resume

1. At the machine taking the team, Daniel starts `team-resume --wait` (or tells the setup session to run it) before anything else.
   It runs the doctor first, then checks that the team home and the code checkout can fast-forward to origin's (and that the team home holds no commit origin's lacks), so either refuses with nothing changed while the old machine still runs the team; once both pass it prints "this machine is ready: say 'hand off' to the coordinator there now" and waits for the release.
2. Then Daniel says "hand off" to the coordinator on Discord.
   Its `handoff` skill asks whether that `team-resume --wait` is running and has said so, and starts only on Daniel's yes; it checks (`team-handoff --check`), posts what is in flight, sends `T<n> STOW` to each live worker and waits up to 10 minutes for `T<n> PAUSED stowed` (a builder pushes a `wip:` commit and writes `handoff.md`).
3. It runs `team-handoff`: workers stopped and removed, a forced checkpoint, task branches pushed, one `stowed` per open task, `team-config capture`, the records committed as `chore: handoff from <machine>` (all of `tasks/`, `machine/`, `memory/`, the ledger) and pushed, the heartbeat disabled, the lease released.
   The workers stop before the checkpoint, so it holds their worktrees' last state: a worker that never answered STOW leaves its uncommitted changes in `wip/<project>/T<n>`, and its `stowed` marks that worktree `uncommitted`.
   A diverged task branch refuses the handoff before any worker stops.
   An ops session is never carried over: `team-ops-end` ends it, deleting its transcript and answer file (the fence does the same), `ops` is never a role to relaunch, and a production question left unanswered is Daniel's to ask again on the new machine.
   Each step is idempotent: a run interrupted anywhere finishes when run again, and the lease is released last.
4. It posts "Released at 14:05 from home-pc. The `team-resume --wait` started on the other machine takes the team now; with none running there, run `team-resume` there." with what config it captured (and any it left to Daniel: a `settings.json` with an `env` key, or a skill folder holding a dotenv-like file), and `team-handoff --retire` removes the coordinator.
5. The release ends the wait of step 1 (with no `--wait` running, Daniel runs `team-resume` at the other machine, which refuses a fresh lease held elsewhere with nothing changed).
   After the release it pulls the team home and then the code checkout (skipped when it is the team home), applies the config, takes the lease, enables the heartbeat, re-homes each open worktree with `team-open --task T<n> --resume <project>` (from origin's branch and the task's archive, with `wip/<project>/T<n>` applied as uncommitted changes to a worktree its `stowed` marks `uncommitted`), writes `tasks/resume-<date>-<time>.json` (one report per run, never overwritten; each worktree it could not re-home is also a `rehome-failed` in the ledger, which `team-state` shows until the worktree is made) and starts the coordinator.
6. The coordinator's `resume` skill reads the report, catches up on Discord messages sent while no coordinator listened, relaunches each stowed role with a `resume` brief (which says what became of the uncommitted changes), logs `resumed`, and posts what resumed and what did not.
7. Daniel pins the coordinator in `claude agents`.

## A crash

- The surviving machine: Daniel runs `team-resume --steal` in their own terminal and types the dead holder's name.
- A task with a launch after its latest `stowed` crashed: `team-open --resume` resumes it from the later of origin's branch and the head `wip/<project>/T<n>` holds, and applies the snapshot as uncommitted changes only when its parent is that head.
- The resume brief tells each worker the checkpoint it starts from and that up to 15 minutes of work, and any no-mistakes run in flight, may be missing, so it checks before building on it.
- When the dead machine boots, its still-enabled heartbeat finds the new holder and fences it before anyone could start a coordinator there (sessions do not restart on their own after a shutdown); its doctor then lists the salvage commands.

## A real server later

- The server holds the lease for good; the PC and the laptop become clients (Discord, Remote Control, SSH), and the lease and fencing stay for failover and maintenance.
- Headless logins: `claude setup-token`, `gh auth login --with-token`, and secrets from the host's secret store instead of Daniel's terminal.
- Supervision: the coordinator under a systemd service that checks the lease before it starts, since agent view does not restart sessions after a reboot.
- Trust accepted once per root over SSH; the doctor's check is the same.
- Sizing: each worker's treehouse slot has its own `node_modules` and Docker stack, so RAM and disk set the pool caps.
- The code's checks could then run on GitHub again from a self-hosted runner, as `manual-steps.md` keeps as option A.
