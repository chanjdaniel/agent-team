#!/usr/bin/env bats
# team-heavy: the machine's heavy commands take one flock in turn, in the sandbox's HOME; and
# tests/run, team-checks' local checks and the doctor use it.

load helpers/common

setup() {
  sandbox
}

teardown() {
  # Let a holder a test left go, so bats does not wait on it.
  touch "$BATS_TEST_TMPDIR/release"
  wait 2>/dev/null || true
}

# Wait until <file> exists, up to 20 seconds.
wait_for() {
  local i
  for ((i = 0; i < 200; i++)); do
    [[ ! -e $1 ]] || return 0
    sleep 0.1
  done
  echo "wait_for: $1 never appeared" >&2
  return 1
}

# Start a run labelled <label> in the background that holds the lock until $BATS_TEST_TMPDIR/release
# exists, and return once it holds it.
hold() {
  "$REPO_ROOT/bin/team-heavy" run --label "$1" -- bash -c '
    touch "$0/held"
    until [[ -e $0/release ]]; do sleep 0.1; done
    echo "$1" >>"$0/order"' "$BATS_TEST_TMPDIR" "$1" >/dev/null 2>&1 3>&- &
  wait_for "$BATS_TEST_TMPDIR/held"
}

@test "run takes the lock, runs the command with TEAM_HEAVY_HELD set and the lock's descriptor closed, and exits with its status" {
  run_bin -0 team-heavy status
  assert_equal "$output" free
  cd "$HOME"
  run_bin -3 team-heavy run -- bash -c 'echo "held=$TEAM_HEAVY_HELD"; "$0/bin/team-heavy" status; exit 3' "$REPO_ROOT"
  assert_equal "${lines[0]}" "held=1"
  [[ ${lines[1]} =~ ^held\ by\ bash\ -c\ .*\ in\ ~\ \(pid\ [0-9]+\)\ since\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9:]{8}\ [+-][0-9]{4}$ ]]
  run_bin -0 team-heavy status
  assert_equal "$output" free
}

@test "a second run waits once, naming the holder, and runs when the first ends" {
  hold first
  run_bin -0 team-heavy status
  [[ $output =~ ^held\ by\ first\ \(pid\ [0-9]+\)\ since\ [0-9-]{10}\ [0-9:]{8}\ [+-][0-9]{4}$ ]]
  (sleep 1 && touch "$BATS_TEST_TMPDIR/release") &
  run_bin -0 --separate-stderr team-heavy run --wait 1 --label second -- bash -c 'echo second >>"$0/order"' "$BATS_TEST_TMPDIR"
  assert_equal "$(grep -c waiting <<<"$stderr")" 1
  assert_contains "$stderr" "team-heavy: waiting up to 1 minutes for the heavy-run lock, held by first (pid "
  assert_equal "$(cat "$BATS_TEST_TMPDIR/order")" "first"$'\n'"second"
}

@test "a run that cannot wait exits 75 naming the holder, and runs nothing" {
  hold first
  run_bin -75 --separate-stderr team-heavy run --wait 0 -- touch "$BATS_TEST_TMPDIR/ran"
  assert_contains "$stderr" "team-heavy: the heavy-run lock is held by first (pid "
  [[ ! -e $BATS_TEST_TMPDIR/ran ]]
  TEAM_HEAVY_WAIT_MINUTES=0 run_bin -75 --separate-stderr team-heavy run -- touch "$BATS_TEST_TMPDIR/ran"
  [[ ! -e $BATS_TEST_TMPDIR/ran ]]
}

@test "a nested run runs at once, and what a run leaves running does not keep the lock" {
  hold first
  TEAM_HEAVY_HELD=1 run_bin -0 team-heavy run --wait 0 -- echo nested
  assert_equal "$output" nested
  touch "$BATS_TEST_TMPDIR/release"
  wait
  run_bin -0 team-heavy run -- bash -c 'sleep 30 >/dev/null 2>&1 & echo $! >"$0/left"' "$BATS_TEST_TMPDIR"
  run_bin -0 team-heavy status
  kill "$(cat "$BATS_TEST_TMPDIR/left")"
  assert_equal "$output" free
}

@test "run and status refuse a malformed command line" {
  run_bin -2 team-heavy
  run_bin -2 team-heavy start
  run_bin -2 team-heavy status --json
  run_bin -2 team-heavy run echo hi
  run_bin -2 team-heavy run --
  run_bin -2 team-heavy run --wait soon -- echo hi
  TEAM_HEAVY_WAIT_MINUTES=soon run_bin -2 team-heavy run -- echo hi
}

# A root holding this checkout's bin/ and tests/run, whose bats is a stub that logs
# TEAM_HEAVY_HELD and the lock's status to $BATS_TEST_TMPDIR/bats.
fake_suite() {
  local root=$BATS_TEST_TMPDIR/suite
  mkdir -p "$root/tests/vendor/bats-core/bin"
  copy_bin "$root/bin"
  cp "$REPO_ROOT/tests/run" "$root/tests/run"
  link_shared tests-shards "$REPO_ROOT/tests/shards" "$root/tests/shards"
  touch "$root/tests/one.bats"
  cat >"$root/tests/vendor/bats-core/bin/bats" <<SH
#!/usr/bin/env bash
echo "held=\$TEAM_HEAVY_HELD \$("$root/bin/team-heavy" status)" >>"$BATS_TEST_TMPDIR/bats"
echo "ok 1 one"
SH
  chmod +x "$root/tests/vendor/bats-core/bin/bats"
  echo "$root"
}

@test "tests/run runs its bats under the heavy-run lock, and waits for another holder" {
  root=$(fake_suite)
  run -0 "$root/tests/run" bats
  [[ $(cat "$BATS_TEST_TMPDIR/bats") =~ ^held=1\ held\ by\ tests/run\ bats\ in\ "$root"\ \(pid\ [0-9]+\)\ since\  ]]
  rm "$BATS_TEST_TMPDIR/bats"
  hold first
  TEAM_HEAVY_WAIT_MINUTES=0 run -75 --separate-stderr "$root/tests/run" bats
  assert_contains "$stderr" "team-heavy: the heavy-run lock is held by first (pid "
  [[ ! -e $BATS_TEST_TMPDIR/bats ]]
  # Under a run already, it runs at once.
  TEAM_HEAVY_HELD=1 run -0 "$root/tests/run" bats
  assert_contains "$(cat "$BATS_TEST_TMPDIR/bats")" "held=1 held by first"
}
