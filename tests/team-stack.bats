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
  # A reading of the machine leaving the team 16 GiB, so team-capacity admit takes none.
  capacity_room $((16 * 1073741824))
}

# Fail when any docker call of the test pruned: every removal names its object.
teardown() {
  if [[ -n ${DOCKER_STATE:-} ]] && docker_calls | grep -E '(system|volume|image|network|builder|buildx|container) prune'; then
    echo "a docker call pruned" >&2
    return 1
  fi
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

# The reaper's lines that remove (or would), one per line, without their verb.
removals() {
  sed -n -E 's/^(would remove|removed) //p' <<<"$output"
}

# The reaper's kept lines without their verb and age: "<type> <name> (<class>[, <size>])".
kept() {
  sed -n -E 's/^kept (.*), [0-9]+[smhd] old\)$/\1)/p' <<<"$output"
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

@test "ls --json carries each project's memory limits, the sum of its containers' mem_limits, null with none set" {
  run_bin -0 team-stack ls --json
  assert_equal "$(jq -c '[.projects[] | [.name, .memory_limit_bytes]]' <<<"$output")" \
    '[["conventioner",null],["conventioner-2",1879048192],["conventioner-3",805306368],["conventioner-4",805306368],["nmtest-12822",null],["nmtest-1895520",536870912]]'
}

@test "ls --json carries each project's CPU, the sum of its running containers' docker stats, null with none running" {
  docker_state stats 'map(if .Name == "conventioner-2-mongodb-1" then .CPUPerc = "150.25%" else . end)'
  run_bin -0 team-stack ls --json
  assert_equal "$(jq -c '[.projects[] | [.name, .running, .cpu_percent]]' <<<"$output")" \
    '[["conventioner",0,null],["conventioner-2",2,150.37],["conventioner-3",1,0.12],["conventioner-4",0,null],["nmtest-12822",0,null],["nmtest-1895520",1,0.12]]'
  # The text form is as it was: no CPU column.
  run_bin -0 team-stack ls
  assert_equal "$(head -n 1 <<<"$output" | tr -s ' ')" "PROJECT STATUS CLASS TASK KIND WORKTREE AGE MEMORY"
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
  assert_equal "$stderr" "team-stack: unknown subcommand 'start'; the subcommands are: ls, up, env, seed, stop, down, sweep, reap"
  run_bin -2 --separate-stderr team-stack
  assert_equal "$stderr" "team-stack: usage: team-stack ls|up|env|seed|stop|down|sweep|reap [options]; team-stack --help says more"
  run_bin -2 --separate-stderr team-stack ls --bogus
  assert_equal "$stderr" "team-stack: usage: team-stack ls [--all] [--json]"
  run_bin -2 --separate-stderr team-stack up --bogus
  assert_equal "$stderr" "team-stack: usage: team-stack up [--worktree <path>] [--instance <name>] [--task T<n>] [--no-seed]"
  run_bin -2 --separate-stderr team-stack up --task 22
  assert_equal "$stderr" "team-stack: --task must look like T<n>, got '22'"
  local cmd
  for cmd in env seed stop down; do
    run_bin -2 --separate-stderr team-stack "$cmd" --task T22
    assert_equal "$stderr" "team-stack: usage: team-stack $cmd [--worktree <path>] [--instance <name>]"
    run_bin -2 --separate-stderr team-stack "$cmd" --worktree
    assert_equal "$stderr" "team-stack: usage: team-stack $cmd [--worktree <path>] [--instance <name>]"
  done
  assert_equal "$(docker_calls)" ""
}

@test "--help prints the header" {
  run_bin -0 team-stack --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-stack")"
  assert_contains "$output" "team-stack ls [--all] [--json]"
  assert_contains "$output" "team-stack up [--worktree <path>] [--instance <name>] [--task T<n>] [--no-seed]"
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
  # Through the wrapper: its config for the project, then (once admitted) up, then its ports for
  # the seed.
  assert_equal "$(docker_compose_env | jq -r '.call | sub(" -f [^ ]+"; "")')" "compose config --format json
compose up -d --wait
compose port web 80"
  # The other stacks are untouched.
  assert_equal "$(docker_calls | grep -E '^compose -p ' || true)" ""
}

@test "the ledger gives the worktree to its task however it spells it, and a primary checkout spelled otherwise is refused (report F6)" {
  open_task T22 "$(other_spelling "$STACK_WORKTREE")"
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$(stack_labels | jq -r .task)" T22
  run_bin -1 --separate-stderr team-stack env --worktree "$(other_spelling "$STACK_PRIMARY")"
  assert_contains "$stderr" "is a primary checkout, whose stack is Daniel's primary stack"
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

@test "up holds a stack it starts to the CPU the level's limits give the team's containers, once a level was applied" {
  open_task T22
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$(docker_calls | grep -c '^update' || true)" 0
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"

  # team-level applied a level: its containers' --cpus is kept for the stacks that start after.
  mkdir -p "$HOME/.local/state/agent-team/level"
  echo '{"at": "2026-11-01T14:05:00Z", "mode": "manual", "level": "minor", "cpu_quota_percent": 360, "cpus": 3.6, "memory_high": 1, "memory_max": 2}' \
    >"$HOME/.local/state/agent-team/level/applied.json"
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  local web
  web=$(jq -r --arg name "/$PROJECT-web-1" '.[] | select(.Name == $name) | .Id' "$DOCKER_STATE/containers.json")
  assert_equal "$(docker_calls | grep '^update')" "update --cpus 3.6 $web"
  assert_equal "$(jq -r --arg name "/$PROJECT-web-1" '.[] | select(.Name == $name) | .HostConfig.NanoCpus' "$DOCKER_STATE/containers.json")" 3600000000
  assert_contains "$stderr" "team-stack: held $PROJECT to --cpus 3.6, the level's (team-level)"
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

# Admission: up starts a new stack only with disk_floor_gb free on Docker's root and team-capacity's
# admission to the level's budget. Setup's stored reading leaves the team 16 GiB at full, which
# capacity_room changes; the fixture stack's mem_limits add up to 64 MiB, and docker_stub gives
# 200 GiB of disk free.

MIB=1048576

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

# The admissions team-capacity keeps, one compact [kind, task, bytes] per line.
admissions() {
  jq -c '.[] | [.kind, .task, .bytes]' "$HOME/.local/state/agent-team/capacity/admitted.json" 2>/dev/null || true
}

# Move every kept admission over 10 minutes into the past, as if the readings now held what each
# started.
admissions_aged() {
  local file=$HOME/.local/state/agent-team/capacity/admitted.json
  jq -c 'map(.at |= (fromdateiso8601 - 601 | todate))' "$file" >"$file.new"
  mv "$file.new" "$file"
}

@test "up is admitted to the level's budget at its mem_limits and with the disk floor, and starts the stack at once" {
  open_task T22
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT is up for T22, seeded: a new database"
  [[ $stderr != *room* ]]
  assert_equal "$(ups)" 1
  assert_equal "$(admissions)" "[\"stack:shop\",\"T22\",$((64 * MIB))]"
  # It read Docker's root, whose file system df measured, and counted no running project.
  assert_contains "$(docker_calls)" "info --format json"
  assert_equal "$(docker_calls | grep -c '^compose ls' || true)" 0
  assert_equal "$(stub_calls df)" '["-Pk","/var/lib/docker"]'
  assert_equal "$(waits_log)" ""
}

@test "up with no room in the budget exits 75 with team-capacity's reason, at none above all, and starts nothing" {
  open_task T22
  stack_settings '{"wait_minutes": 0}'
  capacity_room $((32 * MIB))
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: stack:shop at full (90%): 0.0 GiB of 0.0 GiB reserved, a stack of shop needs 0.1 GiB"
  assert_equal "$output" ""
  assert_equal "$(ups)" 0
  assert_equal "$(waits_log | jq -c '[.project, .task, .admitted, .reasons]')" \
    "[\"$PROJECT\",\"T22\",false,[\"stack:shop at full (90%): 0.0 GiB of 0.0 GiB reserved, a stack of shop needs 0.1 GiB\"]]"
  capacity_room $((16 * 1024 * MIB)) none
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: the team is at level none: nothing starts"
  assert_equal "$(admissions)" ""
  capacity_room $((16 * 1024 * MIB)) full
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$(ups)" 1
}

@test "stack_cap and memory_floor_gib in stack.json are accepted and no longer read" {
  open_task T22
  stack_settings '{"stack_cap": 1, "memory_floor_gib": 1000, "wait_minutes": 0}'
  machine_memory $((1024 * 1024))
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$(ups)" 1
}

@test "up refuses when the free disk of Docker's root is under disk_floor_gb, and then asks team-capacity nothing" {
  open_task T22
  stack_settings '{"wait_minutes": 0}'
  machine_disk_free $((20000000000 / 1024))
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: 20.0 GB free on the file system of /var/lib/docker (disk_floor_gb 30)"
  assert_equal "$(ups)" 0
  assert_equal "$(admissions)" ""
  assert_equal "$(waits_log | jq -c '[.admitted, .reasons]')" '[false,["20.0 GB free on the file system of /var/lib/docker (disk_floor_gb 30)"]]'
  stack_settings '{"wait_minutes": 0, "disk_floor_gb": 20}'
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
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

@test "an up waiting for the budget starts the stack once the level gives room" {
  open_task T22
  stack_settings '{"wait_minutes": 1}'
  capacity_room $((16 * 1024 * MIB)) none
  (sleep 2 && capacity_room $((16 * 1024 * MIB)) full) &
  TEAM_STACK_RECHECK_SECONDS=1 run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$stderr" "team-stack: no room for $PROJECT yet, waiting up to 1 minutes: the team is at level none: nothing starts"
  assert_equal "$(ups)" 1
  assert_equal "$(waits_log | jq -c '[.admitted, .reasons]')" '[true,["the team is at level none: nothing starts"]]'
}

@test "a wait that runs out exits 75 with the failing check, and logs the wait" {
  open_task T22
  stack_settings '{"wait_minutes": 0.03}'
  capacity_room $((16 * 1024 * MIB)) none
  TEAM_STACK_RECHECK_SECONDS=1 run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT yet, waiting up to 0.03 minutes: the team is at level none: nothing starts
team-stack: no room for $PROJECT: the team is at level none: nothing starts"
  ((${#lines[@]} == 0))
  # Checked at the start and again after a second at least, within the wait's 2 s.
  local checks
  checks=$(stub_calls df | wc -l)
  ((checks >= 2 && checks <= 3))
  assert_equal "$(waits_log | jq -c '[.admitted, .reasons]')" '[false,["the team is at level none: nothing starts"]]'
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

@test "two ups racing for the last room start exactly one stack, and the other exits 75" {
  open_task T22
  local first=$STACK_WORKTREE
  stack_project mall
  open_task T23 "$STACK_WORKTREE"
  # Room for one 64 MiB stack, not two.
  capacity_room $((100 * MIB))
  stack_settings '{"wait_minutes": 0}'
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
  assert_contains "$(cat "$dir/a.err" "$dir/b.err")" "at full (90%): 0.1 GiB of 0.1 GiB reserved, a stack of "
}

@test "a re-up of a running stack is admitted without a check, and a stopped one is counted as new" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
  stack_settings '{"wait_minutes": 0}'
  capacity_room 0
  local before
  before=$(docker_calls | wc -l)
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$(docker_calls | tail -n "+$((before + 1))" | grep -cE '^info( |$)' || true)" 0
  assert_equal "$(admissions | wc -l)" 1
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE"
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: no room for $PROJECT: stack:shop at full (90%): 0.1 GiB of 0.0 GiB reserved, a stack of shop needs 0.1 GiB"
}

@test "an admission that fails for another reason fails up" {
  open_task T22
  mkdir -p "$HOME/.config/agent-team"
  echo '{"full_share": 2}' >"$HOME/.config/agent-team/capacity.json"
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: team-capacity admit --kind stack:shop failed (exit 1): team-capacity: $HOME/.config/agent-team/capacity.json: full_share must be a number above 0 and at most 1, not 2"
  assert_equal "$(ups)" 0
}

@test "on macOS the disk is the home directory's, and docker info is not asked for it" {
  as_macos
  open_task T22
  stack_settings '{"wait_minutes": 0}'
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$(stub_calls df)" "[\"-Pk\",\"$HOME\"]"
  assert_equal "$(docker_calls | grep -c '^info' || true)" 0
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  machine_disk_free $((20000000000 / 1024))
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

@test "sweep counts a busy session in the worktree or below it spelled otherwise than its label (report F6)" {
  local other
  other=$(other_spelling "$STACK_WORKTREE")
  sessions "$(session "$other" busy)"
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" ""
  (($(busy_ago conventioner-2) < 60))
  rm "$HOME/.local/state/agent-team/stacks/conventioner-2.json"
  sessions "$(session "$other/src/app" busy)"
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" ""
  (($(busy_ago conventioner-2) < 60))
  rm "$HOME/.local/state/agent-team/stacks/conventioner-2.json"
  sessions "$(session "$(other_spelling "$(dirname "$STACK_WORKTREE")")/${STACK_WORKTREE##*/}-2" busy)"
  run_bin -0 team-stack sweep
  assert_equal "$(stopped)" conventioner-2
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

@test "sweep with Docker not answering says on stderr that no stack runs and exits 0, without reading the session list" {
  docker_down
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$output" ""
  assert_equal "$stderr" "team-stack: Docker does not answer (Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?), so no stack runs and there is nothing to sweep"
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

# reap, on the fixture machine: conventioner-4's worktree is gone, nmtest-1895520 is past its
# expires and nmtest-12822 is a gate stack from before the labels, made on 2026-10-21. The other
# objects whose rules depend on their age are made young by reap_machine (tests/helpers/docker.bash),
# and each test ages the ones it needs.

# The fixture's unattached anonymous volumes, the old and young ones once a test ages them.
OLD_ANONYMOUS=d34171881feb5b31166cdd67ec7d406dc769ac4c3c5dafb72ee98f6ef0a9e7ce
YOUNG_ANONYMOUS=05ab97f3ee4e69dfc7abe03f10bb3cb0115bfafead15e5f74babe7e369cda85e

# Add an image row to the machine: add_image <repository> <tag> <seconds ago>
add_image() {
  local id
  id=sha256:$(sha256sum <<<"$1:$2" | cut -d ' ' -f 1)
  docker_state images '. + [{Containers: "0", CreatedAt: "", CreatedSince: "", Digest: "", ID: $id, Repository: $repo,
    SharedSize: "N/A", Size: "534MB", Tag: $tag, UniqueSize: "N/A"}]' --arg id "$id" --arg repo "$1" --arg tag "$2"
  docker_created image "$1:$2" "$3"
}

# Set the team label <key> to <value> on every object of the Compose project <project>.
relabel() {
  local file
  for file in containers volumes networks; do
    docker_state "$file" 'map(if ((.Config.Labels // .Labels)["com.docker.compose.project"]) == $p then
        (if .Config then .Config.Labels else .Labels end)["io.github.chanjdaniel.team." + $k] = $v else . end)' \
      --arg p "$1" --arg k "$2" --arg v "$3"
  done
}


@test "reap's dry run prints each action with its object, rule and size, lists what it keeps that is not the team's, and changes nothing" {
  reap_machine
  local before
  before=$(cat "$DOCKER_STATE"/*.json | sha256sum)
  local gone=$HOME/.treehouse/Conventioner-d4c77a/4/Conventioner
  run_bin -0 --separate-stderr team-stack reap
  assert_equal "$stderr" ""
  assert_equal "$(removals)" "stack conventioner-4 (team, 0 B): its worktree $gone is gone
stack nmtest-12822 (gate, 0 B): it has no expires and its newest object was created at 2026-10-21T08:00:00Z, over 2 hours ago
stack nmtest-1895520 (gate, 509.1 MB): it expired at 2026-10-24T12:55:00Z"
  assert_equal "$(grep -c '^would remove ' <<<"$output")" 3
  assert_equal "$(kept)" "stack conventioner (unowned, 1.5 GB)
stack conventioner-3 (unowned, 0 B)
volume 0a4c042e60f521e1fe4b878ae5a0513fcfd83294279dd18fef88c940ab0120ab (unowned, 210.9 MB)
volume conventioner_mongodb_data (unowned, 1.3 GB)
volume f8d96e008758d020ea34d0411633d8ca076069b3efe8f765778a74259c7d8cc2 (unowned, 0 B)
volume scratch-data (unowned, 12.5 MB)
volume $YOUNG_ANONYMOUS (anonymous, 0 B)
volume $OLD_ANONYMOUS (anonymous, 210.9 MB)
image nmtest-12822-backend:latest (legacy, 534.0 MB)
image conventioner-backend:latest (unowned, 534.0 MB)
image conventioner-frontend:latest (unowned, 640.0 MB)
image mongo:7 (unowned, 867.0 MB)
image $(jq -r '.[] | select(.Repository == "<none>") | .ID' "$DOCKER_STATE/images.json") (dangling, 397.0 MB)
network conventioner_conventioner_network (unowned)"
  assert_equal "${lines[-1]}" "team-stack: would remove 3 objects, 509.1 MB: 1 team stack (0 B), 2 gate stacks (509.1 MB); kept 14 objects that are not the team's, 4.7 GB"
  # Only read: the machine is as it was.
  assert_read_only
  assert_equal "$(cat "$DOCKER_STATE"/*.json | sha256sum)" "$before"
  [[ ! -e $HOME/.local/state/agent-team/stacks/logs ]]
  # --dry-run says the same.
  local dry=$output
  run_bin -0 team-stack reap --dry-run
  assert_equal "$output" "$dry"
}

@test "reap --apply removes a team stack whose task is closed, its logs saved in its worktree's task directory; one of an open task is kept" {
  reap_machine
  open_task T1
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  # The task open: kept, and not listed, being the team's.
  run_bin -0 team-stack reap
  [[ $output != *"$PROJECT"* ]]
  task_event T1 closed
  task_event T7 opened '{"project": "conventioner", "worktree": "/elsewhere"}'
  mkdir -p "$DOCKER_STATE/logs"
  printf 'web-1  | the web log\n' >"$DOCKER_STATE/logs/$PROJECT-web.log"
  local anonymous
  anonymous=$(jq -r --arg n "/$PROJECT-web-1" '.[] | select(.Name == $n) | .Mounts[] | select(.Destination == "/cache") | .Name' \
    "$DOCKER_STATE/containers.json")
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_equal "$stderr" ""
  local logs=$STACK_WORKTREE/.scratch/task/stack-logs
  assert_contains "$output" "removed stack $PROJECT (team, 0 B): its task T1 is closed; its logs in $logs"
  assert_equal "$(cat "$logs/T1-$PROJECT-web.log")" "web-1  | the web log"
  assert_equal "$(stack_left "$anonymous")" ""
  assert_contains "$(docker_calls)" "compose -p $PROJECT down -v --remove-orphans"
  # T7 is open, so its stack in a worktree that exists stays.
  [[ $output != *conventioner-2* ]]
  jq -e 'any(.[]; .Name == "/conventioner-2-backend-1")' "$DOCKER_STATE/containers.json" >/dev/null
}

@test "reap --apply removes a team stack whose worktree is gone, its logs in the state directory; one whose worktree exists is kept" {
  reap_machine
  local gone=$HOME/.treehouse/Conventioner-d4c77a/4/Conventioner logs
  logs=$HOME/.local/state/agent-team/stacks/logs/conventioner-4-$(date +%F)
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_contains "$output" "removed stack conventioner-4 (team, 0 B): its worktree $gone is gone; its logs in $logs"
  # Every service it has, since no stack block can be found for a worktree that is gone.
  assert_equal "$(ls "$logs")" T5-conventioner-4-backend.log
  assert_contains "$(cat "$logs/T5-conventioner-4-backend.log")" "conventioner-4's backend started"
  assert_contains "$(docker_calls)" "compose -p conventioner-4 down -v --remove-orphans"
  assert_equal "$(jq '[.[] | select(.Name == "/conventioner-4-backend-1")] | length' "$DOCKER_STATE/containers.json")" 0
  # conventioner-2's worktree is the fixture's, which exists.
  jq -e 'any(.[]; .Name == "/conventioner-2-backend-1")' "$DOCKER_STATE/containers.json" >/dev/null
  [[ $output != *conventioner-2* ]]
}

@test "reap --apply removes a gate stack past its expires by project name, with its anonymous volumes; one whose expires is in the future is kept" {
  reap_machine
  docker_leak anonymous
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_contains "$output" "removed stack nmtest-1895520 (gate, 509.1 MB): it expired at 2026-10-24T12:55:00Z"
  # By project name, without compose files, then the anonymous volume its down left.
  assert_contains "$(docker_calls)" "compose -p nmtest-1895520 down -v --remove-orphans"
  [[ $(docker_calls) != *"compose -f"* ]]
  assert_contains "$(docker_calls)" "volume rm bc17ebee5bc23731a063ae52f70ff70fd2524946f265a54cebf6bd4ae9e22161"
  assert_equal "$(jq -r '.[] | select(.Name | test("^nmtest-1895520|^bc17")) | .Name' "$DOCKER_STATE/volumes.json")" ""
  # No logs for a gate stack.
  [[ ! -e $HOME/.local/state/agent-team/stacks/logs/nmtest-1895520-$(date +%F) ]]
}

@test "reap keeps a gate stack whose expires is in the future, however old" {
  reap_machine
  relabel nmtest-1895520 expires "$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)"
  run_bin -0 team-stack reap --apply
  [[ $(removals) != *nmtest-1895520* ]]
  [[ $output =~ (^|$'\n')"kept stack nmtest-1895520 (gate, 509.1 MB, "[0-9]+[smhd]" old)" ]]
}

@test "reap removes a gate stack labelled owner=agent-team by the gate rule, never as a team stack" {
  reap_machine
  open_task T7 "$STACK_WORKTREE"
  relabel nmtest-1895520 owner agent-team
  relabel nmtest-1895520 task T7
  run_bin -0 team-stack reap
  assert_contains "$(removals)" "stack nmtest-1895520 (gate, 509.1 MB): it expired at 2026-10-24T12:55:00Z"
  relabel nmtest-1895520 expires "$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)"
  task_event T7 closed
  run_bin -0 team-stack reap
  [[ $(removals) != *nmtest-1895520* ]]
}

@test "reap removes a gate stack with no expires once its newest object is 2 hours old, and keeps it just before" {
  reap_machine
  # A live run of the name of an aborted one that left its volume and network: its container is
  # young, so the stack is kept.
  docker_created container nmtest-12822-backend-1 $((2 * 3600 - 60))
  docker_created volume nmtest-12822_backend_sessions $((5 * 3600))
  docker_created network nmtest-12822_conventioner_network $((5 * 3600))
  run_bin -0 team-stack reap
  [[ $(removals) != *nmtest-12822* ]]
  assert_contains "$(kept)" "stack nmtest-12822 (gate, 0 B)"
  docker_created container nmtest-12822-backend-1 $((2 * 3600 + 60))
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_contains "$(removals)" "stack nmtest-12822 (gate, 0 B): it has no expires and its newest object was created at "
  assert_contains "$(docker_calls)" "compose -p nmtest-12822 down -v --remove-orphans"
  assert_equal "$(jq -r '.[] | select(.Name | startswith("nmtest-12822")) | .Name' "$DOCKER_STATE/volumes.json" "$DOCKER_STATE/networks.json")" ""
}

@test "reap removes a shared image no container uses, over 7 days old and not among its repository's 2 newest, and keeps the rest" {
  reap_machine
  # The tag containers use, made long ago; two new ones; one just too new; one old enough.
  docker_created image conventioner/backend:4943b69bbb33 $((30 * 86400))
  add_image conventioner/backend new1 86400
  add_image conventioner/backend new2 $((2 * 86400))
  add_image conventioner/backend young $((7 * 86400 - 60))
  add_image conventioner/backend old $((7 * 86400 + 60))
  # The 2 newest are images, not tags: the in-use image's second tag, latest, leaves older the
  # second newest of conventioner/frontend, however old, and oldest not.
  docker_state images '. + [(.[] | select(.Repository == "conventioner/frontend") | .Tag = "latest")]'
  add_image conventioner/frontend older $((20 * 86400))
  add_image conventioner/frontend oldest $((30 * 86400))
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_equal "$(removals | grep '^image')" "image conventioner/backend:old (team, 534.0 MB): no container uses it, it was created over 7 days ago and it is not among the 2 newest of conventioner/backend
image conventioner/frontend:oldest (team, 534.0 MB): no container uses it, it was created over 7 days ago and it is not among the 2 newest of conventioner/frontend"
  assert_contains "$(docker_calls)" "image rm conventioner/backend:old"
  assert_equal "$(jq -r '[.[] | select(.Repository | startswith("conventioner/")) | .Tag] | sort | join(" ")' "$DOCKER_STATE/images.json")" \
    "2a5cc542bea3 4943b69bbb33 latest new1 new2 older young"
  # The team's images kept are not listed.
  [[ $(kept) != *conventioner/* ]]
}

@test "reap removes a legacy image no container uses only with --legacy, and lists it as kept without" {
  reap_machine
  add_image nmfix-abc latest 3600
  run_bin -0 team-stack reap
  [[ $(removals) != *nmfix* ]]
  assert_contains "$(kept)" "image nmfix-abc:latest (legacy, 534.0 MB)"
  run_bin -0 --separate-stderr team-stack reap --apply --legacy
  assert_contains "$(removals)" "image nmfix-abc:latest (legacy, 534.0 MB): a legacy image no container uses (--legacy)"
  assert_contains "$(docker_calls)" "image rm nmfix-abc:latest"
  # nmtest-12822-backend is legacy too, but its gate stack's container used it when the reaper looked.
  [[ $(removals) != *nmtest-12822-backend* ]]
  jq -e 'any(.[]; .Repository == "nmtest-12822-backend")' "$DOCKER_STATE/images.json" >/dev/null
  assert_equal "$(jq '[.[] | select(.Repository == "nmfix-abc")] | length' "$DOCKER_STATE/images.json")" 0
}

@test "reap removes a dangling image no container uses by its id once it is 24 hours old, and keeps one just younger" {
  reap_machine
  local old young
  old=$(jq -r '.[] | select(.Repository == "<none>") | .ID' "$DOCKER_STATE/images.json")
  docker_created image "$old" $((24 * 3600 + 60))
  docker_state images '. + [{Containers: "0", CreatedAt: "", ID: ("sha256:" + "e" * 64), Repository: "<none>", Tag: "<none>",
    Size: "12MB", UniqueSize: "10MB"}]'
  young=sha256:$(printf 'e%.0s' {1..64})
  docker_created image "$young" $((24 * 3600 - 60))
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_equal "$(removals | grep '^image')" "image $old (dangling, 397.0 MB): dangling, no container uses it and it was created over 24 hours ago"
  assert_contains "$(docker_calls)" "image rm $old"
  # Its unique size, when Docker gives one.
  assert_contains "$(kept)" "image $young (dangling, 10.0 MB)"
}

@test "reap removes an unattached anonymous volume once it is 24 hours old, and keeps a younger one and an attached one" {
  reap_machine
  docker_created volume "$OLD_ANONYMOUS" $((24 * 3600 + 60))
  docker_created volume "$YOUNG_ANONYMOUS" $((24 * 3600 - 60))
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_equal "$(removals | grep '^volume')" "volume $OLD_ANONYMOUS (anonymous, 210.9 MB): no container mounts it and it was created over 24 hours ago"
  assert_contains "$(docker_calls)" "volume rm $OLD_ANONYMOUS"
  assert_contains "$(kept)" "volume $YOUNG_ANONYMOUS (anonymous, 0 B)"
  # Daniel's primary stack's anonymous volume, made 2026-10-19, is mounted by its stopped container.
  assert_contains "$(kept)" "volume f8d96e008758d020ea34d0411633d8ca076069b3efe8f765778a74259c7d8cc2 (unowned, 0 B)"
  assert_equal "$(jq -r --arg o "$OLD_ANONYMOUS" '[.[] | select(.Name == $o)] | length' "$DOCKER_STATE/volumes.json")" 0
}

@test "reap removes team-labelled named volumes and networks no container uses, and keeps those a stopped container still uses" {
  reap_machine
  local labels
  labels=$(jq -c '.[] | select(.Name == "conventioner-2_mongodb_data") | .Labels
    | .["com.docker.compose.project"] = "conventioner-6"' "$DOCKER_STATE/volumes.json")
  docker_state volumes '. + [{Name: "conventioner-6_mongodb_data", CreatedAt: "2026-10-25T09:00:00+08:00", Driver: "local",
    Labels: $l, Mountpoint: "/var/lib/docker/volumes/conventioner-6_mongodb_data/_data", Scope: "local", Size: "1MB"}]' --argjson l "$labels"
  docker_state networks '. + [{Name: "conventioner-6_conventioner_network", Id: ("6" * 64), Created: "2026-10-25T09:00:00+08:00",
    Scope: "local", Driver: "bridge", Labels: $l}]' --argjson l "$labels"
  # conventioner-2, of an open task, is stopped: its containers still use its volumes and network.
  docker_state containers 'map(if .Config.Labels["com.docker.compose.project"] == "conventioner-2"
    then .State += {Status: "exited", Running: false} else . end)'
  open_task T7
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_equal "$(removals | grep -E '^(volume|network)')" "volume conventioner-6_mongodb_data (team, 1.0 MB): no container uses it
network conventioner-6_conventioner_network (team): no container uses it"
  assert_contains "$(docker_calls)" "volume rm conventioner-6_mongodb_data"
  # A network by its id, since Docker lets two networks share a name.
  assert_contains "$(docker_calls)" "network rm $(printf '6%.0s' {1..64})"
  [[ $(docker_calls) != *"rm conventioner-2"* ]]
  jq -e 'any(.[]; .Name == "conventioner-2_conventioner_network")' "$DOCKER_STATE/networks.json" >/dev/null
}

@test "reap keeps every object that is not the team's and matches no rule, Daniel's primary stack and its volumes always among them" {
  reap_machine
  run_bin -0 --separate-stderr team-stack reap --apply --legacy
  assert_contains "$(kept)" "stack conventioner (unowned, 1.5 GB)"
  assert_contains "$(kept)" "volume conventioner_mongodb_data (unowned, 1.3 GB)"
  assert_contains "$(kept)" "stack conventioner-3 (unowned, 0 B)"
  assert_contains "$(kept)" "volume scratch-data (unowned, 12.5 MB)"
  [[ $(docker_calls) != *"rm conventioner_"* && $(docker_calls) != *"compose -p conventioner "* ]]
  assert_equal "$(jq -r '[.[] | select(.Config.Labels["com.docker.compose.project"] == "conventioner")] | length' "$DOCKER_STATE/containers.json")" 2
  # Each kept line carries its age.
  [[ $output =~ (^|$'\n')"kept volume conventioner_mongodb_data (unowned, 1.3 GB, "[0-9]+d" old)" ]]
  # Docker's own networks are nobody's leftovers, and are not listed.
  [[ $output != *"network bridge"* && $output != *"network host"* && $output != *"network none"* ]]
}

@test "a removal that fails is reported with Docker's reason, the others still happen, and reap exits 1" {
  reap_machine
  docker_created volume "$OLD_ANONYMOUS" $((25 * 3600))
  docker_created volume "$YOUNG_ANONYMOUS" $((25 * 3600))
  docker_refuse "$OLD_ANONYMOUS" "Error response from daemon: remove $OLD_ANONYMOUS: volume is in use - [abc]"
  docker_fail 'compose down' 'Error response from daemon: cannot remove container: permission denied'
  run_bin -1 --separate-stderr team-stack reap --apply
  assert_equal "$stderr" "team-stack: could not remove stack conventioner-4 (team, 0 B): docker compose down of conventioner-4 failed: Error response from daemon: cannot remove container: permission denied
team-stack: could not remove stack nmtest-12822 (gate, 0 B): docker compose down of nmtest-12822 failed: Error response from daemon: cannot remove container: permission denied
team-stack: could not remove stack nmtest-1895520 (gate, 509.1 MB): docker compose down of nmtest-1895520 failed: Error response from daemon: cannot remove container: permission denied
team-stack: could not remove volume $OLD_ANONYMOUS (anonymous, 210.9 MB): Error response from daemon: remove $OLD_ANONYMOUS: volume is in use - [abc]"
  assert_equal "$(removals)" "volume $YOUNG_ANONYMOUS (anonymous, 0 B): no container mounts it and it was created over 24 hours ago"
  assert_contains "${lines[-1]}" "team-stack: removed 1 object, 0 B: 1 unattached anonymous volume (0 B); 4 removals failed; kept "
}

@test "an object gone before its turn is told as already gone, and is no failure" {
  reap_machine
  docker_created volume "$OLD_ANONYMOUS" $((25 * 3600))
  docker_refuse "$OLD_ANONYMOUS" "Error response from daemon: get $OLD_ANONYMOUS: no such volume"
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_equal "$stderr" ""
  assert_contains "$output" "already gone volume $OLD_ANONYMOUS (anonymous, 210.9 MB)"
  [[ $(removals) != *"$OLD_ANONYMOUS"* ]]
  assert_contains "${lines[-1]}" "team-stack: removed 3 objects, 509.1 MB: 1 team stack (0 B), 2 gate stacks (509.1 MB); kept "
}

@test "reap --apply holds the admission lock while it removes, so no up starts a stack meanwhile" {
  reap_machine
  local lock=$HOME/.local/state/agent-team/stacks.lock log=$BATS_TEST_TMPDIR/lock
  mkdir -p "${lock%/*}"
  sed -i "1i if [[ \$* == compose* ]]; then if flock -n $(printf %q "$lock") true; then echo free; else echo held; fi >>$(printf %q "$log"); fi" \
    "$STUB_FIXTURES/docker.sh"
  run_bin -0 team-stack reap --apply
  assert_equal "$(sort -u "$log")" held
  # The dry run takes no lock.
  rm "$log"
  run_bin -0 team-stack reap
  [[ ! -e $log ]] || assert_equal "$(sort -u "$log")" free
}

@test "reap with nothing to remove says so" {
  docker_empty
  run_bin -0 --separate-stderr team-stack reap --apply
  assert_equal "$output" "team-stack: nothing to remove; kept 0 objects that are not the team's, 0 B"
  assert_equal "$stderr" ""
}

@test "reap refuses a malformed command line, and Docker not answering is exit 1 with its reason" {
  run_bin -2 --separate-stderr team-stack reap --dry-run --apply
  assert_equal "$stderr" "team-stack: usage: team-stack reap [--dry-run | --apply] [--legacy]"
  run_bin -2 team-stack reap --all
  assert_equal "$(docker_calls)" ""
  docker_down
  run_bin -1 --separate-stderr team-stack reap
  assert_equal "$stderr" "team-stack: Docker does not answer: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
}

@test "with TEAM_STACK_REAP_PROJECTS, reap considers only the Compose projects it matches and their objects" {
  reap_machine
  docker_created volume "$OLD_ANONYMOUS" $((25 * 3600))
  TEAM_STACK_REAP_PROJECTS='conventioner-[0-9]+' run_bin -0 team-stack reap
  assert_equal "$(removals)" "stack conventioner-4 (team, 0 B): its worktree $HOME/.treehouse/Conventioner-d4c77a/4/Conventioner is gone"
  assert_equal "$(kept)" "stack conventioner-3 (unowned, 0 B)"
}

# Parallel instances: up --instance <name> starts an extra stack of the worktree, the Compose
# project <its stack>-<name>, whose ports Docker assigns (TH_PORTS=auto); the stub gives each
# new container its own port.

# The team labels of the web container of the Compose project <project>, as stack_labels.
labels_of() {
  jq -c --arg name "/$1-web-1" '.[] | select(.Name == $name) | .Config.Labels
    | with_entries(select(.key | startswith("io.github.chanjdaniel.team.")) | .key |= ltrimstr("io.github.chanjdaniel.team."))
    | {owner, task, kind, worktree, expires}' "$DOCKER_STATE/containers.json"
}

# The host port of the web container of the Compose project <project>.
port_of() {
  jq -r --arg name "/$1-web-1" '.[] | select(.Name == $name) | .NetworkSettings.Ports["80/tcp"][0].HostPort' \
    "$DOCKER_STATE/containers.json"
}

# The state of the web container of the Compose project <project>, or nothing when it has none.
state_of() {
  jq -r --arg name "/$1-web-1" '.[] | select(.Name == $name) | .State.Status' "$DOCKER_STATE/containers.json"
}

# Whether Docker holds any object of the Compose project <project> (a function, so bats counts
# its status).
project_exists() {
  jq -e --arg p "$1" 'any(.[]; (.Config.Labels // .Labels)["com.docker.compose.project"] == $p)' \
    <(jq -s add "$DOCKER_STATE/containers.json" "$DOCKER_STATE/volumes.json" "$DOCKER_STATE/networks.json") >/dev/null
}

# Whether Docker holds no object of the Compose project <project>.
project_gone() {
  ! project_exists "$1"
}

# Start the fixture's stack by hand as the Compose project <project> with Docker's ports, as an
# agent would with the wrapper, with the TEAM_* labels <name>=<value>...
hand_instance() {
  local project=$1
  shift
  (cd "$STACK_WORKTREE" && env "$@" COMPOSE_PROJECT_NAME="$project" TH_PORTS=auto TH_DIR="$STACK_WORKTREE" \
    scripts/compose.sh up -d --wait) >/dev/null
}

# The wrapper calls since the compose call numbered <n> (1-based), one per line: "<call>
# <project> <TH_PORTS or ->", the wrapper's compose file left out.
wrapper_calls_since() {
  compose_env_since "$1" | jq -r 'select(.call | test(" -f ")) | "\(.call | sub(" -f [^ ]+"; "")) \(.project) \(.TH_PORTS // "-")"'
}

@test "up --instance starts the stack <project>-<name> of the worktree's task, kind e2e, on ports Docker assigns, and seeds it" {
  open_task T22
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --instance a
  assert_equal "$output" "team-stack: $PROJECT-a is up for T22, seeded: a new database"
  assert_equal "$(labels_of "$PROJECT-a")" \
    "$(jq -cn --arg wt "$STACK_WORKTREE" '{owner: "agent-team", task: "T22", kind: "e2e", worktree: $wt, expires: ""}')"
  local name
  for name in "$PROJECT-a_data:volumes" "$PROJECT-a_default:networks"; do
    assert_equal "$(jq -r --arg n "${name%:*}" '.[] | select(.Name == $n) | .Labels
      | "\(.["io.github.chanjdaniel.team.task"]) \(.["io.github.chanjdaniel.team.kind"])"' "$DOCKER_STATE/${name#*:}.json")" "T22 e2e"
  done
  assert_contains "$stderr" "seeded $PROJECT-a on port $(port_of "$PROJECT-a") for T22 from $STACK_WORKTREE"
  # The first config call learns the worktree's stack's name; every wrapper call after it is the
  # instance's, with Docker's ports.
  assert_equal "$(wrapper_calls_since 1)" "compose config --format json $PROJECT -
compose config --format json $PROJECT-a auto
compose up -d --wait $PROJECT-a auto
compose port web 80 $PROJECT-a auto"
  # The worktree's own stack is not started.
  assert_equal "$(state_of "$PROJECT")" ""
}

@test "the worktree's stack and two instances run at once on distinct ports, and env --instance reaches each with TH_PORTS=auto" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance b --no-seed
  local own a b
  own=$(port_of "$PROJECT") a=$(port_of "$PROJECT-a") b=$(port_of "$PROJECT-b")
  assert_equal "$(state_of "$PROJECT") $(state_of "$PROJECT-a") $(state_of "$PROJECT-b")" "running running running"
  assert_equal "$(printf '%s\n' "$own" "$a" "$b" | sort -u | grep -c .)" 3
  run_bin -0 --separate-stderr team-stack env --worktree "$STACK_WORKTREE" --instance a
  assert_equal "$stderr" ""
  assert_equal "$output" "export COMPOSE_PROJECT_NAME=$PROJECT-a
export TH_WEB_PORT=$a
export TH_PORTS=auto
export TEAM_OWNER=agent-team
export TEAM_TASK=T22
export TEAM_KIND=e2e
export TEAM_WORKTREE=$STACK_WORKTREE
export TEAM_EXPIRES=''"
  # The wrapper run by hand with those exports reaches the instance.
  assert_equal "$(eval "$output"; cd "$STACK_WORKTREE" && scripts/compose.sh ports)" "export COMPOSE_PROJECT_NAME=$PROJECT-a
export TH_WEB_PORT=$a"
  run_bin -0 team-stack env --worktree "$STACK_WORKTREE" --instance b
  assert_equal "${lines[0]} ${lines[1]} ${lines[2]}" "export COMPOSE_PROJECT_NAME=$PROJECT-b export TH_WEB_PORT=$b export TH_PORTS=auto"
  # The worktree's own stack's env names no TH_PORTS.
  run_bin -0 team-stack env --worktree "$STACK_WORKTREE"
  assert_equal "${lines[0]} ${lines[1]} ${lines[2]}" "export COMPOSE_PROJECT_NAME=$PROJECT export TH_WEB_PORT=$own export TEAM_OWNER=agent-team"
}

@test "seed, stop and down --instance act on the instance alone, every wrapper call with its project and TH_PORTS=auto" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  local n
  n=$(($(docker_compose_env | wc -l) + 1))
  run_bin -0 team-stack seed --worktree "$STACK_WORKTREE" --instance a
  assert_equal "$output" "seeded $PROJECT-a on port $(port_of "$PROJECT-a") for T22 from $STACK_WORKTREE"
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE" --instance a
  assert_equal "$output" "team-stack: $PROJECT-a is stopped, its data kept"
  assert_equal "$(state_of "$PROJECT") $(state_of "$PROJECT-a")" "running exited"
  run_bin -1 --separate-stderr team-stack env --worktree "$STACK_WORKTREE" --instance a
  assert_equal "$stderr" "team-stack: $PROJECT-a is not running (compose.sh: $PROJECT-a's web is not running); start it with team-stack up --instance a"
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE" --instance a
  assert_equal "$output" "team-stack: $PROJECT-a is removed, its logs in $STACK_WORKTREE/.scratch/task/stack-logs"
  [[ -s $STACK_WORKTREE/.scratch/task/stack-logs/$PROJECT-a-web.log ]]
  [[ ! -e $STACK_WORKTREE/.scratch/task/stack-logs/$PROJECT-web.log ]]
  project_gone "$PROJECT-a"
  assert_equal "$(state_of "$PROJECT")" running
  # Each config call learns the worktree's stack's name first; every other wrapper call is the instance's.
  assert_equal "$(wrapper_calls_since "$n" | grep -v "^compose config --format json $PROJECT -$" | sort -u)" \
    "compose config --format json $PROJECT-a auto
compose port web 80 $PROJECT-a auto"
  assert_equal "$(docker_calls | grep '^compose -p ' | grep -v "^compose -p $PROJECT-a " || true)" ""
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE" --instance a
  assert_equal "$output" "team-stack: $PROJECT-a has no stack, so there is nothing to remove"
  run_bin -1 --separate-stderr team-stack env --worktree "$STACK_WORKTREE" --instance a
  assert_equal "$stderr" "team-stack: $PROJECT-a has no stack; start it with team-stack up --instance a"
}

@test "an instance name outside [a-z0-9][a-z0-9_-]* is a usage error, and so is --instance for ls, sweep and reap" {
  open_task T22
  local name cmd
  for name in A -a _a a.b 'a b' ''; do
    run_bin -2 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --instance "$name"
    assert_equal "$stderr" "team-stack: --instance must match [a-z0-9][a-z0-9_-]*, got '$name'"
  done
  for cmd in env seed stop down; do
    run_bin -2 --separate-stderr team-stack "$cmd" --worktree "$STACK_WORKTREE" --instance 'a/b'
    assert_equal "$stderr" "team-stack: --instance must match [a-z0-9][a-z0-9_-]*, got 'a/b'"
    run_bin -2 --separate-stderr team-stack "$cmd" --instance
    assert_equal "$stderr" "team-stack: usage: team-stack $cmd [--worktree <path>] [--instance <name>]"
  done
  for cmd in ls sweep reap; do
    run_bin -2 team-stack "$cmd" --instance a
  done
  assert_equal "$(docker_calls)" ""
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance 0e2e_shard-1 --no-seed
  assert_equal "$output" "team-stack: $PROJECT-0e2e_shard-1 is up for T22, not seeded: --no-seed"
}

@test "admission counts instances as stacks, and a re-up of a running instance is admitted without a check" {
  open_task T22
  # Room for the worktree's stack and one instance, 64 MiB each, not a second instance.
  capacity_room $((150 * MIB))
  stack_settings '{"wait_minutes": 0}'
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --instance b --no-seed
  assert_equal "$stderr" "team-stack: no room for $PROJECT-b: stack:shop at full (90%): 0.1 GiB of 0.1 GiB reserved, a stack of shop needs 0.1 GiB"
  assert_equal "$(state_of "$PROJECT-b")" ""
  assert_equal "$(waits_log | jq -r '"\(.project) \(.task) \(.admitted)"')" "$PROJECT-b T22 false"
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  # A stopped instance is counted as new; room comes once the readings hold what runs.
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE" --instance a
  admissions_aged
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance b --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  run_bin -75 team-stack up --worktree "$STACK_WORKTREE" --instance c --no-seed
}

@test "down removes the worktree's instances before its own stack, and nothing of another worktree or project" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance b --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  # Instances labelled with the worktree by other spellings are the worktree's too; a team stack
  # of another worktree named like an instance, and one of this worktree whose name only starts
  # like the stack's, are not.
  hand_instance "$PROJECT-c" TEAM_OWNER=agent-team TEAM_TASK=T22 TEAM_KIND=e2e TEAM_WORKTREE="$STACK_WORKTREE/" TEAM_EXPIRES=
  hand_instance "$PROJECT-d" TEAM_OWNER=agent-team TEAM_TASK=T22 TEAM_KIND=e2e TEAM_WORKTREE="$(other_spelling "$STACK_WORKTREE")" TEAM_EXPIRES=
  hand_instance "$PROJECT-z" TEAM_OWNER=agent-team TEAM_TASK=T9 TEAM_KIND=dev TEAM_WORKTREE="$HOME/worktrees/shop-1-z" TEAM_EXPIRES=
  hand_instance "${PROJECT}0" TEAM_OWNER=agent-team TEAM_TASK=T22 TEAM_KIND=e2e TEAM_WORKTREE="$STACK_WORKTREE" TEAM_EXPIRES=
  run_bin -0 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  local logs=$STACK_WORKTREE/.scratch/task/stack-logs
  assert_equal "$output" "team-stack: $PROJECT-a is removed, its logs in $logs
team-stack: $PROJECT-b is removed, its logs in $logs
team-stack: $PROJECT-c is removed, its logs in $logs
team-stack: $PROJECT-d is removed, its logs in $logs
team-stack: $PROJECT is removed, its logs in $logs"
  assert_equal "$(docker_calls | sed -n -E 's/^compose -p ([^ ]+) down -v --remove-orphans$/\1/p')" "$PROJECT-a
$PROJECT-b
$PROJECT-c
$PROJECT-d
$PROJECT"
  assert_equal "$(cd "$logs" && ls)" "$PROJECT-a-web.log
$PROJECT-b-web.log
$PROJECT-c-web.log
$PROJECT-d-web.log
$PROJECT-web.log"
  local project
  for project in "$PROJECT" "$PROJECT-a" "$PROJECT-b" "$PROJECT-c" "$PROJECT-d"; do project_gone "$project"; done
  assert_equal "$(state_of "$PROJECT-z") $(state_of "${PROJECT}0")" "running running"
  # The fixture machine's stacks are untouched.
  run_bin -0 team-stack ls --json
  assert_equal "$(jq -r '[.projects[].name] | join(" ")' <<<"$output")" \
    "conventioner conventioner-2 conventioner-3 conventioner-4 nmtest-12822 nmtest-1895520 $PROJECT-z ${PROJECT}0"
}

@test "down removes the instances when the worktree has no stack of its own, and refuses an unowned stack before touching any" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT-a is removed, its logs in $STACK_WORKTREE/.scratch/task/stack-logs
team-stack: $PROJECT has no stack, so there is nothing to remove"
  project_gone "$PROJECT-a"
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  hand_stack
  run_bin -1 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  assert_contains "$stderr" "$PROJECT is not the team's (class unowned)"
  assert_equal "$(state_of "$PROJECT-a")" running
}

@test "down refuses an instance of the worktree that is not wholly the team's, and leaves the worktree's stack" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  # A hand-made volume of the instance's project, with no team labels.
  docker_state volumes '. + [{Name: "\($p)_extra", CreatedAt: "2026-10-24T09:00:00+00:00", Driver: "local", Scope: "local",
    Size: "0B", Mountpoint: "/var/lib/docker/volumes/\($p)_extra/_data", Labels: {"com.docker.compose.project": $p}}]' \
    --arg p "$PROJECT-a"
  run_bin -1 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" "team-stack: $PROJECT-a is not the team's (class unowned), so team-stack leaves it alone: team-stack ls shows it, and removing it is Daniel's or the coordinator's call"
  assert_equal "$(state_of "$PROJECT") $(state_of "$PROJECT-a")" "running running"
}

@test "up --instance takes down an instance of another task in the worktree first, and refuses an unowned one" {
  hand_instance "$PROJECT-a" TEAM_OWNER=agent-team TEAM_TASK=T7 TEAM_KIND=e2e TEAM_WORKTREE="$STACK_WORKTREE" TEAM_EXPIRES=
  open_task T22
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --instance a
  assert_contains "$stderr" "$PROJECT-a is T7's: taking it down first"
  [[ -s $STACK_WORKTREE/.scratch/task/stack-logs/T7-$PROJECT-a-web.log ]]
  assert_equal "$output" "team-stack: $PROJECT-a is up for T22, seeded: a new database"
  assert_equal "$(labels_of "$PROJECT-a" | jq -r '"\(.task) \(.kind)"')" "T22 e2e"
  hand_instance "$PROJECT-b"
  run_bin -1 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --instance b
  assert_contains "$stderr" "$PROJECT-b is not the team's (class unowned)"
}

@test "an exported instance identity never redirects a call to it" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance a --no-seed
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --instance b --no-seed
  run_bin -0 team-stack env --worktree "$STACK_WORKTREE" --instance a
  local n
  n=$(($(docker_compose_env | wc -l) + 1))
  # As in a shell that ran eval "$(team-stack env --instance a)".
  eval "$output"
  run_bin -0 team-stack env --worktree "$STACK_WORKTREE"
  assert_equal "${lines[0]} ${lines[1]}" "export COMPOSE_PROJECT_NAME=$PROJECT export TH_WEB_PORT=$(port_of "$PROJECT")"
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE" --instance b
  assert_equal "$(state_of "$PROJECT") $(state_of "$PROJECT-a") $(state_of "$PROJECT-b")" "running running exited"
  assert_equal "$(wrapper_calls_since "$n" | grep -c " $PROJECT-a " || true)" 0
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  local project
  for project in "$PROJECT" "$PROJECT-a" "$PROJECT-b"; do project_gone "$project"; done
}
