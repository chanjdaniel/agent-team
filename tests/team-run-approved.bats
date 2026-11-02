#!/usr/bin/env bats
# team-run-approved: running a script Daniel approved, bound to the bytes they were asked on.

load helpers/common

setup() {
  sandbox
  hold_lease >/dev/null
  WT=$BATS_TEST_TMPDIR/wt/7
  MARK=$BATS_TEST_TMPDIR/ran-marker
  mkdir -p "$WT/scripts" "$TEAM_HOME/tasks/T7"
  echo "{\"ts\":\"2026-11-01T10:00:00Z\",\"task\":\"T7\",\"event\":\"opened\",\"project\":\"agent-team\",\"path\":\"feature\",\"type\":\"feat\",\"title\":\"x\",\"branch\":\"feat/T7-x\",\"base\":\"dev\",\"base_sha\":\"0123456\",\"worktree\":\"$WT\"}" \
    >>"$TEAM_HOME/ledger.jsonl"
  approved_script "$WT/scripts/fix.sh" 3
}

# Write a script that leaves the marker, prints a line to stdout and one to stderr, names its
# directory, and exits with <code>: approved_script <path> <code>
approved_script() {
  cat >"$1" <<SCRIPT
echo ran >>"$MARK"
echo "fixing in \$PWD"
echo "a warning" >&2
exit $2
SCRIPT
}

hash_of() {
  sha256sum "$1" | cut -d' ' -f1
}

# Ask about <script> as <id> and log Daniel's answer: approve <id> <script>
approve() {
  run_bin -0 team-log T7 asked id="$1" text=run-it script="$2" sha256="$(hash_of "$2")"
  run_bin -0 team-log T7 answered id="$1" answer=yes
}

# The ledger's events of T7 after the opened, without ts, one per line.
events() {
  jq -c 'select(.event != "opened") | del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

# Refuses with <output>, after <before> when given, running nothing and logging nothing:
# refuses <output> <id> [<before>]
refuses() {
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 team-run-approved T7 "$2"
  assert_equal "$output" "${3:-}team-run-approved: $1"
  [[ ! -e $MARK ]]
  [[ ! -e $TEAM_HOME/tasks/T7/runs/$2.log ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "--help prints the header" {
  run_bin -0 team-run-approved --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-run-approved")"
  assert_contains "$output" "Usage: team-run-approved T<n> <id>"
}

@test "a malformed command line is a usage error" {
  run_bin -2 team-run-approved T7
  run_bin -2 team-run-approved T7 fix extra
  run_bin -2 team-run-approved 7 fix
  run_bin -2 team-run-approved T7 ../fix
}

@test "an answered ask runs the script in its directory, its output to the run log, and logs ran with its exit code, which is the command's" {
  approve fix "$WT/scripts/fix.sh"
  run_bin -3 --separate-stderr team-run-approved T7 fix
  local log=$TEAM_HOME/tasks/T7/runs/fix.log
  assert_equal "$(cat "$log")" "fixing in $WT/scripts
a warning"
  assert_equal "$output" "fixing in $WT/scripts
a warning
T7 ran fix ($WT/scripts/fix.sh), exit 3; its output is in $log"
  assert_equal "$(cat "$MARK")" "ran"
  assert_equal "$(events | tail -n 1)" '{"task":"T7","event":"ran","id":"fix","exit":3}'
  run_bin -0 team-log --check
}

@test "a script that exits 0 is exit 0, and one in the task directory runs too" {
  approved_script "$TEAM_HOME/tasks/T7/ok.sh" 0
  approve ok "$TEAM_HOME/tasks/T7/ok.sh"
  run_bin -0 team-run-approved T7 ok
  assert_equal "$(events | tail -n 1)" '{"task":"T7","event":"ran","id":"ok","exit":0}'
  assert_equal "$(cat "$TEAM_HOME/tasks/T7/runs/ok.log")" "fixing in $TEAM_HOME/tasks/T7
a warning"
}

@test "the run is the bytes hashed: a script that rewrites itself as it runs still ran as approved" {
  cat >"$WT/scripts/self.sh" <<SCRIPT
echo 'echo tampered >>"$MARK"' >"$WT/scripts/self.sh"
echo ran >>"$MARK"
SCRIPT
  approve self "$WT/scripts/self.sh"
  run_bin -0 team-run-approved T7 self
  assert_equal "$(cat "$MARK")" "ran"
}

@test "refused with nothing run: no ask, an ask with no script, no answer since the ask" {
  refuses "T7 never asked fix" fix
  run_bin -0 team-log T7 asked id=plain text=no-script
  run_bin -0 team-log T7 answered id=plain answer=yes
  refuses "T7's ask plain, at $(jq -r 'select(.event == "asked") | .ts' "$TEAM_HOME/ledger.jsonl"), names no script: an approved script is asked with team-log T7 asked id=plain text=<the question> script=<absolute path> sha256=<its sha256sum>" plain
  # An answer to an earlier ask of the same id answers nothing asked since.
  approve fix "$WT/scripts/fix.sh"
  run_bin -0 team-log T7 asked id=fix text=again script="$WT/scripts/fix.sh" sha256="$(hash_of "$WT/scripts/fix.sh")"
  local at
  at=$(jq -r 'select(.event == "asked" and .id == "fix") | .ts' "$TEAM_HOME/ledger.jsonl" | tail -n 1)
  refuses "T7's ask fix, at $at, has no answered since: Daniel has not answered it" fix
  # Another ask's answer is not this one's.
  run_bin -0 team-log T7 answered id=plain answer=yes
  refuses "T7's ask fix, at $at, has no answered since: Daniel has not answered it" fix
}

@test "refused with nothing run: a file changed since the ask, naming both hashes" {
  approve fix "$WT/scripts/fix.sh"
  local before
  before=$(hash_of "$WT/scripts/fix.sh")
  echo "echo more" >>"$WT/scripts/fix.sh"
  refuses "$WT/scripts/fix.sh has changed since T7's ask fix: its sha256 is $(hash_of "$WT/scripts/fix.sh") now, and the ask named $before" fix
}

@test "refused with nothing run: a path outside the task's worktree and task directory, through a link or .., or no file" {
  local outside=$BATS_TEST_TMPDIR/elsewhere places="$WT, $TEAM_HOME/tasks/T7"
  mkdir -p "$outside"
  approved_script "$outside/fix.sh" 0
  approve out "$outside/fix.sh"
  refuses "$outside/fix.sh is not under T7's worktrees or its task directory, so it runs nothing: $places" out
  ln -s "$outside/fix.sh" "$WT/scripts/link.sh"
  approve link "$WT/scripts/link.sh"
  refuses "$WT/scripts/link.sh is not under T7's worktrees or its task directory, so it runs nothing: $places" link
  approve dots "$WT/../../elsewhere/fix.sh"
  refuses "$WT/../../elsewhere/fix.sh is not under T7's worktrees or its task directory, so it runs nothing: $places" dots
  # Another task's directory is not this one's.
  mkdir -p "$TEAM_HOME/tasks/T8"
  approved_script "$TEAM_HOME/tasks/T8/fix.sh" 0
  approve other "$TEAM_HOME/tasks/T8/fix.sh"
  refuses "$TEAM_HOME/tasks/T8/fix.sh is not under T7's worktrees or its task directory, so it runs nothing: $places" other
  approve gone "$WT/scripts/fix.sh"
  rm "$WT/scripts/fix.sh"
  refuses "no file at $WT/scripts/fix.sh, the script T7's ask gone names" gone
}

@test "refused with nothing run: a machine that does not hold the lease" {
  approve fix "$WT/scripts/fix.sh"
  run "$REPO_ROOT/bin/team-lease" release
  [[ $status -eq 0 ]]
  # team-lease check's reason comes first, as for a launch.
  refuses "an approved script starts only on the machine that holds the lease" fix 'team-lease: the lease is released (last held by home-pc, epoch 1); take it with team-lease take
'
}

@test "one OK runs the script once: a second run needs a new ask, and a closed task runs nothing" {
  approve fix "$WT/scripts/fix.sh"
  run_bin -3 team-run-approved T7 fix
  local ran
  ran=$(jq -r 'select(.event == "ran") | .ts' "$TEAM_HOME/ledger.jsonl")
  rm "$MARK"
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 team-run-approved T7 fix
  assert_equal "$output" "team-run-approved: T7 already ran fix since its ask, at $ran, exit 3: a new run needs a new ask"
  [[ ! -e $MARK ]]
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  approve fix "$WT/scripts/fix.sh"
  run_bin -3 team-run-approved T7 fix
  assert_equal "$(cat "$MARK")" "ran"
  rm "$MARK" "$TEAM_HOME/tasks/T7/runs/fix.log"
  approve again "$WT/scripts/fix.sh"
  echo '{"ts":"2026-11-02T10:00:00Z","task":"T7","event":"closed","archive":[],"returned":[],"kept":[]}' >>"$TEAM_HOME/ledger.jsonl"
  refuses "T7 is closed" again
}

@test "refused with nothing run: a worker session, whatever its role" {
  approve fix "$WT/scripts/fix.sh"
  local role
  for role in planner builder reviewer ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 refuses "a $role session runs no approved script: that is the coordinator's; send it your message" fix
  done
  AGENT_TEAM_ROLE=coordinator run_bin -3 team-run-approved T7 fix
}
