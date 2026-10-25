#!/usr/bin/env bats
# team-lease: one machine holds the team, through compare-and-swap commits on the lease branch of
# the team home's origin. Two machines share one bare origin: home-pc is the sandbox's own HOME
# and team home, laptop is built by make_machine.

load helpers/common

setup() {
  sandbox
  origin=$(make_team_home home-pc)
  make_machine laptop
}

# What the team home <dir> shows a user: its branch, HEAD, raw index, staged and unstaged changes,
# untracked files and the working tree's contents, read without refreshing the index.
checkout_state() {
  local dir=$1
  git -C "$dir" symbolic-ref HEAD
  git -C "$dir" rev-parse HEAD
  sha256sum <"$dir/.git/index"
  git -C "$dir" --no-optional-locks status --porcelain=v2 --untracked-files=all
  git -C "$dir" --no-optional-locks diff
  git -C "$dir" --no-optional-locks diff --cached
  (cd "$dir" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
}

@test "A takes a fresh lease, creating the branch; B is refused naming A, and sees A hold it" {
  run git -C "$origin" rev-parse -q --verify refs/heads/lease
  assert_equal "$status" 1

  run_bin -0 --separate-stderr team-lease take
  assert_equal "$output" "home-pc holds the lease, epoch 1"
  lease_json | jq -e '.holder == "home-pc" and .epoch == 1 and .state == "held"
    and .ttl_minutes == 60 and .stolen_from == null and .taken_at == .renewed_at
    and (.renewed_at | fromdateiso8601) > now - 120'
  # A root commit holding only lease.json.
  assert_equal "$(git -C "$origin" rev-list --count lease)" 1
  assert_equal "$(git -C "$origin" ls-tree --name-only lease)" lease.json
  # This machine's record of its last write.
  jq -e --arg tip "$(git -C "$origin" rev-parse lease)" \
    '.commit == $tip and .epoch == 1 and .holder == "home-pc" and .state == "held"' \
    "$HOME/.local/state/agent-team/lease.json"

  on_machine laptop run_bin -1 --separate-stderr team-lease take
  assert_contains "$stderr" "held by home-pc (epoch 1), fresh: renewed 0 minutes ago"
  assert_equal "$(git -C "$origin" rev-list --count lease)" 1
  [[ ! -e $BATS_TEST_TMPDIR/machines/laptop/home/.local/state/agent-team/lease.json ]]

  on_machine laptop run_bin -0 team-lease status
  assert_contains "$output" "holder: home-pc"
  assert_contains "$output" "state: held"
  assert_contains "$output" "mine: false"
}

@test "A and B race take on a released lease 20 times: one wins each time, the loser names it" {
  local round a b winner loser
  run_bin -0 team-lease take
  run_bin -0 team-lease release
  for round in $(seq 20); do
    "$REPO_ROOT/bin/team-lease" take >"$BATS_TEST_TMPDIR/a.out" 2>&1 &
    a=$!
    on_machine laptop "$REPO_ROOT/bin/team-lease" take >"$BATS_TEST_TMPDIR/b.out" 2>&1 &
    b=$!
    wait "$a" && a=0 || a=$?
    wait "$b" && b=0 || b=$?
    if [[ $a == 0 && $b == 1 ]]; then
      winner=home-pc loser=b
    elif [[ $a == 1 && $b == 0 ]]; then
      winner=laptop loser=a
    else
      echo "round $round: home-pc exit $a ($(cat "$BATS_TEST_TMPDIR/a.out")), laptop exit $b ($(cat "$BATS_TEST_TMPDIR/b.out"))" >&2
      return 1
    fi
    assert_equal "$(lease_json | jq -r '.holder + " " + .state')" "$winner held"
    assert_contains "$(cat "$BATS_TEST_TMPDIR/$loser.out")" "held by $winner"
    if [[ $winner == home-pc ]]; then
      run_bin -0 team-lease release
    else
      on_machine laptop run_bin -0 team-lease release
    fi
  done
}

@test "A releases, B takes with epoch + 1, and A's renew and check say A no longer holds it" {
  run_bin -0 team-lease take
  run_bin -0 team-lease release
  assert_equal "$output" "home-pc released the lease, epoch 1"
  lease_json | jq -e '.holder == "home-pc" and .state == "released" and .epoch == 1'
  run_bin -1 --separate-stderr team-lease check
  assert_contains "$stderr" "the lease is released"

  on_machine laptop run_bin -0 team-lease take
  assert_equal "$output" "laptop holds the lease, epoch 2"
  lease_json | jq -e '.holder == "laptop" and .state == "held" and .epoch == 2 and .stolen_from == null'
  on_machine laptop run_bin -0 team-lease check
  assert_equal "$output" "laptop holds the lease, epoch 2"

  run_bin -1 --separate-stderr team-lease renew
  assert_contains "$stderr" "home-pc no longer holds the lease: laptop holds it (epoch 2"
  run_bin -1 --separate-stderr team-lease check
  assert_contains "$stderr" "home-pc no longer holds the lease: laptop holds it (epoch 2"
  run_bin -1 --separate-stderr team-lease release
  assert_contains "$stderr" "home-pc no longer holds the lease: laptop holds it (epoch 2"
  lease_json | jq -e '.holder == "laptop" and .state == "held" and .epoch == 2'
}

@test "the holder renews and re-takes without changing the epoch, and release is idempotent" {
  run_bin -0 team-lease take
  local taken
  taken=$(lease_json | jq -r .taken_at)
  age_lease 20
  run_bin -0 team-lease renew
  assert_equal "$output" "home-pc renewed the lease, epoch 1"
  lease_json | jq -e --arg taken "$taken" '.epoch == 1 and .taken_at == $taken
    and (.renewed_at | fromdateiso8601) > now - 120'
  run_bin -0 team-lease take
  assert_equal "$output" "home-pc holds the lease, epoch 1"
  run_bin -0 team-lease release
  run_bin -0 team-lease release
  assert_equal "$output" "the lease is already released (last held by home-pc, epoch 1)"
  run_bin -1 --separate-stderr team-lease renew
  assert_contains "$stderr" "the lease is released"
  # Taken back by its last holder: the holder did not change, so neither does the epoch.
  run_bin -0 team-lease take
  assert_equal "$output" "home-pc holds the lease, epoch 1"
}

@test "a stale lease is still refused; a steal needs the holder's name typed on the terminal" {
  local tty=$BATS_TEST_TMPDIR/tty
  run_bin -0 team-lease take
  age_lease 75

  on_machine laptop run_bin -1 --separate-stderr team-lease take
  assert_contains "$stderr" "held by home-pc (epoch 1), stale: renewed 75 minutes ago"
  assert_contains "$stderr" "team-lease take --steal"

  # No terminal, no steal.
  TEAM_LEASE_TTY=$BATS_TEST_TMPDIR/no/such/tty on_machine laptop run_bin -1 --separate-stderr team-lease take --steal
  assert_contains "$stderr" "no terminal to confirm the steal on"
  # A wrong name, or none, refuses.
  echo laptop >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -1 --separate-stderr team-lease take --steal
  assert_contains "$stderr" "'laptop' is not the holder's name, home-pc; nothing stolen"
  echo >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -1 --separate-stderr team-lease take --steal
  assert_contains "$stderr" "'' is not the holder's name, home-pc; nothing stolen"
  lease_json | jq -e '.holder == "home-pc" and .epoch == 1'

  echo home-pc >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -0 --separate-stderr team-lease take --steal
  assert_equal "$output" "laptop holds the lease, epoch 2, stolen from home-pc"
  lease_json | jq -e '.holder == "laptop" and .epoch == 2 and .state == "held" and .stolen_from == "home-pc"'
  # The terminal was shown the holder, the epoch and the last renewal, then asked for the name.
  assert_contains "$(cat "$tty")" "holder: home-pc, epoch 1, renewed"
  assert_contains "$(cat "$tty")" "(75 minutes ago, stale)"
  assert_contains "$(cat "$tty")" "Type the holder's name to steal the lease:"

  # A fresh lease can be stolen the same way.
  echo laptop >"$tty"
  TEAM_LEASE_TTY=$tty run_bin -0 team-lease take --steal
  lease_json | jq -e '.holder == "home-pc" and .epoch == 3 and .stolen_from == "laptop"'
}

@test "with origin unreachable, status shows the last known lease unconfirmed and nothing changes" {
  run_bin -0 team-lease take
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  local tip record refs
  tip=$(git -C "$origin" rev-parse lease)
  record=$(cat "$HOME/.local/state/agent-team/lease.json")
  refs=$(git -C "$TEAM_HOME" for-each-ref)

  run_bin -75 --separate-stderr team-lease status
  assert_equal "${lines[0]}" "UNCONFIRMED: GitHub is unreachable; this is the last known lease"
  assert_contains "$output" "holder: home-pc"
  assert_contains "$output" "confirmed: false"
  assert_contains "$stderr" "GitHub is unreachable"
  run_bin -75 --separate-stderr team-lease status --json
  jq -e '.holder == "home-pc" and .epoch == 1 and .confirmed == false and .mine == true' <<<"$output"

  local command
  for command in check take renew release; do
    run_bin -75 --separate-stderr team-lease "$command"
    assert_equal "$output" ""
    assert_contains "$stderr" "team-lease: GitHub is unreachable (git ls-remote:"
    assert_contains "$stderr" "nothing changed"
  done
  assert_equal "$(git -C "$origin" rev-parse lease)" "$tip"
  assert_equal "$(cat "$HOME/.local/state/agent-team/lease.json")" "$record"
  assert_equal "$(git -C "$TEAM_HOME" for-each-ref)" "$refs"
}

@test "status --json carries every field, and check exits 0 held, 1 not held" {
  run_bin -0 team-lease status --json
  jq -e '. == {holder: null, epoch: 0, state: "released", taken_at: null, renewed_at: null,
    ttl_minutes: 60, stolen_from: null, stale: false, age_minutes: null, mine: false, lost: false,
    fenced: null, offline_since: null, confirmed: true}' <<<"$output"
  run_bin -1 --separate-stderr team-lease check
  assert_contains "$stderr" "the lease is released"

  run_bin -0 team-lease take
  run_bin -0 team-lease check
  assert_equal "$output" "home-pc holds the lease, epoch 1"
  age_lease 61
  run_bin -0 team-lease status --json
  jq -e '(keys | sort) == (["holder", "epoch", "state", "taken_at", "renewed_at", "ttl_minutes",
      "stolen_from", "stale", "age_minutes", "mine", "lost", "fenced", "offline_since", "confirmed"] | sort)
    and .holder == "home-pc" and .epoch == 1 and .state == "held" and .stale == true
    and .age_minutes == 61 and .mine == true and .lost == false and .fenced == null and .offline_since == null
    and .confirmed == true' <<<"$output"
  on_machine laptop run_bin -0 team-lease status --json
  jq -e '.mine == false and .holder == "home-pc"' <<<"$output"
  on_machine laptop run_bin -1 --separate-stderr team-lease check
  assert_contains "$stderr" "laptop does not hold the lease: home-pc holds it (epoch 1"

  local state=$HOME/.local/state/agent-team
  echo '{"since": "2026-10-22T13:05:00Z"}' >"$state/offline"
  run_bin -0 team-lease status --json
  jq -e '.offline_since == "2026-10-22T13:05:00Z"' <<<"$output"
  run_bin -0 team-lease status
  assert_contains "$output" "offline_since: 2026-10-22T13:05:00Z"
}

@test "a fenced machine fails check and renew until its take clears the fence" {
  local state=$HOME/.local/state/agent-team
  run_bin -0 team-lease take
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$state/fenced"
  run_bin -0 team-lease status --json
  jq -e '.fenced == "2026-10-22T14:00:00Z"' <<<"$output"
  run_bin -1 --separate-stderr team-lease check
  assert_contains "$stderr" "home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2); team-lease take clears it"
  run_bin -1 --separate-stderr team-lease renew
  assert_contains "$stderr" "home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2)"
  run_bin -0 team-lease take
  [[ ! -e $state/fenced ]]
  run_bin -0 team-lease check
}

@test "renew on a machine whose lease was stolen fences it, and only a take clears the fence" {
  local state=$HOME/.local/state/agent-team
  stub_script claude <<'EOF'
case $1 in
  agents) echo '[{"id": "3169fcbd", "name": "coordinator"}, {"id": "81f08540", "name": "T5-builder"}, {"id": "1baf2408", "name": "notes"}]' ;;
  stop) [[ $2 != 81f08540 ]] || { echo "error: no such session" >&2; exit 1; } ;;
esac
EOF
  run_bin -0 team-lease take
  run_bin -0 team-lease status --json
  jq -e '.lost == false' <<<"$output"
  steal_lease laptop home-pc
  run_bin -0 team-lease status --json
  jq -e '.lost == true and .mine == false and .fenced == null' <<<"$output"
  on_machine laptop run_bin -0 team-lease status --json
  jq -e '.lost == false and .mine == true' <<<"$output"

  run_bin -1 --separate-stderr team-lease renew
  assert_equal "$stderr" "team-lease: home-pc no longer holds the lease: laptop holds it (epoch 2); fenced home-pc: stopped coordinator (3169fcbd); the heartbeat is not installed; nothing to disable; could not stop T5-builder (81f08540): error: no such session; team-lease take clears the fence"
  jq -e '.holder == "laptop" and .epoch == 2' "$state/fenced"
  assert_equal "$(stub_calls claude)" "$(printf '%s\n' '["agents","--json"]' '["stop","3169fcbd"]' '["stop","81f08540"]')"
  lease_json | jq -e '.holder == "laptop"'
  run_bin -1 --separate-stderr team-lease check
  assert_contains "$stderr" "home-pc is fenced since"

  # Taken again, once laptop releases it: the fence is gone.
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-lease take
  [[ ! -e $state/fenced ]]
  run_bin -0 team-lease status --json
  jq -e '.lost == false and .mine == true and .fenced == null and .epoch == 3' <<<"$output"
}

@test "the fence ends an ops session with team-ops-end, deleting its transcript; one it cannot end is stopped and said" {
  local uuid=6f93fe38-4a6e-4b35-8f39-776a26bc624b transcript
  transcript=$HOME/.claude/projects/-wt/$uuid.jsonl
  mkdir -p "${transcript%/*}"
  echo '{"query": "results"}' >"$transcript"
  stub_script claude <<EOF
case \$1 in
  agents) echo '[{"id": "81f08540", "name": "T5-builder"}, {"id": "6f93fe38", "sessionId": "$uuid", "name": "T5-ops"},
    {"id": "aaaaaaaa", "name": "T6-ops"}]' ;;
  stop | rm) ;;
esac
EOF
  run_bin -0 team-lease take
  steal_lease laptop home-pc

  run_bin -1 --separate-stderr team-lease renew
  assert_contains "$stderr" "fenced home-pc: stopped T5-builder (81f08540), T5-ops (6f93fe38, ended by team-ops-end), T6-ops (aaaaaaaa)"
  assert_contains "$stderr" "could not end T6-ops (aaaaaaaa) with team-ops-end (team-ops-end: cannot resolve the full session uuid of T6-ops (aaaaaaaa); nothing deleted), so its transcript is kept: run team-ops-end T6"
  [[ ! -e $transcript ]]
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] == "stop" or .[0] == "rm") | join(" ")')" "stop 81f08540
stop 6f93fe38
rm 6f93fe38
stop aaaaaaaa"
}

@test "a machine that released, or never held, the lease is not lost when another holds it" {
  run_bin -0 team-lease take
  run_bin -0 team-lease release
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  run_bin -0 team-lease status --json
  jq -e '.lost == false and .mine == false' <<<"$output"
  run_bin -1 --separate-stderr team-lease renew
  assert_contains "$stderr" "home-pc no longer holds the lease: laptop holds it"
  [[ ! -e $HOME/.local/state/agent-team/fenced ]]
  assert_equal "$(stub_calls claude)" ""

  make_machine desk
  on_machine desk run_bin -0 team-lease status --json
  jq -e '.lost == false' <<<"$output"
}

@test "a lease the record does not match is not this machine's to renew or check" {
  run_bin -0 team-lease take
  rm "$HOME/.local/state/agent-team/lease.json"
  run_bin -1 --separate-stderr team-lease check
  assert_contains "$stderr" "the lease names home-pc at epoch 1, but this machine has no record of taking it"
  run_bin -1 --separate-stderr team-lease renew
  assert_contains "$stderr" "run team-lease take to take it again"
  run_bin -0 team-lease take
  run_bin -0 team-lease check
}

@test "the team home's branch, index and working tree are the same after every command" {
  # A checkout mid-work: a staged change, an unstaged change and an untracked file.
  echo staged >"$TEAM_HOME/staged.txt"
  git -C "$TEAM_HOME" add staged.txt
  echo unstaged >>"$TEAM_HOME/ledger.jsonl"
  echo untracked >"$TEAM_HOME/untracked.txt"
  local before args tty=$BATS_TEST_TMPDIR/tty
  before=$(checkout_state "$TEAM_HOME")
  echo laptop >"$tty"
  for args in "status" "status --json" "take" "check" "renew" "release" "take" "check"; do
    # shellcheck disable=SC2086 # the words of each command
    run_bin team-lease $args
    assert_equal "$status" 0
    assert_equal "$(checkout_state "$TEAM_HOME")" "$before"
  done
  on_machine laptop run_bin -0 team-lease status
  on_machine laptop run_bin -1 team-lease take
  echo home-pc >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -0 team-lease take --steal
  run_bin -1 team-lease check
  run_bin -1 team-lease renew
  assert_equal "$(checkout_state "$TEAM_HOME")" "$before"
}

@test "git log lease shows one commit per change, naming the action, the machine and the epoch" {
  local tty=$BATS_TEST_TMPDIR/tty
  run_bin -0 team-lease take
  run_bin -0 team-lease renew
  run_bin -0 team-lease release
  run_bin -0 team-lease release
  on_machine laptop run_bin -0 team-lease take
  # Refusals and malformed commands write nothing.
  run_bin -1 team-lease take
  on_machine laptop run_bin -2 team-lease release --bogus
  echo laptop >"$tty"
  TEAM_LEASE_TTY=$tty run_bin -0 team-lease take --steal
  run_bin -2 team-lease status --json --bogus
  assert_equal "$(git -C "$origin" log --format=%s lease)" "$(printf '%s\n' \
    "lease: home-pc steal from laptop, epoch 3" \
    "lease: laptop take, epoch 2" \
    "lease: home-pc release, epoch 1" \
    "lease: home-pc renew, epoch 1" \
    "lease: home-pc take, epoch 1")"
  # Every commit holds lease.json alone, on a branch of its own history.
  assert_equal "$(git -C "$origin" log --format='%P' lease | tail -n 1)" ""
  assert_equal "$(git -C "$origin" log --format= --name-only lease | sort -u | grep .)" lease.json
  # The team home's own view of origin follows.
  assert_equal "$(git -C "$TEAM_HOME" rev-parse origin/lease)" "$(git -C "$origin" rev-parse lease)"
}

@test "lease commands on one machine wait for each other's lock" {
  local state=$HOME/.local/state/agent-team start
  mkdir -p "$state"
  flock -x "$state/lease.lock" sleep 2 &
  # Once the holder has the lock, however long a busy machine takes to start it.
  until [[ -f $state/lease.lock ]] && ! flock -n "$state/lease.lock" true; do sleep 0.05; done
  start=$(date +%s%N)
  run_bin -0 team-lease take
  wait
  # It waited for the lock's holder before taking the lease.
  (($(date +%s%N) - start >= 1000000000))
  [[ -f $state/lease.lock ]]
}

@test "team-lease refuses a malformed command line, a team home with no origin and a machine with no name" {
  run_bin -2 --separate-stderr team-lease
  assert_contains "$stderr" "usage: team-lease status [--json] | check | take [--steal] | renew | release"
  run_bin -2 team-lease frob
  run_bin -2 team-lease take --steal --again
  run_bin -2 team-lease status --steal
  run_bin -2 team-lease renew --json
  git -C "$TEAM_HOME" remote remove origin
  run_bin -1 --separate-stderr team-lease status
  assert_contains "$stderr" "team-lease: the team home $TEAM_HOME has no git remote origin"
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 --separate-stderr team-lease status
  assert_contains "$stderr" "team-lease: this machine has no team name"
}

@test "the coordinator and workers are denied typing a steal or a push to the lease ref" {
  local file command
  for file in "$REPO_ROOT/coordinator.settings.json" "$REPO_ROOT/settings/worker.json"; do
    for command in "team-lease take --steal" "$REPO_ROOT/bin/team-lease take --steal" \
      "TEAM_LEASE_TTY=/tmp/x team-lease take --steal" "cd ~/agent-team && bin/team-lease take --steal" \
      "git push origin lease" "git push -u origin lease" "git push origin HEAD:lease" \
      "git push origin abc123:refs/heads/lease" "git push origin :lease" "git push origin --delete lease" \
      "git push origin lease --force-with-lease"; do
      denied_in "$file" "$command" || { echo "${file##*/} allows: $command" >&2; return 1; }
    done
    for command in "team-lease take" "team-lease status --json" "git push origin feat/T20-lease-drill" \
      "git push -u origin feat/T17-portability"; do
      if denied_in "$file" "$command"; then echo "${file##*/} denies: $command" >&2; return 1; fi
    done
  done
}
