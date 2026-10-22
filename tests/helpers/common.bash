# Shared setup for the team home's bats tests: load it with `load helpers/common` and call
# `sandbox` from `setup`. Every test then runs real scripts from this checkout's bin/ against a
# temporary team home and HOME, with claude, gh and curl replaced by logging stubs.
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

# The scripts' platform rules apply to the tests too: on macOS, .bats files get the GNU tools.
# shellcheck source=bin/lib/platform.sh
source "$BATS_TEST_DIRNAME/../bin/lib/platform.sh"

# The checkout under test, whichever worktree it is.
REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
FAKE_DISCORD_TOKEN=fake-discord-token-for-tests

# Build the test's sandbox and point TEAM_HOME, HOME and PATH into it.
sandbox() {
  local root
  root=$(realpath "$BATS_TEST_TMPDIR")
  export TEAM_HOME=$root/team HOME=$root/home
  export STUB_CALLS=$root/calls STUB_FIXTURES=$root/fixtures
  mkdir -p "$TEAM_HOME" "$HOME/.claude/channels/discord" "$STUB_CALLS" "$STUB_FIXTURES" "$root/stubs"
  : >"$TEAM_HOME/ledger.jsonl"
  echo "DISCORD_BOT_TOKEN=$FAKE_DISCORD_TOKEN" >"$HOME/.claude/channels/discord/.env"

  local cmd
  for cmd in claude gh curl; do cp "$REPO_ROOT/tests/helpers/stub" "$root/stubs/$cmd"; done
  export PATH=$root/stubs:$PATH

  # git reads only the sandbox's config.
  export GIT_CONFIG_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  git config --global user.name "Team Test"
  git config --global user.email team-test@example.invalid
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false

  unset TEAM_COORDINATOR_CHANNEL CLAUDE_PROJECT_DIR
  guard_sandbox
}

# Fail unless TEAM_HOME and HOME are inside this test's temporary directory, so no test can
# reach the real team home or the real HOME.
guard_sandbox() {
  local root var path
  root=$(realpath "$BATS_TEST_TMPDIR")
  for var in TEAM_HOME HOME; do
    path=$(realpath -m -- "${!var:-/}")
    if [[ $path != "$root"/* ]]; then
      echo "sandbox guard: $var=${!var:-} is outside the test's directory $root" >&2
      return 1
    fi
  done
}

# Run a script from this checkout's bin/ with bats' `run`, after the sandbox guard.
# Leading options go to `run` (e.g. `run_bin -2 team-thread`, `run_bin --separate-stderr ...`).
run_bin() {
  local opts=()
  while [[ $1 == -* ]]; do opts+=("$1"); shift; done
  guard_sandbox || return 1
  run "${opts[@]}" "$REPO_ROOT/bin/$1" "${@:2}"
}

# The stub <cmd> prints <stdout> and exits with <status> (default 0).
stub_reply() {
  printf '%s\n' "$2" >"$STUB_FIXTURES/$1.out"
  echo "${3:-0}" >"$STUB_FIXTURES/$1.status"
}

# The stub <cmd> runs the Bash read from stdin, with the call's arguments as "$@".
stub_script() {
  cat >"$STUB_FIXTURES/$1.sh"
}

# The calls made to stub <cmd>, one JSON array of arguments per line (nothing if never called).
stub_calls() {
  cat "$STUB_CALLS/$1.log" 2>/dev/null || true
}

# Build a bare repo as origin and a primary clone at $HOME/projects/<name>, with one commit on
# <branch> (default main) pushed; prints the clone's path.
make_repo() {
  local name=$1 branch=${2:-main}
  local origin=$BATS_TEST_TMPDIR/origin/$name.git clone=$HOME/projects/$name
  git init -q --bare -b "$branch" "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  git -C "$clone" checkout -q -B "$branch"
  echo "$name" >"$clone/README.md"
  git -C "$clone" add README.md
  git -C "$clone" commit -q -m "chore: start $name"
  git -C "$clone" push -q -u origin "$branch"
  git -C "$clone" remote set-head origin "$branch"
  echo "$clone"
}

# Make the sandbox's team home a clone of a bare origin standing in for GitHub (at
# $BATS_TEST_TMPDIR/origin/agent-team.git), with its files committed on dev and pushed, and name
# this machine <name> (default home-pc); prints the origin's path.
make_team_home() {
  local origin
  origin=$(realpath "$BATS_TEST_TMPDIR")/origin/agent-team.git
  git init -q --bare -b dev "$origin"
  git -C "$TEAM_HOME" init -q -b dev
  git -C "$TEAM_HOME" remote add origin "$origin"
  git -C "$TEAM_HOME" add -A
  git -C "$TEAM_HOME" commit -q -m "chore: start the team home"
  git -C "$TEAM_HOME" push -q -u origin dev
  mkdir -p "$HOME/.config/agent-team"
  echo "${1:-home-pc}" >"$HOME/.config/agent-team/machine"
  echo "$origin"
}

# Make the sandbox's team home a clone of a bare origin (make_team_home) and take the lease as
# this machine, named <name> (default home-pc), so the team's sessions may launch here; prints
# the origin's path.
hold_lease() {
  local origin
  origin=$(make_team_home "${1:-home-pc}")
  "$REPO_ROOT/bin/team-lease" take >/dev/null
  echo "$origin"
}

# Build a second machine named <name> (make_team_home first): its own HOME, with this HOME's git
# identity and Discord token and its own machine name, its own team home cloned from the team
# home's origin, and a clone at <its HOME>/projects/<repo> of every other bare origin made so
# far (make_repo). Run commands there with on_machine.
make_machine() {
  local name=$1 root origin repo
  root=$(realpath "$BATS_TEST_TMPDIR")/machines/$name
  mkdir -p "$root/home/.config/agent-team" "$root/home/.claude/channels/discord"
  cp "$HOME/.gitconfig" "$root/home/.gitconfig"
  cp "$HOME/.claude/channels/discord/.env" "$root/home/.claude/channels/discord/.env"
  echo "$name" >"$root/home/.config/agent-team/machine"
  git clone -q "$(realpath "$BATS_TEST_TMPDIR")/origin/agent-team.git" "$root/team"
  for origin in "$(realpath "$BATS_TEST_TMPDIR")"/origin/*.git; do
    repo=${origin##*/}
    repo=${repo%.git}
    [[ $repo != agent-team ]] || continue
    git clone -q "$origin" "$root/home/projects/$repo" 2>/dev/null
  done
}

# Run <command...> on the machine make_machine built: with its HOME and its team home, e.g.
# `on_machine laptop run_bin -0 team-lease take`.
on_machine() {
  local root
  root=$(realpath "$BATS_TEST_TMPDIR")/machines/$1
  [[ -d $root ]] || { echo "on_machine: no machine $1 (make_machine $1 first)" >&2; return 1; }
  HOME=$root/home TEAM_HOME=$root/team "${@:2}"
}

assert_equal() {
  if [[ $1 != "$2" ]]; then
    printf 'expected: %s\nactual:   %s\n' "$2" "$1" >&2
    return 1
  fi
}

assert_contains() {
  if [[ $1 != *"$2"* ]]; then
    printf 'expected to contain: %s\nactual: %s\n' "$2" "$1" >&2
    return 1
  fi
}
