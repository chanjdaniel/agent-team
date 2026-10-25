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
- turns the environment variables `TEAM_OWNER`, `TEAM_TASK`, `TEAM_KIND`, `TEAM_WORKTREE` and `TEAM_EXPIRES` into the labels of every service, named volume and network, each empty when its variable is unset.

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
- **The task**, for `up` only, is the open task whose ledger worktree (opened or added, not returned) is this one, compared by real path; `--task T<n>` names one when the ledger gives the worktree to none, and must agree with it when it does.

Every stack starts fresh for its task:

- A team stack of another task in the worktree's slot is taken down first, exactly as `down` does, its logs saved as `stack-logs/<old task>-<project>-<service>.log`, so the new task gets an empty database and volumes carrying its own labels.
- A new stack gets `TEAM_OWNER=agent-team`, its task, `TEAM_KIND=dev`, the worktree's path and an empty `TEAM_EXPIRES`; an existing one of the same task is always called with the labels read back from its containers.
- The seed runs only when the stack is new and none of its named volumes was there before, and not with `up --no-seed`.

`down` saves the last 1 MiB of each `log_services` service's log to `<worktree>/<task_dir>/stack-logs/<project>-<service>.log`, so `team-close`'s archive keeps it.
It then runs `docker compose -p <project> down -v --remove-orphans`, removes any anonymous volume the stack's containers mounted that is still there, and fails naming each object of the stack left.
With no stack, `stop` and `down` say so and exit 0; `env` and `seed` refuse.

Exit codes: 0 done, 1 refused or failed (with the reason), 2 a malformed command line, 75 try again later (no room for the stack, see "Admission").

## Admission

`team-stack up` starts a stack that is not running only when the machine has room for it, so the stacks of every task, gate and person never together outgrow the PC.

- It holds an exclusive lock, `~/.local/state/agent-team/stacks.lock`, from its first check until the wrapper's `up -d --wait` returns, so two racing `up` calls at the cap start exactly one stack.
- A stack already running is admitted without a check; a stopped one is counted as new.
- When `team-capacity` is on `PATH` or at `~/.local/bin/team-capacity`, `team-capacity admit --kind stack:<registered project>` decides: 0 admits, 75 refuses with its stderr as the reason, anything else fails `up`.
  Until that controller exists (T19's design), `team-stack`'s own three checks decide, and all three must hold:
  - **cap**: fewer Compose projects running on the machine (`docker compose ls`, every owner's: gates, Daniel's primary stack and hand-made stacks count too) than `stack_cap`;
  - **memory**: the memory available, less the sum of the stack's `mem_limit`s (a Conventioner stack is about 2.75 GiB), at least `memory_floor_gib` GiB; on Linux `MemAvailable` from `/proc/meminfo`;
  - **disk**: the free space of the file system holding Docker's root (`docker info`'s `DockerRootDir`, measured with `df`) at least `disk_floor_gb` GB.
- With no room, `up` says once on stderr that it waits and why, re-checks every 30 seconds (letting go of the lock between checks) up to `wait_minutes`, and then exits 75 naming every failing check with its numbers, for example `team-stack: no room for conventioner-1: 6 of 6 stacks running (stack_cap 6); 4.1 GiB available after this stack's 2.8 GiB (memory_floor_gib 6)`.
  An agent that gets 75 reports `PAUSED` with that line rather than fighting for room.
- Gate runs never call `team-stack`, so they are counted and never held back; their own turn-taking is Conventioner's end-to-end lock.
- Each wait that ends, admitted or not, a refusal with `wait_minutes` 0 included, adds one line to `~/.local/state/agent-team/stacks/waits.jsonl`: `{start, end, project, task, admitted, reasons}`, the reasons being the last refusal's; the janitor reads it.

The machine's settings live in `~/.config/agent-team/stack.json`, a JSON object whose keys are all optional:

| Key | Default | What it sets |
| - | - | - |
| `stack_cap` | 6 | the most Compose projects running at once, a whole number of 1 or more |
| `memory_floor_gib` | 6 | the GiB of memory left free after a new stack's limits |
| `disk_floor_gb` | 30 | the GB left free on Docker's file system |
| `wait_minutes` | 15 | how long `up` waits for room; 0 does not wait |
| `idle_minutes` | 30 | how long a team stack may go without a busy session before the sweep stops it |
| `heartbeat_sweep` | false | whether the heartbeat runs the sweep |
| `heartbeat_janitor` | false | whether the heartbeat runs the janitor |

A file that is not one JSON object, a key of the wrong type or an unknown key is refused with the reason (exit 1), so a typo never silently keeps a default.

On macOS, Docker runs in Docker Desktop's VM, so the readings differ, and both are **unverified** on a Mac: the memory is `docker info`'s `MemTotal` (the VM's) less what the running containers use (`docker stats`), and the disk is the file system holding the home directory, where Docker Desktop keeps its disk image.

## Closing a task

`team-close` takes the stacks of a task down before it archives the task's directories, so a closed task leaves nothing running and its stack logs are archived with it.

- For each worktree it is about to return whose project has a `stack` block, it runs `team-stack down --worktree <path>`, which saves the logs into the worktree's task directory; the archive then copies them to `tasks/T<n>/`.
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
- `tests/team-stack-live.bats` runs against the real Docker only with `TEAM_LIVE_DOCKER=1`, since a test that creates a network can break a gate run's end to end; it starts and removes the fixture's one-service stack under a project name of its own, and races two `up` calls for the last place under `stack_cap`.
