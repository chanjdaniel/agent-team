#!/usr/bin/env bats
# The library's machine identity and recorded paths: machine_name, the machine's team name, and
# local_path, a recorded path as the same path under this machine's HOME.

load helpers/common

setup() {
  sandbox
  mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# lib_run -<status> <name> <code> [<arguments>...]: run a script named <name> that sources this
# checkout's library and runs <code> with the arguments as "$@", expecting exit <status>.
lib_run() {
  local status=$1 script=$BATS_TEST_TMPDIR/bin/$2
  shift
  cat >"$script" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bin/lib/team.sh"
$2
SCRIPT
  chmod +x "$script"
  guard_sandbox
  run "$status" "$script" "${@:3}"
}

@test "machine_name prints the first line of ~/.config/agent-team/machine" {
  mkdir -p "$HOME/.config/agent-team"
  printf 'home-pc\nignored\n' >"$HOME/.config/agent-team/machine"
  lib_run -0 team-x machine_name
  assert_equal "$output" "home-pc"
}

@test "machine_name with no file fails naming how to write it" {
  lib_run -1 team-x machine_name
  assert_equal "$output" \
    "team-x: this machine has no team name; write one with: echo <name> > ~/.config/agent-team/machine"
}

@test "machine_name refuses a name that is not lower-case kebab case" {
  mkdir -p "$HOME/.config/agent-team"
  local name
  for name in Home-PC home_pc -laptop laptop- 'home pc' home--pc ''; do
    printf '%s\n' "$name" >"$HOME/.config/agent-team/machine"
    lib_run -1 team-x machine_name
    assert_equal "$output" "team-x: ~/.config/agent-team/machine names '$name', not a lower-case kebab-case name like home-pc; write one with: echo <name> > ~/.config/agent-team/machine"
  done
  echo laptop2 >"$HOME/.config/agent-team/machine"
  lib_run -0 team-x machine_name
  assert_equal "$output" "laptop2"
}

@test "local_path re-roots a path under any home directory to this HOME" {
  lib_run -0 team-x 'local_path "$1"' /home/alice/agent-team/x
  assert_equal "$output" "$HOME/agent-team/x"
  lib_run -0 team-x 'local_path "$1"' /Users/alice/agent-team/x
  assert_equal "$output" "$HOME/agent-team/x"
  lib_run -0 team-x 'local_path "$1"' /home/alice
  assert_equal "$output" "$HOME"
}

@test "local_path leaves any other path unchanged" {
  local path
  for path in /tmp/x /opt/x /home /Users/ /var/home/alice/x relative/home/alice/x; do
    lib_run -0 team-x 'local_path "$1"' "$path"
    assert_equal "$output" "$path"
  done
}
