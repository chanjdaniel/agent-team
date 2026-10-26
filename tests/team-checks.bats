#!/usr/bin/env bats
# team-checks: a project's local checks, run in a fresh detached worktree of a head, as team-merge runs them.

load helpers/common

setup() {
  sandbox
  primary=$(make_repo proj dev)
  cat >"$primary/check.sh" <<'SH'
#!/usr/bin/env bash
echo "$PWD $(git rev-parse HEAD) $TMPDIR" >>"$CHECKS_DIR/ran"
echo "checking the head"
[[ -f needed.txt ]] || { echo "needed.txt is missing"; exit 3; }
SH
  chmod +x "$primary/check.sh"
  git -C "$primary" add check.sh
  git -C "$primary" commit -q -m "test: the local check"
  head=$(git -C "$primary" rev-parse HEAD)
  export CHECKS_DIR=$BATS_TEST_TMPDIR/checks
  mkdir -p "$CHECKS_DIR"
  registry '["./check.sh"]'
}

# registry <local_checks as a TOML list, or empty for none>
registry() {
  {
    cat <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "dev"
delivery = "direct-pr"
merge_method = "squash"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []
TOML
    [[ -z $1 ]] || echo "local_checks = $1"
    printf '\n[proj.pool]\nprovider = "git"\nslots = ["slots/proj/1"]\n'
  } >"$TEAM_HOME/projects.toml"
}

# The worktrees of proj's primary checkout, one path per line.
proj_worktrees() {
  git -C "$primary" worktree list --porcelain | sed -n 's/^worktree //p'
}

@test "--help prints the header" {
  run_bin -0 team-checks --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-checks")"
  assert_contains "$output" "Usage: team-checks <project> <head> [--from <checkout>] [--label <text>]"
}

@test "a check that needs an untracked file fails although the calling checkout has it, and its last lines are printed" {
  echo "left by earlier work" >"$primary/needed.txt"
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_contains "$stderr" "team-checks: running ./check.sh on ${head:0:7}"
  assert_contains "$output" "local check './check.sh' failed on the head ${head:0:7} (exit 3); its last lines:"
  assert_contains "$output" "      needed.txt is missing"
  assert_equal "$(proj_worktrees)" "$primary"
}

@test "a passing check exits 0 from a detached worktree of the head, with TMPDIR outside the home directory, and leaves no worktree behind" {
  echo "needed" >"$primary/needed.txt"
  git -C "$primary" add needed.txt
  git -C "$primary" commit -q -m "test: what the check needs"
  head=$(git -C "$primary" rev-parse HEAD)
  # The calling checkout has moved on: the check runs on the head it is given.
  git -C "$primary" commit -q --allow-empty -m "chore: later"
  run_bin -0 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_equal "$output" "local check './check.sh' passed on the head ${head:0:7}"
  local where sha tmp
  read -r where sha tmp <"$CHECKS_DIR/ran"
  assert_equal "$sha" "$head"
  [[ $where != "$primary" && ! -e $where ]]
  [[ $tmp != "$HOME"/* && $tmp != /home/* && $tmp != /Users/* && ! -e $tmp ]]
  assert_equal "$(proj_worktrees)" "$primary"
  assert_equal "$(git -C "$primary" branch --show-current)" dev
}

@test "the checkout defaults to the repository of the current directory, and a head is given in full or short" {
  echo "needed" >"$primary/needed.txt"
  git -C "$primary" add needed.txt
  git -C "$primary" commit -q -m "test: what the check needs"
  head=$(git -C "$primary" rev-parse HEAD)
  mkdir -p "$primary/sub"
  cd "$primary/sub"
  run_bin -0 --separate-stderr team-checks proj "${head:0:12}"
  assert_equal "$output" "local check './check.sh' passed on the head ${head:0:7}"
  assert_equal "$(cut -d' ' -f2 "$CHECKS_DIR/ran")" "$head"
}

@test "every check runs, each one's result printed, and any failure exits 1" {
  registry '["./check.sh", "true", "echo fine && exit 4"]'
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_equal "$(grep -v '^      ' <<<"$output")" "local check './check.sh' failed on the head ${head:0:7} (exit 3); its last lines:
local check 'true' passed on the head ${head:0:7}
local check 'echo fine && exit 4' failed on the head ${head:0:7} (exit 4); its last lines:"
  assert_contains "$output" "      fine"
}

@test "the checks run under the heavy-run lock with the label given, and one that cannot take it exits 75" {
  printf '#!/usr/bin/env bash\n"$HEAVY" status >>"$CHECKS_DIR/heavy"\n' >"$primary/heavy.sh"
  chmod +x "$primary/heavy.sh"
  git -C "$primary" add heavy.sh
  git -C "$primary" commit -q -m "test: a check that reads the lock"
  head=$(git -C "$primary" rev-parse HEAD)
  registry '["./heavy.sh"]'
  HEAVY=$REPO_ROOT/bin/team-heavy run_bin -0 team-checks proj "$head" --from "$primary" --label "team-merge T14"
  [[ $(cat "$CHECKS_DIR/heavy") =~ ^held\ by\ team-merge\ T14:\ ./heavy.sh\ on\ ${head:0:7}\ \(pid\ [0-9]+\)\ since\  ]]

  mkdir -p "$HOME/.local/state/agent-team"
  exec {held}<>"$HOME/.local/state/agent-team/heavy.lock"
  echo "first (pid 1) since 2026-10-25 10:00:00 +0000" >"$HOME/.local/state/agent-team/heavy.lock"
  flock -x "$held"
  TEAM_HEAVY_WAIT_MINUTES=0 run_bin -75 team-checks proj "$head" --from "$primary"
  assert_contains "$output" "could not run on the head ${head:0:7} yet (exit 75, try again later); its last lines:"
  assert_contains "$output" "team-heavy: the heavy-run lock is held by first (pid 1) since 2026-10-25 10:00:00 +0000"
  exec {held}<&-
  assert_equal "$(proj_worktrees)" "$primary"
}

@test "a project with no local checks exits 0 and makes no worktree" {
  registry ''
  run_bin -0 team-checks proj "$head" --from "$primary"
  assert_equal "$output" "team-checks: proj has no local checks"
  [[ ! -e $CHECKS_DIR/ran ]]
  assert_equal "$(proj_worktrees)" "$primary"
}

@test "a head that is not a commit in the checkout, or a checkout that is not a repository, is refused" {
  run_bin -1 team-checks proj 5555555555555555555555555555555555555555 --from "$primary"
  assert_contains "$output" "team-checks: 5555555555555555555555555555555555555555 is not a commit in $primary"
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run_bin -1 team-checks proj "$head" --from "$BATS_TEST_TMPDIR/plain"
  assert_contains "$output" "team-checks: $BATS_TEST_TMPDIR/plain is not a git checkout"
  run_bin -1 team-checks nosuch "$head" --from "$primary"
  [[ ! -e $CHECKS_DIR/ran ]]
}

@test "a malformed command line is a usage error" {
  run_bin -2 team-checks
  assert_contains "$output" "usage: team-checks <project> <head> [--from <checkout>] [--label <text>]"
  run_bin -2 team-checks proj
  run_bin -2 team-checks proj "$head" extra
  run_bin -2 team-checks proj "$head" --from
  run_bin -2 team-checks proj "$head" --label
  run_bin -2 team-checks proj "$head" --bogus
}
