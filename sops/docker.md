# SOP: Docker stacks

How the team runs the Docker stacks of a project's worktrees, and how it tells its own Docker objects from everyone else's.
`team-stack` is the one way an agent starts, reaches, stops and removes a stack; `team-stack --help` is its exact reference.
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

- **team**: `owner=agent-team`.
- **gate**: `kind=gate`; or, with no team label set to a value, a Compose project whose name matches a project's `legacy_gate` (gate runs from before the labels).
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

An agent starts, reaches, stops and removes its stack with `team-stack`, never with `docker compose up`, the wrapper's `up` or `docker run`.

- `team-stack up` starts the worktree's stack, labelled with its task, and seeds a new database.
- `eval "$(team-stack env)"` exports what reaches it: `COMPOSE_PROJECT_NAME`, a `TH_<SERVICE>_PORT` per service (the wrapper's `ports`) and the stack's five `TEAM_*` labels, so the seed, Playwright, `mongosh` and a hand-run wrapper call reach the same stack without changing its labels.
- `team-stack seed` runs the project's seed command again, from the worktree, with those exports.
- `team-stack stop` stops its containers and keeps its data; the next `up` starts them again and does not seed.
- `team-stack down` saves its logs and removes it, leaving no container, volume (named or anonymous) or network of it.

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

Exit codes: 0 done, 1 refused or failed (with the reason), 2 a malformed command line, 75 try again later.

## Seeing what Docker holds

- `team-stack ls` lists every Compose project with its status, class, task, kind, worktree, age and memory.
- `team-stack ls --all` adds the volumes, images and networks, grouped by class with their totals; `--json` gives every object with its class.
- It only reads, so it is safe at any time, a gate run's end-to-end phase included.

## Testing

- The bats tests never reach the machine's Docker: `tests/helpers/docker.bash` installs a stub `docker` that answers from fixtures recorded on this machine (`tests/fixtures/docker/`) and logs every call.
- The stub also models the fixture project's stack (`tests/fixtures/stack/`), so `up`, `env`, `seed`, `stop` and `down` are tested through the wrapper contract rather than Conventioner.
- `tests/team-stack-live.bats` runs against the real Docker only with `TEAM_LIVE_DOCKER=1`, since a test that creates a network can break a gate run's end to end; it starts and removes the fixture's one-service stack under a project name of its own.
