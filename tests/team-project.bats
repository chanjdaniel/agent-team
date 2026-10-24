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

@test "--find names the projects whose key holds a value: repo in any case, paths by their real path" {
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
# registry beside bin/ as the fallback's team home; prints the checkout's path.
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

@test "with neither TEAM_HOME nor ~/.config/agent-team/home it reads the registry of the checkout it runs from" {
  local code
  code=$(code_checkout)
  unset TEAM_HOME
  run -0 "$code/bin/team-project" --list
  assert_equal "$output" $'conventioner\nagent-team'
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

@test "a registry shaped like the team home's passes --check and holds both projects" {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  run_bin -0 team-project --check
  run_bin -0 team-project --list
  assert_equal "$output" $'conventioner\nagent-team'

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
