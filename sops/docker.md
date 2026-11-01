# SOP: Docker stacks

How the team runs the Docker stacks of a project's worktrees, and how it tells its own Docker objects from everyone else's.
`team-stack` is the one way an agent starts, reaches, stops and removes a stack; `~/agent-team/bin/team-stack --help` is its exact reference.
The code checkout's `bin/` is not on a worker's `PATH`, so an agent runs it by that path.
A project's stacks are the team's to manage only when the registry gives it a `stack` block (`team-project --help` documents its keys).

## The labels contract

Every Docker object the team makes says whose it is, in labels under `io.github.chanjdaniel.team.`:

| Key | Value | Set by |
| - | - | - |
| `owner` | `agent-team`, or empty: not the team's | `team-stack`; a gate run (Conventioner's `nm-test.sh`) only when `TEAM_TASK` is in its environment |
| `task` | `T<n>`, or empty | `team-stack`, from the ledger; a gate run passes `TEAM_TASK` through |
| `kind` | `dev`, `e2e` or `gate` | `team-stack` (`dev`, or `e2e` for an extra instance); a gate run always `gate` |
| `worktree` | the worktree's absolute path | `team-stack`; a gate run its repository root |
| `expires` | ISO 8601 UTC time after which the reaper may remove the stack, or empty | a gate run: its start plus 2 hours; `team-stack` leaves it empty |

- The labels are on every container, named volume and network of a stack, and fixed for the object's life: a named volume keeps the labels it was created with even when a later `up` passes others.
  So a stack of another task is removed before a new task's starts, never relabelled.
- Compose hashes labels into its config, so a call with other label values recreates containers and networks and can leave the stack half stopped: every call for an existing stack passes the labels read back from its containers, never recomputed ones.
- Images carry no ownership labels: the shared images are known by repository name, the `stack` block's `images`.
- Anonymous volumes carry no Compose labels, only Docker's own `com.docker.volume.anonymous`.
  Each Conventioner stack makes two: the frontend's `/app/node_modules` (about 210 MB) and MongoDB's `/data/configdb` (empty).

## The owner classes

`team-stack ls` sorts every object into one class, from its own labels and its Compose project (Docker's `com.docker.compose.project` label):

- **gate**: `kind=gate`, whatever its `owner` (a gate run from a shell with `team-stack env`'s exports is labelled `owner=agent-team` too); or, with no team label set to a value, a Compose project whose name matches a project's `legacy_gate` (gate runs from before the labels).
- **team**: `owner=agent-team`, and not `kind=gate`.
- **unowned**: everything else, Daniel's primary stack and stacks started by hand included.
  A slot stack started with `th-compose.sh up` and no `TEAM_*` variables has every team label empty, so it is unowned.
- **anonymous**: an anonymous volume no container mounts; one a container mounts takes that container's class.
- Images: **team** when the repository is in a project's `images`, **legacy** when it matches a `legacy_images` pattern, else **unowned**.

Only team objects are ever started, stopped or removed by `team-stack`; gate objects are the gate's own and the reaper's backstop; unowned ones are listed, never touched.

## The wrapper contract

The project's compose wrapper, the `stack` block's `compose`, is the one seam on the project's side: `team-stack` never computes a project name, a port or a label value the wrapper owns, and reads them back from the wrapper or from Docker.
Conventioner's `scripts/th-compose.sh` meets it, and `tests/fixtures/stack/compose.sh` is the smallest wrapper that does.
The wrapper:

- is run as `<worktree>/<compose> <compose arguments>` with `TH_DIR=<worktree>`, from the worktree, and resolves the worktree's own stack (Conventioner: the treehouse slot's project `conventioner-<slot>` and its fixed ports), unless the caller sets `COMPOSE_PROJECT_NAME` with `TH_PORTS=auto`, which names another project whose ports Docker assigns;
- passes every other argument to `docker compose` with its files, so `config --format json`, `up -d --wait`, `logs`, `stop` and `down` work through it;
- answers `ports` with `export COMPOSE_PROJECT_NAME=...` and one `export TH_<SERVICE>_PORT=...` line per running service, and exits 1 when the stack is not running;
- turns the environment variables `TEAM_OWNER`, `TEAM_TASK`, `TEAM_KIND`, `TEAM_WORKTREE` and `TEAM_EXPIRES` into the labels of every service, named volume and network, each empty when its variable is unset;
- creates each bind mount's host directory before `up` and runs every service that writes into a bind mount as the calling user, since Docker creates a missing source directory as root and a service running as root writes root-owned files into the worktree, which no session can remove without `sudo` (T3's `node_modules`, T21's and T24's gate worktrees).

A caller clears its own stack identity (`COMPOSE_PROJECT_NAME`, `TH_PORTS` and every `TH_*_PORT`) before calling the wrapper and sets only what it means, so a shell that once exported another stack's never redirects a call.

## Running a worktree's stack

An agent starts, reaches, stops and removes its stack with `~/agent-team/bin/team-stack`, never with `docker compose up`, the wrapper's `up` or `docker run`.

- `~/agent-team/bin/team-stack up` starts the worktree's stack once the machine has room for it ("Admission"), labelled with its task, and seeds a new database.
- `eval "$(~/agent-team/bin/team-stack env)"` exports what reaches it: `COMPOSE_PROJECT_NAME`, a `TH_<SERVICE>_PORT` per service (the wrapper's `ports`) and the stack's five `TEAM_*` labels, so the seed, Playwright, `mongosh` and a hand-run wrapper call reach the same stack without changing its labels.
- `~/agent-team/bin/team-stack seed` runs the project's seed command again, from the worktree, with those exports.
- `~/agent-team/bin/team-stack stop` stops its containers and keeps its data; the next `up` starts them again and does not seed.
- `~/agent-team/bin/team-stack down` saves its logs and removes it, leaving no container, volume (named or anonymous) or network of it.

Each acts on the worktree it is run in (or `--worktree <path>`), resolved the same way:

- **The worktree** must be a linked worktree: in a primary checkout, whose stack is Daniel's primary stack, every subcommand refuses.
- **The project** is the registered one whose primary checkout the worktree belongs to, and it must have a `stack` block.
- **The stack** is the one the wrapper resolves for the worktree, named by its `config --format json`: the containers, volumes and networks Docker labels with that Compose project.
  A stack with any object that is not of class team is refused by every subcommand, naming its class: removing it is Daniel's or the coordinator's call.
- **The task**, for `up` only, is the open task whose ledger worktree (opened or added, not returned) is this one, however either is spelled; `--task T<n>` names one when the ledger gives the worktree to none, and must agree with it when it does.

Every stack starts fresh for its task:

- A team stack of another task in the worktree's slot is taken down first, exactly as `down` does, its logs saved as `stack-logs/<old task>-<project>-<service>.log`, so the new task gets an empty database and volumes carrying its own labels.
- A new stack gets `TEAM_OWNER=agent-team`, its task, `TEAM_KIND=dev`, the worktree's path and an empty `TEAM_EXPIRES`; an existing one of the same task is always called with the labels read back from its containers.
- The seed runs only when the stack is new and none of its named volumes was there before, and not with `up --no-seed`.

`down` saves the last 1 MiB of each `log_services` service's log to `<worktree>/<task_dir>/stack-logs/<project>-<service>.log`, for the builder while the task is open.
`team-close`'s archive leaves `stack-logs/` out (`archive_left_out` in `bin/lib/team.sh`), so the logs never reach the records and go when the worktree is returned.
It then runs `docker compose -p <project> down -v --remove-orphans`, removes any anonymous volume the stack's containers mounted that is still there, and fails naming each object of the stack left.
With no stack, `stop` and `down` say so and exit 0; `env` and `seed` refuse.

Exit codes: 0 done, 1 refused or failed (with the reason), 2 a malformed command line, 75 try again later (no room for the stack, see "Admission").

## Instances: more stacks of one worktree

An instance is an extra stack of the worktree, with its own database and ports, for end-to-end runs in parallel (Playwright shards) or a browser-driving agent that must not share the worktree's stack.

- `~/agent-team/bin/team-stack up --instance <name>` starts the Compose project `<stack>-<name>` (`conventioner-3-shard1` in slot 3), with `TEAM_KIND=e2e`, the worktree's task, and ports Docker assigns on `127.0.0.1` (`TH_PORTS=auto` with that `COMPOSE_PROJECT_NAME`); it is admitted against the cap like any stack, each instance counting as one, and seeded as any new stack is.
- `env`, `seed`, `stop` and `down` take `--instance <name>` too, and every wrapper call for an instance passes its project and `TH_PORTS=auto`.
  `env --instance` also exports `TH_PORTS=auto`, so a hand-run wrapper call after its `eval` reaches the instance with the ports it started with, never the slot's fixed ones (which would recreate its containers).
- `down` without `--instance` takes down the worktree's instances first (team stacks whose project is `<stack>-<anything>` and whose `worktree` label is the worktree), then its own stack, so `team-close` removes them with it.
- A name is `[a-z0-9][a-z0-9_-]*`, Compose's rule for a project name; any other is exit 2.

N shards against N instances, each shard in a subshell of its own so its exports reach only its run, and each with its own output directories, which Playwright would otherwise clear and overwrite under the other shard:

```bash
team_stack=~/agent-team/bin/team-stack n=2 status=0
for i in $(seq "$n"); do "$team_stack" up --instance "shard$i" || exit; done
pids=()
for i in $(seq "$n"); do
  (eval "$("$team_stack" env --instance "shard$i")" && cd front-end &&
    PLAYWRIGHT_HTML_OUTPUT_DIR="playwright-report/shard$i" npx playwright test --shard="$i/$n" --output="test-results/shard$i") &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
for i in $(seq "$n"); do "$team_stack" down --instance "shard$i"; done
exit "$status"
```

On `up`'s exit 75, `down --instance` the ones already up and send `T<n> PAUSED <its reason line>`, as for any stack.
A browser-driving agent gets its own the same way: `~/agent-team/bin/team-stack up --instance browser`, then `eval "$(~/agent-team/bin/team-stack env --instance browser)"`, open `http://127.0.0.1:$TH_FRONTEND_PORT` (`127.0.0.1`, not `localhost`: on macOS another process's IPv6 listener can hold the same port), and `~/agent-team/bin/team-stack down --instance browser` when done.

## Admission

`team-stack up` starts a stack that is not running only when the machine has room for it, so the stacks of every task, gate and person never together outgrow the PC.

- It holds an exclusive lock, `~/.local/state/agent-team/stacks.lock`, from its first check until the wrapper's `up -d --wait` returns, so two racing `up` calls at the cap start exactly one stack.
- A stack already running is admitted without a check; a stopped one is counted as new.
- When `team-capacity` is on `PATH` or at `~/.local/bin/team-capacity`, `team-capacity admit --kind stack:<registered project>` decides: 0 admits, 75 refuses with its stderr as the reason, anything else fails `up`, but 2, a command line it does not know.
  With no `team-capacity`, or one with no `admit` yet (until T175's ticket 06), `team-stack`'s own three checks decide, and all three must hold:
  - **cap**: fewer Compose projects running on the machine (`docker compose ls`, every owner's: gates, Daniel's primary stack and hand-made stacks count too) than `stack_cap`;
  - **memory**: the memory available, less the sum of the stack's `mem_limit`s (a Conventioner stack is about 2.75 GiB), at least the floor: `memory_floor_gib` GiB when it is set, else the default for what is measured (6 GiB of `MemAvailable` from `/proc/meminfo` on Linux, half of Docker's VM on macOS, below);
  - **disk**: the free space of the file system holding Docker's root (`docker info`'s `DockerRootDir`, measured with `df`) at least `disk_floor_gb` GB.
- With no room, `up` says once on stderr that it waits and why, re-checks every 30 seconds (letting go of the lock between checks) up to `wait_minutes`, and then exits 75 naming every failing check with its numbers, for example `team-stack: no room for conventioner-1: 6 of 6 stacks running (stack_cap 6); 4.1 GiB available after this stack's 2.8 GiB (floor 6 GiB, the Linux default)`.
  The memory check names the floor it used and where it came from: `memory_floor_gib in stack.json`, `the Linux default`, or `the macOS default: half of Docker's VM's 7.7 GiB`.
  An agent that gets 75 reports `PAUSED` with that line rather than fighting for room.
- Gate runs never call `team-stack`, so they are counted and never held back; their own turn-taking is Conventioner's end-to-end lock.
- Each wait that ends, admitted or not, a refusal with `wait_minutes` 0 included, adds one line to `~/.local/state/agent-team/stacks/waits.jsonl`: `{start, end, project, task, admitted, reasons}`, the reasons being the last refusal's; the janitor reads it.

The machine's settings live in `~/.config/agent-team/stack.json`, a JSON object whose keys are all optional:

| Key | Default | What it sets |
| - | - | - |
| `stack_cap` | 6 | the most Compose projects running at once, a whole number of 1 or more |
| `memory_floor_gib` | unset: 6 on Linux, half of Docker's VM on macOS | the GiB of memory left free after a new stack's limits |
| `disk_floor_gb` | 30 | the GB left free on Docker's file system |
| `wait_minutes` | 15 | how long `up` waits for room; 0 does not wait |
| `idle_minutes` | 30 | how long a team stack may go without a busy session before the sweep stops it |
| `heartbeat_sweep` | false | whether the heartbeat runs the sweep |
| `heartbeat_janitor` | false | whether the heartbeat runs the janitor |

A file that is not one JSON object, a key of the wrong type or an unknown key is refused with the reason (exit 1), so a typo never silently keeps a default.

On macOS, Docker runs in Docker Desktop's VM, so the readings differ: the memory is `docker info`'s `MemTotal` (the VM's) less what the running containers use (`docker stats`), and the disk is the file system holding the home directory, where Docker Desktop keeps its disk image (`~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`, on the same file system on Daniel's laptop, 2026-10-25).
The default floor there is half of the VM's `MemTotal`, not 6 GiB: the VM holds nothing but Docker, so there is no host load to keep room for, and what is measured is the running containers' use, not their limits, so the floor is the room they may still grow into.
Half admits a Conventioner stack's 2.75 GiB on a 7.7 GiB VM (Daniel's laptop's) with nothing running (5.0 GiB left over a 3.9 GiB floor), and further stacks while the running ones use little (about 330 MiB each when idle), where 6 GiB admitted none (T45, 2026-10-25).
`team-doctor`'s `stack memory` line warns when, with nothing else running, the floor leaves room for no stack of a registered project, from the VM's `MemTotal` on macOS and the host's on Linux.

## Stopping idle stacks

`team-stack sweep` stops the team stacks nobody is using, so a crashed or finished worker's stack does not hold memory for hours.
The heartbeat runs it once Daniel turns `heartbeat_sweep` on ("The heartbeat's steps"); anyone may run it by hand.

- It looks only at running team stacks: every container of the Compose project of class team, so gate and unowned stacks, and a project whose containers mix them with team ones, are never stopped; only containers count, so a team project holding an unowned volume is stopped, which keeps every object.
- A stack is busy while a live session (`claude agents --json`, interactive sessions included) with `status` `busy` has its `cwd` in the stack's `worktree` label or below it: the `cwd` or one of its parents names the same directory as the label, however either is spelled (a symlink, or another case on a case-insensitive filesystem), so a sibling path sharing the prefix (`shop-1-2` for `shop-1`) is not inside it.
- For a busy stack it writes the time to `~/.local/state/agent-team/stacks/<project>.json` as `last_busy`, since the session list keeps no last-activity time.
- A stack that is not busy is idle since its `last_busy` or its running containers' latest start, whichever is later, so one never seen busy counts from its start and one started again after its last busy time counts from that start; a missing or unreadable state file is never seen busy.
- Idle for more than `idle_minutes` ("Admission" has the settings), it is stopped with `docker compose -p <project> stop`, its data kept, and one line is printed and added to `~/.local/state/agent-team/stacks/sweep.log`, for example `2026-10-25T10:00:00Z stopped conventioner-2 of T7 in /home/daniel/.treehouse/Conventioner-d4c77a/2/Conventioner: last busy at 2026-10-25T09:20:00Z (idle_minutes 30), its data kept`.
  `~/agent-team/bin/team-stack up` starts it again with its data, without seeding.
- Docker not answering means no stack runs: it says so on stderr and exits 0, so the heartbeat logs nothing for it; a session list that cannot be read exits 1 and stops nothing; a stop that fails is named on stderr, the other stacks are still swept, and it exits 1.
- `down` removes the stack's state file with the stack.
- Instances (`--instance`) are team stacks labelled with their worktree, so they are swept the same way.

## Removing what is left behind

`team-stack reap` removes the Docker objects the team's work leaves behind, by the rules below and nothing else.
The janitor runs it daily with `--apply` ("The daily report and its alerts") once Daniel turns `heartbeat_janitor` on; anyone may run its dry run by hand at any time, since it only reads.

| What | Rule | Action |
| - | - | - |
| team stack: a Compose project all of whose containers, volumes and networks are of class team | its tasks are all closed in the ledger, or its worktrees are all gone | logs saved, then removed as `down` removes it |
| gate stack: one all of whose objects are of class gate | past its `expires`, or, with no `expires`, its newest object created more than 2 hours ago | `docker compose -p <project> down -v --remove-orphans`, then its anonymous volumes as `down` removes them; no logs |
| shared image (a repository in a project's `images`) | no container uses it, created more than 7 days ago, and not among the 2 newest of its repository | `docker image rm <repository>:<tag>` |
| legacy image (matching `legacy_images`) | `--legacy` only, and no container uses it | `docker image rm <repository>:<tag>` |
| dangling image | no container uses it, created more than 24 hours ago | `docker image rm <id>` |
| unattached anonymous volume | no container mounts it, created more than 24 hours ago | `docker volume rm` |
| team-labelled named volume or network | no container uses it, and it is no part of a stack removed above | `docker volume rm`, `docker network rm` |
| everything else | never | listed as kept, with its size and age |

- It never runs `docker system prune`, `docker volume prune`, `docker image prune`, `docker network prune`, `docker builder prune` or `docker container prune`: every removal names its object, so this table is the whole of what it can do, and a test checks that `bin/team-stack` holds none of them.
- "No container uses it" counts containers in every state: a stopped container is on no network's list of containers, but its own settings still name its networks, and Docker would remove such a network under it.
- A team stack's logs, the last 1 MiB of each service's, go to its worktree's task directory as `stack-logs/<task>-<project>-<service>.log` for the project's `log_services` while the worktree is still a project's linked worktree, and otherwise to `~/.local/state/agent-team/stacks/logs/<project>-<local date>/`, for every service it has, since no `stack` block can be found for a worktree that is gone.
- A gate run's stack is past `expires` only 2 hours after its start, longer than any gate run takes (its end-to-end lock waits at most 45 minutes), so the reaper never races a live run.
- Without `--apply` (or with `--dry-run`, the default) it only reads, and prints `would remove <type> <name> (<class>, <size>): <why the rule matches>` for each action.
  With `--apply` it holds the admission lock (`~/.local/state/agent-team/stacks.lock`) while it reads and removes, so no `up` starts a stack under it, and prints `removed ...` for each removal, a team stack's line ending with where its logs went, or `already gone ...` for an object that went before its turn.
- Then it prints `kept <type> <name> (<class>, <size>, <age> old)` for every object no rule matched that is not the team's (stacks, containers of no stack, volumes, images, and networks but Docker's own `bridge`, `host` and `none`), Daniel's primary stack and its volumes always among them, and one summary line with the totals by rule.
  A stack's size is its volumes'; a network has none, and a container of no stack shows none, since Docker gives a container's size only to a slower `docker ps --size`.
- A tagged image is removed by `<repository>:<tag>`, a dangling one by its id, and a network by its id, since Docker lets two networks share a name; the 2 newest of a repository are its 2 newest images, every tag of either kept.
- A removal that fails is named on stderr with Docker's reason, the others still happen, and it exits 1; Docker not answering is exit 1 too.
- Before a stack's removal it reads the stack again and removes it only when every object is still of the class the rule matched.

## The daily report and its alerts

`~/agent-team/bin/team-janitor` runs `team-stack reap --apply`, then writes the day's report, `~/.local/state/agent-team/janitor/<local date>.md`, and prints it as one paragraph, alerts first.
The heartbeat runs it once a day once Daniel turns `heartbeat_janitor` on ("The heartbeat's steps"); `team-janitor --dry-run` previews a run at any time.

- The report's sections, in order: Alerts; Disk, the free and used space on the file system Docker keeps its data on (`docker info`'s `DockerRootDir`, and on macOS the home directory, where Docker Desktop keeps its disk image), as admission reads it; Docker's totals, `docker system df`'s by type; Stacks, every Compose project left after the reap, running or stopped, with its class, task, kind, age and memory; Removed, each removal with its size and rule, the ones that failed, and the reaper's summary; and Kept as not the team's, with size and age.
- A second run on the same day replaces the day's report.
- The alerts, by kind:

  | Kind | When |
  | - | - |
  | `disk` | under 15% or under 50 GB free on that file system |
  | `oom` | a container killed for memory in the last 24 hours (`docker events --filter event=oom`) |
  | `waits` | admission waits (`stacks/waits.jsonl`) adding up to more than an hour in the last 24 hours, each counted for its part inside them |
  | `removal` | a removal the reaper could not make |

- Each kind is posted to `#coordinator` at most once a local day, for example `Docker on home-pc: disk: 40.0 GB free of 1.0 TB (3.9%) on the file system of /var/lib/docker, under 15% or 50 GB. The day's report: ~/.local/state/agent-team/janitor/2026-10-25.md`, and remembered in `janitor/posted-<local date>.json`; the report says beside each alert whether it was posted, already posted that day, or why its post failed.
- A post that fails is also on stderr, is tried again on the next run, and changes no exit code: the run exits 1 only when the reaper or a removal failed, a part of the report could not be read, or the report could not be written.
  The heartbeat's next run of the janitor is the next day's, since the day's report is written, so a failed post waits for that day or for a run by hand.
- An `oom` alert of `not checked: ...` (`docker events` failed) stays in the report and is never posted, and the run exits 1.
- Docker not answering is the report's one line and the summary's, nothing is posted, and it exits 1.
- `--dry-run` runs the reaper's dry run, writes `<local date>-dry-run.md` (never the day's real report) with "Would remove" for "Removed", and posts nothing.
- It writes no ledger event: every ledger line needs a task, and the report belongs to none.

## The heartbeat's steps

The heartbeat (`team-timers run`, every 5 minutes on the lease holder) can run the sweep and the janitor, each only once Daniel turns it on; both ship off, so nothing new runs on a machine until then.

| Step | Key in `~/.config/agent-team/stack.json` | What it runs | When |
| - | - | - | - |
| `stacks` | `heartbeat_sweep` | `team-stack sweep` | every run, before the checkpoint |
| `janitor` | `heartbeat_janitor` | `team-janitor` | after the checkpoint, while no report of today's local date is there yet (a dry run's is none) |

- To turn a step on, Daniel sets its key to `true` in `stack.json`, keeping any other key there, for example `{"heartbeat_sweep": true}`; turning the sweep on first and the janitor a day later lets each be checked on its own.
  The next run picks it up: there is nothing to restart.
- To turn it off, they set the key to `false` or remove it; a missing file is every key off.
- Both run only where the checkpoint runs: on the lease holder, after the lease step (or the back step, after an outage), never on a fenced machine, while GitHub is unreachable, on a machine that does not hold the lease, or while another run holds the heartbeat's lock.
- Each logs one line in `~/.local/state/agent-team/heartbeat.log` per line its command prints, and nothing while it is off.
  A step that fails, or whose `stack.json` is malformed, is logged as `<step>: failed: <reason>`; the steps after it still run, and the run exits 1.
  A checkpoint that fails ends the run before the janitor, which then runs on the next one.
- A hung Docker never holds the heartbeat's lock past the lease's renewals: the sweep is stopped after 5 minutes and the janitor after 20, each with every command it started, and logged as `<step>: failed: timed out after <seconds> s`.
  A janitor stopped so wrote no report, so the next run starts it again, and its reaper goes on where the last one stopped.
  The `slots` and `capacity` steps, which run every run before them and are no setting's, each give `team-stack ls --json` 30 seconds for their reading of the machine's load (`team-slots sample`, `team-capacity sample`), then take the reading without Docker; each of their commands is stopped after 60 seconds.
  The `level` step after them, no setting's either, runs `team-level tick`, which holds every running team container to the level's CPU with `docker update --cpus` (`sops/resources.md`), and is stopped after 60 seconds.
  While Docker stays hung a run takes up to 28 minutes, so the lease is still renewed well inside its hour, and a checkpoint comes about every 28 minutes instead of every 15.
- A janitor run that fails (Docker not answering, a removal that failed) still writes the day's report, so the heartbeat runs it again only the next day; `~/agent-team/bin/team-janitor` by hand runs it again at once.
- The job runs with the `PATH` that `team-timers enable` captured, and both steps need `docker` on it (the sweep `claude` too): on macOS Docker Desktop's `docker` is in `/usr/local/bin`.
  When Docker was installed after the heartbeat was enabled, or `docker` was not on the `PATH` of the shell that enabled it, run `team-timers enable` again, with Daniel's yes as every enable needs, from a shell where `command -v docker` answers; it rewrites the job with that `PATH`.
  Until then the sweep finds no Docker to sweep and logs nothing, and the janitor fails.

## Closing a task

`team-close` takes the stacks of a task down before it archives the task's directories, so a closed task leaves nothing running.

- For each worktree it is about to return whose project has a `stack` block, it runs `team-stack down --worktree <path>`, which saves the logs into the worktree's task directory; the archive leaves them out.
- A worktree kept with `--keep-worktree` keeps its stack, and a project without a `stack` block is never asked of Docker.
- A teardown that fails stops the close with `team-stack`'s reason, the task half closed: fix the cause and run `team-close T<n>` again.
- A project's own return command may tear its stack down as a second line (Conventioner's `th-return.sh` does).

## Rules for agents

Builders, planners and reviewers carry these rules in a short `## Docker stacks` section of their role:

- Start the worktree's stack only with `~/agent-team/bin/team-stack up`, never `docker compose up`, the wrapper's `up` or `docker run`, and reach it with `eval "$(~/agent-team/bin/team-stack env)"`.
- On `up`'s exit 75, send `T<n> PAUSED <its reason line>` and wait, rather than fighting for room.
- `~/agent-team/bin/team-stack stop` a stack no longer needed, and `~/agent-team/bin/team-stack down` it when done.
- Never prune, and never remove another task's or project's containers, volumes or networks; never test against Daniel's primary stack.

Every worker's settings (`settings/worker.json`) deny Docker's prune commands, `docker <object> prune` for `system`, `volume`, `image`, `network`, `builder`, `container` and `buildx`, each in three spellings: `docker <object> prune*`, `docker * <object> prune*` (global options first) and `*/docker <object> prune*` (by path).
These are a speed bump, as every deny rule is; the guarantee is that no script the team runs prunes.

## Seeing what Docker holds

- `~/agent-team/bin/team-stack ls` lists every Compose project with its status, class, task, kind, worktree, age and memory.
- `~/agent-team/bin/team-stack ls --all` adds the volumes, images and networks, grouped by class with their totals; `--json` gives every object with its class.
- It only reads, so it is safe at any time, a gate run's end-to-end phase included.

## Testing

- The bats tests never reach the machine's Docker: `tests/helpers/docker.bash` installs a stub `docker` that answers from fixtures recorded on this machine (`tests/fixtures/docker/`) and logs every call.
- The stub also models the fixture project's stack (`tests/fixtures/stack/`), so `up`, `env`, `seed`, `stop` and `down` are tested through the wrapper contract rather than Conventioner.
- The stub also stands in for the machine's memory and disk: `TEAM_MEMINFO` names a file read in place of `/proc/meminfo`, a stub `df` answers from the test's numbers, and `TEAM_STACK_RECHECK_SECONDS` shortens the 30 seconds between admission checks.
- The sweep's tests stub `claude agents --json` (the sandbox's `claude` stub) with sessions in and around the worktree.
- The reaper's tests age the stub's objects with `docker_created` and refuse one removal with `docker_refuse`, and every test of `tests/team-stack.bats` and `tests/team-janitor.bats` fails when a Docker call it made pruned.
- The janitor's tests add `oom` events with `docker_event`, set the free disk through the stub `df`, and stub Discord's answers to its posts (the sandbox's `curl` stub).
- `tests/team-stack-live.bats` runs against the real Docker only with `TEAM_LIVE_DOCKER=1`, since a test that creates a network can break a gate run's end to end; it starts and removes the fixture's one-service stack under a project name of its own, races two `up` calls for the last place under `stack_cap`, has the sweep stop an idle stack that `up` then brings back with its data, runs the worktree's stack and two instances at once on ports of their own, and has `reap --apply` remove a closed task's stack and an expired gate stack and keep an unowned one, limited by the test seam `TEAM_STACK_REAP_PROJECTS` to its own projects, so it never reaps the machine.
