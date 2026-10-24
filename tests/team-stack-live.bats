#!/usr/bin/env bats
# team-stack against this machine's real Docker, run only when asked for: TEAM_LIVE_DOCKER=1
# tests/vendor/bats-core/bin/bats tests/team-stack-live.bats. Skipped otherwise, so tests/run at
# a merge never reaches Docker while a gate run's end to end runs (sops/docker.md). These tests
# only read: ls, and the fixture wrapper's compose config, which starts nothing.

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
