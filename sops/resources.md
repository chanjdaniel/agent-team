# SOP: the team's resources

Built by T175 (2026-11-01), toward Daniel's resource levels: full, minor and none, each a share of the machine.
`team-capacity --help` and `team-level --help` are the exact reference for their commands and the settings, `~/.config/agent-team/capacity.json`; this SOP says why the team's work is held and measured as it is and what to do when it is not.

## Levels and modes

The team runs at one of three levels, each a share of the machine: full (`full_share`, 90%), minor (`minor_share`, 30%) and none (0%).
The coordinator runs outside the share, at every level.
The mode is manual, which holds the level until Daniel changes it, or automatic, where the heartbeat picks the level from what Daniel's programs use ("Automatic mode" below).

The record is the team home's `level.jsonl`, one line per change: `{ts, mode, level, by, machine}`, with `discord_message` when the change came from Daniel's message in `#coordinator`, and an automatic pick's `reason` and `reading`.
The current mode and level are the last line's; with no line the team is manual full, as it was before levels.
It is a record, committed by `team-checkpoint` and by the handoff's records commit, so Daniel's level holds across restarts and handoffs; the ledger is not used, since every ledger line needs a task.

`team-level full|minor|none [--message <id>]` records manual mode at that level, `team-level manual` manual mode at the current one, and `team-level auto [--message <id>]` automatic mode at the level it picks now; a change to the mode and level the team is already at records nothing and says so, and so does `auto` while the team is already automatic.
Each applies the limits at once and prints the acknowledgement the coordinator posts: "Resources: manual, minor (30%): 9.2 GiB and 3.6 cores for the team; 6.1 GiB reserved."
`team-level` alone says the mode, the level, the budget and what bounds it, the team's use and the last change; `team-level apply` applies the recorded level's limits again, after a reboot or a reset slice.
A change, `apply` and `tick` refuse on a machine that does not hold the lease; `status` only reads.

## Automatic mode

With `team-level auto`, the heartbeat's `level` step, `team-level tick`, runs after its `capacity` step and picks the level from the stored readings; it takes no reading itself.

The pick of a reading, with `T` the memory total, `C` the cores, and `O_m` and `O_c` what the other programs use: `f` is the lower of `(T - O_m - reserve_gib) / T` and `(C - O_c - reserve_cores) / C`, memory's alone when the reading has no CPU.
The pick is full when `f` is at least `auto_full_free`, none when it is below `auto_none_below`, and minor between.

With the current level `L`:

- A drop needs one reading: when the newest reading picks below `L`, the level drops to that pick at once.
- A rise needs `rise_minutes` of headroom: the last change is at least `rise_minutes` old, a reading at least `rise_minutes` old exists, and it and every reading after it pick above `L`; the level then rises to the lowest of their picks.
  So one spike never raises it, nor one reading after the heartbeat was off.
- With no reading of the last 15 minutes nothing changes, and the step says so in the heartbeat log.

Each change is a `level.jsonl` line `{ts, mode: "auto", level, by: "auto", machine, reason, reading}`, the reading being the one it rests on (the newest for a drop, the newest of the lowest pick for a rise, kept as `{at, total, others_memory, cpus, others_cores, free, pick}`), and one line in `#coordinator`, such as "Resources: auto lowered the team to minor (30%) at 14:05: other programs use 18.2 GiB of 30.6 GiB and 7.9 of 12 cores".
A post Discord refuses fails the step, logged in the heartbeat log, and is kept in `~/.local/state/agent-team/level/posted.json` until a later run posts it, once.
In both modes the step then applies the level's limits again, so the `MemoryHigh` held at the slice's use comes down as the use falls, and a reboot or a reset slice is held again within five minutes.

An example day on home-pc (30.6 GiB, 12 cores, the default settings, a reading every five minutes):

| Time | Other programs use | `f` | Pick | Level |
| - | - | - | - | - |
| 09:00 | 9.8 GiB, 2 cores | 0.55 | full | full |
| 14:05 | 18.2 GiB, 7.9 cores | 0.26 | minor | minor, at once |
| 14:30 | 24 GiB, 6 cores | 0.08 | none | none, at once |
| 14:35 on | 18 GiB, 6 cores | 0.28 | minor | none until 14:50, then minor: the 14:35 reading is then 15 minutes old, and it and every one since pick minor |
| 17:00 on | 9.8 GiB, 2 cores | 0.55 | full | minor until 17:15, then full |

## The settings

`~/.config/agent-team/capacity.json` is the machine's own, beside `stack.json`, never moved between machines; every key is optional, and a file that is not one JSON object, a key of the wrong kind or an unknown key is refused, naming each problem.

| Key | Default | What it sets |
| - | - | - |
| `full_share` | 0.9 | full's share of memory and CPU |
| `minor_share` | 0.3 | minor's share |
| `reserve_gib` | 4 | memory kept free beyond the other programs' current use, for their growth |
| `reserve_cores` | 1 | cores kept free beyond their current use |
| `auto_full_free` | 0.5 | automatic mode picks full while the other programs leave at least this fraction of memory and of CPU free |
| `auto_none_below` | 0.15 | automatic mode picks none while they leave less than this fraction of either |
| `rise_minutes` | 15 | how long every reading must allow a higher level before automatic mode rises |
| `session_gib` | 0.5 | a session's seed cost, until learned |
| `heavy_gib` | 5 | a heavy run's seed cost, until learned |
| `gate_gib` | 2.2 | a gate run's seed cost, until learned |
| `min_cores` | 1 | the slice's CPU quota floor, and the containers', so workers can still stow at none |
| `min_gib` | 2 | the slice's `MemoryHigh` floor, for the same reason |

The evidence for the defaults is the plan's deep dive of 2026-11-01: 13 sessions at 0.3 to 0.55 GiB each; a Conventioner stack 0.6 GiB in use against 2.8 GiB of limits; one heavy run 4 to 6 GiB; a gate about 2.2 GiB (T19's measure); and Daniel's programs about 9.8 GiB of 30.6 GiB, which leaves `(30.6 - 9.8 - 4) / 30.6`, 0.55, so full is what a normal day allows.
`min_gib` is the coordinator's call of 2026-11-01, the memory twin of `min_cores`.

## The budget

With `T` the memory total, `C` the cores, `s` the level's share (0 for none), and `O_m` and `O_c` what the other programs use (Daniel's own, the coordinator and the claude daemon's spare sessions among them):

- the memory budget is `max(0, min(s * T, T - O_m - reserve_gib))`, from the newest reading;
- the CPU budget is `max(0, min(s * C, C - O_c - reserve_cores))`, from the newest reading with CPU, or `s * C` when none has.

So none's budget is 0, and no level's is more than what Daniel's programs leave.
A command that needs the budget takes a reading first when the newest is more than 10 minutes old.
What the team's live work reserves is, for each live team session, running team or gate stack and running gate, the larger of its kind's estimate (below) and its use.

Memory is read as RAM alone, as the kernel's `MemAvailable` and each cgroup's `memory.current` count it: swap is left out of the budget, the use and the limits (home-pc has a 33.6 GiB swap partition, much of it in use).
A page the slice's limits push to swap frees RAM for Daniel's programs, which is the budget's point, so the slice's swap is not limited.

## The limits

On Linux `team-level` sets the slice's limits with `systemctl --user set-property --runtime agent-team.slice`, so they need no root and are gone after a reboot, until the heartbeat's `level` step (every 5 minutes) or `team-level apply` sets them again:

- `CPUQuota` is `max(B_c, min_cores) * 100%`, so the kernel holds the team's CPU at once, whatever a worker runs.
- `MemoryHigh` is the largest of `min_gib`, the memory budget less the reservations of the team's stacks (which run outside the slice), and, while the slice uses more than that, the lower of its use and its `MemoryHigh` before. So a drop never throttles live sessions into reclaim: the slice is held where it is, and comes down as finished sessions stop and tasks stow.
- `MemoryMax` is the larger of `MemoryHigh` and the slice's use, plus 1 GiB, so a drop never kills a worker.

Rootful Docker keeps its containers outside every user slice, so their CPU is held by `docker update --cpus <max(B_c, min_cores)>` on every running container labelled `io.github.chanjdaniel.team.owner=agent-team`, with each apply; `team-stack up` gives a stack it starts the `--cpus` of the last apply (`~/.local/state/agent-team/level/applied.json`), so one started between two applies is held too.
A slice that is not installed is said with its fix, `team-capacity install` (Daniel's yes), and the containers are still held.
On macOS only the containers' CPU is held.

## The team's slice

On Linux every worker session, heavy run and gate run sits in one systemd user slice, `agent-team.slice`, so the kernel can measure and limit the team's work as one, apart from Daniel's own programs.
Each task's work is in a slice of its own inside it, `agent-team-T<n>.slice`, so each task's memory and CPU are measured apart.
systemd nests a slice under every dash prefix of its name, so `agent-team-T175.slice` sits in `agent.slice/agent-team.slice/`, and a new slice name must keep that rule in mind.

`team-capacity install` writes `~/.config/systemd/user/agent-team.slice` and, for each gate daemon unit no-mistakes wrote there (`no-mistakes-daemon-<hash>.service`), a drop-in `agent-team.conf` holding `Slice=agent-team.slice`, then reloads the user manager.
It is Daniel's yes, as `team-timers enable` is.
The drop-in is a file of its own in the unit's `.d` directory, never an edit of the unit no-mistakes writes.
The gate's daemon moves into the slice only when it restarts: `install` restarts a running one with `no-mistakes daemon restart`, never `--force`, which refuses while a pipeline runs, and then says to run `install` again once no gate runs.

Docker's containers are not in the slice: rootful Docker keeps them in its own cgroups (its driver is `systemd`, cgroup v2), so a stack's memory is held by its own `mem_limit`s.
The coordinator and Daniel's own sessions are never in the slice.

## Placement

A worker session is the claude daemon's child (the daemon, then the session's `bg-pty-host`, then the session), never `team-worker`'s, so it cannot be started inside the slice.
Instead `team-capacity place` adopts each live session named `T<n>-<role>` after it starts, but a load check's `T0-<role>`, which is no task's work: the session's process, its `bg-pty-host` parent and every descendant move into the transient scope `agent-team-T<n>-<id>.scope` in its task's slice, through the user manager's `StartTransientUnit` (`busctl --user call org.freedesktop.systemd1 ...`).
A descendant the team's slice already holds stays where it is, a session already in its scope is left, and a call that fails is tried once more with a fresh tree, since a process may end between the read and the call.
`team-worker` runs `place` for its new session right after the launch; a session it cannot place is a warning, and the launch stands.
Once all of a scope's processes end, systemd removes the scope.

The assumptions, checked on home-pc on 2026-11-01 (T175 build note `01-cgroups.md`): the user manager's cgroup delegates `cpu`, `memory` and `pids`; systemd is 262, so `MemoryPeak` is there; Docker's cgroup driver is `systemd` on cgroup v2; the claude daemon was started from a Konsole tab, and every session it starts sits in that tab's scope under `user@1000.service`; and Daniel's own run of the probe moved such a process into `agent-team-probe.scope`.
Workers' permissions do not allow the `busctl` call by hand: the tests use a stub, and a live check of placement is Daniel's or the coordinator's.

## Readings

The heartbeat's `capacity` step runs `team-capacity sample` on the lease holder every run, every 5 minutes, then `team-capacity place --quiet`, which places again any live team session outside its slice (one the claude daemon restarted, say).
Each reading goes to `~/.local/state/agent-team/capacity/readings.jsonl`, kept for 24 hours.
Its machine's part is the reading `team-slots sample` takes, by the same code (`bin/lib/reading.sh`), against a CPU snapshot of its own, so the two never differ: the memory, what the other programs use, and the team's processes, found by their working directory and their descent.
On top of it, each reading says each task's use:

- On Linux, a task's memory is its slice's `MemoryCurrent`, plus its team processes outside the team's slice, plus its running team stacks (their `task` label), since Docker's containers are outside every user slice.
- Its CPU is its slice's `CPUUsageNSec` since the newest stored reading, plus its processes outside the slice since the snapshot, plus its stacks' share of a core.
- Elsewhere, or for a task with no slice, it is every process that is the task's: one whose working directory is the task's held worktree or below it, or that descends from one.
- Each live team session's use is its scope's on Linux (`MemoryCurrent`, `MemoryPeak`, `CPUUsageNSec`), else its process tree's, but the heavy run that holds the lock (the `team-heavy` its holder line names, and what it runs), whose cost is its own `heavy:<kind>`, so a builder's samples never carry its test runs.
- The gate runs a pipeline while a process works in one of its worktrees, `~/.no-mistakes/worktrees/...`; its use is its daemon unit's on Linux, else the processes in `~/.no-mistakes` and their descendants.

`team-capacity status` says the newest reading, taking one first when the newest is over 10 minutes old.
A user manager or a session list that does not answer is said in the reading (`"systemd": false`, `"sessions": false`), and the reading still goes in.
`team-doctor`'s `resources` line warns on the lease holder when the newest reading is over 15 minutes old.

## Learned costs

So that admission can rest on what work costs on this machine, each reading also keeps what it saw running in `capacity/live.json`, and each item that ended adds one line to `capacity/costs.jsonl`: `{at, kind, peak_bytes, cpu_seconds, seconds}`.

| Kind | Ends when | Its peak |
| - | - | - |
| `session:<role>` | the session list no longer has the session | the highest `MemoryPeak` its scope had (its tree's memory elsewhere) |
| `stack:<project>` | Docker no longer runs the stack | the highest memory the readings saw it use |
| `gate` | no gate pipeline runs | the highest memory its daemon used while one ran |
| `heavy:<kind>` | `team-heavy run` ends | its scope's `MemoryPeak` (its process group's memory, sampled every 10 seconds, elsewhere) |

A session list or a Docker that did not answer ends nothing, so a hiccup never writes a false sample.
The readings are 5 minutes apart, so a peak is what they saw, and a session or a run shorter than that may never be seen; a session's `MemoryPeak` is the kernel's own, so it is exact.
A stack's kind needs its registered project, read from the held worktree its `worktree` label names, so a gate's stack has none and writes no sample.

A heavy run measures itself: `team-heavy run` runs its command in a process group of its own and, on Linux, in a transient scope `agent-team-heavy-<pid>.scope` in its task's slice (`AGENT_TEAM_TASK`'s, else `agent-team.slice`), and writes its line when the command ends.
Its kind is `heavy:tests-run` for `tests/run`, `heavy:checks:<project>` for `team-checks`, else the label's first word, its file name when it is a path, so a script's kind is one from every checkout and no path goes in `costs.jsonl`.
When systemd's user manager does not answer, the run says so once and goes in its process group alone, measured as on macOS.
A run that was stopped, or that ended before its first sample, writes nothing, since its peak would understate the kind's.
`team-heavy stop [--task T<n>]` ends a run's whole tree (its scope on Linux, its process group's TERM then KILL after 10 seconds), so a worker blocked in a test returns to read its STOW.
It never reaches a Docker container the run started, which rootful Docker keeps outside the scope and the process group, and the stopped test's own cleanup never runs: a team stack goes with its task's stack, by `team-stack`, and any other container stays: a stopped `tests/run toolkits` leaves its throwaway MongoDB (`toolkit-test-<hex>`, labelled `agent-team-test=toolkits`) running, which `team-janitor`'s report lists as not the team's and only a hand removal (`docker rm --force --volumes <name>`) takes.

`team-capacity costs` gives each kind's estimate: from 5 samples, the 90th percentile of the last 20 peaks plus 10%; before that, the seed.
The seeds are `capacity.json`'s `session_gib` (0.5), `heavy_gib` (5) and `gate_gib` (2.2), and for a stack the sum of its services' `mem_limit`s as the readings last saw it running (`team-stack ls --json`'s `memory_limit_bytes`).
The seeds' evidence: 13 sessions at 0.3 to 0.55 GiB each, one heavy run 4 to 6 GiB and a gate about 2.2 GiB (T19's measure), from the plan's deep dive of 2026-11-01.

## What the doctor says

`team-doctor`'s `resources` line reads `team-capacity check --json`.
Its reason starts with the level's words, as `team-level` acknowledges a change.
It fails when the user's systemd does not answer or its cgroup does not delegate `cpu` and `memory`, which only Daniel can change (a `user@.service` drop-in, with sudo), since the level's limits need the slice; `team-resume` and `team-load-check`, which stop on any FAIL, stop there too.
It fails on a `capacity.json` or a `level.jsonl` line that is malformed, naming it.
It warns when the slice or a gate daemon's drop-in is not installed (`team-capacity install`, Daniel's yes), when the gate's daemon still runs outside the slice (its restart waits on a pipeline), when a live team session runs outside its task's slice (`team-capacity place`, or the heartbeat's next run), and on the lease holder when no reading is under 15 minutes old (the `capacity` step's lines in the heartbeat log say why).
On Linux with the slice installed it warns, naming `team-level apply`, when the limits last applied are missing or another mode and level's than the record's, or the slice's CPU quota is not theirs, as after a reboot.
macOS has no cgroups: `install` and `place` change nothing there, and the line passes with "no hard limits on macOS: admission and stow only".
