# SOP: the team's resources

Built by T175 (2026-11-01), toward Daniel's resource levels: full, minor and none, each a share of the machine.
`team-capacity --help` is the exact reference for its commands; this SOP says why the team's work is held as it is and what to do when it is not.
No limit is set on the team's slice yet: it holds and measures the team's work, and the levels' limits come later.

## The team's slice

On Linux every worker session and gate run sits in one systemd user slice, `agent-team.slice`, so the kernel can measure and later limit the team's work as one, apart from Daniel's own programs.
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

## What the doctor says

`team-doctor`'s `resources` line reads `team-capacity check --json`.
It fails when the user's systemd does not answer or its cgroup does not delegate `cpu` and `memory`, which only Daniel can change (a `user@.service` drop-in, with sudo).
It warns when the slice or a gate daemon's drop-in is not installed (`team-capacity install`, Daniel's yes), when the gate's daemon still runs outside the slice (its restart waits on a pipeline), and when a live team session runs outside its task's slice (`team-capacity place`).
macOS has no cgroups: `install` and `place` change nothing there, and the line passes with "no hard limits on macOS: admission and stow only".
