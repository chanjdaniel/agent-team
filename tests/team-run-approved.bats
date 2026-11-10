#!/usr/bin/env bats
# team-run-approved: running a script Daniel approved, bound to the bytes they were asked on.

load helpers/common

setup() {
  sandbox
  hold_lease >/dev/null
  WT=$BATS_TEST_TMPDIR/wt/7
  MARK=$BATS_TEST_TMPDIR/ran-marker
  RUNS=$HOME/.local/state/agent-team/runs/T7
  mkdir -p "$WT/scripts" "$TEAM_HOME/tasks/T7"
  echo "{\"ts\":\"2026-11-01T10:00:00Z\",\"task\":\"T7\",\"event\":\"opened\",\"project\":\"agent-team\",\"path\":\"feature\",\"type\":\"feat\",\"title\":\"x\",\"branch\":\"feat/T7-x\",\"base\":\"dev\",\"base_sha\":\"0123456\",\"worktree\":\"$WT\"}" \
    >>"$TEAM_HOME/ledger.jsonl"
  approved_script "$WT/scripts/fix.sh" 3
  echo '{"dmPolicy": "allowlist", "allowFrom": ["757"], "groups": {}, "pending": {}}' \
    >"$HOME/.claude/channels/discord/access.json"
  DISCORD_DIR=$BATS_TEST_TMPDIR/discord
  mkdir -p "$DISCORD_DIR"
  export DISCORD_DIR
  echo 0 >"$DISCORD_DIR/next"
  stub_discord
}

# The fake Discord API: GET channels/<c>/messages/<m> answers $DISCORD_DIR/<c>-<m>.json, a
# missing one fails as curl -f does on a 404.
stub_discord() {
  stub_script curl <<'EOF'
url=${*: -1}
if [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)/messages/([0-9]+)$ &&
  -f $DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json ]]; then
  cat "$DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
EOF
}

# The next Discord message id, later than every one before it in the test: next_message
next_message() {
  local n
  n=$(($(cat "$DISCORD_DIR/next") + 1))
  echo "$n" >"$DISCORD_DIR/next"
  echo $((1564000000000000000 + n * 4194304))
}

# Message <id> in #coordinator by author <author id>, saying <text>: message <id> <author> <text>
message() {
  jq -n --arg c 1562486564871995482 --arg id "$1" --arg a "$2" --arg text "$3" \
    '{id: $id, channel_id: $c, content: $text, author: {id: $a, username: "daniel"}}' \
    >"$DISCORD_DIR/1562486564871995482-$1.json"
}

# Daniel's answer <text> to ask <id>, sent in #coordinator now and logged as team-answer logs it;
# prints its message id: answer <id> <text>
answer() {
  local m
  m=$(next_message)
  message "$m" 757 "$2"
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg id "$1" --arg text "$2" --arg m "$m" \
    '{ts: $ts, task: "T7", event: "answered", id: $id, answer: $text, discord_message: $m}' >>"$TEAM_HOME/ledger.jsonl"
  echo "$m"
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

hash_of() {
  sha256sum "$1" | cut -d' ' -f1
}

# Log an ask about <script> as <id>, as team-ask --script logs it, and Daniel's answer in
# Discord, <text> or yes: approve <id> <script> [<text>]
approve() {
  asked_about "$1" run-it "$2"
  answer "$1" "${3:-yes}" >/dev/null
}

# Log the asked team-ask --script logs, its script <script> as given and its question a Discord
# message sent now: asked_about <id> <text> <script>
asked_about() {
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg id "$1" --arg text "$2" --arg script "$3" --arg sha256 "$(hash_of "$3")" \
    --arg m "$(next_message)" \
    '{ts: $ts, task: "T7", event: "asked", id: $id, text: $text, script: $script, sha256: $sha256, discord_message: $m}' >>"$TEAM_HOME/ledger.jsonl"
}

# The ts of the latest asked of <id>: asked_at <id>
asked_at() {
  jq -r --arg id "$1" 'select(.event == "asked" and .id == $id) | .ts' "$TEAM_HOME/ledger.jsonl" | tail -n 1
}

# The refusal of a reply with no line that starts with yes to ask <id>, Discord message <m>:
# no_yes <id> <m>
no_yes() {
  echo "T7's ask $1, at $(asked_at "$1"), runs nothing: Daniel's latest answer, Discord message $2, has no line that starts with yes, and the script runs only on a reply with a line that starts with the word yes, in any case, after an optional list marker (1., 2), - or *) and this task's id, no other (T7, T7: or T7,); ask again with team-ask T7 $1 --file <question> --script <path>"
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
  [[ ! -e $RUNS/$2.log && ! -e $RUNS/$2.started ]]
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
  local log=$RUNS/fix.log
  assert_equal "$(cat "$log")" "fixing in $WT/scripts
a warning"
  assert_equal "$output" "fixing in $WT/scripts
a warning
T7 ran fix ($WT/scripts/fix.sh), exit 3; its output is in $log"
  assert_equal "$(cat "$MARK")" "ran"
  assert_equal "$(events | tail -n 1)" '{"task":"T7","event":"ran","id":"fix","exit":3}'
  run_bin -0 team-log --check
  # The log is the machine's, never a record: nothing of the run is in the team home.
  [[ ! -e $TEAM_HOME/tasks/T7/runs ]]
  [[ -f $RUNS/fix.started && -f $RUNS/fix.lock ]]
}

@test "the ran is on origin when the run ends, and the exit is still the script's" {
  local team_origin=$BATS_TEST_TMPDIR/origin/agent-team.git tip
  approve fix "$WT/scripts/fix.sh"
  tip=$(git -C "$team_origin" rev-parse dev)
  run_bin -3 --separate-stderr team-run-approved T7 fix
  assert_equal "$stderr" ""
  assert_equal "$(tail -n 1 <<<"$output")" "T7 ran fix ($WT/scripts/fix.sh), exit 3; its output is in $RUNS/fix.log"
  assert_equal "$(git -C "$team_origin" rev-parse dev^)" "$tip"
  assert_equal "$(git -C "$team_origin" log -1 --format=%s dev)" "chore: ledger T7 ran"
  assert_equal "$(git -C "$team_origin" diff-tree -r --no-commit-id --name-only dev)" "ledger.jsonl"
  assert_equal "$(git -C "$team_origin" show dev:ledger.jsonl | tail -n 1 | jq -c 'del(.ts)')" '{"task":"T7","event":"ran","id":"fix","exit":3}'
}

@test "a script that exits 0 is exit 0, and one in the task directory runs too" {
  approved_script "$TEAM_HOME/tasks/T7/ok.sh" 0
  approve ok "$TEAM_HOME/tasks/T7/ok.sh"
  run_bin -0 team-run-approved T7 ok
  assert_equal "$(events | tail -n 1)" '{"task":"T7","event":"ran","id":"ok","exit":0}'
  assert_equal "$(cat "$RUNS/ok.log")" "fixing in $TEAM_HOME/tasks/T7
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
  refuses "T7's ask plain, at $(jq -r 'select(.event == "asked") | .ts' "$TEAM_HOME/ledger.jsonl"), names no script: an approved script is asked with team-ask T7 plain --file <question> --script <path>" plain
  # An answer to an earlier ask of the same id answers nothing asked since.
  approve fix "$WT/scripts/fix.sh"
  asked_about fix again "$WT/scripts/fix.sh"
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
  rm "$MARK" "$RUNS/fix.log"
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

@test "the runs directory follows XDG_STATE_HOME when it is set" {
  approve fix "$WT/scripts/fix.sh"
  XDG_STATE_HOME=$BATS_TEST_TMPDIR/state run_bin -3 team-run-approved T7 fix
  assert_contains "$output" "its output is in $BATS_TEST_TMPDIR/state/agent-team/runs/T7/fix.log"
  [[ -f $BATS_TEST_TMPDIR/state/agent-team/runs/T7/fix.log && ! -e $RUNS ]]
}

@test "a link at the log's path is replaced by the log, never written through" {
  local victim=$BATS_TEST_TMPDIR/victim
  echo "keep me" >"$victim"
  mkdir -p "$RUNS"
  ln -s "$victim" "$RUNS/fix.log"
  approve fix "$WT/scripts/fix.sh"
  run_bin -3 team-run-approved T7 fix
  assert_equal "$(cat "$victim")" "keep me"
  [[ -f $RUNS/fix.log && ! -L $RUNS/fix.log ]]
  assert_equal "$(cat "$RUNS/fix.log")" "fixing in $WT/scripts
a warning"
}

@test "refused with nothing run: a link at the runs directory, above it, or at the lock or the mark" {
  local elsewhere=$BATS_TEST_TMPDIR/elsewhere
  mkdir -p "$elsewhere" "${RUNS%/*}"
  ln -s "$elsewhere" "$RUNS"
  approve fix "$WT/scripts/fix.sh"
  refuses "$RUNS is a symbolic link, so T7's ask fix runs nothing there" fix
  rm "$RUNS"
  mv "${RUNS%/*}" "$elsewhere/runs"
  ln -s "$elsewhere/runs" "${RUNS%/*}"
  refuses "${RUNS%/*} is a symbolic link, so T7's ask fix runs nothing there" fix
  rm "${RUNS%/*}"
  mkdir -p "$RUNS"
  local file
  for file in fix.lock fix.started; do
    ln -s "$elsewhere/target" "$RUNS/$file"
    refuses "$RUNS/$file is a symbolic link, so T7's ask fix runs nothing" fix
    rm "$RUNS/$file"
  done
  [[ ! -e $elsewhere/target && -z $(ls "$elsewhere/runs") ]]
}

@test "one OK runs once even when the run is killed: a second call while it runs, or after it was killed, runs nothing" {
  cat >"$WT/scripts/slow.sh" <<SCRIPT
echo ran >>"$MARK"
echo \$\$ >"$BATS_TEST_TMPDIR/pid.tmp" && mv "$BATS_TEST_TMPDIR/pid.tmp" "$BATS_TEST_TMPDIR/pid"
exec sleep 30
SCRIPT
  approve slow "$WT/scripts/slow.sh"
  "$REPO_ROOT/bin/team-run-approved" T7 slow >/dev/null 2>&1 3>&- &
  local caller=$!
  wait_for "$BATS_TEST_TMPDIR/pid"
  local script
  script=$(cat "$BATS_TEST_TMPDIR/pid")
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")

  # While it runs, another call is refused by its lock.
  run_bin -1 team-run-approved T7 slow
  assert_equal "$output" "team-run-approved: another run of T7's ask slow holds $RUNS/slow.lock: it is running now"

  # Killed as a session's end kills it, it logs no ran, and the OK is still used.
  kill -KILL "$caller" "$script"
  wait "$caller" || true
  local i
  for ((i = 0; i < 100; i++)); do flock -n "$RUNS/slow.lock" true && break; sleep 0.1; done
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  local started
  started=$(jq -r .started_at "$RUNS/slow.started")
  run_bin -1 team-run-approved T7 slow
  assert_equal "$output" "team-run-approved: T7's ask slow, at $(jq -r 'select(.event == "asked") | .ts' "$TEAM_HOME/ledger.jsonl"), already started a run on this machine, at $started, with no ran logged since: it was killed or could not log, and it used the OK; a new run needs a new ask"
  assert_equal "$(cat "$MARK")" "ran"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"

  # A new ask of the same id is a new OK.
  approved_script "$WT/scripts/slow.sh" 0
  approve slow "$WT/scripts/slow.sh"
  run_bin -0 team-run-approved T7 slow
  assert_equal "$(cat "$MARK")" "ran
ran"
}

@test "a reply with a line that starts with yes runs the script, whatever else it says" {
  approved_script "$WT/scripts/ok.sh" 0
  local n=0 reply
  for reply in "yes" "Yes, run it" "YES." "t7 yes" "T7: yes" "T7, Yes please" $'1. yes\n2. go with rec\n3. later' \
    "2) yes" "- yes" "* yes" "  yes" $'Thanks.\nyes, go ahead'; do
    n=$((n + 1))
    approve "ok$n" "$WT/scripts/ok.sh" "$reply"
    run_bin -0 team-run-approved T7 "ok$n"
    assert_equal "$(events | tail -n 1)" "{\"task\":\"T7\",\"event\":\"ran\",\"id\":\"ok$n\",\"exit\":0}"
  done
  assert_equal "$(wc -l <"$MARK")" "$n"
}

@test "refused with nothing run: a reply with no line that starts with yes, quoting the rule" {
  local n=0 reply m
  for reply in "no" "No, wait" "not yet" "yesterday's plan" "go with rec" "wait" "yess" $'1. no\n2. not that one either' \
    "ok, yes" "T7 no" "T7yes" "1.5 yes"; do
    n=$((n + 1))
    asked_about "no$n" run-it "$WT/scripts/fix.sh"
    m=$(answer "no$n" "$reply")
    refuses "$(no_yes "no$n" "$m")" "no$n"
  done
}

@test "refused with nothing run: a yes on a line that names another task, as in a batched reply" {
  local n=0 reply m
  for reply in $'T8 yes\nT7 no' "T200: yes" "t70 yes" "1. T8, yes"; do
    n=$((n + 1))
    asked_about "other$n" run-it "$WT/scripts/fix.sh"
    m=$(answer "other$n" "$reply")
    refuses "$(no_yes "other$n" "$m")" "other$n"
  done
}

@test "a later answer supersedes an earlier one: yes, then no, runs nothing; no, then yes, runs" {
  approve fix "$WT/scripts/fix.sh"
  local m
  m=$(answer fix "no, wait")
  refuses "$(no_yes fix "$m")" fix
  approve fix "$WT/scripts/fix.sh" "not yet"
  answer fix "yes" >/dev/null
  run_bin -3 team-run-approved T7 fix
}

@test "refused with nothing run: an answered that names no Discord message, as one logged at the terminal" {
  asked_about fix run-it "$WT/scripts/fix.sh"
  run_bin -0 team-log T7 answered id=fix answer=yes
  local answered
  answered=$(jq -r 'select(.event == "answered") | .ts' "$TEAM_HOME/ledger.jsonl")
  refuses "T7's ask fix, at $(asked_at fix), runs nothing on its latest answered, at $answered, which names no Discord message, as one logged for an answer given at the terminal: Daniel runs the script themselves, or answers in Discord for team-answer T7 fix <message id> to log" fix
  # A yes in Discord before it is superseded by it too.
  approve fix "$WT/scripts/fix.sh"
  run_bin -0 team-log T7 answered id=fix answer=yes
  answered=$(jq -r 'select(.event == "answered") | .ts' "$TEAM_HOME/ledger.jsonl" | tail -n 1)
  refuses "T7's ask fix, at $(asked_at fix), runs nothing on its latest answered, at $answered, which names no Discord message, as one logged for an answer given at the terminal: Daniel runs the script themselves, or answers in Discord for team-answer T7 fix <message id> to log" fix
}

@test "refused with nothing run: an answer Discord does not have, not Daniel's, edited, or sent before the question" {
  local m prefix
  # Discord has no such message.
  asked_about gone run-it "$WT/scripts/fix.sh"
  m=$(answer gone yes)
  rm "$DISCORD_DIR/1562486564871995482-$m.json"
  refuses "T7's ask gone, at $(asked_at gone), runs nothing on Daniel's latest answer: Discord message $m cannot be fetched from #coordinator 1562486564871995482: curl: (22) The requested URL returned error: 404" gone
  # Someone not in allowFrom wrote it.
  asked_about other run-it "$WT/scripts/fix.sh"
  m=$(answer other yes)
  message "$m" 999 yes
  refuses "T7's ask other, at $(asked_at other), runs nothing on Daniel's latest answer: Discord message $m is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json" other
  # It was edited after it was sent.
  asked_about edited run-it "$WT/scripts/fix.sh"
  m=$(answer edited yes)
  jq '. + {edited_timestamp: "2026-11-01T10:05:00.000000+00:00"}' "$DISCORD_DIR/1562486564871995482-$m.json" >"$DISCORD_DIR/m"
  mv "$DISCORD_DIR/m" "$DISCORD_DIR/1562486564871995482-$m.json"
  refuses "T7's ask edited, at $(asked_at edited), runs nothing on Daniel's latest answer: Discord message $m was edited at 2026-11-01T10:05:00.000000+00:00, so its text may not be what Daniel first sent: ask them to send the answer again as a new message" edited
  # It was sent before the question, so it answers an earlier one.
  m=$(next_message)
  message "$m" 757 yes
  asked_about early run-it "$WT/scripts/fix.sh"
  jq -nc --arg m "$m" '{ts: "2026-11-01T10:00:00Z", task: "T7", event: "answered", id: "early", answer: "yes", discord_message: $m}' >>"$TEAM_HOME/ledger.jsonl"
  prefix="T7's ask early, at $(asked_at early), runs nothing on Daniel's latest answer: Discord message $m was sent at"
  run_bin -1 team-run-approved T7 early
  assert_contains "$output" "team-run-approved: $prefix"
  assert_contains "$output" ", before T7's question early (Discord message $((m + 4194304))), so it is not Daniel's answer to it"
  [[ ! -e $MARK ]]
}
