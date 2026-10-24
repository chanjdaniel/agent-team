#!/usr/bin/env bash
# The fixture project's compose wrapper, the smallest that meets team-stack's wrapper contract
# (sops/docker.md), so the tests exercise the contract rather than Conventioner's th-compose.sh.
# stack_project (tests/helpers/docker.bash) commits it as scripts/compose.sh beside
# docker-compose.yml, one busybox service, web, with a named volume, an anonymous one and the
# default network, each labelled from the TEAM_* variables.
#
# Usage: TH_DIR=<worktree> <worktree>/scripts/compose.sh <docker compose arguments...>
#        TH_DIR=<worktree> <worktree>/scripts/compose.sh ports
# The worktree's own stack is project stackfix-<the worktree's directory name>, its web port
# fixed by the worktree's path; COMPOSE_PROJECT_NAME with TH_PORTS=auto names another project,
# whose port Docker assigns. ports prints the export lines of the running stack's project and
# port, and exits 1 when it is not running. Every other call runs docker compose with the
# project's file and its arguments.
set -euo pipefail

wt=${TH_DIR:-$PWD}
if [[ ! -f $wt/docker-compose.yml ]]; then
  echo "compose.sh: no docker-compose.yml in '$wt'; run it from a worktree or set TH_DIR" >&2
  exit 1
fi
case ${TH_PORTS:-} in
  auto)
    if [[ -z ${COMPOSE_PROJECT_NAME:-} ]]; then
      echo "compose.sh: TH_PORTS=auto needs COMPOSE_PROJECT_NAME, the stack's own project name" >&2
      exit 1
    fi
    export TH_WEB_PORT=''
    ;;
  '')
    name=${wt##*/}
    name=${name,,}
    export COMPOSE_PROJECT_NAME=stackfix-${name//[^a-z0-9_-]/-}
    export TH_WEB_PORT=$((20000 + $(cksum <<<"$wt" | cut -d ' ' -f 1) % 10000))
    ;;
  *)
    echo "compose.sh: TH_PORTS='$TH_PORTS' is not a ports mode; the only one is TH_PORTS=auto" >&2
    exit 1
    ;;
esac

compose() {
  docker compose -f "$wt/docker-compose.yml" "$@"
}

if [[ ${1:-} == ports ]]; then
  if ! published=$(compose port web 80 2>/dev/null) || [[ -z $published ]]; then
    echo "compose.sh: $COMPOSE_PROJECT_NAME's web is not running" >&2
    exit 1
  fi
  echo "export COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME"
  echo "export TH_WEB_PORT=${published##*:}"
  exit 0
fi
compose "$@"
