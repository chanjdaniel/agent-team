# Shared setup for the team home's bats tests: load it with `load helpers/common` and call
# `sandbox` from `setup`. Every test then runs real scripts from this checkout's bin/ against a
# temporary team home and HOME, with claude, gh and curl replaced by logging stubs.
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

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
