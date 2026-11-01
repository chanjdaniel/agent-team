# SOP: the team's resources

Built by T175 (2026-11-01), toward Daniel's resource levels: full, minor and none, each a share of the machine.
`team-capacity --help` is the exact reference for its commands and its settings, `~/.config/agent-team/capacity.json`; this SOP says why the team's work is held and measured as it is and what to do when it is not.
No limit is set on the team's slice yet: it holds and measures the team's work, and the levels' limits come later.

## The team's slice

On Linux every worker session, heavy run and gate run sits in one systemd user slice, `agent-team.slice`, so the kernel can measure and later limit the team's work as one, apart from Daniel's own programs.
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
Instead `team-capacity place` adopts each live session named `T<n>-<role>` after it starts: the session's process, its `bg-pty-host` parent and every descendant move into the transient scope `agent-team-T<n>-<id>.scope` in its task's slice, through the user manager's `StartTransientUnit` (`busctl --user call org.freedesktop.systemd1 ...`).
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
- Each live team session's use is its scope's on Linux (`MemoryCurrent`, `MemoryPeak`, `CPUUsageNSec`), else its process tree's.
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
Its kind is `heavy:tests-run` for `tests/run`, `heavy:checks:<project>` for `team-checks`, else the label's first word.
When systemd's user manager does not answer, the run says so once and goes in its process group alone, measured as on macOS.
A run that was stopped, or that ended before its first sample, writes nothing, since its peak would understate the kind's.
`team-heavy stop [--task T<n>]` ends a run's whole tree (its scope on Linux, its process group's TERM then KILL after 10 seconds), so a worker blocked in a test returns to read its STOW.

`team-capacity costs` gives each kind's estimate: from 5 samples, the 90th percentile of the last 20 peaks plus 10%; before that, the seed.
The seeds are `capacity.json`'s `session_gib` (0.5), `heavy_gib` (5) and `gate_gib` (2.2), and for a stack the sum of its services' `mem_limit`s as the readings last saw it running (`team-stack ls --json`'s `memory_limit_bytes`).
The seeds' evidence: 13 sessions at 0.3 to 0.55 GiB each, one heavy run 4 to 6 GiB and a gate about 2.2 GiB (T19's measure), from the plan's deep dive of 2026-11-01.

## What the doctor says

`team-doctor`'s `resources` line reads `team-capacity check --json`.
It fails when the user's systemd does not answer or its cgroup does not delegate `cpu` and `memory`, which only Daniel can change (a `user@.service` drop-in, with sudo).
It warns when the slice or a gate daemon's drop-in is not installed (`team-capacity install`, Daniel's yes), when the gate's daemon still runs outside the slice (its restart waits on a pipeline), when a live team session runs outside its task's slice (`team-capacity place`, or the heartbeat's next run), and on the lease holder when no reading is under 15 minutes old (the `capacity` step's lines in the heartbeat log say why).
macOS has no cgroups: `install` and `place` change nothing there, and the line passes with "no hard limits on macOS: admission and stow only".
