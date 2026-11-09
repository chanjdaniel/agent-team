#!/usr/bin/env bats
# team-timers' health: the record every heartbeat run writes (health.json) and the view
# `team-timers health [--json]` makes of it, the lease record and now (bin/lib/health.jq). The
# heartbeat suite's setup: home-pc holds the lease on a bare origin, the stub claude lists no
# session and the service managers are fakes. Time is stepped by dating the record's and the
# lease record's times and by the thresholds' seams, never by sleeping.

load helpers/common
load helpers/inbox

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stub_reply claude '[]'
  origin=$(hold_lease home-pc)
  fake_service_managers
  stub_command uname
  stub_reply uname Linux
  state=$HOME/.local/state/agent-team
  log=$state/heartbeat.log
  record=$state/health.json
  inbox_discord
  inbox_kept
}

teardown() {
  [[ ! -f $BATS_TEST_TMPDIR/http.pids ]] || xargs kill <"$BATS_TEST_TMPDIR/http.pids" 2>/dev/null || true
}

# The view as JSON, in $view, and its exit status in $view_status.
view() {
  run_bin team-timers health --json
  view=$output view_status=$status
}

# The view's problem <key>, or null.
problem_of() {
  jq -c --arg key "$1" 'first(.problems[] | select(.key == $key)) // null' <<<"$view"
}

# The UTC time <minutes> ago.
ago() {
  date -u -d "-$1 minutes" +%FT%TZ
}

# Date the health record: apply the jq filter <filter> to it, with $ago(<minutes>) at hand.
date_record() {
  jq --arg now "$(date -u +%FT%TZ)" "def ago(\$m): now - \$m * 60 | floor | todate; $1" "$record" >"$record.new"
  mv "$record.new" "$record"
}

# Date the lease record's write <minutes> ago (0 for now).
date_lease_record() {
  jq --argjson m "$1" '.written_at = (now - $m * 60 | floor | todate)' "$state/lease.json" >"$state/lease.json.new"
  mv "$state/lease.json.new" "$state/lease.json"
}

# Make the checkpoint due on the next run.
checkpoint_due() {
  touch -d '-5 minutes' "$state/last-checkpoint"
}

# Replace team-checkpoint with the bash read from stdin, in a code checkout of the test's own.
fake_checkpoint() {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm "$CODE_CHECKOUT/bin/team-checkpoint"
  { echo '#!/usr/bin/env bash'; cat; } >"$CODE_CHECKOUT/bin/team-checkpoint"
  chmod +x "$CODE_CHECKOUT/bin/team-checkpoint"
}

# Make the 60-second wait before the probe's second try return at once.
stub_sleep() {
  stub_command sleep
  stub_script sleep </dev/null
}

# Serve HTTP <status> to every request on a free local port, standing in for GitHub; prints the
# URL of a repository there. teardown stops it.
http_origin() {
  local port=$BATS_TEST_TMPDIR/http.port
  rm -f "$port"
  python3 -I "$REPO_ROOT/tests/helpers/http-status.py" "$1" "$port" </dev/null >/dev/null 2>"$port.err" 3>&- &
  echo $! >>"$BATS_TEST_TMPDIR/http.pids"
  for _ in $(seq 1 200); do
    [[ ! -s $port ]] || break
    sleep 0.05
  done
  [[ -s $port ]] || return 1
  echo "http://127.0.0.1:$(cat "$port")/agent-team.git"
}

@test "after a good holder run, the view is ok with no problem, its line says the last checkpoint and the lease's renewal, and it exits 0" {
  run_bin -0 team-timers run
  view
  assert_equal "$view_status" 0
  jq -e '.schema == "team-health/1" and .machine == "home-pc" and .holding and .ok and .problems == []' <<<"$view"
  local checkpoint renewed
  checkpoint=$(date -u -r "$state/last-checkpoint" +%s)
  renewed=$(lease_json "$origin" | jq '.renewed_at | fromdateiso8601')
  assert_equal "$(jq -r .line <<<"$view")" "-# Health: ok - last checkpoint <t:$checkpoint:R>, lease renewed <t:$renewed:R>"
  [[ $(jq -r .text <<<"$view") =~ ^"Health: ok - last checkpoint "[0-9T:-]+"Z (0 minutes ago), lease renewed "[0-9T:-]+"Z (0 minutes ago)"$ ]]

  # The text form is the plain line, and the view asks no service manager.
  : >"$STUB_CALLS/systemctl.log"
  run_bin -0 team-timers health
  assert_equal "$output" "$(jq -r .text <<<"$view")"
  assert_equal "$(stub_calls systemctl)" ""
}

@test "a failed checkpoint run is a checkpoint problem with its reason, alerting from the second run in a row, which counts once however often the record is written" {
  run_bin -0 team-timers run
  git -C "$TEAM_HOME" checkout -q --detach
  checkpoint_due
  run_bin -1 team-timers run
  view
  assert_equal "$view_status" 1
  local problem since
  problem=$(problem_of checkpoint)
  since=$(jq -r .since <<<"$problem")
  jq -e --arg since "$since" '. == {key: "checkpoint", since: $since,
    text: "checkpoint failing since \($since) (1 run): team home: not on a branch, so the records are not committed",
    alerting: false, sweep: null}' <<<"$problem"
  assert_equal "$(jq -r .line <<<"$view")" \
    "**Health**: checkpoint failing since <t:$(date -d "$since" +%s):t> (1 run): team home: not on a branch, so the records are not committed"

  run_bin -1 team-timers run
  view
  jq -e --arg since "$since" '.since == $since and .alerting and .sweep == "checkpoint-stale"
    and (.text | startswith("checkpoint failing since \($since) (2 runs): team home: not on a branch"))' <<<"$(problem_of checkpoint)"

  # Back on its branch, the next run clears it.
  git -C "$TEAM_HOME" checkout -q dev
  run_bin -0 team-timers run
  view
  assert_equal "$view_status" 0
  jq -e '.ok' <<<"$view"
}

@test "the Waiting on you message carries the view's line between the resources line and its last line: ok after a good run, the failing checkpoint after two failed runs" {
  run_bin -0 team-timers run
  local checkpoint renewed
  checkpoint=$(date -u -r "$state/last-checkpoint" +%s)
  renewed=$(lease_json "$origin" | jq '.renewed_at | fromdateiso8601')
  assert_equal "$(inbox_shown | tail -n 3 | head -n 2)" "Resources: manual, full (90%): no reading of the machine's load yet, so no budget
-# Health: ok - last checkpoint <t:$checkpoint:R>, lease renewed <t:$renewed:R>"
  [[ $(inbox_shown | tail -n 1) =~ ^"-# team-inbox keeps this current; updated <t:"[0-9]+":R>"$ ]]

  git -C "$TEAM_HOME" checkout -q --detach
  checkpoint_due
  run_bin -1 team-timers run
  checkpoint_due
  run_bin -1 team-timers run
  view
  local since
  since=$(jq -r '.problems[] | select(.key == "checkpoint") | .since' <<<"$view")
  # The message shows this run's line: the record is written before the inbox step.
  assert_equal "$(inbox_health_shown)" "$(jq -r .line <<<"$view")"
  assert_equal "$(inbox_health_shown)" \
    "**Health**: checkpoint failing since <t:$(date -d "$since" +%s):t> (2 runs): team home: not on a branch, so the records are not committed"
}

@test "a last good checkpoint more than 15 minutes old with no failure recorded is an alerting checkpoint problem saying since when" {
  run_bin -0 team-timers run
  date_record '.last_checkpoint = ago(16)'
  local since
  since=$(jq -r .last_checkpoint "$record")
  view
  assert_equal "$view_status" 1
  jq -e --arg since "$since" '. == {key: "checkpoint", since: $since,
    text: "no good checkpoint since \($since) (16 minutes ago): the checkpoint step did not run",
    alerting: true, sweep: "checkpoint-stale"}' <<<"$(problem_of checkpoint)"
  assert_equal "$(jq -r .line <<<"$view")" \
    "**Health**: no good checkpoint since <t:$(date -d "$since" +%s):R>: the checkpoint step did not run"

  # 14 minutes is not stale, and the threshold's seam moves it.
  date_record '.last_checkpoint = ago(14)'
  view
  jq -e '.ok' <<<"$view"
  TEAM_TIMERS_HEALTH_STALE_MINUTES=10 run_bin -1 team-timers health --json
  jq -e '.problems[0].key == "checkpoint" and .problems[0].alerting' <<<"$output"
}

@test "a heartbeat whose last run and lease record are both over 15 minutes old is the heartbeat problem and no checkpoint problem; a lease record written just now is neither" {
  run_bin -0 team-timers run
  date_record '.last_run.start = ago(20) | .written = ago(20) | .last_checkpoint = ago(20)'
  date_lease_record 18
  local seen
  seen=$(jq -r .written_at "$state/lease.json")
  view
  assert_equal "$view_status" 1
  jq -e --arg seen "$seen" '[.problems[].key] == ["heartbeat"]
    and .problems[0] == {key: "heartbeat", since: $seen, text: "the heartbeat last ran \($seen) (18 minutes ago)",
      alerting: true, sweep: "checkpoint-stale"}' <<<"$view"
  assert_equal "$(jq -r .line <<<"$view")" "**Health**: the heartbeat last ran <t:$(date -d "$seen" +%s):R>"

  # A take or a resume just now: quiet until its first run is overdue.
  date_lease_record 0
  view
  assert_equal "$view_status" 0
  jq -e '.ok and .problems == []' <<<"$view"
}

@test "a run that went offline and one whose login was refused are recorded as such, shown as their problem, and raise no checkpoint problem" {
  # No good checkpoint yet: the checkpoint would be stale but for the flags.
  stub_sleep
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -75 team-timers run
  # The record says how the run ended.
  assert_equal "$(jq -r .last_run.ended "$record")" offline
  view
  local since
  since=$(jq -r .since "$state/offline")
  jq -e --arg since "$since" '[.problems[].key] == ["offline"]
    and .problems[0] == {key: "offline", since: $since, text: "GitHub unreachable since \($since), the team is holding",
      alerting: false, sweep: null}' <<<"$view"
  assert_equal "$(jq -r .line <<<"$view")" "**Health**: GitHub unreachable since <t:$(date -d "$since" +%s):t>, the team is holding"

  rm "$state/offline"
  git -C "$TEAM_HOME" remote set-url origin "$(http_origin 403)"
  run_bin -1 team-timers run
  assert_equal "$(jq -r .last_run.ended "$record")" login-refused
  view
  since=$(jq -r .since "$state/login-refused")
  jq -e --arg since "$since" '[.problems[].key] == ["login-refused"]
    and .problems[0] == {key: "login-refused", since: $since, text: "GitHub refuses home-pc'"'"'s login since \($since)",
      alerting: true, sweep: "health"}' <<<"$view"

  # GitHub answers again: the flag goes, and the next run is good.
  git -C "$TEAM_HOME" remote set-url origin "$origin"
  run_bin -0 team-timers run
  assert_equal "$(jq -r .last_run.ended "$record")" ok
  view
  jq -e '.ok' <<<"$view"
}

@test "a ledger line that is not JSON fails the ledger step and is an alerting ledger problem naming the count and the line numbers, until fixed" {
  local ledger=$TEAM_HOME/ledger.jsonl count
  printf '%s\n' "not json" '[1, 2]' >>"$ledger"
  count=$(wc -l <"$ledger")
  run_bin -1 team-timers run
  assert_contains "$output" " ledger: failed: 2 lines are not JSON objects: line $((count - 1)), $count"
  view
  jq -e --arg text "2 ledger lines no reader can parse (line $((count - 1)), $count)" \
    '(first(.problems[] | select(.key == "ledger")) | .text == $text and .alerting and .sweep == "health")
     and ([.problems[].key] | index("step-ledger") | not)' <<<"$view"
  assert_contains "$(jq -r .line <<<"$view")" "2 ledger lines no reader can parse"

  # Fixed, the next run clears it.
  head -n "$((count - 2))" "$ledger" >"$ledger.new"
  mv "$ledger.new" "$ledger"
  checkpoint_due
  run_bin -0 team-timers run
  [[ $output != *" ledger: "* ]]
  view
  jq -e '.ok' <<<"$view"
}

@test "a failing step is a step problem alerting only from its twelfth run in a row, and a step that did not run keeps its entry" {
  local file=$HOME/.config/agent-team/capacity.json
  mkdir -p "${file%/*}"
  echo '{"minor_share": "a third"}' >"$file"
  run_bin -1 team-timers run
  view
  local problem since
  problem=$(problem_of step-capacity)
  since=$(jq -r .since <<<"$problem")
  jq -e --arg since "$since" --arg file "$file" '. == {key: "step-capacity", since: $since,
    text: "capacity failing since \($since) (1 run): \($file): minor_share must be a number above 0 and at most 1, not \"a third\"",
    alerting: false, sweep: null}' <<<"$problem"
  # The text form: one line per problem, and exit 1.
  run_bin -1 team-timers health
  assert_equal "$output" "$(jq -r '.problems[].text' <<<"$view")"
  assert_equal "${#lines[@]}" 2
  assert_contains "${lines[1]}" "level failing since "

  date_record '.steps.capacity.runs = 10'
  run_bin -1 team-timers run
  view
  jq -e '.alerting == false and (.text | contains("(11 runs)"))' <<<"$(problem_of step-capacity)"
  run_bin -1 team-timers run
  view
  jq -e --arg since "$since" '.since == $since and .alerting and .sweep == "health" and (.text | contains("(12 runs)"))' \
    <<<"$(problem_of step-capacity)"

  # A run that does not hold the lease runs no capacity step, so the entry stays.
  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-timers run
  run -0 "$REPO_ROOT/bin/team-lease" take
  view
  jq -e '.alerting and (.text | contains("(12 runs)"))' <<<"$(problem_of step-capacity)"

  # Fixed, the next run clears it.
  rm "$file"
  run_bin -0 team-timers run
  view
  jq -e '.ok' <<<"$view"
}

@test "a failed usage export is the step-usage problem, and an export that works clears it" {
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-tokens/projects" "$HOME/.claude/projects"
  mkdir -p "$TEAM_HOME/usage/home-pc"
  echo "not json" >"$TEAM_HOME/usage/home-pc/2026-10-21.jsonl"
  run_bin -0 team-timers run
  view
  jq -e --arg file "$TEAM_HOME/usage/home-pc/2026-10-21.jsonl" '[.problems[].key] == ["step-usage"]
    and (.problems[0].text | startswith("usage failing since ")) and (.problems[0].text | contains(" (1 run): cannot export: \($file) holds a line"))' <<<"$view"

  # A checkpoint not due exports nothing, so the entry stays.
  run_bin -0 team-timers run
  view
  jq -e '.problems[0].key == "step-usage"' <<<"$view"

  rm "$TEAM_HOME/usage/home-pc/2026-10-21.jsonl"
  checkpoint_due
  run_bin -0 team-timers run
  view
  jq -e '.ok' <<<"$view"
}

@test "a machine that does not hold the lease, or is fenced, keeps no health: no problem, a null line, exit 0" {
  run_bin -0 team-timers run
  run -0 "$REPO_ROOT/bin/team-lease" release
  view
  assert_equal "$view_status" 0
  jq -e '. == {schema: "team-health/1", machine: "home-pc", holding: false, ok: true, line: null, text: null, problems: []}' <<<"$view"
  run_bin -0 team-timers health
  assert_equal "$output" "home-pc does not hold the lease, so it keeps no health"

  run -0 "$REPO_ROOT/bin/team-lease" take
  view
  jq -e '.holding' <<<"$view"
  echo '{"since": "2026-11-01T00:00:00Z"}' >"$state/fenced"
  view
  assert_equal "$view_status" 0
  jq -e '.holding == false and .problems == [] and .line == null' <<<"$view"
}

@test "on the holder, no record yet and a record that is not JSON are an unknown health with the reason, exit 1" {
  view
  assert_equal "$view_status" 1
  jq -e '.holding and (.ok | not) and .line == "**Health**: unknown - no health record yet; the heartbeat writes one each run"
    and .text == "Health: unknown - no health record yet; the heartbeat writes one each run"' <<<"$view"
  run_bin -1 team-timers health
  assert_equal "$output" "health unknown: no health record yet; the heartbeat writes one each run"

  mkdir -p "$state"
  echo "{not json" >"$record"
  view
  assert_equal "$view_status" 1
  assert_equal "$(jq -r .line <<<"$view")" \
    "**Health**: unknown - the health record is not a team-health/1 record (the heartbeat's next run writes it again)"

  # The next run writes it again.
  run_bin -0 team-timers run
  view
  jq -e '.ok' <<<"$view"
}

@test "each reason in the line is cut at 150 characters and the line at 500" {
  local long
  long=$(printf 'x%.0s' {1..300})
  fake_checkpoint <<SH
echo "team-checkpoint: T1 home: cannot push: $long" >&2
echo "team-checkpoint: warning: usage: cannot export: $long" >&2
exit 1
SH
  local file=$HOME/.config/agent-team/capacity.json
  mkdir -p "${file%/*}"
  echo '{"minor_share": "a third"}' >"$file"
  echo "not json" >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-timers run
  view
  local reason
  reason=$(jq -r '.problems[] | select(.key == "checkpoint") | .text | sub("^checkpoint failing since [^ ]+ \\(1 run\\): "; "")' <<<"$view")
  assert_equal "${#reason}" 150
  assert_equal "$reason" "T1 home: cannot push: $(printf 'x%.0s' {1..125})..."
  assert_equal "$(jq -r '.line | length' <<<"$view")" 500
  [[ $(jq -r .line <<<"$view") == *... ]]
  assert_equal "$(jq -r '.text | length' <<<"$view")" 500
}

@test "status says the last good run and the plain health line; a failed run moves the last run, never the last good run" {
  run_bin -0 team-timers run
  local good last
  good=$(jq -r .last_run.start "$record")
  run_bin -0 team-timers status --json
  jq -e --arg good "$good" '.last_good_run == $good and (.health | startswith("Health: ok - last checkpoint "))' <<<"$output"
  run_bin -0 team-timers status
  assert_equal "${lines[3]}" "last good run: $good"
  assert_contains "${lines[4]}" "health: ok - last checkpoint "

  git -C "$TEAM_HOME" checkout -q --detach
  checkpoint_due
  run_bin -1 team-timers run
  last=$(tail -n 1 "$log" | cut -d' ' -f1)
  run_bin -0 team-timers status --json
  jq -e --arg good "$good" --arg last "$last" '.last_good_run == $good and .last_run == $last and $last >= $good
    and (.health | startswith("Health: checkpoint failing since "))' <<<"$output"

  # Off the lease: no health kept.
  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-timers status --json
  jq -e '.health == null' <<<"$output"
  run_bin -0 team-timers status
  assert_equal "${lines[4]}" "health: none kept here, since this machine does not hold the lease"
}

@test "a run stopped at the run limit is recorded as timed-out, and the run step's problem says so" {
  local hung=$BATS_TEST_TMPDIR/hung
  stub_script claude <<SH
[[ \$1 == agents ]] || exit 0
trap '' TERM
echo "\$\$" >>'$hung'
command -p sleep 300
SH
  TEAM_TIMERS_RUN_SECONDS=3 TEAM_TIMERS_KILL_SECONDS=1 run_bin -1 team-timers run
  assert_equal "$(jq -r .last_run.ended "$record")" timed-out
  view
  jq -e '.text | endswith("(1 run): timed out after 3 s")' <<<"$(problem_of step-run)"

  rm "$STUB_FIXTURES/claude.sh"
  stub_reply claude '[]'
  run_bin -0 team-timers run
  view
  jq -e '.ok' <<<"$view"
}

@test "the record is written before the inbox step, so the inbox reads this run's, and again when the run ends" {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm "$CODE_CHECKOUT/bin/team-inbox"
  printf '#!/usr/bin/env bash\ncp "$HOME/.local/state/agent-team/health.json" "$HOME/at-inbox.json"\n' >"$CODE_CHECKOUT/bin/team-inbox"
  chmod +x "$CODE_CHECKOUT/bin/team-inbox"
  run_bin -0 team-timers run
  # At the inbox step: this run, still going, its checkpoint and ledger steps in.
  jq -e --slurpfile final "$record" '.last_run.start == $final[0].last_run.start
    and .last_run.ended == null and .last_run.end == null and .last_run.holding and .last_checkpoint != null
    and .ledger.count == 0' "$HOME/at-inbox.json"
  jq -e '.last_run.ended == "ok" and .last_run.end != null and .last_good_run == .last_run.start' "$record"
}
