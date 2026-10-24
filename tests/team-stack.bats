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
  run_bin -2 --separate-stderr team-stack start
  assert_equal "$stderr" "team-stack: unknown subcommand 'start'; the subcommands are: ls, up, env, seed, stop, down"
  run_bin -2 --separate-stderr team-stack
  assert_equal "$stderr" "team-stack: usage: team-stack ls|up|env|seed|stop|down [options]; team-stack --help says more"
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
  # Through the wrapper: its config for the project, then up, then its ports for the seed.
  assert_equal "$(docker_compose_env | jq -r '.call | sub(" -f [^ ]+"; "")')" "compose config --format json
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
