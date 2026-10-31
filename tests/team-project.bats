#!/usr/bin/env bats
# team-project: reading and checking the project registry, projects.toml.

load helpers/common

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[alpha]
repo = "owner/alpha"
path = "projects/alpha"
base = "main"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = ["AGENTS.md"]
toolkits = []

[alpha.pool]
provider = "treehouse"
lease = "scripts/lease.sh"
return = "scripts/return.sh"
slots = [".treehouse/alpha/1/alpha", ".treehouse/alpha/2/alpha"]

[beta]
repo = "owner/beta"
path = "beta"
base = "dev"
delivery = "direct-pr"
merge_method = "squash"
required_checks = ["shellcheck", "test"]
task_dir = ".scratch/task"
docs = []
toolkits = []

[beta.pool]
provider = "git"
slots = ["beta/.claude/worktrees/1"]
TOML
}

# Replace the fixture registry with the TOML on stdin.
registry() {
  cat >"$TEAM_HOME/projects.toml"
}

@test "a project prints as JSON with every rooted path absolute" {
  run_bin -0 team-project alpha
  assert_equal "$(jq -r .path <<<"$output")" "$HOME/projects/alpha"
  assert_equal "$(jq -c .pool.slots <<<"$output")" "[\"$HOME/.treehouse/alpha/1/alpha\",\"$HOME/.treehouse/alpha/2/alpha\"]"
  assert_equal "$(jq -r .pool.lease <<<"$output")" "$HOME/projects/alpha/scripts/lease.sh"
  assert_equal "$(jq -r .pool.return <<<"$output")" "$HOME/projects/alpha/scripts/return.sh"
  assert_equal "$(jq -r '[.repo, .base, .delivery, .merge_method, .task_dir] | join(" ")' <<<"$output")" \
    "owner/alpha main no-mistakes merge .scratch/task"
  assert_equal "$(jq -c '[.docs, .required_checks, .toolkits]' <<<"$output")" '[["AGENTS.md"],[],[]]'
}

@test "one dotted key prints strings bare and lists and tables as JSON" {
  run_bin -0 team-project beta pool.provider
  assert_equal "$output" "git"
  run_bin -0 team-project beta path
  assert_equal "$output" "$HOME/beta"
  run_bin -0 team-project beta pool.slots
  assert_equal "$(jq -c . <<<"$output")" "[\"$HOME/beta/.claude/worktrees/1\"]"
  run_bin -0 team-project beta pool
  assert_equal "$(jq -c . <<<"$output")" "{\"provider\":\"git\",\"slots\":[\"$HOME/beta/.claude/worktrees/1\"]}"
}

@test "--list prints the project names in file order" {
  run_bin -0 team-project --list
  assert_equal "$output" $'alpha\nbeta'
}

@test "an unknown project is refused naming the known ones" {
  run_bin -1 --separate-stderr team-project gamma
  assert_equal "$output" ""
  assert_contains "$stderr" "unknown project 'gamma'; known: alpha, beta"
}

@test "an unknown key is refused naming the keys that exist where it was looked up" {
  run_bin -1 --separate-stderr team-project alpha pool.size
  assert_equal "$output" ""
  assert_contains "$stderr" "alpha has no key 'pool.size'; pool has: provider, lease, return, slots"
  run_bin -1 --separate-stderr team-project alpha owner
  assert_contains "$stderr" "alpha has no key 'owner'; alpha has: repo, path, base, delivery"
  run_bin -1 --separate-stderr team-project alpha base.name
  assert_contains "$stderr" "alpha has no key 'base.name'; base is not a table"
}

@test "--find names the projects whose key holds a value: repo in any case, paths as the same file however spelled" {
  run_bin -0 team-project --find repo owner/beta
  assert_equal "$output" beta
  run_bin -0 team-project --find repo Owner/ALPHA
  assert_equal "$output" alpha
  run_bin -0 team-project --find repo owner/gamma
  assert_equal "$output" ""
  run_bin -0 team-project --find base dev
  assert_equal "$output" beta
  run_bin -0 team-project --find required_checks test
  assert_equal "$output" beta
  run_bin -0 team-project --find delivery merge
  assert_equal "$output" ""

  # Paths: the primary checkout, a slot, a lease command, through a symlink and a trailing slash.
  mkdir -p "$HOME/projects/alpha" "$HOME/.treehouse/alpha/2/alpha"
  ln -s "$HOME/.treehouse/alpha" "$HOME/th"
  run_bin -0 team-project --find path "$HOME/projects/alpha/"
  assert_equal "$output" alpha
  run_bin -0 team-project --find pool.slots "$HOME/th/2/alpha"
  assert_equal "$output" alpha
  run_bin -0 team-project --find pool.slots "$HOME/beta/.claude/worktrees/1"
  assert_equal "$output" beta
  run_bin -0 team-project --find pool.lease "$HOME/projects/alpha/scripts/lease.sh"
  assert_equal "$output" alpha
  # A primary checkout is not a slot.
  run_bin -0 team-project --find pool.slots "$HOME/projects/alpha"
  assert_equal "$output" ""
  # Another spelling of one directory is that directory, and a slot not made yet is the slot of
  # that name in another spelling of the directory it will be in (report F6).
  run_bin -0 team-project --find path "$(other_spelling "$HOME/projects/alpha")"
  assert_equal "$output" alpha
  run_bin -0 team-project --find pool.slots "$(other_spelling "$HOME/.treehouse")/alpha/1/alpha"
  assert_equal "$output" alpha
  run_bin -0 team-project --find pool.slots "$HOME/.treehouse/alpha/1/other"
  assert_equal "$output" ""

  run_bin -1 team-project --find pool.color red
  assert_contains "$output" "no project has a key 'pool.color'"
}

@test "a malformed command line is a usage error" {
  run_bin -2 team-project
  assert_contains "$output" "usage: team-project"
  run_bin -2 team-project alpha path extra
  assert_contains "$output" "usage: team-project"
  run_bin -2 team-project --bogus
  assert_contains "$output" "usage: team-project"
  run_bin -2 team-project --list extra
  assert_contains "$output" "usage: team-project"
  run_bin -2 team-project --find repo
  assert_contains "$output" "usage: team-project"
  run_bin -2 team-project --find repo a b
}

@test "--help prints the header" {
  run_bin -0 team-project --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-project")"
  assert_contains "$output" "team-project --check"
  run_bin -0 team-project -h
  assert_contains "$output" "team-project --check"
}

@test "--check passes a valid registry" {
  run_bin -0 team-project --check
  assert_contains "$output" "2 projects"
}

@test "--check reports every problem at once" {
  registry <<'TOML'
[alpha]
repo = "owner/alpha"
path = "projects/alpha"
delivery = "by-hand"
merge_method = "fast-forward"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []
colour = "blue"

[alpha.pool]
provider = "treehouse"
slots = ["shared/1", "shared/1"]

[beta]
repo = "owner/beta"
path = "beta"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[beta.pool]
provider = "docker"
slots = ["shared/1"]
size = 2
TOML
  run_bin -1 --separate-stderr team-project --check
  assert_equal "$output" ""
  local expected
  for expected in \
    "alpha: missing required key 'base'" \
    "alpha: unknown key 'colour'" \
    "alpha.delivery: 'by-hand' is not one of no-mistakes, direct-pr" \
    "alpha.merge_method: 'fast-forward' is not one of merge, squash, rebase" \
    "alpha.pool: a treehouse pool needs 'lease'" \
    "alpha.pool: a treehouse pool needs 'return'" \
    "alpha.pool.slots: 'shared/1' is listed twice" \
    "beta.pool.slots: 'shared/1' is already a slot of alpha" \
    "beta.pool.provider: 'docker' is not one of treehouse, git" \
    "beta.pool: unknown key 'size'"; do
    assert_contains "$stderr" "$expected"
  done
}

@test "--check refuses wrong types, rooted paths and git pools with treehouse keys" {
  registry <<'TOML'
[alpha]
repo = "alpha"
path = "/home/someone/alpha"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = "test"
task_dir = "../task"
docs = [1]
toolkits = []
pool = { provider = "git", lease = "scripts/lease.sh", slots = ["~/alpha/1"] }
TOML
  run_bin -1 --separate-stderr team-project --check
  local expected
  for expected in \
    "alpha.repo: 'alpha' is not owner/name" \
    "alpha.path: '/home/someone/alpha' must be a relative path" \
    "alpha.required_checks: must be a list of strings" \
    "alpha.task_dir: '../task' must be a relative path" \
    "alpha.docs: must be a list of strings" \
    "alpha.pool: 'lease' is for treehouse pools only" \
    "alpha.pool.slots: '~/alpha/1' must be a relative path"; do
    assert_contains "$stderr" "$expected"
  done
}

@test "--check refuses a project named coordinator, the team home's memory folder" {
  sed 's/^\[beta/[coordinator/' "$TEAM_HOME/projects.toml" >"$BATS_TEST_TMPDIR/projects.toml"
  registry <"$BATS_TEST_TMPDIR/projects.toml"
  run_bin -1 --separate-stderr team-project --check
  assert_contains "$stderr" "coordinator: the name is reserved for the team home's auto memory, memory/coordinator/"
  [[ $stderr != *alpha* ]]
}

@test "--check refuses TOML that does not parse and a registry that is missing" {
  registry <<<'[alpha'
  run_bin -1 --separate-stderr team-project --check
  assert_contains "$stderr" "projects.toml"
  rm "$TEAM_HOME/projects.toml"
  run_bin -1 --separate-stderr team-project --check
  assert_contains "$stderr" "no registry at $TEAM_HOME/projects.toml"
}

@test "reading a broken registry is refused with its problems" {
  registry <<'TOML'
[alpha]
repo = "owner/alpha"
TOML
  run_bin -1 --separate-stderr team-project alpha repo
  assert_equal "$output" ""
  assert_contains "$stderr" "alpha: missing required key 'base'"
}

# A copy of team-project in a code checkout of its own, $BATS_TEST_TMPDIR/code, with the fixture
# registry beside bin/, where no team home is; prints the checkout's path.
code_checkout() {
  local code=$BATS_TEST_TMPDIR/code
  mkdir -p "$code/bin"
  cp "$REPO_ROOT/bin/team-project" "$code/bin/"
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$code/"
  echo "$code"
}

# The team home this machine names: home_setting <first line>
home_setting() {
  mkdir -p "$HOME/.config/agent-team"
  printf '%s\nignored\n' "$1" >"$HOME/.config/agent-team/home"
}

@test "with TEAM_HOME unset it reads the registry of the team home ~/.config/agent-team/home names" {
  local code
  code=$(code_checkout)
  mkdir -p "$HOME/agent-team-records"
  mv "$TEAM_HOME/projects.toml" "$HOME/agent-team-records/"
  home_setting agent-team-records
  unset TEAM_HOME
  run -0 "$code/bin/team-project" --list
  assert_equal "$output" $'alpha\nbeta'
  home_setting "$HOME/agent-team-records"
  run -0 "$code/bin/team-project" --list
  assert_equal "$output" $'alpha\nbeta'
}

@test "TEAM_HOME, when set, wins over ~/.config/agent-team/home" {
  local code
  code=$(code_checkout)
  home_setting agent-team-records
  run -0 "$code/bin/team-project" --list
  assert_equal "$output" $'alpha\nbeta'
}

@test "with neither TEAM_HOME nor ~/.config/agent-team/home it refuses with the setting's fix, never reading the checkout's registry" {
  local code
  code=$(code_checkout)
  unset TEAM_HOME
  run -1 "$code/bin/team-project" --list
  assert_equal "$output" "team-project: neither TEAM_HOME nor ~/.config/agent-team/home names the team home; name its checkout there, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  TEAM_HOME='' run -1 "$code/bin/team-project" --list
  assert_contains "$output" "team-project: neither TEAM_HOME nor ~/.config/agent-team/home names the team home"
  run -0 "$code/bin/team-project" --help
}

@test "a setting naming a missing directory, or none, is refused with the path and the file it came from" {
  local code
  code=$(code_checkout)
  unset TEAM_HOME
  home_setting agent-team-records
  run -1 "$code/bin/team-project" --list
  assert_equal "$output" "team-project: the team home $HOME/agent-team-records, named by ~/.config/agent-team/home, is not a directory; name its checkout there, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  home_setting ''
  run -1 "$code/bin/team-project" --list
  assert_equal "$output" "team-project: the setting ~/.config/agent-team/home names no team home; name its checkout there, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
}

@test "a registry shaped like the team home's passes --check and holds every project" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  run_bin -0 team-project --check
  run_bin -0 team-project --list
  assert_equal "$output" $'conventioner\nagent-team\nno-mistakes'

  run_bin -0 team-project conventioner
  assert_equal "$(jq -r '[.repo, .base, .delivery, .merge_method, .task_dir, .pool.provider] | join(" ")' <<<"$output")" \
    "chanjdaniel/Conventioner dev no-mistakes merge .scratch/task treehouse"
  assert_equal "$(jq -r .path <<<"$output")" "$HOME/Documents/projects/personal/Conventioner"
  assert_equal "$(jq -r '.pool.slots | length' <<<"$output")" "4"

  run_bin -0 team-project agent-team
  assert_equal "$(jq -r '[.repo, .base, .delivery, .merge_method, .pool.provider] | join(" ")' <<<"$output")" \
    "chanjdaniel/agent-team dev direct-pr merge git"
  assert_equal "$(jq -c .pool.slots <<<"$output")" \
    "[\"$HOME/agent-team/.claude/worktrees/1\",\"$HOME/agent-team/.claude/worktrees/2\",\"$HOME/agent-team/.claude/worktrees/3\",\"$HOME/agent-team/.claude/worktrees/4\",\"$HOME/agent-team/.claude/worktrees/5\"]"

  # Daniel's no-mistakes fork: merge commits keep upstream's history, so the next update is a merge.
  run_bin -0 team-project no-mistakes
  assert_equal "$(jq -r '[.repo, .base, .delivery, .merge_method, .task_dir, .pool.provider] | join(" ")' <<<"$output")" \
    "chanjdaniel/no-mistakes main direct-pr merge .scratch/task git"
  assert_equal "$(jq -r .path <<<"$output")" "$HOME/Documents/projects/personal/no-mistakes"
  assert_equal "$(jq -c '[.required_checks, .docs, .toolkits]' <<<"$output")" '[[],["AGENTS.md"],[]]'
  assert_equal "$(jq -c .local_checks <<<"$output")" \
    '["test -z \"$(gofmt -l .)\"","make lint","go test -race ./...","bash scripts/e2e.sh"]'
  assert_equal "$(jq -c .pool.slots <<<"$output")" \
    "[\"$HOME/Documents/projects/personal/no-mistakes/.claude/worktrees/1\",\"$HOME/Documents/projects/personal/no-mistakes/.claude/worktrees/2\",\"$HOME/Documents/projects/personal/no-mistakes/.claude/worktrees/3\"]"
}

@test "local_checks is optional, defaults to none, and must be one-line commands" {
  run_bin -0 team-project alpha local_checks
  assert_equal "$(jq -c . <<<"$output")" '[]'
  sed -i 's|^toolkits = \[\]$|toolkits = []\nlocal_checks = ["tests/run", "make lint"]|' "$TEAM_HOME/projects.toml"
  run_bin -0 team-project --check
  run_bin -0 team-project beta local_checks
  assert_equal "$(jq -c . <<<"$output")" '["tests/run","make lint"]'
  run_bin -0 team-project --find local_checks "make lint"
  assert_equal "$output" $'alpha\nbeta'

  registry <<'TOML'
[alpha]
repo = "owner/alpha"
path = "alpha"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
local_checks = "tests/run"
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["alpha/1"] }

[beta]
repo = "owner/beta"
path = "beta"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
local_checks = ["tests/run", " ", "a\nb"]
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["beta/1"] }
TOML
  run_bin -1 --separate-stderr team-project --check
  assert_contains "$stderr" "alpha.local_checks: must be a list of strings"
  assert_contains "$stderr" "beta.local_checks: each command must be one line, not empty"
}

@test "models is optional, defaults to none, and maps a worker role to a model alias" {
  run_bin -0 team-project alpha models
  assert_equal "$(jq -c . <<<"$output")" '{}'
  run_bin -0 team-project alpha
  assert_equal "$(jq -c .models <<<"$output")" '{}'
  sed -i 's|^toolkits = \[\]$|toolkits = []\nmodels = { reviewer = "sonnet", builder = "claude-sonnet-5-5" }|' "$TEAM_HOME/projects.toml"
  run_bin -0 team-project --check
  run_bin -0 team-project beta models
  assert_equal "$(jq -c . <<<"$output")" '{"reviewer":"sonnet","builder":"claude-sonnet-5-5"}'
  run_bin -0 team-project beta models.reviewer
  assert_equal "$output" "sonnet"
  run_bin -0 team-project --find models.reviewer sonnet
  assert_equal "$output" $'alpha\nbeta'

  registry <<'TOML'
[alpha]
repo = "owner/alpha"
path = "alpha"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
models = "sonnet"
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["alpha/1"] }

[beta]
repo = "owner/beta"
path = "beta"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
models = { ops = "sonnet", coordinator = "sonnet", tester = "sonnet", planner = 5, builder = "", reviewer = "--sonnet x" }
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["beta/1"] }
TOML
  run_bin -1 --separate-stderr team-project --check
  local expected
  for expected in \
    "alpha.models: must be a table of role to model" \
    "beta.models: 'ops' always runs on the default model" \
    "beta.models: 'coordinator' is not a worker role; one of planner, builder, reviewer" \
    "beta.models: 'tester' is not a worker role; one of planner, builder, reviewer" \
    "beta.models.planner: must be a string" \
    "beta.models.builder: '' is not a model alias or name" \
    "beta.models.reviewer: '--sonnet x' is not a model alias or name"; do
    assert_contains "$stderr" "$expected"
  done
}

@test "merge_with_plan is optional, false by default, a boolean, and found by --find" {
  run_bin -0 team-project alpha merge_with_plan
  assert_equal "$output" false
  run_bin -0 team-project alpha
  assert_equal "$(jq -c .merge_with_plan <<<"$output")" false
  sed -i 's|^docs = \[\]$|docs = []\nmerge_with_plan = true|' "$TEAM_HOME/projects.toml"
  run_bin -0 team-project --check
  run_bin -0 team-project beta merge_with_plan
  assert_equal "$output" true
  run_bin -0 team-project --find merge_with_plan true
  assert_equal "$output" beta
  run_bin -0 team-project --find merge_with_plan false
  assert_equal "$output" alpha

  registry <<'TOML'
[alpha]
repo = "owner/alpha"
path = "alpha"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
merge_with_plan = "yes"
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["alpha/1"] }

[beta]
repo = "owner/beta"
path = "beta"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
merge_with_plan = 1
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["beta/1"] }
TOML
  run_bin -1 --separate-stderr team-project --check
  assert_contains "$stderr" "alpha.merge_with_plan: must be true or false"
  assert_contains "$stderr" "beta.merge_with_plan: must be true or false"
}

# A registry of one project, <name>, at <path> under HOME, with merge_with_plan = <value>:
# own_registry <name> <path> <value> [<repo>]
own_registry() {
  registry <<TOML
[$1]
repo = "${4:-owner/$1}"
path = "$2"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
merge_with_plan = $3
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["$2/1"] }
TOML
}

# A code checkout of the test's own at ~/projects/tools, a clone with this checkout's bin/ in it,
# which run_bin runs from: own_checkout
own_checkout() {
  export CODE_CHECKOUT
  CODE_CHECKOUT=$(make_repo tools dev)
  copy_bin "$CODE_CHECKOUT/bin"
}

@test "--check refuses merge_with_plan = true on the team's own project: agent-team, or the one at this code checkout" {
  own_registry agent-team agent-team true
  run_bin -1 --separate-stderr team-project --check
  assert_contains "$stderr" "agent-team.merge_with_plan: agent-team is the team's own project, whose PRs merge only on Daniel's word per head"
  own_registry agent-team agent-team false
  run_bin -0 team-project --check

  # The project at the code checkout team-project runs from is the team's own, whatever its name.
  own_checkout
  own_registry tools projects/tools true
  run_bin -1 --separate-stderr team-project --check
  assert_contains "$stderr" "tools.merge_with_plan: its path is the code checkout team-project runs from, $CODE_CHECKOUT, the team's own project, whose PRs merge only on Daniel's word per head"
  own_registry tools projects/other true
  run_bin -0 team-project --check
}

@test "own_project is true for the team's own project, by name, by path or by repo, and false for another" {
  own_checkout
  cat >"$CODE_CHECKOUT/bin/team-own" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"
if own_project "$1"; then echo own; else echo other; fi
SCRIPT
  chmod +x "$CODE_CHECKOUT/bin/team-own"

  own_registry agent-team elsewhere false
  run_bin -0 team-own agent-team
  assert_equal "$output" own
  own_registry tools projects/tools false
  run_bin -0 team-own tools
  assert_equal "$output" own
  own_registry beta beta true
  run_bin -0 team-own beta
  assert_equal "$output" other

  # By repo: the owner/name of the code checkout's origin, in any case, however the URL is spelled.
  local url
  for url in git@github.com:Owner/Code.git https://github.com/owner/code https://github.com/OWNER/code.git/ \
    ssh://git@github.com/owner/Code.git; do
    git -C "$CODE_CHECKOUT" remote set-url origin "$url"
    own_registry beta beta true owner/CODE
    run_bin -0 team-own beta
    assert_equal "$output" own
    own_registry beta beta true owner/codex
    run_bin -0 team-own beta
    assert_equal "$output" other
  done

  run_bin -1 --separate-stderr team-own gamma
  assert_contains "$stderr" "unknown project 'gamma'"
}

# A worktree of the test's code checkout at ~/projects/tools-wt, with this checkout's bin/ in it,
# which run_bin then runs from: own_worktree
own_worktree() {
  local wt=$HOME/projects/tools-wt
  git -C "$CODE_CHECKOUT" worktree add -q --detach "$wt"
  copy_bin "$wt/bin"
  CODE_CHECKOUT=$wt
}

@test "run from a worktree of the code checkout, the project at the checkout's main worktree is the team's own" {
  own_checkout
  local main=$CODE_CHECKOUT
  own_worktree
  own_registry tools projects/tools true owner/elsewhere
  run_bin -1 --separate-stderr team-project --check
  assert_contains "$stderr" "tools.merge_with_plan: its path is $main, the main worktree of the code checkout team-project runs from, the team's own project, whose PRs merge only on Daniel's word per head"
  own_registry tools projects/tools-wt true owner/elsewhere
  run_bin -1 --separate-stderr team-project --check
  assert_contains "$stderr" "tools.merge_with_plan: its path is the code checkout team-project runs from, $CODE_CHECKOUT, the team's own project"

  cat >"$CODE_CHECKOUT/bin/team-own" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"
if own_project "$1"; then echo own; else echo other; fi
SCRIPT
  chmod +x "$CODE_CHECKOUT/bin/team-own"
  git -C "$main" remote set-url origin git@github.com:owner/tools.git
  own_registry tools projects/tools false owner/elsewhere
  run_bin -0 team-own tools
  assert_equal "$output" own
  own_registry tools projects/other false owner/elsewhere
  run_bin -0 team-own tools
  assert_equal "$output" other
}

@test "--help documents every key the registry may hold, and no other" {
  local known documented
  # The keys from the script's own lists: a project's, its optional ones, and its pool's.
  known=$(python3 -I - "$REPO_ROOT/bin/team-project" <<'PY'
import ast, sys
lists = {}
for node in ast.parse(open(sys.argv[1]).read()).body:
    if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
        name = node.targets[0].id
        if name in ("PROJECT_STRINGS", "PROJECT_LISTS", "PROJECT_OPTIONAL", "POOL_KEYS", "STACK_KEYS"):
            value = node.value
            lists[name] = [ast.literal_eval(k) for k in (value.keys if isinstance(value, ast.Dict) else value.elts)]
print("\n".join(sorted(k for keys in lists.values() for k in keys)))
PY
)
  run_bin -0 team-project --help
  # Each key is a word at the start of a line indented two spaces ("lease, return" names two).
  documented=$(grep -E '^  [a-z_]+(, [a-z_]+)* {2,}' <<<"$output" | sed -E 's/^  //; s/ {2,}.*//; s/, /\n/g' | sort)
  assert_equal "$documented" "$known"
  [[ $(wc -l <<<"$known") -ge 20 ]]
}

# The stack block of the registry shaped like the team home's, on alpha: stack_block <TOML lines>
# appended after its pool, so a test can add or change keys.
stack_block() {
  cat >>"$TEAM_HOME/projects.toml" <<TOML

[alpha.stack]
$(cat)
TOML
}

@test "an optional stack block reads whole and by dotted key, with its optional lists empty" {
  stack_block <<'TOML'
compose = "scripts/compose.sh"
seed = "scripts/seed.sh"
log_services = ["backend", "frontend"]
TOML
  run_bin -0 team-project --check
  run_bin -0 team-project alpha stack.compose
  assert_equal "$output" "scripts/compose.sh"
  run_bin -0 team-project alpha stack
  assert_equal "$(jq -c . <<<"$output")" \
    '{"compose":"scripts/compose.sh","seed":"scripts/seed.sh","log_services":["backend","frontend"],"images":[],"legacy_images":[]}'
  # A project without one has none.
  run_bin -0 team-project beta
  assert_equal "$(jq -c 'has("stack")' <<<"$output")" false
  run_bin -0 team-project --find stack.compose scripts/compose.sh
  assert_equal "$output" alpha
}

@test "the fixture registry's conventioner stack block passes --check and reads back" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  run_bin -0 team-project --check
  run_bin -0 team-project conventioner stack
  assert_equal "$(jq -c . <<<"$output")" \
    '{"compose":"scripts/th-compose.sh","seed":"scripts/seed_fixture.sh","log_services":["backend","frontend"],"images":["conventioner/backend","conventioner/frontend"],"legacy_images":["nmtest-[0-9]+-(backend|frontend)","nmfix-.*","nmtest-t12-.*","conventioner-[0-9]+-(backend|frontend)"],"legacy_gate":"nmtest-[0-9]+"}'
}

@test "--check refuses a stack block's missing and unknown keys, wrong types and rooted paths" {
  stack_block <<'TOML'
compose = "/opt/compose.sh"
log_services = "backend"
images = [1]
legacy_gate = ["nmtest-[0-9]+"]
ports = "auto"
TOML
  sed -i 's|^\[beta.pool\]$|stack = "compose.sh"\n\n[beta.pool]|' "$TEAM_HOME/projects.toml"
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'

[gamma]
repo = "owner/gamma"
path = "gamma"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["gamma/1"] }
stack = { compose = 7, seed = "../seed.sh", log_services = [], legacy_images = "nmfix-.*" }
TOML
  run_bin -1 --separate-stderr team-project --check
  assert_equal "$output" ""
  local expected
  for expected in \
    "alpha.stack: missing required key 'seed'" \
    "alpha.stack: unknown key 'ports'" \
    "alpha.stack.compose: '/opt/compose.sh' must be a relative path" \
    "alpha.stack.log_services: must be a list of strings" \
    "alpha.stack.images: must be a list of strings" \
    "alpha.stack.legacy_gate: must be a string" \
    "beta.stack: must be a table" \
    "gamma.stack.compose: must be a string" \
    "gamma.stack.seed: '../seed.sh' must be a relative path" \
    "gamma.stack.legacy_images: must be a list of strings"; do
    assert_contains "$stderr" "$expected"
  done
}

@test "--check refuses a stack pattern that does not compile, uses a backslash class or a lookaround" {
  stack_block <<'TOML'
compose = "scripts/compose.sh"
seed = "scripts/seed.sh"
log_services = []
images = ["conventioner/backend"]
legacy_images = ["nmtest-(backend", 'nmtest-\d+', 'nmfix-\.old', "nmtest-(?!t12).*", "conventioner-[0-9]+-(backend|frontend)"]
legacy_gate = 'nmtest-\w+'
TOML
  run_bin -1 --separate-stderr team-project --check
  local expected
  for expected in \
    "alpha.stack.legacy_images: 'nmtest-(backend' is not a valid pattern: missing ), unterminated subpattern at position 7" \
    "alpha.stack.legacy_images: 'nmtest-\\d+' uses a backslash class, which Bash and jq read differently; use a bracket expression such as [0-9]" \
    "alpha.stack.legacy_images: 'nmtest-(?!t12).*' uses a (?...) group, a lookaround or another extension Bash does not read" \
    "alpha.stack.legacy_gate: 'nmtest-\\w+' uses a backslash class, which Bash and jq read differently; use a bracket expression such as [0-9]"; do
    assert_contains "$stderr" "$expected"
  done
  # An escaped literal and the plain forms pass.
  [[ $stderr != *"nmfix-"* && $stderr != *"conventioner-"* ]]
  assert_contains "$stderr" "4 problems"
}
