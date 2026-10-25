#!/usr/bin/env bats
# team-stack against this machine's real Docker, run only when asked for: TEAM_LIVE_DOCKER=1
# tests/vendor/bats-core/bin/bats tests/team-stack-live.bats. Skipped otherwise, so tests/run at
# a merge never reaches Docker while a gate run's end to end runs (sops/docker.md). The first
# two only read (ls, and the fixture wrapper's compose config, which starts nothing); the others
# start and remove stacks of the fixture project's one busybox service, under project names of
# their own, which teardown removes whatever happened. The sweep's test shows every other team
# stack running on the machine as busy in the stub session list, so it stops only its own, and
# the reaper's test limits it to its own projects with TEAM_STACK_REAP_PROJECTS.

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
  local project
  for project in ${LIVE_PROJECT:-} ${LIVE_PROJECTS[@]+"${LIVE_PROJECTS[@]}"}; do
    docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true
  done
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

@test "live: two ups racing for the last place under stack_cap start exactly one stack, and the other exits 75" {
  local a=liva$RANDOM$$ b=livb$RANDOM$$ wt_a wt_b
  stack_project "$a"
  wt_a=$STACK_WORKTREE
  stack_project "$b"
  wt_b=$STACK_WORKTREE
  LIVE_PROJECTS=("stackfix-$a-1" "stackfix-$b-1")
  jq -cn --arg a "$a" --arg wa "$wt_a" --arg b "$b" --arg wb "$wt_b" '
    {ts: "2026-10-24T09:00:00Z", event: "opened", path: "feature", type: "feature", title: "Live", branch: "work",
     base: "main", base_sha: "0000000"} as $e
    | ($e + {task: "T22", project: $a, worktree: $wa}), ($e + {task: "T23", project: $b, worktree: $wb})' \
    >>"$TEAM_HOME/ledger.jsonl"
  # Room for one more stack than runs now, whatever the memory and disk.
  local running
  running=$(docker compose ls --format json | jq length)
  mkdir -p "$HOME/.config/agent-team"
  jq -n --argjson cap $((running + 1)) '{stack_cap: $cap, memory_floor_gib: 0, disk_floor_gb: 0, wait_minutes: 0}' \
    >"$HOME/.config/agent-team/stack.json"

  local dir=$BATS_TEST_TMPDIR pid_a pid_b status_a=0 status_b=0
  "$REPO_ROOT/bin/team-stack" up --worktree "$wt_a" --no-seed >"$dir/a.out" 2>"$dir/a.err" &
  pid_a=$!
  "$REPO_ROOT/bin/team-stack" up --worktree "$wt_b" --no-seed >"$dir/b.out" 2>"$dir/b.err" &
  pid_b=$!
  wait "$pid_a" || status_a=$?
  wait "$pid_b" || status_b=$?
  assert_equal "$(printf '%s\n' "$status_a" "$status_b" | sort -n | paste -sd ' ')" "0 75"
  assert_contains "$(cat "$dir/a.err" "$dir/b.err")" "$((running + 1)) of $((running + 1)) stacks running (stack_cap $((running + 1)))"
  # Exactly one of the two runs.
  local started
  started=$(docker compose ls --format json | jq -c --arg a "stackfix-$a-1" --arg b "stackfix-$b-1" '[.[].Name | select(. == $a or . == $b)]')
  assert_equal "$(jq length <<<"$started")" 1
  assert_equal "$(jq -c '[.[] | select(.admitted == false)] | length' -s "$HOME/.local/state/agent-team/stacks/waits.jsonl")" 1

  local winner
  if ((status_a == 0)); then winner=$wt_a; else winner=$wt_b; fi
  run_bin -0 team-stack down --worktree "$winner"
}

# Make the stub session list hold a busy session in each of <worktrees...> and in the worktree of
# every team container running on the machine, so a live sweep never stops another task's stack;
# skip when a running team container has no worktree label, which no session could keep busy.
live_busy() {
  local -a ids worktrees=("$@")
  local worktree
  mapfile -t ids < <(docker ps --quiet --filter label=io.github.chanjdaniel.team.owner=agent-team)
  if ((${#ids[@]})); then
    while IFS= read -r worktree; do
      [[ -n $worktree ]] || skip "a running team container has no worktree label, so a live sweep could stop it"
      worktrees+=("$worktree")
    done < <(docker inspect --format '{{index .Config.Labels "io.github.chanjdaniel.team.worktree"}}' "${ids[@]}")
  fi
  for worktree in ${worktrees[@]+"${worktrees[@]}"}; do
    [[ $worktree != "$LIVE_IDLE" ]] || continue
    jq -cn --arg cwd "$worktree" '{cwd: $cwd, kind: "background", status: "busy", state: null}'
  done | jq -cs . >"$STUB_FIXTURES/claude.out"
}

@test "live: the sweep stops an idle stack with its volume intact, and up brings it back with its data" {
  local name=lsw$RANDOM$$
  stack_project "$name"
  LIVE_PROJECT=stackfix-$name-1
  jq -cn --arg wt "$STACK_WORKTREE" '{ts: "2026-10-24T09:00:00Z", task: "T22", event: "opened", project: "'"$name"'",
    path: "feature", type: "feature", title: "Live", branch: "work", base: "main", base_sha: "0000000", worktree: $wt}' \
    >>"$TEAM_HOME/ledger.jsonl"
  mkdir -p "$HOME/.config/agent-team"
  echo '{"idle_minutes": 1, "memory_floor_gib": 0, "disk_floor_gb": 0, "wait_minutes": 0, "stack_cap": 1000}' \
    >"$HOME/.config/agent-team/stack.json"
  cd "$STACK_WORKTREE"
  run_bin -0 team-stack up --no-seed
  local filter=label=com.docker.compose.project=$LIVE_PROJECT container
  container=$(docker ps --quiet --filter "$filter")
  docker exec "$container" sh -c 'echo kept > /data/marker'

  # Busy: kept, its last busy time written.
  LIVE_IDLE=''
  live_busy "$STACK_WORKTREE"
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$output$stderr" ""
  jq -e .last_busy "$HOME/.local/state/agent-team/stacks/$LIVE_PROJECT.json" >/dev/null
  # Idle, but busy less than a minute ago: kept.
  LIVE_IDLE=$STACK_WORKTREE
  live_busy
  run_bin -0 team-stack sweep
  assert_equal "$output" ""
  [[ -n $(docker ps --quiet --filter "$filter") ]]
  # Idle past idle_minutes: stopped, alone.
  sleep 62
  live_busy
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$stderr" ""
  [[ $output == *" stopped $LIVE_PROJECT of T22 in $STACK_WORKTREE: last busy at "*" (idle_minutes 1), its data kept" ]]
  assert_equal "${#lines[@]}" 1
  assert_equal "$(docker ps --quiet --filter "$filter")" ""
  assert_equal "$(docker ps --all --quiet --filter "$filter")" "$container"
  assert_equal "$(docker volume ls --quiet --filter "$filter")" "${LIVE_PROJECT}_data"

  run_bin -0 --separate-stderr team-stack up
  assert_equal "$output" "team-stack: $LIVE_PROJECT is up for T22, not seeded: its database was there"
  run_bin -0 team-stack env
  assert_equal "$(eval "$output"; live_get "$TH_WEB_PORT" /marker)" kept
  run_bin -0 team-stack down
  [[ ! -e $HOME/.local/state/agent-team/stacks/$LIVE_PROJECT.json ]]
}

@test "live: reap --apply removes a closed task's stack and an expired gate stack with their volumes, and keeps an unowned one" {
  local name=lrp$RANDOM$$
  stack_project "$name"
  local team=stackfix-$name-1 gate=stackfix-$name-g unowned=stackfix-$name-u project
  LIVE_PROJECTS=("$team" "$gate" "$unowned")
  jq -cn --arg wt "$STACK_WORKTREE" --arg p "$name" '{ts: "2026-10-24T09:00:00Z", task: "T22", event: "opened", project: $p,
    path: "feature", type: "feature", title: "Live", branch: "work", base: "main", base_sha: "0000000", worktree: $wt}' \
    >>"$TEAM_HOME/ledger.jsonl"
  mkdir -p "$HOME/.config/agent-team"
  echo '{"memory_floor_gib": 0, "disk_floor_gb": 0, "wait_minutes": 0, "stack_cap": 1000}' >"$HOME/.config/agent-team/stack.json"
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  # One request, which httpd -v logs, so the saved log has a line.
  run_bin -0 team-stack env --worktree "$STACK_WORKTREE"
  (eval "$output"; live_get "$TH_WEB_PORT" / >/dev/null)
  # A gate run's stack past its expires, and a stack made by hand with no labels, both through the wrapper.
  (cd "$STACK_WORKTREE" && COMPOSE_PROJECT_NAME=$gate TH_PORTS=auto TH_DIR=$STACK_WORKTREE TEAM_KIND=gate \
    TEAM_WORKTREE=$STACK_WORKTREE TEAM_EXPIRES=2026-01-01T00:00:00Z scripts/compose.sh up -d --wait) >/dev/null 2>&1
  (cd "$STACK_WORKTREE" && COMPOSE_PROJECT_NAME=$unowned TH_PORTS=auto TH_DIR=$STACK_WORKTREE \
    scripts/compose.sh up -d --wait) >/dev/null 2>&1
  jq -cn '{ts: "2026-10-24T10:00:00Z", task: "T22", event: "closed"}' >>"$TEAM_HOME/ledger.jsonl"
  # The anonymous volumes of all three, by project.
  local -A anonymous=()
  for project in "${LIVE_PROJECTS[@]}"; do
    anonymous[$project]=$(docker ps --all --quiet --filter "label=com.docker.compose.project=$project" |
      xargs docker inspect --format '{{range .Mounts}}{{if eq .Destination "/cache"}}{{.Name}}{{end}}{{end}}')
    [[ -n ${anonymous[$project]} ]]
  done
  local scope="stackfix-$name-(1|g|u)"

  # The dry run says what it would do, and does nothing.
  TEAM_STACK_REAP_PROJECTS=$scope run_bin -0 --separate-stderr team-stack reap
  assert_equal "$stderr" ""
  assert_equal "$(grep -c '^would remove ' <<<"$output")" 2
  assert_contains "$output" "would remove stack $team (team, "
  assert_contains "$output" "): its task T22 is closed"
  assert_contains "$output" "would remove stack $gate (gate, "
  assert_contains "$output" "): it expired at 2026-01-01T00:00:00Z"
  [[ $output =~ (^|$'\n')"kept stack $unowned (unowned, "[^$'\n']*" old)" ]]
  assert_equal "$(docker compose ls --format json | jq -c --arg n "$name" '[.[].Name | select(contains($n))] | sort')" \
    "$(jq -cn --args '$ARGS.positional | sort' "$team" "$gate" "$unowned")"

  TEAM_STACK_REAP_PROJECTS=$scope run_bin -0 --separate-stderr team-stack reap --apply
  assert_equal "$stderr" ""
  assert_contains "$output" "removed stack $team (team, "
  assert_contains "$output" "; its logs in $STACK_WORKTREE/.scratch/task/stack-logs"
  assert_contains "$output" "removed stack $gate (gate, "
  grep -q 'response:' "$STACK_WORKTREE/.scratch/task/stack-logs/T22-$team-web.log"
  for project in "$team" "$gate"; do
    assert_equal "$(docker ps --all --quiet --filter "label=com.docker.compose.project=$project")" ""
    assert_equal "$(docker volume ls --quiet --filter "label=com.docker.compose.project=$project")" ""
    assert_equal "$(docker network ls --quiet --filter "label=com.docker.compose.project=$project")" ""
    run docker volume inspect "${anonymous[$project]}"
    assert_equal "$status" 1
  done
  # The unowned stack is untouched, its volumes with it.
  [[ -n $(docker ps --quiet --filter "label=com.docker.compose.project=$unowned") ]]
  assert_equal "$(docker volume ls --quiet --filter "label=com.docker.compose.project=$unowned")" "${unowned}_data"
  docker volume inspect "${anonymous[$unowned]}" >/dev/null
  LIVE_ANONYMOUS=${anonymous[$unowned]}
}
