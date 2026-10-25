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

@test "a gate run started from a task's shell is a gate stack, though owner=agent-team" {
  # nm-test.sh sets owner=agent-team and the task whenever TEAM_TASK is in its environment, as
  # after eval "$(team-stack env)".
  local relabel='select(.["com.docker.compose.project"] == "nmtest-1895520")
    |= (.["io.github.chanjdaniel.team.owner"] = "agent-team" | .["io.github.chanjdaniel.team.task"] = "T7")'
  docker_state containers ".[].Config.Labels |= ($relabel)"
  docker_state volumes ".[].Labels |= ($relabel)"
  docker_state networks ".[].Labels |= ($relabel)"
  run_bin -0 team-stack ls --all --json
  assert_equal "$(jq -c '.projects[] | select(.name == "nmtest-1895520") | [.class, .owner, .task, .kind]' <<<"$output")" \
    '["gate","agent-team","T7","gate"]'
  assert_equal "$(class_of volumes nmtest-1895520_mongodb_data)" gate
  assert_equal "$(class_of networks nmtest-1895520_conventioner_network)" gate
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
  run_bin -2 --separate-stderr team-stack start
  assert_equal "$stderr" "team-stack: unknown subcommand 'start'; the subcommands are: ls, up, env, seed, stop, down, sweep"
  run_bin -2 --separate-stderr team-stack
  assert_equal "$stderr" "team-stack: usage: team-stack ls|up|env|seed|stop|down|sweep [options]; team-stack --help says more"
  run_bin -2 --separate-stderr team-stack ls --bogus
  assert_equal "$stderr" "team-stack: usage: team-stack ls [--all] [--json]"
  run_bin -2 --separate-stderr team-stack up --bogus
  assert_equal "$stderr" "team-stack: usage: team-stack up [--worktree <path>] [--task T<n>] [--no-seed]"
  run_bin -2 --separate-stderr team-stack up --task 22
  assert_equal "$stderr" "team-stack: --task must look like T<n>, got '22'"
  local cmd
  for cmd in env seed stop down; do
    run_bin -2 --separate-stderr team-stack "$cmd" --task T22
    assert_equal "$stderr" "team-stack: usage: team-stack $cmd [--worktree <path>]"
    run_bin -2 --separate-stderr team-stack "$cmd" --worktree
    assert_equal "$stderr" "team-stack: usage: team-stack $cmd [--worktree <path>]"
  done
  assert_equal "$(docker_calls)" ""
}

@test "--help prints the header" {
  run_bin -0 team-stack --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-stack")"
  assert_contains "$output" "team-stack ls [--all] [--json]"
  assert_contains "$output" "team-stack up [--worktree <path>] [--task T<n>] [--no-seed]"
}

# Every removal names its object, so no team script prunes (sops/docker.md).
@test "team-stack runs no prune command" {
  if grep -nE 'docker[^|;&]*(system|volume|image|network|builder|buildx|container) prune' "$REPO_ROOT/bin/team-stack"; then
    echo "bin/team-stack prunes" >&2
    return 1
  fi
}

# up, env, seed, stop and down, on the fixture project's worktree, whose wrapper's stack is
# stackfix-shop-1.

PROJECT=stackfix-shop-1

# The ledger opens <task> in the fixture project with the worktree <path> (default the fixture's).
open_task() {
  jq -cn --arg t "$1" --arg wt "${2:-$STACK_WORKTREE}" '{ts: "2026-10-24T09:00:00Z", task: $t, event: "opened",
    project: "shop", path: "feature", type: "feature", title: "A task", branch: "work", base: "main",
    base_sha: "0000000", worktree: $wt}' >>"$TEAM_HOME/ledger.jsonl"
}

# The ledger gets the event <event> of <task>, with the fields of the JSON object <fields>.
task_event() {
  jq -cn --arg t "$1" --arg e "$2" --argjson f "${3:-{\}}" '{ts: "2026-10-24T10:00:00Z", task: $t, event: $e} + $f' \
    >>"$TEAM_HOME/ledger.jsonl"
}

# Start the fixture's stack by hand, as an agent would with the wrapper, with the TEAM_* labels
# <name>=<value>... (none: a hand-made, unowned stack).
hand_stack() {
  (cd "$STACK_WORKTREE" && env "$@" TH_DIR="$STACK_WORKTREE" scripts/compose.sh up -d --wait) >/dev/null
}

# The team labels of the fixture stack's container, compact: {owner, task, kind, worktree, expires}.
stack_labels() {
  jq -c --arg name "/$PROJECT-web-1" '.[] | select(.Name == $name) | .Config.Labels
    | with_entries(select(.key | startswith("io.github.chanjdaniel.team.")) | .key |= ltrimstr("io.github.chanjdaniel.team."))
    | {owner, task, kind, worktree, expires}' "$DOCKER_STATE/containers.json"
}

# The names of the fixture stack's objects left: containers, volumes (named, and the anonymous
# ones its containers mounted, given as <anonymous...>) and networks, one per line.
stack_left() {
  jq -r --arg p "$PROJECT" '.[] | select(.Config.Labels["com.docker.compose.project"] == $p) | .Name' "$DOCKER_STATE/containers.json"
  jq -r --arg p "$PROJECT" '.[] | select(.Labels["com.docker.compose.project"] == $p or (.Name | IN($ARGS.positional[]))) | .Name' \
    "$DOCKER_STATE/volumes.json" --args "$@"
  jq -r --arg p "$PROJECT" '.[] | select(.Labels["com.docker.compose.project"] == $p) | .Name' "$DOCKER_STATE/networks.json"
}

# The fixture stack's anonymous volume, the one its web container mounts at /cache.
stack_anonymous() {
  jq -r --arg name "/$PROJECT-web-1" '.[] | select(.Name == $name) | .Mounts[] | select(.Destination == "/cache") | .Name' \
    "$DOCKER_STATE/containers.json"
}

# The compose calls team-stack made since the call numbered <n> (1-based), as docker_compose_env.
compose_env_since() {
  docker_compose_env | tail -n "+$1"
}

@test "up starts the worktree's stack, labelled with the task the ledger gives the worktree, and seeds its new database" {
  open_task T22
  cd "$STACK_WORKTREE/scripts"
  run_bin -0 --separate-stderr team-stack up
  assert_equal "$(stack_labels)" "$(jq -cn --arg wt "$STACK_WORKTREE" '{owner: "agent-team", task: "T22", kind: "dev", worktree: $wt, expires: ""}')"
  local port
  port=$(jq -r --arg name "/$PROJECT-web-1" '.[] | select(.Name == $name) | .NetworkSettings.Ports["80/tcp"][0].HostPort' "$DOCKER_STATE/containers.json")
  assert_contains "$stderr" "seeded $PROJECT on port $port for T22 from $STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT is up for T22, seeded: a new database"
  # The named volume and the network carry the task's labels too.
  assert_equal "$(jq -r --arg n "${PROJECT}_data" '.[] | select(.Name == $n) | .Labels["io.github.chanjdaniel.team.task"]' "$DOCKER_STATE/volumes.json")" T22
  assert_equal "$(jq -r --arg n "${PROJECT}_default" '.[] | select(.Name == $n) | .Labels["io.github.chanjdaniel.team.task"]' "$DOCKER_STATE/networks.json")" T22
  # Through the wrapper: its config for the project, then (after admission counted the running
  # projects) up, then its ports for the seed.
  assert_equal "$(docker_compose_env | jq -r '.call | sub(" -f [^ ]+"; "")')" "compose config --format json
compose ls --format json
compose up -d --wait
compose port web 80"
  # The other stacks are untouched.
  assert_equal "$(docker_calls | grep -E '^compose -p ' || true)" ""
}

@test "up takes --task when the ledger gives the worktree to no open task" {
  open_task T9 "$HOME/elsewhere"
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --task T9
  assert_equal "$(stack_labels | jq -r .task)" T9
}

@test "up with no task for the worktree is refused, and so is --task naming a task that is not open" {
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no open task holds $STACK_WORKTREE in the ledger; name one with --task T<n>"
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --task T9
  assert_equal "$stderr" "team-stack: T9 is not open: the ledger has no opened event for it"
  # A returned worktree is no longer the task's.
  open_task T22
  task_event T22 worktree-returned "$(jq -cn --arg wt "$STACK_WORKTREE" '{project: "shop", worktree: $wt}')"
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_contains "$stderr" "no open task holds $STACK_WORKTREE"
  # A closed task holds nothing, and --task cannot name it.
  open_task T5
  task_event T5 closed '{"archive": [], "returned": [], "kept": []}'
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_contains "$stderr" "no open task holds $STACK_WORKTREE"
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --task T5
  assert_equal "$stderr" "team-stack: T5 is closed"
  assert_equal "$(docker_calls)" ""
}

@test "up compares the ledger's worktree by real path, and refuses a --task that disagrees with it" {
  # Recorded under another machine's home, through a symlink: the same worktree.
  ln -s "$HOME/worktrees" "$HOME/linked"
  open_task T22 /home/someone/linked/shop-1
  open_task T9 "$HOME/elsewhere"
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --task T9
  assert_equal "$stderr" "team-stack: the ledger gives $STACK_WORKTREE to T22, but --task names T9"
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --task T22
  assert_equal "$(stack_labels | jq -r .task)" T22
}

@test "every subcommand refuses a primary checkout, naming Daniel's primary stack" {
  open_task T22
  local cmd
  for cmd in up env seed stop down; do
    run_bin -1 --separate-stderr team-stack "$cmd" --worktree "$STACK_PRIMARY"
    assert_equal "$stderr" "team-stack: $STACK_PRIMARY is a primary checkout, whose stack is Daniel's primary stack, which team-stack never starts, uses or removes; run it in a task's linked worktree"
  done
  assert_equal "$(docker_calls)" ""
}

@test "a worktree of no registered project, or of a project without a stack block, is refused" {
  local other
  other=$(make_repo other)
  git -C "$other" worktree add -q -b work "$HOME/worktrees/other-1"
  run_bin -1 --separate-stderr team-stack down --worktree "$HOME/worktrees/other-1"
  assert_equal "$stderr" "team-stack: $HOME/worktrees/other-1 is a worktree of $other, which is no project's primary checkout in projects.toml"
  sed -i '/^\[shop.stack\]$/,$d' "$TEAM_HOME/projects.toml"
  run_bin -1 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: shop has no stack block in projects.toml, so team-stack manages no stacks of it"
  run_bin -1 --separate-stderr team-stack env --worktree "$HOME"
  assert_equal "$stderr" "team-stack: $HOME is not a git worktree"
  assert_equal "$(docker_calls)" ""
}

@test "a stack that is not the team's is refused by every subcommand, naming it and its class" {
  open_task T22
  hand_stack
  local before cmd
  before=$(docker_calls | wc -l)
  for cmd in up env seed stop down; do
    run_bin -1 --separate-stderr team-stack "$cmd" --worktree "$STACK_WORKTREE"
    assert_equal "$stderr" "team-stack: $PROJECT is not the team's (class unowned), so team-stack leaves it alone: team-stack ls shows it, and removing it is Daniel's or the coordinator's call"
  done
  # Only reads since: nothing started, stopped or removed.
  assert_equal "$(docker_calls | tail -n "+$((before + 1))" | grep -Ev "$READ_ONLY|config --format json" || true)" ""
  assert_equal "$(stack_labels | jq -r .owner)" ""
}

@test "up takes down a team stack of another task first, its logs saved under that task, and starts a fresh one" {
  hand_stack TEAM_OWNER=agent-team TEAM_TASK=T7 TEAM_KIND=dev TEAM_WORKTREE="$STACK_WORKTREE" TEAM_EXPIRES=
  local old_anonymous
  old_anonymous=$(stack_anonymous)
  open_task T22
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_contains "$stderr" "$PROJECT is T7's: taking it down first"
  assert_equal "$(cat "$STACK_WORKTREE/.scratch/task/stack-logs/T7-$PROJECT-web.log")" \
    "web-1  | 2026-10-24T09:00:00.000000000Z $PROJECT's web started"
  [[ ! -e $STACK_WORKTREE/.scratch/task/stack-logs/$PROJECT-web.log ]]
  assert_contains "$(docker_calls)" "compose -p $PROJECT down -v --remove-orphans"
  # T7's anonymous volume went with it, and every object of the new stack is T22's.
  assert_equal "$(jq -r --arg n "$old_anonymous" '.[] | select(.Name == $n) | .Name' "$DOCKER_STATE/volumes.json")" ""
  assert_equal "$(stack_labels | jq -r .task)" T22
  assert_equal "$(jq -r --arg n "${PROJECT}_data" '.[] | select(.Name == $n) | .Labels["io.github.chanjdaniel.team.task"]' "$DOCKER_STATE/volumes.json")" T22
  assert_contains "$output" "seeded: a new database"
}

@test "an up of the task's stopped stack starts it again with its data, and does not seed" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
  local volume_created
  volume_created=$(jq -r --arg n "${PROJECT}_data" '.[] | select(.Name == $n) | .CreatedAt' "$DOCKER_STATE/volumes.json")
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE"
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT is up for T22, not seeded: its database was there"
  [[ $stderr != *seeded* ]]
  assert_equal "$(jq -r --arg n "${PROJECT}_data" '.[] | select(.Name == $n) | .CreatedAt' "$DOCKER_STATE/volumes.json")" "$volume_created"
  assert_equal "$(jq -r --arg n "/$PROJECT-web-1" '.[] | select(.Name == $n) | .State.Status' "$DOCKER_STATE/containers.json")" running
  assert_equal "$(docker_calls | grep -c ' down ' || true)" 0
}

@test "up --no-seed starts a new stack without seeding it" {
  open_task T22
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$output" "team-stack: $PROJECT is up for T22, not seeded: --no-seed"
  [[ $stderr != *seeded* ]]
  assert_equal "$(docker_compose_env | jq -r '.call' | grep -c port || true)" 0
}

@test "every wrapper call for an existing stack passes the labels read back from its containers, whatever the caller exports" {
  open_task T22
  # Started by an older team-stack with an expiry and the worktree's path as another spelling.
  hand_stack TEAM_OWNER=agent-team TEAM_TASK=T22 TEAM_KIND=dev TEAM_WORKTREE="$STACK_WORKTREE/" TEAM_EXPIRES=2026-10-25T00:00:00Z
  local labels n
  labels=$(stack_labels)
  n=$(($(docker_compose_env | wc -l) + 1))
  export TEAM_OWNER=someone TEAM_TASK=T7 TEAM_KIND=gate TEAM_WORKTREE=/elsewhere TEAM_EXPIRES=never
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
  run_bin -0 team-stack env --worktree "$STACK_WORKTREE"
  run_bin -0 team-stack seed --worktree "$STACK_WORKTREE"
  # The config call, which finds the project, sees no labels; every later one the stack's own.
  assert_equal "$(compose_env_since "$n" | jq -c 'select(.call | test(" config ")) | .labels | map_values(. // "") | [.[]] | unique')" '[""]
[""]
[""]'
  assert_equal "$(compose_env_since "$n" | jq -c 'select(.call | test(" config ") | not) | .labels' | sort -u)" "$labels"
  assert_equal "$(stack_labels)" "$labels"
  # A recreation would have made a new container.
  assert_equal "$(jq '[.[] | select(.Name == "/'"$PROJECT"'-web-1")] | length' "$DOCKER_STATE/containers.json")" 1
}

@test "env prints the exports that reach the stack, and a stack that is not running is exit 1 with the reason" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  local port
  port=$(jq -r --arg name "/$PROJECT-web-1" '.[] | select(.Name == $name) | .NetworkSettings.Ports["80/tcp"][0].HostPort' "$DOCKER_STATE/containers.json")
  run_bin -0 --separate-stderr team-stack env --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" ""
  assert_equal "$output" "export COMPOSE_PROJECT_NAME=$PROJECT
export TH_WEB_PORT=$port
export TEAM_OWNER=agent-team
export TEAM_TASK=T22
export TEAM_KIND=dev
export TEAM_WORKTREE=$STACK_WORKTREE
export TEAM_EXPIRES=''"
  assert_equal "$(eval "$output"; env | grep -E '^(COMPOSE_PROJECT_NAME|TH_WEB_PORT|TEAM_TASK|TEAM_EXPIRES)=' | LC_ALL=C sort)" \
    "COMPOSE_PROJECT_NAME=$PROJECT
TEAM_EXPIRES=
TEAM_TASK=T22
TH_WEB_PORT=$port"
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE"
  run_bin -1 --separate-stderr team-stack env --worktree "$STACK_WORKTREE"
  assert_equal "$output" ""
  assert_equal "$stderr" "team-stack: $PROJECT is not running (compose.sh: $PROJECT's web is not running); start it with team-stack up"
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  run_bin -1 --separate-stderr team-stack env --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: $PROJECT has no stack; start it with team-stack up"
}

@test "seed runs the project's seed command from the worktree with env's exports" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 --separate-stderr team-stack seed --worktree "$STACK_WORKTREE"
  assert_contains "$output" "seeded $PROJECT on port "
  assert_contains "$output" " for T22 from $STACK_WORKTREE"
  printf '#!/usr/bin/env bash\necho "half seeded"\nexit 3\n' >"$STACK_WORKTREE/scripts/seed.sh"
  run_bin -1 --separate-stderr team-stack seed --worktree "$STACK_WORKTREE"
  assert_equal "$output" "half seeded"
  assert_equal "$stderr" "team-stack: the seed command scripts/seed.sh failed (exit 3) for $PROJECT"
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE"
  run_bin -1 --separate-stderr team-stack seed --worktree "$STACK_WORKTREE"
  assert_contains "$stderr" "$PROJECT is not running"
}

@test "stop stops the stack and keeps its data, and with no stack says so" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 --separate-stderr team-stack stop --worktree "$STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT is stopped, its data kept"
  assert_contains "$(docker_calls)" "compose -p $PROJECT stop"
  assert_equal "$(jq -r --arg n "/$PROJECT-web-1" '.[] | select(.Name == $n) | .State.Status' "$DOCKER_STATE/containers.json")" exited
  assert_equal "$(stack_left)" "/$PROJECT-web-1
${PROJECT}_data
${PROJECT}_default"
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  run_bin -0 --separate-stderr team-stack stop --worktree "$STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT has no stack, so there is nothing to stop"
}

@test "down saves the logs into the task directory, then removes the stack with every volume and network" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  local anonymous
  anonymous=$(stack_anonymous)
  [[ -n $anonymous ]]
  run_bin -0 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT is removed, its logs in $STACK_WORKTREE/.scratch/task/stack-logs"
  assert_equal "$(cat "$STACK_WORKTREE/.scratch/task/stack-logs/$PROJECT-web.log")" \
    "web-1  | 2026-10-24T09:00:00.000000000Z $PROJECT's web started"
  assert_equal "$(stack_left "$anonymous")" ""
  assert_contains "$(docker_calls)" "compose -p $PROJECT logs --no-color --timestamps web"
  assert_contains "$(docker_calls)" "compose -p $PROJECT down -v --remove-orphans"
  # Nothing was left for it to remove by hand.
  assert_equal "$(docker_calls | grep -c '^volume rm' || true)" 0
  # Nothing else went.
  run_bin -0 team-stack ls --json
  assert_equal "$(jq -r '[.projects[].name] | join(" ")' <<<"$output")" \
    "conventioner conventioner-2 conventioner-3 conventioner-4 nmtest-12822 nmtest-1895520"
}

@test "down keeps the last 1 MiB of a service's log" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  mkdir -p "$DOCKER_STATE/logs"
  { head -c 1600000 < <(yes 'web-1  | 2026-10-24T09:00:00.000000000Z a line of the log'); echo; echo 'web-1  | the last line'; } \
    >"$DOCKER_STATE/logs/$PROJECT-web.log"
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  local log=$STACK_WORKTREE/.scratch/task/stack-logs/$PROJECT-web.log
  assert_equal "$(stat -c %s "$log")" 1048576
  assert_equal "$(tail -n 1 "$log")" "web-1  | the last line"
  cmp -s "$log" <(tail -c 1048576 "$DOCKER_STATE/logs/$PROJECT-web.log")
}

@test "down removes the anonymous volumes its containers mounted that compose down left behind" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  local anonymous
  anonymous=$(stack_anonymous)
  docker_leak anonymous
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  assert_contains "$(docker_calls)" "volume rm $anonymous"
  assert_equal "$(stack_left "$anonymous")" ""
}

@test "down fails naming each object of the stack left after it" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  local anonymous
  anonymous=$(stack_anonymous)
  docker_leak anonymous
  docker_leak network
  docker_fail 'volume rm' "Error response from daemon: remove $anonymous: volume is in use"
  run_bin -1 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: docker volume rm failed: Error response from daemon: remove $anonymous: volume is in use
team-stack: $PROJECT is not all gone after its down: volume $anonymous, network ${PROJECT}_default"
}

@test "down with no stack says so and exits 0" {
  run_bin -0 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT has no stack, so there is nothing to remove"
  assert_equal "$(docker_calls | grep -Ev "$READ_ONLY|config --format json" || true)" ""
}

@test "an exported stack identity never redirects a call to another stack" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  local n
  n=$(($(docker_compose_env | wc -l) + 1))
  # As after eval "$(team-stack env)" in another worktree, or a gate's identity.
  export COMPOSE_PROJECT_NAME=conventioner-2 TH_PORTS=auto TH_WEB_PORT=5999 TH_BACKEND_PORT=5020 COMPOSE_FILE=/elsewhere.yml
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$(compose_env_since "$n" | jq -r '"\(.project) \(.TH_PORTS // "unset")"' | sort -u)" "$PROJECT unset"
  assert_equal "$(stack_left)" ""
  run_bin -0 team-stack ls --json
  assert_equal "$(jq -r '.projects[] | select(.name == "conventioner-2") | .status' <<<"$output")" "running(2)"
}

# Admission: up starts a new stack only within the machine's cap and floors, or team-capacity's
# yes. The fixture machine runs three Compose projects (conventioner-2, conventioner-3 and
# nmtest-1895520), the fixture stack's limits add up to 64 MiB, and docker_stub gives 24 GiB of
# memory available and 200 GiB of disk free.

# Write the machine's stack settings, ~/.config/agent-team/stack.json: stack_settings <JSON>
stack_settings() {
  mkdir -p "$HOME/.config/agent-team"
  printf '%s\n' "$1" >"$HOME/.config/agent-team/stack.json"
}

# The admission waits logged, one compact JSON object per line.
waits_log() {
  jq -c . "$HOME/.local/state/agent-team/stacks/waits.jsonl" 2>/dev/null || true
}

# How many times the fixture stack was started.
ups() {
  docker_calls | grep -c '^compose -f [^ ]* up -d --wait$' || true
}

@test "up under the cap and above both floors starts the stack at once, without a wait" {
  open_task T22
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT is up for T22, seeded: a new database"
  [[ $stderr != *room* ]]
  assert_equal "$(ups)" 1
  # It counted the running projects and read Docker's root, whose file system df measured.
  assert_contains "$(docker_calls)" "compose ls --format json"
  assert_contains "$(docker_calls)" "info --format json"
  assert_equal "$(stub_calls df)" '["-Pk","/var/lib/docker"]'
  assert_equal "$(waits_log)" ""
}

@test "up at the cap, counting every owner's running projects, exits 75 naming the cap and starts nothing" {
  open_task T22
  stack_settings '{"stack_cap": 3, "wait_minutes": 0}'
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: 3 of 3 stacks running (stack_cap 3)"
  assert_equal "$output" ""
  assert_equal "$(ups)" 0
  # One fewer running project is room.
  docker_state containers 'map(select(.Name != "/conventioner-3-backend-1"))'
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$(ups)" 1
}

@test "up refuses when the memory left after the stack's limits is under memory_floor_gib" {
  open_task T22
  stack_settings '{"wait_minutes": 0}'
  machine_memory $((6 * 1024 * 1024))
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: 5.9 GiB available after this stack's 0.1 GiB (memory_floor_gib 6)"
  assert_equal "$(ups)" 0
  stack_settings '{"wait_minutes": 0, "memory_floor_gib": 5.5}'
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
}

@test "up refuses when the free disk of Docker's root is under disk_floor_gb" {
  open_task T22
  stack_settings '{"wait_minutes": 0}'
  machine_disk_free $((20000000000 / 1024))
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: 20.0 GB free on the file system of /var/lib/docker (disk_floor_gb 30)"
  assert_equal "$(ups)" 0
  stack_settings '{"wait_minutes": 0, "disk_floor_gb": 20}'
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
}

@test "with every check failing, the refusal names each with its numbers, and the waits log has them" {
  open_task T22
  stack_settings '{"stack_cap": 2, "memory_floor_gib": 8, "disk_floor_gb": 300, "wait_minutes": 0}'
  machine_memory $((4 * 1024 * 1024))
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  local reasons='["3 of 2 stacks running (stack_cap 2)","3.9 GiB available after this stack'"'"'s 0.1 GiB (memory_floor_gib 8)","214.7 GB free on the file system of /var/lib/docker (disk_floor_gb 300)"]'
  assert_equal "$stderr" "team-stack: no room for $PROJECT: $(jq -r 'join("; ")' <<<"$reasons")"
  # wait_minutes 0: no wait announced, one wait logged, not admitted.
  assert_equal "$(waits_log | wc -l)" 1
  assert_equal "$(waits_log | jq -c '[.project, .task, .admitted, .reasons]')" "[\"$PROJECT\",\"T22\",false,$reasons]"
  assert_equal "$(waits_log | jq -c '[.start, .end] | map(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))')" '[true,true]'
}

@test "a refused up says once that it waits and why, re-checks, and starts the stack when room comes" {
  open_task T22
  stack_settings '{"wait_minutes": 1}'
  # The disk is short for two checks, then has room.
  machine_disk_free 1000 1000 $((200 * 1024 * 1024))
  TEAM_STACK_RECHECK_SECONDS=1 run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$(grep -c 'no room' <<<"$stderr")" 1
  assert_contains "$stderr" "team-stack: no room for $PROJECT yet, waiting up to 1 minutes: 0.0 GB free on the file system of /var/lib/docker (disk_floor_gb 30)"
  assert_equal "$output" "team-stack: $PROJECT is up for T22, seeded: a new database"
  assert_equal "$(stub_calls df | wc -l)" 3
  assert_equal "$(waits_log | jq -c '[.admitted, .reasons]')" '[true,["0.0 GB free on the file system of /var/lib/docker (disk_floor_gb 30)"]]'
  local start end
  start=$(waits_log | jq '.start | fromdate')
  end=$(waits_log | jq '.end | fromdate')
  ((end - start >= 2))
}

@test "a wait that runs out exits 75 with every failing check, and logs the wait" {
  open_task T22
  stack_settings '{"stack_cap": 3, "wait_minutes": 0.03}'
  TEAM_STACK_RECHECK_SECONDS=1 run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT yet, waiting up to 0.03 minutes: 3 of 3 stacks running (stack_cap 3)
team-stack: no room for $PROJECT: 3 of 3 stacks running (stack_cap 3)"
  ((${#lines[@]} == 0))
  # Checked at the start and again after a second at least, within the wait's 2 s.
  local checks
  checks=$(docker_calls | grep -c '^compose ls --format json$')
  ((checks >= 2 && checks <= 3))
  assert_equal "$(waits_log | jq -c '[.admitted, .reasons]')" '[false,["3 of 3 stacks running (stack_cap 3)"]]'
  assert_equal "$(ups)" 0
}

@test "the admission lock is held through up -d --wait and released before the seed" {
  open_task T22
  local lock=$HOME/.local/state/agent-team/stacks.lock
  local log=$BATS_TEST_TMPDIR/lock
  # The wrapper's up and the seed each try the lock.
  mv "$STACK_WORKTREE/scripts/compose.sh" "$STACK_WORKTREE/scripts/compose-real.sh"
  cat >"$STACK_WORKTREE/scripts/compose.sh" <<SH
#!/usr/bin/env bash
if [[ \${1:-} == up ]]; then if flock -n "$lock" true; then echo free; else echo held; fi >>"$log"; fi
exec "\$(dirname "\$0")/compose-real.sh" "\$@"
SH
  chmod +x "$STACK_WORKTREE/scripts/compose.sh"
  printf 'if flock -n %q true; then echo free; else echo held; fi >>%q\n' "$lock" "$log" >>"$STACK_WORKTREE/scripts/seed.sh"
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/lock")" "held
free"
}

@test "two ups racing for the last place start exactly one stack, and the other exits 75" {
  open_task T22
  local first=$STACK_WORKTREE
  stack_project mall
  open_task T23 "$STACK_WORKTREE"
  stack_settings '{"stack_cap": 4, "wait_minutes": 0}'
  local dir=$BATS_TEST_TMPDIR a b
  "$REPO_ROOT/bin/team-stack" up --worktree "$first" --no-seed >"$dir/a.out" 2>"$dir/a.err" &
  a=$!
  "$REPO_ROOT/bin/team-stack" up --worktree "$STACK_WORKTREE" --no-seed >"$dir/b.out" 2>"$dir/b.err" &
  b=$!
  local status_a=0 status_b=0
  wait "$a" || status_a=$?
  wait "$b" || status_b=$?
  assert_equal "$(printf '%s\n' "$status_a" "$status_b" | sort -n | paste -sd ' ')" "0 75"
  assert_equal "$(ups)" 1
  assert_contains "$(cat "$dir/a.err" "$dir/b.err")" "4 of 4 stacks running (stack_cap 4)"
}

@test "a re-up of a running stack is admitted without a check, and a stopped one is counted as new" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
  stack_settings '{"stack_cap": 1, "wait_minutes": 0}'
  local before
  before=$(docker_calls | wc -l)
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$(docker_calls | tail -n "+$((before + 1))" | grep -cE '^(compose ls|info)( |$)' || true)" 0
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE"
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: 3 of 1 stacks running (stack_cap 1)"
}

@test "with team-capacity, its admit decides: 0 admits, 75 refuses with its reason, anything else fails" {
  open_task T22
  stack_settings '{"stack_cap": 1, "wait_minutes": 0}'
  mkdir -p "$HOME/.local/bin"
  cp "$REPO_ROOT/tests/helpers/stub" "$HOME/.local/bin/team-capacity"
  stub_reply team-capacity ""
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$(stub_calls team-capacity)" '["admit","--kind","stack:shop"]'
  # Its own checks are not made.
  assert_equal "$(docker_calls | grep -cE '^(compose ls|info)( |$)' || true)" 0
  assert_equal "$(stub_calls df)" ""
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"

  stub_script team-capacity <<'SH'
echo "2 of 2 stack tokens held" >&2
exit 75
SH
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: 2 of 2 stack tokens held"
  assert_equal "$(waits_log | jq -c '[.admitted, .reasons]')" '[false,["2 of 2 stack tokens held"]]'

  stub_script team-capacity <<'SH'
echo "team-capacity: no such kind" >&2
exit 3
SH
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: team-capacity admit --kind stack:shop failed (exit 3): team-capacity: no such kind"
  # Only the first, admitted up started it.
  assert_equal "$(ups)" 1
}

@test "team-capacity on PATH is found as well" {
  open_task T22
  cp "$REPO_ROOT/tests/helpers/stub" "$BATS_TEST_TMPDIR/stubs/team-capacity"
  stub_reply team-capacity "" 75
  stack_settings '{"wait_minutes": 0}'
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: team-capacity refused it"
}

@test "on macOS, memory is Docker's VM's total less its running containers' use, and the disk is the home directory's" {
  as_macos
  open_task T22
  stack_settings '{"wait_minutes": 0}'
  # 8 GiB less the 1061 MiB the three running projects use, less the stack's 64 MiB.
  docker_state info '.MemTotal = 8589934592'
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$(stub_calls df)" "[\"-Pk\",\"$HOME\"]"
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  stack_settings '{"wait_minutes": 0, "memory_floor_gib": 7}'
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: 6.9 GiB available after this stack's 0.1 GiB (memory_floor_gib 7)"
  machine_disk_free $((20000000000 / 1024))
  stack_settings '{"wait_minutes": 0}'
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: 20.0 GB free on the file system of $HOME (disk_floor_gb 30)"
}

@test "a malformed stack.json is exit 1 with the reason, before Docker is asked anything" {
  open_task T22
  local file=$HOME/.config/agent-team/stack.json
  stack_settings '{"stack_cap": 6,'
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_contains "$stderr" "team-stack: $file is not JSON: "
  stack_settings '[6]'
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: $file is not one JSON object"
  stack_settings '{"stack_cap": "6", "wait_minutes": -1, "heartbeat_sweep": "yes", "stack_caps": 4}'
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: $file: stack_cap must be a whole number of 1 or more, not \"6\"; wait_minutes must be a number of 0 or more, not -1; heartbeat_sweep must be true or false, not \"yes\"; stack_caps is not a setting (they are: stack_cap, memory_floor_gib, disk_floor_gb, wait_minutes, idle_minutes, heartbeat_sweep, heartbeat_janitor)"
  stack_settings '{"stack_cap": 2.5}'
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: $file: stack_cap must be a whole number of 1 or more, not 2.5"
  assert_equal "$(docker_calls)" ""
  # Every key, of the right types, is accepted.
  stack_settings '{"stack_cap": 6, "memory_floor_gib": 6, "disk_floor_gb": 30, "wait_minutes": 15, "idle_minutes": 30, "heartbeat_sweep": false, "heartbeat_janitor": false}'
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
}

# session <cwd> <status> [<kind>]: one live session as claude agents --json lists it.
session() {
  jq -cn --arg cwd "$1" --arg status "$2" --arg kind "${3:-background}" \
    '{pid: 4242, cwd: $cwd, kind: $kind, startedAt: 1761098400000, sessionId: "5e55a0b1-1111-4222-8333-444455556666",
      name: "T7-builder", status: $status, id: "5e55a0b1", state: null}'
}

# sessions [<session JSON>...]: the live session list.
sessions() {
  stub_reply claude "$(jq -cs . <<<"$*")"
}

# The projects the sweep asked Compose to stop, one per line.
stopped() {
  docker_calls | sed -n 's/^compose -p \(.*\) stop$/\1/p'
}

# The running containers of <project> started <seconds> ago: started <project> <seconds>
started() {
  docker_state containers "map(if .Config.Labels[\"com.docker.compose.project\"] == \"$1\" and .State.Running
    then .State.StartedAt = (now - $2 | todate) else . end)"
}

# The sweep's state file of <project>, holding <JSON>: sweep_state <project> <JSON>
sweep_state() {
  mkdir -p "$HOME/.local/state/agent-team/stacks"
  printf '%s\n' "$2" >"$HOME/.local/state/agent-team/stacks/$1.json"
}

# The last_busy the sweep's state file of <project> holds, as seconds before now.
busy_ago() {
  jq -r '.last_busy | now - fromdate | floor' "$HOME/.local/state/agent-team/stacks/$1.json"
}

@test "sweep keeps a stack with a busy session in its worktree, interactive ones included, and writes when it was busy" {
  sessions "$(session "$STACK_WORKTREE" busy interactive)" "$(session "$HOME/elsewhere" idle)"
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(stopped)" ""
  (($(busy_ago conventioner-2) < 60))
  assert_equal "$(jq -c 'keys' "$HOME/.local/state/agent-team/stacks/conventioner-2.json")" '["last_busy"]'
  # Only running team stacks get a state file.
  assert_equal "$(ls "$HOME/.local/state/agent-team/stacks")" conventioner-2.json
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
}

@test "sweep stops a stack whose last busy time is older than idle_minutes, logs the line and prints it, its data kept" {
  sessions "$(session "$STACK_WORKTREE" idle)"
  sweep_state conventioner-2 "{\"last_busy\": \"$(date -u -d '31 minutes ago' +%FT%TZ)\"}"
  started conventioner-2 7200
  local since
  since=$(jq -r .last_busy "$HOME/.local/state/agent-team/stacks/conventioner-2.json")
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$stderr" ""
  [[ $output =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ stopped\ conventioner-2\ of\ T7\ in\ $STACK_WORKTREE:\ last\ busy\ at\ $since\ \(idle_minutes\ 30\),\ its\ data\ kept$ ]]
  assert_equal "$(cat "$HOME/.local/state/agent-team/stacks/sweep.log")" "$output"
  assert_equal "$(stopped)" conventioner-2
  assert_equal "$(jq -r '[.[] | select(.Config.Labels["com.docker.compose.project"] == "conventioner-2") | .State.Status] | unique[]' "$DOCKER_STATE/containers.json")" exited
  # Its volumes stay.
  assert_equal "$(docker_calls | grep -E '^(compose -p [^ ]+ (down|rm)|volume rm|rm)( |$)' || true)" ""
  # A second sweep finds nothing running to stop, and adds no line.
  run_bin -0 team-stack sweep
  assert_equal "$output" ""
  assert_equal "$(stopped)" conventioner-2
  assert_equal "$(wc -l <"$HOME/.local/state/agent-team/stacks/sweep.log")" 1
}

@test "sweep keeps a stack busy within idle_minutes, though no session is busy now" {
  sessions
  sweep_state conventioner-2 "{\"last_busy\": \"$(date -u -d '29 minutes ago' +%FT%TZ)\"}"
  started conventioner-2 7200
  run_bin -0 team-stack sweep
  assert_equal "$output" ""
  assert_equal "$(stopped)" ""
}

@test "sweep counts a stack never seen busy from its containers' start: stopped when old, kept when new" {
  sessions "$(session "$STACK_WORKTREE" idle)"
  started conventioner-2 600
  stack_settings '{"idle_minutes": 15}'
  run_bin -0 team-stack sweep
  assert_equal "$output" ""
  assert_equal "$(stopped)" ""
  [[ ! -e $HOME/.local/state/agent-team/stacks/conventioner-2.json ]]
  started conventioner-2 1000
  local since
  since=$(jq -r '[.[] | select(.Config.Labels["com.docker.compose.project"] == "conventioner-2") | .State.StartedAt] | max' "$DOCKER_STATE/containers.json")
  run_bin -0 team-stack sweep
  [[ $output == *" stopped conventioner-2 of T7 in $STACK_WORKTREE: not seen busy since its start at $since (idle_minutes 15), its data kept" ]]
  assert_equal "$(stopped)" conventioner-2
}

@test "sweep counts a stack started again after its last busy time from that start" {
  sessions
  sweep_state conventioner-2 "{\"last_busy\": \"$(date -u -d '3 hours ago' +%FT%TZ)\"}"
  started conventioner-2 120
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" ""
}

@test "sweep counts a busy session in a subdirectory of the worktree, never one in a sibling path with the same prefix" {
  sessions "$(session "$STACK_WORKTREE/src/app" busy)"
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" ""
  (($(busy_ago conventioner-2) < 60))
  rm "$HOME/.local/state/agent-team/stacks/conventioner-2.json"
  sessions "$(session "$STACK_WORKTREE-2" busy)" "$(session "${STACK_WORKTREE}x/src" busy)"
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" conventioner-2
  [[ ! -e $HOME/.local/state/agent-team/stacks/conventioner-2.json ]]
}

@test "sweep never stops a gate or unowned stack, a gate run from a task's shell included, however long idle" {
  sessions
  # The gate run labelled from a shell with team-stack env's exports: owner agent-team, kind gate.
  docker_state containers '(.[] | select(.Name == "/nmtest-1895520-frontend-1") | .Config.Labels)
    |= . + {"io.github.chanjdaniel.team.owner": "agent-team", "io.github.chanjdaniel.team.task": "T7"}'
  started nmtest-1895520 86400
  started conventioner-3 86400
  run_bin -0 team-stack sweep
  # Only the idle team stack.
  assert_equal "$(stopped)" conventioner-2
  [[ ! -e $HOME/.local/state/agent-team/stacks/nmtest-1895520.json ]]
  [[ ! -e $HOME/.local/state/agent-team/stacks/conventioner-3.json ]]
  # A team project holding any object of another class is not the team's to stop either.
  docker_state containers '(.[] | select(.Name == "/conventioner-2-mongodb-1") | .Config.Labels["io.github.chanjdaniel.team.owner"]) = ""
    | (.[] | select(.Config.Labels["com.docker.compose.project"] == "conventioner-2") | .State) |= . + {Running: true, Status: "running"}'
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" conventioner-2
}

@test "sweep stops an instance's stack (kind e2e) by its worktree label like any team stack" {
  docker_state containers '(.[] | select(.Config.Labels["com.docker.compose.project"] == "conventioner-2") | .Config.Labels)
    |= . + {"io.github.chanjdaniel.team.kind": "e2e"}'
  sessions "$(session "$STACK_WORKTREE" busy)"
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" ""
  sessions
  sweep_state conventioner-2 "{\"last_busy\": \"$(date -u -d '31 minutes ago' +%FT%TZ)\"}"
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" conventioner-2
}

@test "sweep reads a missing or unreadable state file as never seen busy, and a busy session writes it anew" {
  sessions
  started conventioner-2 120
  sweep_state conventioner-2 'not json'
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$stderr" ""
  assert_equal "$(stopped)" ""
  sweep_state conventioner-2 '{"last_busy": "yesterday"}'
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" ""
  sessions "$(session "$STACK_WORKTREE" busy)"
  run_bin -0 team-stack sweep
  (($(busy_ago conventioner-2) < 60))
  sessions
  chmod 000 "$HOME/.local/state/agent-team/stacks/conventioner-2.json"
  started conventioner-2 7200
  run_bin -0 --separate-stderr team-stack sweep
  chmod 644 "$HOME/.local/state/agent-team/stacks/conventioner-2.json"
  assert_equal "$(stopped)" conventioner-2
}

@test "sweep with Docker not answering says no stack runs and exits 0, without reading the session list" {
  docker_down
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$output" "team-stack: Docker does not answer (Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?), so no stack runs and there is nothing to sweep"
  assert_equal "$(stub_calls claude)" ""
}

@test "sweep with the session list unreadable exits 1 and stops nothing" {
  stub_reply claude 'claude: not logged in' 1
  run_bin -1 --separate-stderr team-stack sweep
  assert_equal "$stderr" "team-stack: cannot read the live session list (claude agents --json)"
  assert_equal "$output" ""
  assert_equal "$(stopped)" ""
  [[ ! -e $HOME/.local/state/agent-team/stacks/sweep.log ]]
  # A list that is not a JSON array is unreadable too.
  stub_reply claude '{"sessions": []}'
  run_bin -1 team-stack sweep
  assert_equal "$(stopped)" ""
}

@test "sweep with no running team stack asks nothing of the session list" {
  docker_state containers 'map(select(.Config.Labels["com.docker.compose.project"] != "conventioner-2"))'
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$output$stderr" ""
  assert_equal "$(stub_calls claude)" ""
}

@test "a stop that fails is reported on stderr, the other stacks are still swept, and the sweep exits 1" {
  sessions
  docker_state containers '(.[] | select(.Name == "/conventioner-3-backend-1") | .Config.Labels)
    |= . + {"io.github.chanjdaniel.team.owner": "agent-team", "io.github.chanjdaniel.team.task": "T8"}'
  docker_fail 'compose stop' 'Error response from daemon: cannot stop container: permission denied'
  run_bin -1 --separate-stderr team-stack sweep
  assert_equal "$stderr" "team-stack: docker compose stop of conventioner-2 failed: Error response from daemon: cannot stop container: permission denied
team-stack: docker compose stop of conventioner-3 failed: Error response from daemon: cannot stop container: permission denied"
  assert_equal "$output" ""
  [[ ! -e $HOME/.local/state/agent-team/stacks/sweep.log ]]
}

@test "sweep takes no options, and reads idle_minutes through the checked settings" {
  run_bin -2 --separate-stderr team-stack sweep --all
  assert_equal "$stderr" "team-stack: usage: team-stack sweep"
  stack_settings '{"idle_minutes": "30"}'
  run_bin -1 --separate-stderr team-stack sweep
  assert_equal "$stderr" "team-stack: $HOME/.config/agent-team/stack.json: idle_minutes must be a number of 0 or more, not \"30\""
  assert_equal "$(docker_calls)" ""
}

@test "down removes the sweep's state file of the stack" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  sweep_state "$PROJECT" '{"last_busy": "2026-10-25T09:00:00Z"}'
  sweep_state conventioner-2 '{"last_busy": "2026-10-25T09:00:00Z"}'
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  [[ ! -e $HOME/.local/state/agent-team/stacks/$PROJECT.json ]]
  [[ -e $HOME/.local/state/agent-team/stacks/conventioner-2.json ]]
}
