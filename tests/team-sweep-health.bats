#!/usr/bin/env bats
# team-sweep's health findings: checkpoint-stale and health, read from the heartbeat's health view
# (team-timers health --json) at each look. home-pc holds the lease on a bare origin and the stub
# claude lists no session; the health record is written by hand, its times dated relative to now,
# so the real team-timers and bin/lib/health.jq make the view the sweep reads.

load helpers/common

setup() {
  sandbox
  stub_reply claude '[]'
  hold_lease home-pc >/dev/null
  state=$HOME/.local/state/agent-team
  record=$state/health.json
}

NEXT_CHECKPOINT="next: fix what it names (heartbeat-failures.log has every line), then run team-checkpoint --force"
NEXT_HEALTH="next: fix what each names; team-timers health lists them"

# The UTC time <minutes> ago.
ago() {
  date -u -d "-$1 minutes" +%FT%TZ
}

# health_record [<filter>]: a health record of a good run just now, with jq's <filter> applied,
# ago(<minutes>) at hand.
health_record() {
  jq -n "def ago(\$m): now - \$m * 60 | floor | todate;
    {schema: \"team-health/1\", machine: \"home-pc\", written: ago(0),
     last_run: {start: ago(0), end: ago(0), ended: \"ok\", holding: true},
     last_good_run: ago(0), lease_renewed: ago(0), last_checkpoint: ago(1), offline: null,
     login_refused: null, steps: {}, ledger: {count: 0, bad_lines: [], last_event: null}, alerts: {}}
    | ${1:-.}" >"$record"
}

# A checkpoint step failing for <runs> runs in a row since 10 minutes ago.
checkpoint_failing() {
  health_record ".last_run.ended = \"failed\" | .last_checkpoint = ago(10)
    | .steps.checkpoint = {since: ago(10), runs: $1, reason: \"home: push to origin refused\", more: 0, run: \"r\"}"
}

# Replace team-timers with the bash read from stdin, in a code checkout of the test's own.
fake_timers() {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm -f "$CODE_CHECKOUT/bin/team-timers"
  { echo '#!/usr/bin/env bash'; cat; } >"$CODE_CHECKOUT/bin/team-timers"
  chmod +x "$CODE_CHECKOUT/bin/team-timers"
}

@test "checkpoint-stale: an alerting checkpoint problem is one finding with its plain text and the next step; one failed run raises nothing" {
  run_bin -0 team-sweep
  assert_equal "$output" ""

  # One failed run is a problem that is not alerting yet.
  checkpoint_failing 1
  run_bin -0 team-sweep
  assert_equal "$output" ""
  run_bin -1 team-timers health --json
  assert_equal "$(jq -c '[.problems[] | {key, alerting}]' <<<"$output")" '[{"key":"checkpoint","alerting":false}]'

  # The second is alerting.
  checkpoint_failing 2
  local since
  since=$(jq -r .steps.checkpoint.since "$record")
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "$output" "checkpoint: checkpoint failing since $since (2 runs): home: push to origin refused; $NEXT_CHECKPOINT"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg text "checkpoint: checkpoint failing since $since (2 runs): home: push to origin refused; $NEXT_CHECKPOINT" \
    '[{task: null, kind: "checkpoint-stale", session: null, name: null,
       next: "fix what it names (heartbeat-failures.log has every line), then run team-checkpoint --force", text: $text}]')"
}

@test "checkpoint-stale: a heartbeat with no run for 15 minutes on the holder is the same kind, saying when it last ran" {
  # One time for the run and the lease, since the text names the later of the two, and two reads
  # of now may fall either side of a second.
  local t
  t=$(ago 20)
  health_record ".written = \"$t\" | .last_run.start = \"$t\" | .last_run.end = \"$t\""
  jq --arg t "$t" '.written_at = $t' "$state/lease.json" >"$state/lease.json.new"
  mv "$state/lease.json.new" "$state/lease.json"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map(.kind)' <<<"$output")" '["checkpoint-stale"]'
  assert_equal "$(jq -r '.[0].text' <<<"$output")" \
    "checkpoint: the heartbeat last ran $t (20 minutes ago); $NEXT_CHECKPOINT"
}

@test "health: alerting ledger, login-refused and step problems are one finding listing them; a step short of its runs and offline raise nothing" {
  # A step failing 11 runs in a row is not alerting yet, and the offline flag never raises one.
  health_record '.steps.capacity = {since: ago(55), runs: 11, reason: "team-capacity: no reading", run: "r"}
    | .offline = {since: ago(5)}'
  run_bin -0 team-sweep
  assert_equal "$output" ""

  health_record '.steps.capacity = {since: ago(60), runs: 12, reason: "team-capacity: no reading", run: "r"}
    | .steps.ledger = {since: ago(3), runs: 1, reason: "1 line is not a JSON object: line 4", run: "r"}
    | .ledger = {count: 1, bad_lines: [4], last_event: ago(3)}
    | .login_refused = {since: ago(2), reason: "HTTP 401"}'
  run_bin -1 team-timers health --json
  local texts
  texts=$(jq -r '[.problems[] | select(.sweep == "health") | .text] | join("; ")' <<<"$output")
  assert_equal "$(jq -c '[.problems[] | .key]' <<<"$output")" '["login-refused","ledger","step-capacity"]'
  run_bin -1 team-sweep
  assert_equal "$output" "health: $texts; $NEXT_HEALTH"
  assert_contains "$output" "health: GitHub refuses home-pc's login since "
  assert_contains "$output" "; 1 ledger line no reader can parse (line 4); capacity failing since "
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[] | del(.text)' <<<"$output")" \
    '{"task":null,"kind":"health","session":null,"name":null,"next":"fix what each names; team-timers health lists them"}'
}

@test "health: only an alerting problem that names a sweep kind raises one, so the coordinator's own problems raise nothing" {
  # The view names no sweep kind for a problem that is not alerting; step-level holds the sweep to
  # its alerting all the same.
  fake_timers <<'EOF'
cat <<'VIEW'
{"schema": "team-health/1", "machine": "home-pc", "holding": true, "ok": false, "line": "x", "text": "x",
 "problems": [
  {"key": "coordinator", "since": "2026-11-09T10:00:00Z", "text": "no coordinator session since 2026-11-09T10:00:00Z", "alerting": true, "sweep": null},
  {"key": "unattended", "since": "2026-11-09T10:00:00Z", "text": "the coordinator has left 2 findings unattended", "alerting": true, "sweep": null},
  {"key": "step-pack", "since": "2026-11-09T10:00:00Z", "text": "pack failing since 2026-11-09T10:00:00Z (3 runs): no room", "alerting": false, "sweep": null},
  {"key": "step-level", "since": "2026-11-09T10:00:00Z", "text": "level failing since 2026-11-09T10:00:00Z (3 runs): no room", "alerting": false, "sweep": "health"},
  {"key": "step-usage", "since": "2026-11-09T09:00:00Z", "text": "usage failing since 2026-11-09T09:00:00Z (12 runs): no transcripts", "alerting": true, "sweep": "health"}]}
VIEW
exit 1
EOF
  run_bin -1 team-sweep
  assert_equal "$output" "health: usage failing since 2026-11-09T09:00:00Z (12 runs): no transcripts; $NEXT_HEALTH"
}

@test "health: a team-timers health that fails is one finding naming its last stderr line, and the other findings still come" {
  event_line='{"ts": "2026-10-22T02:00:00Z", "task": "T3", "event": "opened", "project": "proj", "path": "feature", "type": "feat", "title": "Work", "branch": "feat/T3-work", "base": "main", "base_sha": "0123456", "worktree": "/w/1"}'
  printf '%s\n' "$event_line" >>"$TEAM_HOME/ledger.jsonl"
  fake_timers <<'EOF'
echo "not a view"
echo "team-timers: something first" >&2
echo "team-timers: cannot read the health record $HOME/.local/state/agent-team/health.json" >&2
exit 1
EOF
  run_bin -1 --separate-stderr team-sweep
  assert_equal "$stderr" ""
  assert_equal "${lines[0]%%:*}" "T3 no-worker"
  assert_equal "${lines[1]}" "health: team-timers: cannot read the health record ~/.local/state/agent-team/health.json: fix what team-timers names"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c '.[1] | del(.text)' <<<"$output")" \
    '{"task":null,"kind":"health","session":null,"name":null,"next":"fix what team-timers names"}'

  # One that prints no view and says nothing.
  fake_timers <<<'exit 3'
  run_bin -1 team-sweep
  assert_equal "${lines[1]}" "health: team-timers health exited 3 with no view: fix what team-timers names"
  # And a JSON value that is not a view.
  fake_timers <<<'echo "[]"'
  run_bin -1 team-sweep
  assert_equal "${lines[1]}" "health: team-timers health exited 0 with no view: fix what team-timers names"
}

@test "on a machine that does not hold the lease, or has no team name, neither finding is raised" {
  checkpoint_failing 3
  run_bin -1 team-sweep
  jq '.holder = "work-mac"' "$state/lease.json" >"$state/lease.json.new"
  mv "$state/lease.json.new" "$state/lease.json"
  run_bin -0 team-sweep
  assert_equal "$output" ""

  # A machine with no team name holds no lease, so team-timers is not asked.
  rm "$HOME/.config/agent-team/machine"
  fake_timers <<<'echo "asked" >&2; exit 1'
  run_bin -0 --separate-stderr team-sweep
  assert_equal "$output$stderr" ""
}

@test "the health findings come after retro-due, so no other finding moves" {
  printf '%s\n' '{"ts": "2026-10-22T02:00:00Z", "task": "T26", "event": "retro-schedule", "every_hours": 1}' >>"$TEAM_HOME/ledger.jsonl"
  checkpoint_failing 2
  jq '.steps.capacity = {since: (now - 3600 | floor | todate), runs: 12, reason: "no reading", run: "r"}' "$record" >"$record.new"
  mv "$record.new" "$record"
  run_bin -1 team-sweep --json
  assert_equal "$(jq -c 'map(.kind)' <<<"$output")" '["retro-due","checkpoint-stale","health"]'
}

@test "--wait ends on a checkpoint-stale finding once it has stood three minutes" {
  checkpoint_failing 1
  stub_command sleep uname
  stub_reply uname Linux
  # Each wait counts a look; the checkpoint fails a second run before the second look, and the
  # watch is stopped after 20 looks.
  echo 0 >"$BATS_TEST_TMPDIR/look"
  stub_script sleep <<EOF
n=\$(cat "$BATS_TEST_TMPDIR/look")
((n < 20)) || exit 99
echo \$((n + 1)) >"$BATS_TEST_TMPDIR/look"
if ((n == 0)); then
  jq '.steps.checkpoint.runs = 2' "$record" >"$record.new"
  mv "$record.new" "$record"
fi
EOF
  run_bin -0 --separate-stderr team-sweep --wait
  assert_equal "$stderr" ""
  assert_contains "$output" "checkpoint: checkpoint failing since "
  assert_contains "$output" "(2 runs): home: push to origin refused; $NEXT_CHECKPOINT"
  # Seen at the second look (0:30), it has stood three minutes at the eighth (3:30).
  assert_equal "$(grep -c . <<<"$(stub_calls sleep)")" 7
}
