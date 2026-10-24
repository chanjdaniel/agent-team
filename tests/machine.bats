#!/usr/bin/env bats
# The library's machine identity and recorded paths: the team home it finds and home_repo, the
# repo its origin names, machine_name, the machine's team name, and local_path, a recorded path as
# the same path under this machine's HOME.

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

# A copy of the library in a code checkout of its own, $BATS_TEST_TMPDIR/code, whose bin/team-x
# prints the team home it finds; prints the checkout's path.
code_checkout() {
  local code=$BATS_TEST_TMPDIR/code
  mkdir -p "$code/bin"
  cp -R "$REPO_ROOT/bin/lib" "$code/bin/"
  cat >"$code/bin/team-x" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"
printf '%s\n' "$TEAM_HOME"
SCRIPT
  chmod +x "$code/bin/team-x"
  echo "$code"
}

# The team home this machine names: home_setting <first line>
home_setting() {
  mkdir -p "$HOME/.config/agent-team"
  printf '%s\nignored\n' "$1" >"$HOME/.config/agent-team/home"
}

@test "with TEAM_HOME unset, the team home is the first line of ~/.config/agent-team/home, under HOME" {
  local code
  code=$(code_checkout)
  mkdir -p "$HOME/agent-team-records"
  home_setting agent-team-records
  unset TEAM_HOME
  run -0 "$code/bin/team-x"
  assert_equal "$output" "$HOME/agent-team-records"
}

@test "an absolute path in ~/.config/agent-team/home is used as written" {
  local code
  code=$(code_checkout)
  mkdir -p "$BATS_TEST_TMPDIR/records"
  home_setting "$BATS_TEST_TMPDIR/records"
  unset TEAM_HOME
  run -0 "$code/bin/team-x"
  assert_equal "$output" "$BATS_TEST_TMPDIR/records"
}

@test "TEAM_HOME, when set, wins over ~/.config/agent-team/home" {
  local code
  code=$(code_checkout)
  home_setting agent-team-records
  run -0 "$code/bin/team-x"
  assert_equal "$output" "$TEAM_HOME"
}

@test "with neither TEAM_HOME nor ~/.config/agent-team/home, the team home is the directory above bin/" {
  local code
  code=$(code_checkout)
  unset TEAM_HOME
  run -0 "$code/bin/team-x"
  assert_equal "$output" "$code"
}

@test "a setting naming a missing directory, or none, is refused with the path and the file it came from" {
  local code
  code=$(code_checkout)
  unset TEAM_HOME
  home_setting agent-team-records
  run -1 "$code/bin/team-x"
  assert_equal "$output" "team-x: the team home $HOME/agent-team-records, named by ~/.config/agent-team/home, is not a directory; name its checkout there, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  home_setting ''
  run -1 "$code/bin/team-x"
  assert_equal "$output" "team-x: the setting ~/.config/agent-team/home names no team home; name its checkout there, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  # --help still answers.
  run -0 "$code/bin/team-x" --help
}

@test "home_repo reads owner/name from the team home's origin in each GitHub form, and fails for others" {
  git -C "$TEAM_HOME" init -q
  lib_run -1 team-x home_repo
  local url
  for url in https://github.com/Owner/agent-team.git https://github.com/Owner/agent-team \
    https://github.com/Owner/agent-team/ git@github.com:Owner/agent-team.git ssh://git@github.com/Owner/agent-team.git; do
    git -C "$TEAM_HOME" remote remove origin 2>/dev/null || true
    git -C "$TEAM_HOME" remote add origin "$url"
    lib_run -0 team-x home_repo
    assert_equal "$output" Owner/agent-team
  done
  for url in "$BATS_TEST_TMPDIR/origin.git" https://gitlab.com/owner/agent-team.git https://github.com/owner/a/b; do
    git -C "$TEAM_HOME" remote set-url origin "$url"
    lib_run -1 team-x home_repo
  done
  # The URL as configured, never the one url.insteadOf leads to.
  git -C "$TEAM_HOME" remote set-url origin https://github.com/owner/agent-team.git
  git config --global url."$BATS_TEST_TMPDIR/origin.git".insteadOf https://github.com/owner/agent-team.git
  lib_run -0 team-x home_repo
  assert_equal "$output" owner/agent-team
}
