# A stub docker for the tests of the scripts that run Docker (team-stack): load it with
# `load helpers/docker` after `load helpers/common`, and call `docker_stub` from `setup` after
# `sandbox`. Opt-in per test file, so the other files' tool answers stay as they are.
#
# docker_stub installs tests/helpers/stub as `docker`, so every call is logged (stub_calls docker)
# and answered by the Bash below from the machine's state: JSON files in $DOCKER_STATE, copied
# from tests/fixtures/docker/ (recorded on home-pc on 2026-10-24 from Docker 29.9.2 and Compose
# 5.6.1, trimmed to the fields the scripts read, with no environment and no secrets; the team
# and gate stacks the machine did not run at the time are its real stacks renamed and
# relabelled), with @HOME@ and @WORKTREE@ filled in:
#   containers.json   docker inspect --type container of every container
#   volumes.json      docker inspect --type volume of every volume, each with the Size that
#                     docker system df -v gives it
#   images.json       the Images of docker system df -v --format json
#   networks.json     docker inspect --type network of every network
#   stats.json        docker stats --no-stream --format json of the running containers
#   info.json         docker info --format json, trimmed
#   events.json       the events docker events gives (docker_event), none to begin with
# The calls it answers, each from that state as Docker would:
#   compose ls [--all] --format json    the Compose projects of the containers, running ones
#                                       only without --all, with Compose's status and files
#   ps [--all] --quiet --no-trunc [--filter label=<key>[=<value>]]...
#   inspect --type container|volume|network <names or ids>...
#                                       a JSON array; any name not found is "Error: No such
#                                       object" on stderr and exit 1, as Docker does
#   stats --no-stream --format json <names or ids>...
#   system df -v --format json          {Images, Containers, Volumes, BuildCache}
#   system df --format json             one line of totals per type, as Docker writes them
#   events --since <epoch> --until <epoch> --filter event=<action> --format json
#   volume ls --quiet, network ls --quiet --no-trunc, each with any --filter label=<key>[=<value>]
#   volume rm <names>...                a volume missing or mounted by a container is refused
#   image rm <repository:tag or id>...  an image missing or used by a container is refused
#   network rm <names or ids>...        a network missing or a running container is on is
#                                       refused (Docker removes one only stopped ones are on)
#   info --format json
# and, modelling the fixture project's stack (stack_project) as Compose 5.6.1 makes it, from the
# TEAM_* variables, COMPOSE_PROJECT_NAME and TH_WEB_PORT the call sees:
#   compose [-f <file>] config --format json
#   compose [-f <file>] up -d --wait    the network and named volume made when missing (an
#                                       existing one keeps its labels), the web container made,
#                                       started, or recreated when its labels changed
#   compose [-f <file>] port web 80     the running web's address
#   compose -p <project> logs --no-color --timestamps <service>
#                                       $DOCKER_STATE/logs/<project>-<service>.log when the test
#                                       wrote one, else one line
#   compose -p <project> stop, compose -p <project> down -v --remove-orphans
# Each compose call is logged with what it sees (docker_compose_env).
# The machine's memory and disk, which team-stack's admission reads, are the sandbox's too: a
# stub df answers df -Pk <path> from $DOCKER_STATE/disk-free (machine_disk_free; 200 GiB free
# unless a test says otherwise), and TEAM_MEMINFO names $DOCKER_STATE/meminfo, read in place of
# /proc/meminfo (machine_memory; 24 GiB available unless a test says otherwise). A stub uname
# says Linux, so admission reads them the Linux way on any host; as_macos makes it say Darwin.
# Any other call fails (exit 127), so a test never passes on an unplanned call.
# docker_down makes every call fail as Docker does when its daemon does not answer,
# docker_fail <call> <message> makes one call (its key: "compose ls", "ps", "inspect",
# "system df"...) fail with <message>, and docker_vanish <id> makes ps list a container that is
# gone when it is inspected, and docker_leak <anonymous|network|container> makes compose down
# leave the project's anonymous volumes, its networks or its containers behind, and
# docker_refuse <name> <message> makes the removal of the volume, image or network <name> fail.
# docker_created <volume|image|network|container> <name> <seconds ago> sets an object's creation
# time in the form Docker gives it, docker_event <action> <container> <seconds ago> adds an event
# of a container, and reap_machine makes the fixture's objects whose reaping depends on their
# age young, so the reaper's results never depend on the clock.
# shellcheck shell=bash

# docker_stub [<worktree>]: install the stub docker on the machine state of the fixtures, the
# team stack's worktree label being <worktree> (default $HOME/worktree).
docker_stub() {
  export DOCKER_STATE=$BATS_TEST_TMPDIR/docker
  stub_command docker
  mkdir -p "$DOCKER_STATE"
  local file worktree=${1:-$HOME/worktree}
  for file in "$REPO_ROOT"/tests/fixtures/docker/*.json; do
    sed -e "s#@WORKTREE@#$worktree#g" -e "s#@HOME@#$HOME#g" "$file" >"$DOCKER_STATE/${file##*/}"
  done
  printf 'source %q\ndocker_stub_answer "$@"\n' "$REPO_ROOT/tests/helpers/docker-answer.bash" >"$STUB_FIXTURES/docker.sh"
  stub_command df
  printf 'source %q\ndocker_stub_df "$@"\n' "$REPO_ROOT/tests/helpers/docker-answer.bash" >"$STUB_FIXTURES/df.sh"
  export TEAM_MEMINFO=$DOCKER_STATE/meminfo
  stub_command uname
  stub_reply uname Linux
  machine_disk_free $((200 * 1024 * 1024))
  machine_memory $((24 * 1024 * 1024))
}

# The free space df gives on every file system, in 1024-byte blocks: machine_disk_free <blocks>...,
# one per df call in turn, the last for every call after.
machine_disk_free() {
  printf '%s\n' "$@" >"$DOCKER_STATE/disk-free"
}

# The machine's memory available, in kB, as /proc/meminfo gives it: machine_memory <kB>
machine_memory() {
  printf 'MemTotal:       %s kB\nMemFree:         1048576 kB\nMemAvailable:   %s kB\n' $((32 * 1024 * 1024)) "$1" \
    >"$DOCKER_STATE/meminfo"
}

# An empty machine: no container, volume, image or network.
docker_empty() {
  local file
  for file in containers volumes images networks stats events; do echo '[]' >"$DOCKER_STATE/$file.json"; done
}

# Change the machine's state: docker_state <file without .json> <jq filter> [jq options...], e.g.
# docker_state containers 'map(select(.Name != "/conventioner-3-backend-1"))'.
docker_state() {
  local tmp
  tmp=$(mktemp)
  jq "$2" "${@:3}" "$DOCKER_STATE/$1.json" >"$tmp"
  mv "$tmp" "$DOCKER_STATE/$1.json"
}

# Every call fails as when the daemon does not answer.
docker_down() {
  touch "$DOCKER_STATE/down"
}

# One call fails with <message>: docker_fail <call key> <message>
docker_fail() {
  printf '%s\n' "$2" >"$DOCKER_STATE/fail-${1// /-}"
}

# ps lists the container <id>, which is gone by the time it is inspected: docker_vanish <id>
docker_vanish() {
  echo "$1" >>"$DOCKER_STATE/vanished"
}

# compose down leaves what it should remove: docker_leak <anonymous|network|container>
docker_leak() {
  touch "$DOCKER_STATE/leak-$1"
}

# The removal of the volume, image or network <name> (as the rm call names it) fails with
# <message>: docker_refuse <name> <message>
docker_refuse() {
  jq -cn --arg name "$1" --arg message "$2" '{name: $name, message: $message}' >>"$DOCKER_STATE/refuse.jsonl"
}

# Add the event <action> (oom, die...) of the container <name>, <seconds> ago, as docker events
# gives it: docker_event <action> <name> <seconds>
docker_event() {
  local id
  id=$(jq -r --arg name "/$2" 'first(.[] | select(.Name == $name) | .Id) // empty' "$DOCKER_STATE/containers.json")
  docker_state events '. + [{Type: "container", Action: $action,
      Actor: {ID: $id, Attributes: {image: "busybox", name: $name}}, scope: "local",
      time: (now - $seconds | floor), timeNano: ((now - $seconds | floor) * 1000000000)}]' \
    --arg action "$1" --arg name "$2" --arg id "${id:-$(printf '%064d' 0)}" --argjson seconds "$3"
}

# The fixture's dangling image and its unattached anonymous volumes made 23 hours ago, so the
# reaper keeps them whenever it runs; a test ages the ones it needs (docker_created).
reap_machine() {
  docker_created image "$(jq -r '.[] | select(.Repository == "<none>") | .ID' "$DOCKER_STATE/images.json")" $((23 * 3600))
  docker_created volume d34171881feb5b31166cdd67ec7d406dc769ac4c3c5dafb72ee98f6ef0a9e7ce $((23 * 3600))
  docker_created volume 05ab97f3ee4e69dfc7abe03f10bb3cb0115bfafead15e5f74babe7e369cda85e $((23 * 3600))
}

# Set the creation time of the object <name> (an image by repository:tag or id) to <seconds> ago,
# in the form Docker gives each type: docker_created <volume|image|network|container> <name> <seconds>
docker_created() {
  local -A field=([container]=Created [volume]=CreatedAt [network]=Created [image]=CreatedAt)
  local -A file=([container]=containers [volume]=volumes [network]=networks [image]=images)
  local -A form=([container]='%Y-%m-%dT%H:%M:%S.000000000Z' [volume]='%Y-%m-%dT%H:%M:%S+00:00'
    [network]='%Y-%m-%dT%H:%M:%S.000000000+00:00' [image]='%Y-%m-%d %H:%M:%S +0000 UTC')
  [[ -n ${file[$1]:-} ]] || { echo "docker_created: no type $1" >&2; return 1; }
  docker_state "${file[$1]}" 'map(if .Name == $name or .Name == "/" + $name or .ID == $name
      or "\(.Repository):\(.Tag)" == $name then .[$field] = (now - $seconds | strftime($form)) else . end)' \
    --arg name "$2" --argjson seconds "$3" --arg field "${field[$1]}" --arg form "${form[$1]}"
}

# The compose calls made, one compact JSON object per line: {call, project, COMPOSE_PROJECT_NAME,
# TH_PORTS, TH_WEB_PORT, labels: {owner, task, kind, worktree, expires}}, each as the call saw
# it (null when unset).
docker_compose_env() {
  cat "$DOCKER_STATE/compose-env.jsonl" 2>/dev/null || true
}

# The docker calls made, one line each as typed (arguments joined by spaces).
docker_calls() {
  stub_calls docker | jq -r 'join(" ")'
}

# stack_project <name>: a project the team manages stacks of, in the sandbox: a repository whose
# primary checkout is $HOME/projects/<name> (make_repo), holding the fixture wrapper
# (tests/fixtures/stack/) as scripts/compose.sh and its docker-compose.yml, a scripts/seed.sh
# that says what it seeded ("seeded <project> on port <TH_WEB_PORT> for <TEAM_TASK> from <its
# directory>"), with a linked
# worktree at $HOME/worktrees/<name>-1 on the branch work, and registered in the sandbox's
# projects.toml with a stack block naming the wrapper. Sets STACK_PRIMARY and STACK_WORKTREE.
stack_project() {
  local name=$1
  STACK_PRIMARY=$(make_repo "$name")
  STACK_WORKTREE=$HOME/worktrees/$name-1
  mkdir -p "$STACK_PRIMARY/scripts" "$HOME/worktrees"
  cp "$REPO_ROOT/tests/fixtures/stack/compose.sh" "$STACK_PRIMARY/scripts/compose.sh"
  cp "$REPO_ROOT/tests/fixtures/stack/docker-compose.yml" "$STACK_PRIMARY/docker-compose.yml"
  printf '#!/usr/bin/env bash\necho "seeded $COMPOSE_PROJECT_NAME on port $TH_WEB_PORT for $TEAM_TASK from $PWD"\n' \
    >"$STACK_PRIMARY/scripts/seed.sh"
  chmod +x "$STACK_PRIMARY/scripts/seed.sh"
  git -C "$STACK_PRIMARY" add scripts docker-compose.yml
  git -C "$STACK_PRIMARY" commit -q -m "feat: add the stack"
  git -C "$STACK_PRIMARY" push -q origin HEAD
  git -C "$STACK_PRIMARY" worktree add -q -b work "$STACK_WORKTREE"
  cat >>"$TEAM_HOME/projects.toml" <<TOML

[$name]
repo = "owner/$name"
path = "projects/$name"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["worktrees/$name-1"] }

[$name.stack]
compose = "scripts/compose.sh"
seed = "scripts/seed.sh"
log_services = ["web"]
images = ["$name/web"]
legacy_images = ["$name-[0-9]+-web"]
legacy_gate = "nmtest-[0-9]+"
TOML
  export STACK_PRIMARY STACK_WORKTREE
}
