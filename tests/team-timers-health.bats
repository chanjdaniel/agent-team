#!/usr/bin/env bats
# team-timers' health: the record every heartbeat run writes (health.json) and the view
# `team-timers health [--json]` makes of it, the lease record and now (bin/lib/health.jq). The
# heartbeat suite's setup: home-pc holds the lease on a bare origin, the stub claude lists one
# live session, the coordinator, and the service managers are fakes. Time is stepped by dating the record's and the
# lease record's times and by the thresholds' seams, never by sleeping.

load helpers/common
load helpers/inbox

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stub_reply claude "$COORDINATOR"
  origin=$(hold_lease home-pc)
  fake_service_managers
  stub_command uname
  stub_reply uname Linux
  state=$HOME/.local/state/agent-team
  log=$state/heartbeat.log
  record=$state/health.json
  notices=$state/notices.json
  inbox_discord alerts
  inbox_guild_kept
}

# The live session list with a coordinator in it, as claude agents --json gives it.
COORDINATOR='[{"id": "c0ffee00", "name": "coordinator", "status": "idle"}]'

teardown() {
  [[ ! -f $BATS_TEST_TMPDIR/http.pids ]] || xargs kill <"$BATS_TEST_TMPDIR/http.pids" 2>/dev/null || true
  [[ ! -f $STUB_FIXTURES/lock.pid ]] || kill "$(cat "$STUB_FIXTURES/lock.pid")" 2>/dev/null || true
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

# Date the lease record's write <minutes> ago (0 for now), as a renewal writes it; with --take,
# its taken_at as well, as a take or a steal writes it.
date_lease_record() {
  local fields='.written_at = $at'
  if [[ $1 == --take ]]; then
    fields+=' | .taken_at = $at'
    shift
  fi
  jq --argjson m "$1" "(now - \$m * 60 | floor | todate) as \$at | $fields" "$state/lease.json" >"$state/lease.json.new"
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
  assert_equal "$(jq -r .line <<<"$view")" "-# Health: ok - last checkpoint <t:$checkpoint:R>, lease renewed <t:$renewed:R>, coordinator live"
  [[ $(jq -r .text <<<"$view") =~ ^"Health: ok - last checkpoint "[0-9T:-]+"Z (0 minutes ago), lease renewed "[0-9T:-]+"Z (0 minutes ago), coordinator live"$ ]]

  # The text form is the plain line, and the view asks no service manager.
  : >"$STUB_CALLS/systemctl.log"
  run_bin -0 team-timers health
  assert_equal "$output" "$(jq -r .text <<<"$view")"
  assert_equal "$(stub_calls systemctl)" ""
}

@test "a failed checkpoint run is a checkpoint problem with its reason, alerting from the second run in a row, which counts once however often the record is written" {
  run_bin -0 team-timers run
  git -C "${TEAM_HOME:?}" checkout -q --detach
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

  # A renewal rewrites the lease record after the record's last write, as the lease step does
  # before the checkpoint step: the failing checkpoint still shows, and the sweep still raises it.
  date_lease_record --take 30
  date_record '.written = ago(1)'
  date_lease_record 0
  view
  jq -e --arg since "$since" '.since == $since and .alerting and .sweep == "checkpoint-stale"' <<<"$(problem_of checkpoint)"
  run_bin -1 team-sweep --json
  jq -e 'any(.[]; .kind == "checkpoint-stale")' <<<"$output"

  # Back on its branch, the next run clears it.
  git -C "${TEAM_HOME:?}" checkout -q dev
  run_bin -0 team-timers run
  view
  assert_equal "$view_status" 0
  jq -e '.ok' <<<"$view"
}

@test "the post of the list carries the view's line after the resources line: ok after a good run, the failing checkpoint after two failed runs" {
  run_bin -0 team-timers run
  local checkpoint renewed
  checkpoint=$(date -u -r "$state/last-checkpoint" +%s)
  renewed=$(lease_json "$origin" | jq '.renewed_at | fromdateiso8601')
  run_bin -0 team-inbox --post
  # The heartbeat took a reading, so the resources line names a budget.
  [[ $(posted_shown | tail -n 3 | head -n 1) == "Resources: manual, full (90%): "*" GiB and "*" cores for the team; 0.0 GiB reserved" ]]
  assert_equal "$(posted_shown | tail -n 2 | head -n 1)" \
    "-# Health: ok - last checkpoint <t:$checkpoint:R>, lease renewed <t:$renewed:R>, coordinator live"
  # waiting.md, which the heartbeat writes, holds neither line.
  assert_equal "$(waiting_shown)" "**Waiting on you**
Nothing waits on you."

  git -C "${TEAM_HOME:?}" checkout -q --detach
  checkpoint_due
  run_bin -1 team-timers run
  checkpoint_due
  run_bin -1 team-timers run
  view
  local since
  since=$(jq -r '.problems[] | select(.key == "checkpoint") | .since' <<<"$view")
  # The post shows the last run's line.
  run_bin -0 team-inbox --post
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

  # A run that started 20 minutes ago and has not ended says so.
  local start
  date_record '.last_run.end = null | .last_run.ended = null'
  date_lease_record --take 25
  start=$(jq -r .last_run.start "$record")
  view
  jq -e --arg start "$start" '[.problems[].key] == ["heartbeat"]
    and .problems[0].text == "a heartbeat run started \($start) (20 minutes ago) has not ended"' <<<"$view"
  assert_equal "$(jq -r .line <<<"$view")" "**Health**: a heartbeat run started <t:$(date -d "$start" +%s):R> has not ended"
  # The same when that run renewed the lease after it started, as one run in three does.
  date_lease_record 19
  view
  jq -e --arg start "$start" '[.problems[].key] == ["heartbeat"]
    and .problems[0].text == "a heartbeat run started \($start) (20 minutes ago) has not ended"' <<<"$view"
  # A run with no end from before a take is no run of this holding.
  date_lease_record --take 18
  seen=$(jq -r .written_at "$state/lease.json")
  view
  jq -e --arg seen "$seen" '.problems[0].text == "the heartbeat last ran \($seen) (18 minutes ago)"' <<<"$view"

  # A take or a resume just now: quiet until its first run is overdue.
  date_lease_record --take 0
  view
  assert_equal "$view_status" 0
  jq -e '.ok and .problems == []' <<<"$view"
}

@test "a run that went offline and one whose login was refused are recorded as such, shown as their problem, and raise no checkpoint problem" {
  # No good checkpoint yet: the checkpoint would be stale but for the flags.
  stub_sleep
  git -C "${TEAM_HOME:?}" remote set-url origin https://127.0.0.1:9/agent-team.git
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
  git -C "${TEAM_HOME:?}" remote set-url origin "$(http_origin 403)"
  run_bin -1 team-timers run
  assert_equal "$(jq -r .last_run.ended "$record")" login-refused
  view
  since=$(jq -r '.notices["login-refused"].since' "$notices")
  jq -e --arg since "$since" '[.problems[].key] == ["login-refused"]
    and .problems[0] == {key: "login-refused", since: $since, text: "GitHub refuses home-pc'"'"'s login since \($since)",
      alerting: true, sweep: "health"}' <<<"$view"

  # GitHub answers again: the flag goes, and the next run is good.
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
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
  assert_equal "$(grep -cE '^[^ ]+ ledger: ' <<<"$output")" 0
  view
  jq -e '.ok' <<<"$view"
}

@test "a failing step is a step problem alerting only from its twelfth run in a row, and a step that did not run keeps its entry" {
  local file=$HOME/.config/agent-team/capacity.json
  mkdir -p "${file%/*}"
  echo '{"minor_share": "a third"}' >"$file"
  run_bin -1 team-timers run
  view
  local problem since reason
  problem=$(problem_of step-capacity)
  since=$(jq -r .since <<<"$problem")
  # The reason starts with the file's path, which on macOS's long TMPDIR passes the view's cut at
  # 150 characters.
  reason="$file: minor_share must be a number above 0 and at most 1, not \"a third\""
  (( ${#reason} <= 150 )) || reason="${reason:0:147}..."
  jq -e --arg since "$since" --arg reason "$reason" '. == {key: "step-capacity", since: $since,
    text: "capacity failing since \($since) (1 run): \($reason)", alerting: false, sweep: null}' <<<"$problem"
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
  # The reason starts with the file's path, so a long TMPDIR may pass the view's cut at 150
  # characters: its kept part, less the "...", is then where the expected start is cut.
  jq -e --arg start "cannot export: $TEAM_HOME/usage/home-pc/2026-10-21.jsonl holds a line" '[.problems[].key] == ["step-usage"]
    and (.problems[0].text | startswith("usage failing since "))
    and (.problems[0].text | split(" (1 run): ")[1] as $reason
      | ($reason | startswith($start))
        or ($reason | length == 150 and endswith("...") and ($start | startswith($reason[:-3]))))' <<<"$view"

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

  git -C "${TEAM_HOME:?}" checkout -q --detach
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

# The alerts: one post in #coordinator when a problem becomes alerting, nothing more while it
# stands, and an edit of that post when it ends. The inbox's fake Discord answers them
# (alerts_shown); the times in them are this machine's local hours and minutes.

# A UTC time as the heartbeat writes it in a post.
clock() {
  date -d "$1" +%H:%M
}

# The heartbeat log's alert lines, each without its time.
alert_lines() {
  grep ' alert: ' "$log" | cut -d' ' -f2- || true
}

# The failures log's lines, each without its time.
problems_logged() {
  cut -d' ' -f2- "$state/heartbeat-failures.log" 2>/dev/null || true
}

# The ids of the open alerts in the notice record, by key, as "<key> <message>" lines.
open_alerts() {
  [[ ! -e $notices ]] || jq -r '.notices[] | select(.source == "health") | "\(.key) \(.message)"' "$notices"
}

# The open alert <key> in the notice record, or null.
open_alert() {
  jq -c --arg id "health/$1" '.notices[$id]' "$notices"
}

# Fail the checkpoint as a team home off its branch does, and make it due.
fail_checkpoint() {
  git -C "${TEAM_HOME:?}" checkout -q --detach
  checkpoint_due
}

@test "two failed checkpoint runs post one alert with the first failure line and the last good one; later failing runs post nothing; a good run edits it resolved; a later incident posts anew" {
  run_bin -0 team-timers run
  fail_checkpoint
  # One failed run posts nothing.
  run_bin -1 team-timers run
  assert_equal "$(alerts_shown)" ""
  assert_equal "$(alert_lines)" ""

  checkpoint_due
  run_bin -1 team-timers run
  local since first more id good
  since=$(jq -r .steps.checkpoint.since "$record")
  # The last good checkpoint, which checkpoint_due dated 5 minutes back.
  good=$(jq -r .last_checkpoint "$record")
  first=$(jq -r .steps.checkpoint.reason "$record")
  more=$(jq -r .steps.checkpoint.more "$record")
  assert_equal "$first" "team home: not on a branch, so the records are not committed"
  assert_equal "$more" 1
  id=$(jq -r .id <<<"$(alerts_shown)")
  jq -e --arg text "Checkpoints are failing on home-pc since $(clock "$since") (2 runs): $first, and 1 more. Work since the last good one ($(clock "$good")) is on this machine only." \
    '. == {id: .id, content: $text, allowed_mentions: {parse: []}}' <<<"$(alerts_shown)"
  assert_equal "$(alert_lines)" "alert: checkpoint: posted to #coordinator (message $id)"
  assert_equal "$(open_alerts)" "checkpoint $id"

  # A third and a fourth failing run post nothing more.
  checkpoint_due
  run_bin -1 team-timers run
  checkpoint_due
  run_bin -1 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 1
  assert_equal "$(alert_lines | wc -l)" 1

  # The next good checkpoint edits the message in place and posts nothing new.
  local posts
  posts=$(grep -c '^POST channels/[0-9]*/messages$' "$STUB_FIXTURES/inbox/calls")
  git -C "${TEAM_HOME:?}" checkout -q dev
  checkpoint_due
  run_bin -0 team-timers run
  local text
  text=$(jq -r .content <<<"$(alerts_shown)")
  [[ $text =~ ^"Checkpoints are failing on home-pc since $(clock "$since") (2 runs): "[^$'\n']+$'\n'"-# Resolved at "[0-9]{2}:[0-9]{2}"."$ ]]
  assert_equal "$(grep -c '^POST channels/[0-9]*/messages$' "$STUB_FIXTURES/inbox/calls")" "$posts"
  assert_contains "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/$id"
  assert_equal "$(alert_lines | tail -n 1)" "alert: checkpoint: resolved (message $id edited)"
  assert_equal "$(open_alerts)" ""
  # A good run after it does nothing more.
  run_bin -0 team-timers run
  assert_equal "$(alert_lines | wc -l)" 2

  # A later incident posts a new message.
  fail_checkpoint
  run_bin -1 team-timers run
  checkpoint_due
  run_bin -1 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 2
  [[ $(alerts_shown | tail -n 1 | jq -r .id) != "$id" ]]
  [[ $(alerts_shown | tail -n 1 | jq -r .content) == "Checkpoints are failing on home-pc since "*" (2 runs): "* ]]
}

@test "a last good checkpoint over 15 minutes old with no failure recorded posts the stale alert once, saying since when and why" {
  run_bin -0 team-timers run
  fake_checkpoint <<'SH'
echo "not due: the last checkpoint is recent"
SH
  touch -d '-16 minutes' "$state/last-checkpoint"
  local good
  good=$(date -u -r "$state/last-checkpoint" +%FT%TZ)
  run_bin -0 team-timers run
  jq -e --arg text "No good checkpoint on home-pc since $(clock "$good") (16 minutes): the checkpoint step did not run." \
    '.content == $text' <<<"$(alerts_shown)"
  run_bin -0 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 1
}

@test "with no good checkpoint yet the stale alert says so, and its open alert keeps a null since" {
  run_bin -0 team-timers run
  fake_checkpoint <<'SH'
echo "not due: the last checkpoint is recent"
SH
  rm "$state/last-checkpoint"
  run_bin -0 team-timers run
  jq -e '.content == "No good checkpoint on home-pc yet: the checkpoint step did not run."' <<<"$(alerts_shown)"
  jq -e '.since == null and (.message | type) == "string"' <<<"$(open_alert checkpoint)"
}

@test "an alert post Discord refuses is logged in both logs and posted by the next run; an edit of a message that is gone is logged and closes the incident" {
  run_bin -0 team-timers run
  fail_checkpoint
  run_bin -1 team-timers run
  echo 503 >"$STUB_FIXTURES/inbox/fail"
  checkpoint_due
  run_bin -1 team-timers run
  assert_equal "$(alerts_shown)" ""
  # Refused at the judging before the inbox step and again at the run's end.
  assert_equal "$(alert_lines)" "alert: checkpoint: the post to #coordinator failed (curl: (22) The requested URL returned error: 503); it is tried again next run
alert: checkpoint: the post to #coordinator failed (curl: (22) The requested URL returned error: 503); it is tried again next run"
  assert_equal "$(problems_logged | grep '^alert: ')" "$(alert_lines)"
  jq -e '.state == "open" and .posted == null and .message == null' <<<"$(open_alert checkpoint)"

  # The next run posts it, with its text of that run, from the incident's since.
  rm "$STUB_FIXTURES/inbox/fail"
  local since
  since=$(jq -r .since <<<"$(open_alert checkpoint)")
  checkpoint_due
  run_bin -1 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 1
  [[ $(alerts_shown | jq -r .content) == "Checkpoints are failing on home-pc since $(clock "$since") (3 runs): "* ]]
  local id
  id=$(alerts_shown | jq -r .id)
  assert_equal "$(open_alerts)" "checkpoint $id"

  # The message is gone: the edit fails, is logged, and the incident is closed all the same.
  rm "$STUB_FIXTURES/inbox/$id.json"
  git -C "${TEAM_HOME:?}" checkout -q dev
  checkpoint_due
  run_bin -0 team-timers run
  assert_equal "$(alert_lines | tail -n 1)" "alert: checkpoint: ended, but message $id could not be marked resolved (curl: (22) The requested URL returned error: 404); closed all the same"
  assert_equal "$(problems_logged | grep '^alert: ' | tail -n 1)" "$(alert_lines | tail -n 1)"
  assert_equal "$(open_alerts)" ""
  assert_equal "$(open_alert checkpoint)" null
  run_bin -0 team-timers run
  assert_equal "$(grep -c 'PATCH channels/[0-9]*/messages/'"$id" "$STUB_FIXTURES/inbox/calls")" 1
}

@test "an alert whose post Discord refused, whose problem ends before the next run, is closed with no post and no edit" {
  run_bin -0 team-timers run
  fail_checkpoint
  run_bin -1 team-timers run
  echo 503 >"$STUB_FIXTURES/inbox/fail"
  checkpoint_due
  run_bin -1 team-timers run
  jq -e '.state == "open"' <<<"$(open_alert checkpoint)"

  rm "$STUB_FIXTURES/inbox/fail"
  git -C "${TEAM_HOME:?}" checkout -q dev
  checkpoint_due
  run_bin -0 team-timers run
  assert_equal "$(alert_lines | tail -n 1)" "alert: checkpoint: ended before its post went through; closed"
  assert_equal "$(alerts_shown)" ""
  assert_equal "$(grep -c '^PATCH ' "$STUB_FIXTURES/inbox/calls" || true)" 0
  assert_equal "$(open_alerts)" ""
}

# The alerts of a health.json from before the notice record, <filter> its alerts object (with
# date_record's $now at hand), the notice record removed as it was then: old_alerts <filter>
old_alerts() {
  rm -f "$notices"
  date_record ".alerts = ($1)"
}

@test "the open alerts of a health.json from before the notice record are moved by the next run: the posted one resolved by an edit, the unposted one posted once" {
  run_bin -0 team-timers run
  local old=1569000000000000099 text="No coordinator session is live on home-pc since 09:00."
  jq -n --arg text "$text" '{content: $text}' >"$STUB_FIXTURES/inbox/$old.json"
  old_alerts "{coordinator: {since: \$now, text: \"$text\", posted: \$now, message: \"$old\"},
    checkpoint: {since: \$now, text: \"an older text\", posted: null, message: null}}"
  fail_checkpoint
  TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  jq -e 'has("alerts") | not' "$record"
  jq -e '.upgraded | index("health") != null' "$notices"
  # The posted one, whose problem has ended, is edited resolved, never posted again.
  assert_equal "$(edits_of "$old")" 1
  [[ $(jq -r .content "$STUB_FIXTURES/inbox/$old.json") =~ ^"$text"$'\n'"-# Resolved at "[0-9]{2}:[0-9]{2}"."$ ]]
  # The unposted one, whose problem stands, is posted once, with this run's text.
  assert_equal "$(alerts_shown | wc -l)" 1
  [[ $(alerts_shown | jq -r .content) == "Checkpoints are failing on home-pc since "* ]]
  local id
  id=$(alerts_shown | jq -r .id)
  assert_equal "$(alert_lines)" "alert: checkpoint: posted to #coordinator (message $id)
alert: coordinator: resolved (message $old edited)"
  assert_equal "$(open_alerts)" "checkpoint $id"
  checkpoint_due
  TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 1
  assert_equal "$(edits_of "$old")" 1
}

@test "an alerts key put back in health.json once its alerts are moved brings no alert back, and is stripped" {
  run_bin -0 team-timers run
  jq -e '(.upgraded | index("health") != null) and .notices == {}' "$notices"
  local old=1569000000000000099
  echo '{"content": "an old alert"}' >"$STUB_FIXTURES/inbox/$old.json"
  date_record ".alerts = {coordinator: {since: \$now, text: \"an old alert\", posted: \$now, message: \"$old\"}}"
  checkpoint_due
  run_bin -0 team-timers run
  jq -e 'has("alerts") | not' "$record"
  assert_equal "$(edits_of "$old")" 0
  assert_equal "$(alert_lines)" ""
  assert_equal "$(open_alerts)" ""
}

@test "a notice record that is not team-notices/1 is set aside as notices.json.bad with a problem line, and the run goes on to post the alert" {
  run_bin -0 team-timers run
  echo 'not json' >"$notices"
  fail_checkpoint
  TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  assert_equal "$(cat "$notices.bad")" "not json"
  assert_equal "$(problems_logged | grep '^alert: ')" \
    "alert: $notices is not a team-notices/1 record; it is set aside as $notices.bad, and the notices start again from empty"
  assert_equal "$(alerts_shown | wc -l)" 1
  assert_equal "$(open_alerts)" "checkpoint $(alerts_shown | jq -r .id)"

  # A record of another schema is set aside the same way.
  echo '{"schema": "team-notices/2", "notices": {}}' >"$notices"
  checkpoint_due
  TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  jq -e '.schema == "team-notices/2"' "$notices.bad"
  jq -e '.schema == "team-notices/1"' "$notices"
}

@test "a notice record whose lock another writer holds is a problem line that fails nothing, and the next run posts the alert once" {
  # The lock is taken during the alert's post, and held until the test lets it go.
  stub_script curl <<'SH'
if [[ $* == *"-X POST"* && $* == *allowed_mentions* && ! -e $STUB_FIXTURES/lock.pid ]]; then
  (exec 9>>"$HOME/.local/state/agent-team/notices.lock" && flock 9 && echo "$BASHPID" >"$STUB_FIXTURES/lock.pid.new" &&
    mv "$STUB_FIXTURES/lock.pid.new" "$STUB_FIXTURES/lock.pid" && exec sleep 60) </dev/null >/dev/null 2>&1 3>&- &
  for _ in $(seq 1 200); do [[ ! -s $STUB_FIXTURES/lock.pid ]] || break; sleep 0.05; done
fi
source "$STUB_FIXTURES/inbox.sh"
echo "curl: (22) The requested URL returned error: 404" >&2
exit 22
SH
  run_bin -0 team-timers run
  fail_checkpoint
  TEAM_NOTICES_LOCK_SECONDS=1 TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  kill "$(cat "$STUB_FIXTURES/lock.pid")"
  local lock=$state/notices.lock
  assert_equal "$(alerts_shown | wc -l)" 1
  # The post went through, but its outcome could not be written; the run's end could not judge.
  assert_equal "$(problems_logged | grep '^alert: ')" \
    "alert: checkpoint: cannot write the notice record $notices (another writer held $lock for 1 s), so this alert is judged again next run
alert: cannot judge the alerts: another writer held $lock for 1 s"
  jq -e '.state == "open" and .posted == null' <<<"$(open_alert checkpoint)"

  checkpoint_due
  TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 2
  assert_equal "$(open_alerts)" "checkpoint $(alerts_shown | tail -n 1 | jq -r .id)"
  checkpoint_due
  TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 2
}

@test "a ledger line no reader can parse posts the ledger alert in the same run, once, and resolves when the line is fixed" {
  local ledger=$TEAM_HOME/ledger.jsonl count
  printf '%s\n' "not json" '[1, 2]' >>"$ledger"
  count=$(wc -l <"$ledger")
  run_bin -1 team-timers run
  jq -e --arg text "ledger.jsonl on home-pc holds 2 lines no reader can parse (line $((count - 1)), $count), so every reader skips them: team-log --check names them." \
    '.content == $text' <<<"$(alerts_shown)"
  checkpoint_due
  run_bin -1 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 1

  head -n "$((count - 2))" "$ledger" >"$ledger.new"
  mv "$ledger.new" "$ledger"
  checkpoint_due
  run_bin -0 team-timers run
  [[ $(alerts_shown | jq -r .content) == *$'\n'"-# Resolved at "??:??. ]]
  assert_equal "$(open_alerts)" ""
}

@test "a step failing 12 runs in a row posts its alert once, 11 runs post nothing, and its first good run resolves it" {
  local file=$HOME/.config/agent-team/capacity.json
  mkdir -p "${file%/*}"
  echo '{"minor_share": "a third"}' >"$file"
  run_bin -1 team-timers run
  date_record '.steps.capacity.runs = 10 | .steps.level.runs = 10'
  run_bin -1 team-timers run
  assert_equal "$(alerts_shown)" ""

  run_bin -1 team-timers run
  local since
  since=$(jq -r .steps.capacity.since "$record")
  assert_equal "$(alerts_shown | jq -r .content | head -n 1)" \
    "The heartbeat's capacity step has failed 12 runs in a row on home-pc, since $(clock "$since"): $file: minor_share must be a number above 0 and at most 1, not \"a third\"."
  # The level step reads the same file, so it alerts in the same run.
  assert_equal "$(open_alerts | cut -d' ' -f1 | sort | paste -sd ' ')" "step-capacity step-level"
  run_bin -1 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 2

  rm "$file"
  run_bin -0 team-timers run
  assert_equal "$(open_alerts)" ""
  assert_equal "$(alert_lines | grep -c ': resolved (message ')" 2
}

@test "offline, with the login refused and off the lease, no alert is posted or resolved, and an open one is judged again on the next holder run" {
  run_bin -0 team-timers run
  fail_checkpoint
  run_bin -1 team-timers run
  checkpoint_due
  run_bin -1 team-timers run
  local id
  id=$(alerts_shown | jq -r .id)
  # The checkpoint would now work, but no run here judges the alerts.
  git -C "${TEAM_HOME:?}" checkout -q dev
  local before
  before=$(alert_lines | wc -l)

  stub_sleep
  git -C "${TEAM_HOME:?}" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -75 team-timers run
  run_bin -75 team-timers run
  rm "$state/offline"
  git -C "${TEAM_HOME:?}" remote set-url origin "$(http_origin 403)"
  run_bin -1 team-timers run
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  assert_equal "$(alert_lines | wc -l)" "$before"
  assert_equal "$(open_alerts)" "checkpoint $id"
  [[ $(alerts_shown | jq -r .content) != *Resolved* ]]

  # The next holder run, in the same holding, judges it again: the checkpoint works, so it
  # resolves.
  checkpoint_due
  run_bin -0 team-timers run
  assert_equal "$(alert_lines | tail -n 1)" "alert: checkpoint: resolved (message $id edited)"
  assert_equal "$(open_alerts)" ""

  # Off the lease and fenced, a run judges nothing.
  fail_checkpoint
  run_bin -1 team-timers run
  checkpoint_due
  run_bin -1 team-timers run
  id=$(alerts_shown | tail -n 1 | jq -r .id)
  git -C "${TEAM_HOME:?}" checkout -q dev
  before=$(alert_lines | wc -l)
  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-timers run
  assert_equal "$(alert_lines | wc -l)" "$before"
  assert_equal "$(open_alerts)" "checkpoint $id"
  run -0 "$REPO_ROOT/bin/team-lease" take
  echo '{"since": "2026-11-01T00:00:00Z"}' >"$state/fenced"
  run_bin team-timers run
  assert_equal "$(alert_lines | wc -l)" "$before"
  rm "$state/fenced"

  # The next holder run judges it again, in a new holding of the lease: it is closed with no edit.
  checkpoint_due
  run_bin -0 team-timers run
  assert_equal "$(alert_lines | tail -n 1)" \
    "alert: checkpoint: posted in an earlier holding of the lease, so it is closed without an edit (message $id)"
  assert_equal "$(edits_of "$id")" 0
  assert_equal "$(open_alerts)" ""
}

# Open the checkpoint alert in this holding of the lease, let laptop steal the lease and release
# it, and take it back here, as Daniel would after a steal: lease_round_trip
lease_round_trip() {
  run_bin -0 team-timers run
  fail_checkpoint
  run_bin -1 team-timers run
  checkpoint_due
  run_bin -1 team-timers run
  make_machine laptop
  steal_lease laptop home-pc
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" release
  run -0 "$REPO_ROOT/bin/team-lease" take
}

# How many edits message <id> got.
edits_of() {
  inbox_calls | grep -c "^PATCH channels/[0-9]*/messages/$1$" || true
}

@test "an alert posted in an earlier holding of the lease whose problem has ended is closed with no edit when the lease returns" {
  lease_round_trip
  local id
  id=$(alerts_shown | jq -r .id)
  git -C "${TEAM_HOME:?}" checkout -q dev
  checkpoint_due
  run_bin -0 team-timers run
  assert_equal "$(edits_of "$id")" 0
  [[ $(alerts_shown | jq -r .content) != *Resolved* ]]
  assert_equal "$(alert_lines | tail -n 1)" \
    "alert: checkpoint: posted in an earlier holding of the lease, so it is closed without an edit (message $id)"
  assert_equal "$(problems_logged | grep -c '^alert: ')" 0
  assert_equal "$(alerts_shown | wc -l)" 1
  assert_equal "$(open_alerts)" ""
}

@test "an alert posted in an earlier holding of the lease whose problem still stands is closed with no edit and posted afresh when the lease returns" {
  lease_round_trip
  local id new
  id=$(alerts_shown | jq -r .id)
  checkpoint_due
  run_bin -1 team-timers run
  assert_equal "$(edits_of "$id")" 0
  assert_equal "$(alerts_shown | wc -l)" 2
  new=$(alerts_shown | tail -n 1 | jq -r .id)
  [[ $new != "$id" ]]
  [[ $(alerts_shown | tail -n 1 | jq -r .content) == "Checkpoints are failing on home-pc since "*" (3 runs): "* ]]
  assert_equal "$(alert_lines | tail -n 2)" \
    "alert: checkpoint: posted in an earlier holding of the lease, so it is closed without an edit (message $id)
alert: checkpoint: posted to #coordinator (message $new)"
  assert_equal "$(open_alerts)" "checkpoint $new"
  # The next run, in the same holding, posts nothing more.
  checkpoint_due
  run_bin -1 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 2
}

@test "an alert of a health.json from before the notice record, posted before this holding of the lease, whose problem has ended is closed with no edit" {
  run_bin -0 team-timers run
  local old=1569000000000000099 text="No coordinator session is live on home-pc since 09:00."
  jq -n --arg text "$text" '{content: $text}' >"$STUB_FIXTURES/inbox/$old.json"
  date_lease_record --take 1
  old_alerts "{coordinator: {since: ago(70), text: \"$text\", posted: ago(60), message: \"$old\"}}"
  run_bin -0 team-timers run
  jq -e 'has("alerts") | not' "$record"
  assert_equal "$(edits_of "$old")" 0
  assert_equal "$(jq -r .content "$STUB_FIXTURES/inbox/$old.json")" "$text"
  assert_equal "$(alert_lines)" \
    "alert: coordinator: posted in an earlier holding of the lease, so it is closed without an edit (message $old)"
  assert_equal "$(alerts_shown)" ""
  assert_equal "$(open_alerts)" ""
}

@test "an alert of a health.json from before the notice record, posted before this holding of the lease, whose problem still stands is closed with no edit and posted afresh" {
  run_bin -0 team-timers run
  local old=1569000000000000099
  echo '{"content": "Checkpoints are failing on home-pc since 09:00."}' >"$STUB_FIXTURES/inbox/$old.json"
  date_lease_record --take 1
  old_alerts "{checkpoint: {since: ago(70), text: \"Checkpoints are failing on home-pc since 09:00.\", posted: ago(60),
    message: \"$old\"}}"
  fail_checkpoint
  TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  assert_equal "$(edits_of "$old")" 0
  assert_equal "$(alerts_shown | wc -l)" 1
  local id
  id=$(alerts_shown | jq -r .id)
  [[ $id != "$old" ]]
  [[ $(alerts_shown | jq -r .content) == "Checkpoints are failing on home-pc since "* ]]
  assert_equal "$(alert_lines)" \
    "alert: checkpoint: posted in an earlier holding of the lease, so it is closed without an edit (message $old)
alert: checkpoint: posted to #coordinator (message $id)"
  assert_equal "$(open_alerts)" "checkpoint $id"
}

@test "a checkpoint alert is posted before the run's janitor step" {
  fake_checkpoint <<'SH'
echo "team-checkpoint: T1 home: cannot push: the remote hung up" >&2
exit 1
SH
  rm "$BATS_TEST_TMPDIR/code/bin/team-janitor"
  printf '#!/usr/bin/env bash\necho "the janitor ran"\n' >"$BATS_TEST_TMPDIR/code/bin/team-janitor"
  chmod +x "$BATS_TEST_TMPDIR/code/bin/team-janitor"
  mkdir -p "$HOME/.config/agent-team"
  echo '{"heartbeat_janitor": true}' >"$HOME/.config/agent-team/stack.json"
  TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  local alert janitor
  alert=$(grep -n ' alert: checkpoint: posted ' <<<"$output" | cut -d: -f1)
  janitor=$(grep -n ' janitor: the janitor ran$' <<<"$output" | cut -d: -f1)
  [[ -n $alert && -n $janitor ]]
  ((alert < janitor))
  assert_equal "$(alerts_shown | wc -l)" 1
}

@test "an alert mentions no one whatever its reason holds, and is cut to Discord's limit with room for its resolved line" {
  local long
  long=$(printf 'x%.0s' {1..3000})
  fake_checkpoint <<SH
echo "team-checkpoint: T1 home: cannot push: @everyone <@123> $long" >&2
exit 1
SH
  TEAM_TIMERS_HEALTH_RUNS=1 run_bin -1 team-timers run
  local shown
  shown=$(alerts_shown)
  jq -e '.allowed_mentions == {parse: []} and (.content | length) == 1978 and (.content | endswith("..."))' <<<"$shown"

  rm "$BATS_TEST_TMPDIR/code/bin/team-checkpoint"
  cp "$REPO_ROOT/bin/team-checkpoint" "$BATS_TEST_TMPDIR/code/bin/team-checkpoint"
  checkpoint_due
  run_bin -0 team-timers run
  shown=$(alerts_shown)
  jq -e '.allowed_mentions == {parse: []} and (.content | length) == 2000' <<<"$shown"
}

@test "a run that outlasts the stale minutes judges nothing at its end, so an open checkpoint alert is not resolved by the heartbeat problem it then sees" {
  run_bin -0 team-timers run
  fail_checkpoint
  run_bin -1 team-timers run
  checkpoint_due
  run_bin -1 team-timers run
  local id
  id=$(alerts_shown | jq -r .id)
  # A janitor that takes 4 s, with a run 3 s old counted as a heartbeat not running: at the run's
  # end the view says the heartbeat last ran too long ago, which says nothing of the checkpoint.
  fake_checkpoint <<'SH'
echo "team-checkpoint: team home: not on a branch, so the records are not committed" >&2
exit 1
SH
  rm "$BATS_TEST_TMPDIR/code/bin/team-janitor"
  printf '#!/usr/bin/env bash\ncommand -p sleep 4\n' >"$BATS_TEST_TMPDIR/code/bin/team-janitor"
  chmod +x "$BATS_TEST_TMPDIR/code/bin/team-janitor"
  mkdir -p "$HOME/.config/agent-team"
  echo '{"heartbeat_janitor": true}' >"$HOME/.config/agent-team/stack.json"
  TEAM_TIMERS_HEALTH_STALE_MINUTES=0.05 run_bin -1 team-timers run
  assert_equal "$(open_alerts)" "checkpoint $id"
  assert_equal "$(alert_lines | wc -l)" 1
}

# The coordinator step: one read of the live session list after the checkpoint and ledger steps,
# looking for a session named coordinator, as claude-coordinator does before it launches one.

# The heartbeat log's coordinator lines, each without its time.
coordinator_lines() {
  grep -E '^[^ ]+ coordinator: ' "$log" | cut -d' ' -f2- || true
}

# The live session list with no coordinator: a worker whose name merely holds the word.
no_coordinator() {
  stub_reply claude '[{"id": "a1b2c3d4", "name": "T5-coordinator-notes", "status": "idle"}]'
}

@test "with a live coordinator the step logs nothing and the view has no coordinator problem; the healthy line ends with it" {
  run_bin -0 team-timers run
  assert_equal "$(coordinator_lines)" ""
  view
  jq -e '.ok and .problems == [] and (.line | endswith(", coordinator live"))
    and (.text | endswith(", coordinator live"))' <<<"$view"
}

@test "no coordinator session two runs in a row posts one alert with the command that starts one; later runs post nothing; the first run with one resolves it" {
  run_bin -0 team-timers run
  no_coordinator
  # One run with none is the coordinator problem, not alerting, and posts nothing.
  run_bin -0 team-timers run
  assert_equal "$(coordinator_lines)" "coordinator: no session named coordinator is live; claude-coordinator starts one"
  view
  assert_equal "$view_status" 1
  local since
  since=$(jq -r '.coordinator.since' "$record")
  jq -e --arg since "$since" '. == {key: "coordinator", since: $since, text: "no coordinator session since \($since)",
    alerting: false, sweep: null}' <<<"$(problem_of coordinator)"
  assert_equal "$(alerts_shown)" ""

  # The second run in a row posts once, mentioning no one.
  run_bin -0 team-timers run
  view
  jq -e --arg since "$since" '.since == $since and .alerting and .sweep == null' <<<"$(problem_of coordinator)"
  local id
  id=$(jq -r .id <<<"$(alerts_shown)")
  jq -e --arg text "No coordinator session is live on home-pc since $(clock "$since"): workers' reports and your messages go unread until one runs. Start it with claude-coordinator." \
    '. == {id: .id, content: $text, allowed_mentions: {parse: []}}' <<<"$(alerts_shown)"
  assert_equal "$(alert_lines)" "alert: coordinator: posted to #coordinator (message $id)"
  assert_equal "$(open_alerts)" "coordinator $id"
  # It names no sweep kind, so the sweep raises nothing for it: only the worker, in no task of
  # the ledger, is a finding.
  run_bin -1 team-sweep --json
  jq -e 'map(.kind) == ["stray"]' <<<"$output"

  # Later runs post nothing more, and the line says since when.
  run_bin -0 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 1
  view
  assert_equal "$(jq -r .line <<<"$view")" "**Health**: no coordinator session since <t:$(date -d "$since" +%s):t>"

  # The first run that finds one edits the post resolved and clears the problem.
  stub_reply claude "$COORDINATOR"
  run_bin -0 team-timers run
  [[ $(jq -r .content <<<"$(alerts_shown)") =~ ^"No coordinator session is live on home-pc since $(clock "$since"): "[^$'\n']+" Start it with claude-coordinator."$'\n'"-# Resolved at "[0-9]{2}:[0-9]{2}"."$ ]]
  assert_equal "$(alert_lines | tail -n 1)" "alert: coordinator: resolved (message $id edited)"
  assert_equal "$(open_alerts)" ""
  view
  jq -e '.ok' <<<"$view"
  assert_equal "$(coordinator_lines | wc -l)" 3
}

# The next read of the session list only, the coordinator step's (the run's first), runs the bash
# read from stdin, which exits; every later call answers as stub_reply set it.
next_list() {
  cat >"$STUB_FIXTURES/next-list.sh"
  stub_script claude <<'SH'
if [[ $1 == agents && -e $STUB_FIXTURES/next-list.sh ]]; then
  mv "$STUB_FIXTURES/next-list.sh" "$STUB_FIXTURES/next-list.ran"
  source "$STUB_FIXTURES/next-list.ran"
fi
print_file "$STUB_FIXTURES/claude.out"
exit "$(cat "$STUB_FIXTURES/claude.status")"
SH
}

@test "a session list that cannot be read is the coordinator step failing: one failed line, nothing concluded, an open coordinator alert left open" {
  run_bin -0 team-timers run
  # With a coordinator last seen live, an unreadable list concludes nothing about it, and the run
  # still ends 0.
  next_list <<'SH'
echo "cannot reach the daemon" >&2
exit 1
SH
  run_bin -0 team-timers run
  assert_equal "$(coordinator_lines)" \
    "coordinator: failed: cannot read the live session list (claude agents --json): cannot reach the daemon"
  assert_contains "$(problems_logged)" "coordinator: failed: cannot read the live session list"
  view
  assert_equal "$(problem_of coordinator)" null
  jq -e '.alerting | not' <<<"$(problem_of step-coordinator)"
  assert_equal "$(alerts_shown)" ""
  jq -e '.coordinator == {live: true}' "$record"

  # With none for two runs and its alert open, an unreadable list leaves the alert open.
  no_coordinator
  run_bin -0 team-timers run
  run_bin -0 team-timers run
  local id runs
  id=$(jq -r .id <<<"$(alerts_shown)")
  runs=$(jq .coordinator.runs "$record")
  next_list <<'SH'
echo '{"not": "a list"}'
exit 0
SH
  run_bin -0 team-timers run
  assert_equal "$(coordinator_lines | tail -n 1)" \
    "coordinator: failed: cannot read the live session list (claude agents --json): it printed no JSON list"
  assert_equal "$(open_alerts)" "coordinator $id"
  assert_equal "$(alerts_shown | wc -l)" 1
  assert_equal "$(jq .coordinator.runs "$record")" "$runs"
  view
  jq -e '.alerting' <<<"$(problem_of coordinator)"

  # A list that never answers is stopped at the step's limit.
  next_list <<'SH'
sleep 30
exit 0
SH
  TEAM_TIMERS_FINISHED_CALL_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 run_bin -0 team-timers run
  assert_equal "$(coordinator_lines | tail -n 1)" \
    "coordinator: failed: cannot read the live session list (claude agents --json): timed out after 1 s"
  assert_equal "$(open_alerts)" "coordinator $id"
  jq -e '.steps.coordinator.runs == 2' "$record"
}

@test "off the lease, offline and fenced the coordinator step does not run, and the record keeps what the last holder run saw" {
  run_bin -0 team-timers run
  no_coordinator
  run_bin -0 team-timers run
  local seen
  seen=$(jq -c .coordinator "$record")
  : >"$STUB_CALLS/claude.log"
  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-timers run
  stub_sleep
  run -0 "$REPO_ROOT/bin/team-lease" take
  git -C "${TEAM_HOME:?}" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -75 team-timers run
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  rm "$state/offline"
  echo '{"since": "2026-11-01T00:00:00Z"}' >"$state/fenced"
  run_bin team-timers run
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(coordinator_lines | wc -l)" 1
  assert_equal "$(jq -c .coordinator "$record")" "$seen"

  # Holding again, a record written before the take says nothing of the coordinator until the
  # first run of this holding looks.
  rm "$state/fenced"
  date_record '.written = ago(2)'
  view
  assert_equal "$(problem_of coordinator)" null
  date_lease_record --take 3
  view
  jq -e '.key == "coordinator"' <<<"$(problem_of coordinator)"
}

# The unattended findings: the coordinator step's team-sweep --json, each finding dated from the
# first run that saw it, and the alert once one has stood an hour with nothing logged since.

# The live session list with the coordinator and a worker of a task the ledger does not hold, which
# the sweep finds stray at every look; STRAYS has two such workers.
STRAY='[{"id": "c0ffee00", "name": "coordinator", "status": "idle"}, {"id": "9a9a9a9a", "name": "T9-builder", "status": "idle"}]'
STRAYS='[{"id": "c0ffee00", "name": "coordinator", "status": "idle"}, {"id": "8a8a8a8a", "name": "T8-builder", "status": "idle"}, {"id": "9a9a9a9a", "name": "T9-builder", "status": "idle"}]'

# Append an event <event> to the ledger, logged <minutes> ago: log_event <minutes> <event>
log_event() {
  jq -cn --argjson m "$1" --arg event "$2" '{ts: (now - $m * 60 | floor | todate), task: "T1", event: $event}' \
    >>"$TEAM_HOME/ledger.jsonl"
}

# Date every event of the ledger <minutes> ago.
date_ledger() {
  local file=$TEAM_HOME/ledger.jsonl
  [[ -s $file ]] || return 0
  jq -c --argjson m "$1" '.ts = (now - $m * 60 | floor | todate)' "$file" >"$file.new"
  mv "$file.new" "$file"
}

# The time of the ledger's last event that is not a denied.
last_logged() {
  jq -r 'select(.event != "denied") | .ts' "$TEAM_HOME/ledger.jsonl" | tail -n 1
}

# The sweep's stray findings' texts, in its order, one a line.
stray_texts() {
  { "$REPO_ROOT/bin/team-sweep" --json || true; } | jq -r '.[] | select(.kind == "stray") | .text'
}

# Replace team-sweep with the bash read from stdin, in a code checkout of the test's own.
fake_sweep() {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  [[ -d $CODE_CHECKOUT/bin ]] || copy_bin "$CODE_CHECKOUT/bin"
  rm -f "$CODE_CHECKOUT/bin/team-sweep"
  { echo '#!/usr/bin/env bash'; cat; } >"$CODE_CHECKOUT/bin/team-sweep"
  chmod +x "$CODE_CHECKOUT/bin/team-sweep"
}

@test "a sweep finding seen at every run for an hour with nothing logged since posts one unattended alert; at 59 minutes nothing; later runs post nothing; its clearing resolves it" {
  stub_reply claude "$STRAY"
  log_event 0 note
  run_bin -0 team-timers run
  local text
  text=$(stray_texts)
  date_ledger 120
  # First seen 59 minutes ago: nothing.
  date_record '.findings[].since = ago(59)'
  run_bin -0 team-timers run
  view
  assert_equal "$(problem_of unattended)" null
  assert_equal "$(alerts_shown)" ""

  # Past the hour, at every run, with nothing logged since: one post, mentioning no one.
  date_record '.findings[].since = ago(61)'
  run_bin -0 team-timers run
  view
  local since id
  since=$(jq -r '.findings[0].since' "$record")
  jq -e --arg since "$since" '. == {key: "unattended", since: $since,
    text: "the coordinator has left 1 finding unattended since \($since)", alerting: true, sweep: null}' <<<"$(problem_of unattended)"
  id=$(jq -r .id <<<"$(alerts_shown)")
  jq -e --arg text "The coordinator on home-pc has left 1 finding unattended for over an hour, with nothing logged since $(clock "$(last_logged)"): $text. It may be stalled: look at its session, and restart it with claude-coordinator if it is." \
    '. == {id: .id, content: $text, allowed_mentions: {parse: []}}' <<<"$(alerts_shown)"
  assert_equal "$(alert_lines)" "alert: unattended: posted to #coordinator (message $id)"
  # The heartbeat starts no coordinator: no claude call but the session lists.
  assert_equal "$(stub_calls claude | jq -sc 'map(select(. != ["agents", "--json"]))')" "[]"

  # Later runs post nothing more, and the line says since when.
  run_bin -0 team-timers run
  assert_equal "$(alerts_shown | wc -l)" 1
  view
  assert_equal "$(jq -r .line <<<"$view")" "**Health**: the coordinator has left 1 finding unattended since <t:$(date -d "$since" +%s):t>"

  # The finding clears: the post is edited resolved.
  stub_reply claude "$COORDINATOR"
  run_bin -0 team-timers run
  [[ $(jq -r .content <<<"$(alerts_shown)") =~ ^"The coordinator on home-pc has left 1 finding unattended "[^$'\n']+$'\n'"-# Resolved at "[0-9]{2}:[0-9]{2}"."$ ]]
  assert_equal "$(alert_lines | tail -n 1)" "alert: unattended: resolved (message $id edited)"
  assert_equal "$(open_alerts)" ""
  view
  jq -e '.ok' <<<"$view"
}

@test "several unattended findings are counted, the first quoted with how many more; an event logged since posts nothing, a denied alone is none, and one logged after the post resolves it" {
  stub_reply claude "$STRAYS"
  log_event 0 note
  run_bin -0 team-timers run
  local first
  first=$(stray_texts | head -n 1)
  date_record '.findings[].since = ago(61)'
  # An event logged since the findings were first seen: nothing.
  date_ledger 120
  log_event 30 note
  run_bin -0 team-timers run
  view
  assert_equal "$(problem_of unattended)" null
  assert_equal "$(alerts_shown)" ""

  # With nothing logged since but a denied, both are counted in one post.
  date_ledger 120
  log_event 0 denied
  run_bin -0 team-timers run
  view
  jq -e '.text | startswith("the coordinator has left 2 findings unattended since ")' <<<"$(problem_of unattended)"
  assert_equal "$(jq -r .content <<<"$(alerts_shown)")" \
    "The coordinator on home-pc has left 2 findings unattended for over an hour, with nothing logged since $(clock "$(last_logged)"): $first; and 1 more. It may be stalled: look at its session, and restart it with claude-coordinator if it is."

  # An event logged now ends it while the findings stand.
  log_event 0 note
  run_bin -0 team-timers run
  [[ $(jq -r .content <<<"$(alerts_shown)") == *$'\n'"-# Resolved at "[0-9][0-9]:[0-9][0-9]. ]]
  assert_equal "$(alerts_shown | wc -l)" 1
  assert_equal "$(open_alerts)" ""
  view
  assert_equal "$(problem_of unattended)" null
}

@test "a finding that cleared for one run is dated from its return, and none is unattended while no coordinator is live, which the coordinator alert says" {
  stub_reply claude "$STRAY"
  run_bin -0 team-timers run
  date_ledger 120
  date_record '.findings[].since = ago(61)'
  stub_reply claude "$COORDINATOR"
  run_bin -0 team-timers run
  jq -e '.findings == []' "$record"
  local back
  back=$(date -u +%FT%TZ)
  stub_reply claude "$STRAY"
  run_bin -0 team-timers run
  jq -e --arg back "$back" '(.findings | length) == 1 and .findings[0].since >= $back' "$record"
  view
  assert_equal "$(problem_of unattended)" null

  # With no coordinator live, an hour-old finding is the coordinator problem only.
  stub_reply claude '[{"id": "9a9a9a9a", "name": "T9-builder", "status": "idle"}]'
  run_bin -0 team-timers run
  date_record '.findings[].since = ago(61)'
  run_bin -0 team-timers run
  view
  assert_equal "$(problem_of unattended)" null
  jq -e '.alerting' <<<"$(problem_of coordinator)"
  assert_equal "$(alerts_shown | wc -l)" 1
  jq -e '.content | startswith("No coordinator session is live on home-pc")' <<<"$(alerts_shown)"
  assert_equal "$(open_alerts | cut -d' ' -f1)" coordinator
}

@test "a sweep that cannot run is the coordinator step failing with its reason, one line a run, keeping the findings seen and posting no unattended alert" {
  stub_reply claude "$STRAY"
  run_bin -0 team-timers run
  date_record '.findings[].since = ago(30)'
  local seen
  seen=$(jq -c .findings "$record")
  fake_sweep <<'SH'
echo "team-sweep: cannot read the live session list: the daemon is down" >&2
exit 1
SH
  run_bin -0 team-timers run
  assert_equal "$(coordinator_lines)" \
    "coordinator: failed: cannot run the sweep (team-sweep --json): cannot read the live session list: the daemon is down"
  assert_contains "$(problems_logged)" "coordinator: failed: cannot run the sweep (team-sweep --json): cannot read"
  assert_equal "$(jq -c .findings "$record")" "$seen"
  view
  jq -e '.alerting | not' <<<"$(problem_of step-coordinator)"
  assert_equal "$(problem_of unattended)" null

  fake_sweep <<'SH'
echo '{"not": "a list"}'
SH
  run_bin -0 team-timers run
  assert_equal "$(coordinator_lines | tail -n 1)" "coordinator: failed: cannot run the sweep (team-sweep --json): it printed no JSON list"
  fake_sweep <<'SH'
exit 1
SH
  run_bin -0 team-timers run
  assert_equal "$(coordinator_lines | tail -n 1)" "coordinator: failed: cannot run the sweep (team-sweep --json): team-sweep exited 1 with no JSON list"
  fake_sweep <<'SH'
sleep 30
SH
  TEAM_TIMERS_COORDINATOR_SWEEP_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 run_bin -0 team-timers run
  assert_equal "$(coordinator_lines | tail -n 1)" "coordinator: failed: cannot run the sweep (team-sweep --json): timed out after 1 s"
  assert_equal "$(coordinator_lines | wc -l)" 4
  jq -e '.steps.coordinator.runs == 4' "$record"
  assert_equal "$(jq -c .findings "$record")" "$seen"
  assert_equal "$(alerts_shown)" ""
}

@test "a finding is unattended only when seen at every run: a run whose sweep failed starts it again, so an hour of failed looks posts no unattended alert" {
  stub_reply claude "$STRAY"
  run_bin -0 team-timers run
  date_ledger 120
  date_record '.findings[].since = ago(61)'
  fake_sweep <<'SH'
echo "team-sweep: cannot read the live session list: the daemon is down" >&2
exit 1
SH
  run_bin -0 team-timers run
  assert_equal "$(coordinator_lines)" \
    "coordinator: failed: cannot run the sweep (team-sweep --json): cannot read the live session list: the daemon is down"
  view
  assert_equal "$(problem_of unattended)" null
  assert_equal "$(alerts_shown)" ""

  # The sweep runs again: the finding is dated from this look, not from the one before the failure.
  rm -f "$CODE_CHECKOUT/bin/team-sweep"
  cp "$REPO_ROOT/bin/team-sweep" "$CODE_CHECKOUT/bin/team-sweep"
  local back
  back=$(date -u +%FT%TZ)
  run_bin -0 team-timers run
  jq -e --arg back "$back" '(.findings | length) == 1 and .findings[0].since >= $back' "$record"
  view
  assert_equal "$(problem_of unattended)" null
  assert_equal "$(alerts_shown)" ""
}

@test "a finding is unattended only when seen at every run: after a sleep longer than the stale minutes, the first look dates it anew and posts nothing" {
  stub_reply claude "$STRAY"
  run_bin -0 team-timers run
  date_ledger 120
  # The machine slept for over an hour after that run, the coordinator with it.
  date_record '.findings[].since = ago(61) | .last_run.start = ago(61) | .last_run.end = ago(61)
    | if has("findings_at") then .findings_at = ago(61) else . end'
  date_lease_record 61
  local back
  back=$(date -u +%FT%TZ)
  # Read before the first run after waking, the view says nothing of it either.
  view
  assert_equal "$(problem_of unattended)" null
  run_bin -0 team-timers run
  # The sweep also saw the old record's stale heartbeat, a checkpoint-stale finding of its own.
  jq -e --arg back "$back" '[.findings[] | select(.kind == "stray")] | length == 1 and .[0].since >= $back' "$record"
  view
  assert_equal "$(problem_of unattended)" null
  assert_equal "$(alerts_shown)" ""
}

@test "a finding seen by a long run and by the next is still aged: only a run that starts over the stale minutes after the last ended dates it anew" {
  stub_reply claude "$STRAY"
  run_bin -0 team-timers run
  date_ledger 120
  # The run before took 18 minutes: it looked 20 minutes ago and ended 2 minutes ago, missing no slot.
  date_record '.findings[].since = ago(61) | .findings_at = ago(20) | .last_run.start = ago(20) | .last_run.end = ago(2)'
  run_bin -0 team-timers run
  view
  jq -e '.alerting' <<<"$(problem_of unattended)"
  assert_equal "$(alerts_shown | wc -l)" 1
  jq -e '.content | startswith("The coordinator on home-pc has left 1 finding unattended for over an hour")' <<<"$(alerts_shown)"
}
