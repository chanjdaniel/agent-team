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
# The calls it answers, each from that state as Docker would:
#   compose ls [--all] --format json    the Compose projects of the containers, running ones
#                                       only without --all, with Compose's status and files
#   ps [--all] --quiet --no-trunc [--filter label=<key>[=<value>]]...
#   inspect --type container|volume|network <names or ids>...
#                                       a JSON array; any name not found is "Error: No such
#                                       object" on stderr and exit 1, as Docker does
#   stats --no-stream --format json <names or ids>...
#   system df -v --format json          {Images, Containers, Volumes, BuildCache}
#   volume ls --quiet, network ls --quiet --no-trunc
# Any other call fails (exit 127), so a test never passes on an unplanned call.
# docker_down makes every call fail as Docker does when its daemon does not answer,
# docker_fail <call> <message> makes one call (its key: "compose ls", "ps", "inspect",
# "system df"...) fail with <message>, and docker_vanish <id> makes ps list a container that is
# gone when it is inspected.
# shellcheck shell=bash

# docker_stub [<worktree>]: install the stub docker on the machine state of the fixtures, the
# team stack's worktree label being <worktree> (default $HOME/worktree).
docker_stub() {
  export DOCKER_STATE=$BATS_TEST_TMPDIR/docker
  cp "$REPO_ROOT/tests/helpers/stub" "$BATS_TEST_TMPDIR/stubs/docker"
  mkdir -p "$DOCKER_STATE"
  local file worktree=${1:-$HOME/worktree}
  for file in "$REPO_ROOT"/tests/fixtures/docker/*.json; do
    sed -e "s#@WORKTREE@#$worktree#g" -e "s#@HOME@#$HOME#g" "$file" >"$DOCKER_STATE/${file##*/}"
  done
  printf 'source %q\ndocker_stub_answer "$@"\n' "$REPO_ROOT/tests/helpers/docker-answer.bash" >"$STUB_FIXTURES/docker.sh"
}

# An empty machine: no container, volume, image or network.
docker_empty() {
  local file
  for file in containers volumes images networks stats; do echo '[]' >"$DOCKER_STATE/$file.json"; done
}

# Change the machine's state: docker_state <file without .json> <jq filter>, e.g.
# docker_state containers 'map(select(.Name != "/conventioner-3-backend-1"))'.
docker_state() {
  local tmp
  tmp=$(mktemp)
  jq "$2" "$DOCKER_STATE/$1.json" >"$tmp"
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

# The docker calls made, one line each as typed (arguments joined by spaces).
docker_calls() {
  stub_calls docker | jq -r 'join(" ")'
}

# stack_project <name>: a project the team manages stacks of, in the sandbox: a repository whose
# primary checkout is $HOME/projects/<name> (make_repo), holding the fixture wrapper
# (tests/fixtures/stack/) as scripts/compose.sh and its docker-compose.yml, with a linked
# worktree at $HOME/worktrees/<name>-1 on the branch work, and registered in the sandbox's
# projects.toml with a stack block naming the wrapper. Sets STACK_PRIMARY and STACK_WORKTREE.
stack_project() {
  local name=$1
  STACK_PRIMARY=$(make_repo "$name")
  STACK_WORKTREE=$HOME/worktrees/$name-1
  mkdir -p "$STACK_PRIMARY/scripts" "$HOME/worktrees"
  cp "$REPO_ROOT/tests/fixtures/stack/compose.sh" "$STACK_PRIMARY/scripts/compose.sh"
  cp "$REPO_ROOT/tests/fixtures/stack/docker-compose.yml" "$STACK_PRIMARY/docker-compose.yml"
  printf '#!/usr/bin/env bash\necho "seeded $COMPOSE_PROJECT_NAME"\n' >"$STACK_PRIMARY/scripts/seed.sh"
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
