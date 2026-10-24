#!/usr/bin/env bats
# team-stack: the team's Docker stacks, on the stub docker (tests/helpers/docker.bash), whose
# machine holds a team stack of T7 in the fixture project's worktree, a team stack whose
# worktree is gone, a hand-made slot stack, a gate run's stack, a gate stack from before the
# labels and Daniel's primary stack, with their volumes, images and networks.

load helpers/common
load helpers/docker

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stack_project shop
  docker_stub "$STACK_WORKTREE"
}

# The calls a read-only command may make: their first words.
READ_ONLY='^(compose ls|ps|inspect|stats --no-stream|system df|volume ls|network ls)( |$)'

# Fail naming each docker call that is not read-only.
assert_read_only() {
  local writes
  writes=$(docker_calls | grep -Ev "$READ_ONLY" || true)
  assert_equal "$writes" ""
  [[ -n $(docker_calls) ]]
}

# The class of the item named <name> in the list <list> of team-stack ls --all --json's output.
class_of() {
  jq -r --arg list "$1" --arg name "$2" '.[$list][] | select(.name == $name or .repository == $name) | .class' <<<"$output"
}

@test "ls lists every Compose project with its status, class, task, kind, worktree, age and memory" {
  run_bin -0 --separate-stderr team-stack ls
  assert_equal "$stderr" ""
  # Worktrees under the home directory are shown under ~, so these stay literal.
  # shellcheck disable=SC2088
  local worktree='~/worktrees/shop-1' gone='~/.treehouse/Conventioner-d4c77a/4/Conventioner'
  # shellcheck disable=SC2088
  local gate='~/.no-mistakes/worktrees/01KQ3V2M8Z/Conventioner'
  # Ages move with the clock, so each is matched as a number and a unit.
  local age='[0-9]+[smhd]'
  [[ ${lines[0]} =~ ^PROJECT\ +STATUS\ +CLASS\ +TASK\ +KIND\ +WORKTREE\ +AGE\ +MEMORY$ ]]
  [[ ${lines[1]} =~ ^conventioner\ +exited\(2\)\ +unowned\ +-\ +-\ +-\ +$age\ +-$ ]]
  [[ ${lines[2]} =~ ^conventioner-2\ +running\(2\)\ +team\ +T7\ +dev\ +$worktree\ +$age\ +599.8\ MiB$ ]]
  [[ ${lines[3]} =~ ^conventioner-3\ +running\(1\)\ +unowned\ +-\ +-\ +-\ +$age\ +160.2\ MiB$ ]]
  [[ ${lines[4]} =~ ^conventioner-4\ +exited\(1\)\ +team\ +T5\ +dev\ +$gone\ \(gone\)\ +$age\ +-$ ]]
  [[ ${lines[5]} =~ ^nmtest-12822\ +exited\(1\)\ +gate\ +-\ +-\ +-\ +$age\ +-$ ]]
  [[ ${lines[6]} =~ ^nmtest-1895520\ +running\(1\)\ +gate\ +-\ +gate\ +$gate\ \(gone\)\ +$age\ +301.0\ MiB$ ]]
  assert_equal "${#lines[@]}" 7
  assert_read_only
}

@test "ls's age is the time since the project's oldest container was created" {
  docker_state containers '(.[] | select(.Name == "/conventioner-2-mongodb-1") | .Created) = (now - 3 * 3600 - 60 | todate)
    | (.[] | select(.Name == "/conventioner-2-backend-1") | .Created) = (now - 600 | todate)
    | (.[] | select(.Name == "/conventioner-3-backend-1") | .Created) = (now - 2 * 86400 - 60 | todate)
    | (.[] | select(.Name == "/nmtest-1895520-frontend-1") | .Created) = (now - 300 | todate)'
  run_bin -0 team-stack ls
  [[ ${lines[2]} =~ ^conventioner-2\ .*\ 3h\ +599.8\ MiB$ ]]
  [[ ${lines[3]} =~ ^conventioner-3\ .*\ 2d\ +160.2\ MiB$ ]]
  [[ ${lines[6]} =~ ^nmtest-1895520\ .*\ 5m\ +301.0\ MiB$ ]]
}

@test "ls --json prints the projects with their classes and labels, and no other objects" {
  run_bin -0 team-stack ls --json
  assert_equal "$(jq -c 'keys' <<<"$output")" '["projects"]'
  assert_equal "$(jq -c '[.projects[] | [.name, .class]]' <<<"$output")" \
    '[["conventioner","unowned"],["conventioner-2","team"],["conventioner-3","unowned"],["conventioner-4","team"],["nmtest-12822","gate"],["nmtest-1895520","gate"]]'
  assert_equal "$(jq -c --arg wt "$STACK_WORKTREE" '.projects[1] | [.status, .owner, .task, .kind, .worktree == $wt, .worktree_gone, .containers, .running, .memory_bytes, .created]' <<<"$output")" \
    '["running(2)","agent-team","T7","dev",true,false,2,2,628935884,"2026-10-24T09:00:00Z"]'
  # An unset or empty label is null, and so is the memory of a project with nothing running.
  assert_equal "$(jq -c '.projects[0] | [.owner, .task, .kind, .worktree, .worktree_gone, .running, .memory_bytes]' <<<"$output")" \
    '[null,null,null,null,null,0,null]'
  assert_equal "$(jq -c '.projects[3] | [.task, .worktree_gone]' <<<"$output")" '["T5",true]'
  assert_equal "$(jq -c '.projects[5] | [.owner, .kind]' <<<"$output")" '[null,"gate"]'
  assert_read_only
}

@test "ls --all --json classifies volumes: team and gate by their labels or their project, attached anonymous ones by their container, unattached anonymous ones as anonymous" {
  run_bin -0 team-stack ls --all --json
  assert_equal "$(jq -c 'keys' <<<"$output")" '["images","networks","projects","volumes"]'
  assert_equal "$(class_of volumes conventioner-2_mongodb_data)" team
  assert_equal "$(class_of volumes conventioner-2_backend_sessions)" team
  assert_equal "$(class_of volumes nmtest-1895520_mongodb_data)" gate
  # A volume of a gate stack from before the labels: its project matches legacy_gate.
  assert_equal "$(class_of volumes nmtest-12822_backend_sessions)" gate
  assert_equal "$(class_of volumes conventioner_mongodb_data)" unowned
  assert_equal "$(class_of volumes scratch-data)" unowned
  # Each anonymous volume: one mounted by T7's MongoDB, the gate's frontend, Daniel's two, and two loose ones.
  assert_equal "$(jq -c '[.volumes[] | select(.anonymous) | [.class, .attached, .project, .size_bytes]] | sort' <<<"$output")" \
    '[["anonymous",false,null,0],["anonymous",false,null,210900000],["gate",true,"nmtest-1895520",210900000],["team",true,"conventioner-2",0],["unowned",true,"conventioner",0],["unowned",true,"conventioner",210900000]]'
  assert_equal "$(jq -c '.volumes[] | select(.name == "conventioner-2_mongodb_data") | [.project, .attached, .size_bytes, .task, .kind]' <<<"$output")" \
    '["conventioner-2",true,312400000,"T7","dev"]'
  assert_equal "$(jq -c '.volumes[] | select(.name == "nmtest-1895520_mongodb_data") | .attached' <<<"$output")" false
  assert_equal "$(jq '.volumes | length' <<<"$output")" 12
  assert_read_only
}

@test "ls --all --json classifies images by the registry's images and legacy_images, in use or not" {
  run_bin -0 team-stack ls --all --json
  assert_equal "$(jq -c '[.images[] | [.repository, .tag, .class, .in_use, .dangling, .size_bytes]]' <<<"$output")" \
    '[["conventioner/backend","4943b69bbb33","team",true,false,534000000],["conventioner/frontend","2a5cc542bea3","team",true,false,397000000],["nmtest-12822-backend","latest","legacy",true,false,534000000],["<none>","<none>","unowned",false,true,397000000],["conventioner-backend","latest","unowned",false,false,534000000],["conventioner-frontend","latest","unowned",true,false,640000000],["mongo","7","unowned",true,false,867000000]]'
  assert_equal "$(jq -r '.images[0].id' <<<"$output")" "$(jq -r '.[0].ID' "$DOCKER_STATE/images.json")"
}

@test "ls --all --json classifies networks by their labels or their project" {
  run_bin -0 team-stack ls --all --json
  assert_equal "$(jq -c '[.networks[] | [.name, .class, .project]]' <<<"$output")" \
    '[["conventioner-2_conventioner_network","team","conventioner-2"],["nmtest-12822_conventioner_network","gate","nmtest-12822"],["nmtest-1895520_conventioner_network","gate","nmtest-1895520"],["bridge","unowned",null],["conventioner_conventioner_network","unowned","conventioner"],["host","unowned",null],["none","unowned",null]]'
}

@test "ls --all adds one line per group of volumes, images and networks, with totals" {
  run_bin -0 team-stack ls --all
  local text
  text=$(sed -n '/^VOLUMES/,$p' <<<"$output" | sed -E 's/ +/ /g')
  assert_equal "$text" "VOLUMES COUNT ATTACHED SIZE
team 3 3 312.4 MB
gate 3 2 509.1 MB
unowned 4 3 1.5 GB
anonymous 2 0 210.9 MB

IMAGES REPOSITORY TAGS IN USE SIZE
team conventioner/backend 1 1 534.0 MB
team conventioner/frontend 1 1 397.0 MB
legacy nmtest-12822-backend 1 1 534.0 MB
unowned <none> 1 0 397.0 MB
unowned conventioner-backend 1 0 534.0 MB
unowned conventioner-frontend 1 1 640.0 MB
unowned mongo 1 1 867.0 MB

NETWORKS COUNT
team 1
gate 2
unowned 4"
  # The projects come first, then a blank line.
  [[ ${lines[0]} == PROJECT* && ${lines[6]} == nmtest-1895520* ]]
  assert_equal "$(sed -n 8p <<<"$output")" ""
  assert_read_only
}

@test "an image repository's tags are counted together, in use when any is" {
  docker_state images '. + [.[0] | .ID = "sha256:\("1" * 64)" | .Tag = "e95a57a7410f" | .Containers = "0"]'
  run_bin -0 team-stack ls --all
  [[ $(grep -E '^team +conventioner/backend ' <<<"$output" | sed -E 's/ +/ /g') == "team conventioner/backend 2 1 1.1 GB" ]]
}

@test "without stack blocks in the registry nothing is a legacy gate and every image is unowned" {
  sed -i '/^\[conventioner.stack\]$/,/^$/d' "$TEAM_HOME/projects.toml"
  sed -i '/^\[shop.stack\]$/,$d' "$TEAM_HOME/projects.toml"
  run_bin -0 team-project --check
  run_bin -0 team-stack ls --all --json
  assert_equal "$(jq -r '.projects[] | select(.name == "nmtest-12822") | .class' <<<"$output")" unowned
  assert_equal "$(jq -r '.projects[] | select(.name == "nmtest-1895520") | .class' <<<"$output")" gate
  assert_equal "$(jq -c '[.images[].class] | unique' <<<"$output")" '["unowned"]'
}

@test "a registry that fails its check is refused with its problems" {
  echo 'colour = "blue"' >>"$TEAM_HOME/projects.toml"
  run_bin -1 --separate-stderr team-stack ls
  assert_equal "$output" ""
  assert_contains "$stderr" "unknown key 'colour'"
}

@test "a machine with no projects prints nothing, and empty lists with --json" {
  docker_empty
  run_bin -0 --separate-stderr team-stack ls
  assert_equal "$output$stderr" ""
  run_bin -0 --separate-stderr team-stack ls --all
  assert_equal "$output$stderr" ""
  run_bin -0 team-stack ls --json
  assert_equal "$(jq -c . <<<"$output")" '{"projects":[]}'
  run_bin -0 team-stack ls --all --json
  assert_equal "$(jq -c . <<<"$output")" '{"projects":[],"volumes":[],"images":[],"networks":[]}'
  # With no container, nothing is inspected and no stats are read.
  assert_equal "$(docker_calls | grep -E '^(inspect --type container|stats)' || true)" ""
}

@test "Docker not answering is exit 1 with its reason" {
  docker_down
  run_bin -1 --separate-stderr team-stack ls
  assert_equal "$output" ""
  assert_equal "$stderr" "team-stack: Docker does not answer: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
  run_bin -1 --separate-stderr team-stack ls --all --json
  assert_equal "$output" ""
  assert_contains "$stderr" "Docker does not answer"
}

@test "a docker call that fails after the first is exit 1 naming the call and its reason" {
  docker_fail 'system df' 'Error response from daemon: a disk usage operation is already running'
  run_bin -1 --separate-stderr team-stack ls --all
  assert_equal "$output" ""
  assert_equal "$stderr" "team-stack: docker system df failed: Error response from daemon: a disk usage operation is already running"
}

@test "a container gone between the listing and its inspection is left out" {
  # Docker answers the ones it still has, and an error for the one it lost.
  docker_vanish "$(printf 'f%.0s' {1..64})"
  run_bin -0 --separate-stderr team-stack ls --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -r '[.projects[].name] | join(" ")' <<<"$output")" \
    "conventioner conventioner-2 conventioner-3 conventioner-4 nmtest-12822 nmtest-1895520"
}

@test "hundreds of volumes are inspected 500 to a call" {
  docker_state volumes '. + [range(989) as $i | .[9] | .Name = ("\($i)" | ("0" * (64 - length)) + .)]'
  run_bin -0 team-stack ls --all --json
  assert_equal "$(jq '.volumes | length' <<<"$output")" 1001
  assert_equal "$(jq '[.volumes[] | select(.class == "anonymous")] | length' <<<"$output")" 991
  assert_equal "$(docker_calls | grep -c '^inspect --type volume ')" 3
}

@test "another subcommand, a missing one or an unknown option is a usage error naming the subcommands" {
  run_bin -2 --separate-stderr team-stack up
  assert_equal "$stderr" "team-stack: unknown subcommand 'up'; the subcommands are: ls"
  run_bin -2 --separate-stderr team-stack
  assert_equal "$stderr" "team-stack: usage: team-stack ls [--all] [--json]"
  run_bin -2 --separate-stderr team-stack ls --bogus
  assert_equal "$stderr" "team-stack: usage: team-stack ls [--all] [--json]"
  assert_equal "$(docker_calls)" ""
}

@test "--help prints the header" {
  run_bin -0 team-stack --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-stack")"
  assert_contains "$output" "team-stack ls [--all] [--json]"
}

# Every removal names its object, so no team script prunes (sops/docker.md).
@test "team-stack runs no prune command" {
  if grep -nE 'docker[^|;&]*(system|volume|image|network|builder|buildx|container) prune' "$REPO_ROOT/bin/team-stack"; then
    echo "bin/team-stack prunes" >&2
    return 1
  fi
}
