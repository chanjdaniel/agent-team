#!/usr/bin/env bats
# team-stack against this machine's real Docker, run only when asked for: TEAM_LIVE_DOCKER=1
# tests/vendor/bats-core/bin/bats tests/team-stack-live.bats. Skipped otherwise, so tests/run at
# a merge never reaches Docker while a gate run's end to end runs (sops/docker.md). The first
# two only read (ls, and the fixture wrapper's compose config, which starts nothing); the last
# starts and removes a stack of the fixture project's one busybox service, under a project name
# of its own, which teardown removes whatever happened.

load helpers/common
load helpers/docker

setup() {
  [[ ${TEAM_LIVE_DOCKER:-} == 1 ]] || skip "live Docker tests run only with TEAM_LIVE_DOCKER=1"
  command -v docker >/dev/null || skip "docker is not installed"
  # The real Docker client config (its context, on Docker Desktop), whatever HOME the sandbox sets.
  export DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stack_project shop
}

@test "live: ls --all --json classifies everything Docker holds, and changes nothing" {
  local before after
  before=$(docker compose ls --all --format json | jq -c 'map(.Name)')
  run_bin -0 team-stack ls --all --json
  after=$(docker compose ls --all --format json | jq -c 'map(.Name)')
  assert_equal "$after" "$before"
  assert_equal "$(jq -c '[.projects[].name]' <<<"$output")" "$before"
  assert_equal "$(jq -c '[.projects[], .volumes[], .networks[] | .class] - ["team", "gate", "unowned", "anonymous"]' <<<"$output")" '[]'
  assert_equal "$(jq -c '[.images[].class] - ["team", "legacy", "unowned"]' <<<"$output")" '[]'
  # Docker's own networks are always there.
  jq -e '[.networks[].name] | index("bridge")' <<<"$output" >/dev/null
  run_bin -0 team-stack ls --all
}

@test "live: the fixture wrapper labels its service, named volume and network from TEAM_*" {
  local config
  config=$(cd "$STACK_WORKTREE" && TH_DIR=$STACK_WORKTREE TEAM_OWNER=agent-team TEAM_TASK=T22 TEAM_KIND=dev \
    TEAM_WORKTREE=$STACK_WORKTREE TEAM_EXPIRES='' scripts/compose.sh config --format json)
  assert_equal "$(jq -r .name <<<"$config")" stackfix-shop-1
  local where expected
  expected=$(jq -cnS --arg wt "$STACK_WORKTREE" '{owner: "agent-team", task: "T22", kind: "dev", worktree: $wt, expires: ""}')
  for where in .services.web .volumes.data .networks.default; do
    assert_equal "$(jq -cS "$where.labels | with_entries(select(.key | startswith(\"io.github.chanjdaniel.team.\")) | .key |= ltrimstr(\"io.github.chanjdaniel.team.\"))" <<<"$config")" "$expected"
  done
  # Unset, every label is empty; with TH_PORTS=auto the caller names the project and Docker picks the port.
  config=$(cd "$STACK_WORKTREE" && COMPOSE_PROJECT_NAME=stackfix-shop-1-a TH_PORTS=auto TH_DIR=$STACK_WORKTREE \
    scripts/compose.sh config --format json)
  assert_equal "$(jq -r .name <<<"$config")" stackfix-shop-1-a
  assert_equal "$(jq -c '[.services.web.labels | to_entries[] | select(.key | startswith("io.github.chanjdaniel.team.")) | .value] | unique' <<<"$config")" '[""]'
  assert_equal "$(jq -c '.services.web.ports[0] | [.host_ip, .published // ""]' <<<"$config")" '["127.0.0.1",""]'
}

teardown() {
  [[ -n ${LIVE_PROJECT:-} ]] || return 0
  docker compose -p "$LIVE_PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${LIVE_ANONYMOUS:-} ]]; then docker volume rm "$LIVE_ANONYMOUS" >/dev/null 2>&1 || true; fi
}

# GET <path> from the stack's web on 127.0.0.1:<port>, the body only: live_get <port> <path>
live_get() {
  local response
  exec 3<>"/dev/tcp/127.0.0.1/$1"
  printf 'GET %s HTTP/1.0\r\n\r\n' "$2" >&3
  response=$(cat <&3)
  exec 3<&-
  printf '%s\n' "${response#*$'\r\n\r\n'}"
}

@test "live: up, env, stop, up again with its data, and down leaving no container, volume or network" {
  local name=live$RANDOM$$
  stack_project "$name"
  LIVE_PROJECT=stackfix-$name-1
  jq -cn --arg wt "$STACK_WORKTREE" '{ts: "2026-10-24T09:00:00Z", task: "T22", event: "opened", project: "'"$name"'",
    path: "feature", type: "feature", title: "Live", branch: "work", base: "main", base_sha: "0000000", worktree: $wt}' \
    >>"$TEAM_HOME/ledger.jsonl"
  cd "$STACK_WORKTREE"

  run_bin -0 --separate-stderr team-stack up
  assert_equal "$output" "team-stack: $LIVE_PROJECT is up for T22, seeded: a new database"
  assert_contains "$stderr" "seeded $LIVE_PROJECT on port "
  local filter=label=com.docker.compose.project=$LIVE_PROJECT container
  container=$(docker ps --quiet --filter "$filter")
  [[ -n $container ]]
  assert_equal "$(docker inspect --format '{{index .Config.Labels "io.github.chanjdaniel.team.owner"}} {{index .Config.Labels "io.github.chanjdaniel.team.task"}} {{index .Config.Labels "io.github.chanjdaniel.team.kind"}} {{index .Config.Labels "io.github.chanjdaniel.team.worktree"}}' "$container")" \
    "agent-team T22 dev $STACK_WORKTREE"
  assert_equal "$(docker volume inspect --format '{{index .Labels "io.github.chanjdaniel.team.task"}}' "${LIVE_PROJECT}_data")" T22
  LIVE_ANONYMOUS=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/cache"}}{{.Name}}{{end}}{{end}}' "$container")
  [[ -n $LIVE_ANONYMOUS ]]

  # env reaches the stack: its port serves what the named volume holds.
  docker exec "$container" sh -c 'echo kept > /data/marker'
  run_bin -0 team-stack env
  local exports=$output
  assert_equal "$(eval "$exports"; live_get "$TH_WEB_PORT" /marker)" kept

  run_bin -0 team-stack stop
  [[ -z $(docker ps --quiet --filter "$filter") ]]
  run_bin -1 --separate-stderr team-stack env
  assert_contains "$stderr" "$LIVE_PROJECT is not running"

  run_bin -0 --separate-stderr team-stack up
  assert_equal "$output" "team-stack: $LIVE_PROJECT is up for T22, not seeded: its database was there"
  # The same container, started again with its labels, and its data.
  assert_equal "$(docker ps --quiet --filter "$filter")" "$container"
  run_bin -0 team-stack env
  assert_equal "$output" "$exports"
  assert_equal "$(eval "$output"; live_get "$TH_WEB_PORT" /marker)" kept

  run_bin -0 --separate-stderr team-stack down
  assert_equal "$output" "team-stack: $LIVE_PROJECT is removed, its logs in $STACK_WORKTREE/.scratch/task/stack-logs"
  assert_equal "$stderr" ""
  # httpd -v logs each response, with Docker's timestamp first: both GETs, from both starts.
  local log=$STACK_WORKTREE/.scratch/task/stack-logs/$LIVE_PROJECT-web.log
  assert_equal "$(grep -Ec '^web-1 +\| [0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+Z .*response:200$' "$log")" 2
  assert_equal "$(docker ps --all --quiet --filter "$filter")" ""
  assert_equal "$(docker volume ls --quiet --filter "$filter")" ""
  assert_equal "$(docker network ls --quiet --filter "$filter")" ""
  run docker volume inspect "$LIVE_ANONYMOUS"
  assert_equal "$status" 1
  run_bin -0 team-stack down
  assert_equal "$output" "team-stack: $LIVE_PROJECT has no stack, so there is nothing to remove"
}
