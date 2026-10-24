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

## Seeing what Docker holds

- `team-stack ls` lists every Compose project with its status, class, task, kind, worktree, age and memory.
- `team-stack ls --all` adds the volumes, images and networks, grouped by class with their totals; `--json` gives every object with its class.
- It only reads, so it is safe at any time, a gate run's end-to-end phase included.

## Testing

- The bats tests never reach the machine's Docker: `tests/helpers/docker.bash` installs a stub `docker` that answers from fixtures recorded on this machine (`tests/fixtures/docker/`) and logs every call.
- `tests/team-stack-live.bats` runs against the real Docker only with `TEAM_LIVE_DOCKER=1`, since a test that creates a network can break a gate run's end to end.
