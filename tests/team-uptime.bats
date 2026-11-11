#!/usr/bin/env bats
# team-uptime: each project's production checks, run by the heartbeat's uptime step on the lease
# holder. home-pc holds the lease (its local record, as team-lease leaves it); the checks fetch a
# stub production on the loopback (tests/helpers/http-check.py) with the machine's own curl, and
# the posts reach the fake Discord (tests/helpers/inbox.bash).

load helpers/common
load helpers/inbox
load helpers/uptime

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  uptime_holder home-pc
  inbox_discord alerts
  uptime_curl
  base=$(uptime_server)
  export TEAM_UPTIME_SECONDS=1 TEAM_UPTIME_KNOWN_GOOD=$base/known-good
  uptime_answer known-good 200 ''
  state=$HOME/.local/state/agent-team/uptime.json
  notices=$HOME/.local/state/agent-team/notices.json
}

teardown() {
  uptime_teardown
}

# A UTC time as the posts write it: this machine's local hours and minutes.
clock() {
  date -d "$1" +%H:%M
}

# Conventioner's API check on the stub, answering <status> with <body>.
api_check() {
  uptime_check conventioner api "$base/api" '"status":"ok"'
  uptime_answer api "$1" "$2"
}

# Rewrite the state file with jq <filter>, given $at: edit_state <filter> <at>
edit_state() {
  jq --arg at "$2" "$1" "$state" >"$state.new"
  mv "$state.new" "$state"
}

# jq <filter> on the open outage of the check <key> ("<project>/<name>"), its notice in the notice
# record as team-uptime status shows it, {since, posted, reminded, message, back} (back its
# ended), or null for none: outage <key> [<filter>]
outage() {
  jq -r --arg id "uptime/$1" '.notices[$id] | if . == null then null else {since, posted, reminded, message, back: .ended} end
    | '"${2:-.}" "$notices"
}

# Rewrite the notice of the check <key>'s outage with jq <filter>, given $at: edit_outage <key>
# <filter> <at>
edit_outage() {
  jq --arg id "uptime/$1" --arg at "$3" ".notices[\$id] |= ($2)" "$notices" >"$notices.new"
  mv "$notices.new" "$notices"
}

# The UTC time <minutes> ago.
ago() {
  date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ
}

@test "with no checks in the registry a run fetches nothing, posts nothing, prints nothing and writes no state" {
  run_bin -0 team-uptime run
  assert_equal "$output" ""
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(uptime_requests)" ""
  [[ ! -e $state ]]
}

@test "a check that is up prints nothing, posts nothing and is kept up in the state" {
  api_check 200 '{"status":"ok","db":"up"}'
  run_bin -0 team-uptime run
  assert_equal "$output" ""
  assert_equal "$(uptime_posts)" ""
  assert_equal "$(uptime_state .schema)" team-uptime/1
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.project, .name, .url, .expect, .ok, .failures, .since, .reason] | @json')" \
    "$(jq -nc --arg url "$base/api" '["conventioner", "api", $url, "\"status\":\"ok\"", true, 0, null, null]')"
  assert_equal "$(outage conventioner/api)" null
  uptime_state '.checks["conventioner/api"].checked | fromdateiso8601 > now - 60' | grep -qx true
}

@test "one failure posts nothing and prints the failed line" {
  api_check 503 'Service Unavailable'
  run_bin -0 team-uptime run
  local since
  since=$(uptime_state '.checks["conventioner/api"].since')
  assert_equal "$output" "conventioner/api: failed: HTTP 503 (1 in a row, since $since)"
  assert_equal "$(uptime_posts)" ""
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.ok, .failures, .reason] | @json')" '[false,1,"HTTP 503"]'
}

@test "a second failure posts one Production down, mentioning no one and with no preview, and opens the alert" {
  api_check 503 'Service Unavailable'
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  local since
  since=$(uptime_state '.checks["conventioner/api"].since')
  assert_equal "$output" "conventioner/api: failed: HTTP 503 (2 in a row, since $since)
posted to #coordinator (message 1569000000000000001): down: conventioner/api"
  assert_equal "$(uptime_posts)" "Production down: conventioner api (<$base/api>) since $(clock "$since"), 2 checks in a row from home-pc: HTTP 503."
  assert_equal "$(uptime_bodies | jq -c '[.allowed_mentions, .flags]')" '[{"parse":[]},4]'
  assert_equal "$(outage conventioner/api '[.since, .message, .reminded, .back] | @json')" \
    "$(jq -nc --arg since "$since" '[$since, "1569000000000000001", null, null]')"
  outage conventioner/api '.posted | fromdateiso8601 > now - 60' | grep -qx true
}

@test "a third failure posts nothing more" {
  api_check 503 'Service Unavailable'
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  assert_equal "$output" "conventioner/api: failed: HTTP 503 (3 in a row, since $(uptime_state '.checks["conventioner/api"].since'))"
  assert_equal "$(uptime_post_ids | wc -l)" 1
}

@test "a check that answers again posts one Production back with how long it was down, and closes the alert" {
  api_check 503 'Service Unavailable'
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  # The outage began 75 minutes ago.
  local since before after
  since=$(ago 75)
  edit_state '.checks["conventioner/api"].since = $at' "$since"
  edit_outage conventioner/api '.since = $at' "$since"
  uptime_answer api 200 '{"status":"ok"}'
  before=$(date -u +%FT%TZ)
  run_bin -0 team-uptime run
  after=$(date -u +%FT%TZ)
  assert_equal "$output" "posted to #coordinator (message 1569000000000000002): back: conventioner/api"
  local back
  back=$(uptime_posts | sed -n 2p)
  [[ $back == "Production back: conventioner api (<$base/api>) answers again at $(clock "$before"), down since $(clock "$since") (1 hour 15 minutes)." ||
    $back == "Production back: conventioner api (<$base/api>) answers again at $(clock "$after"), down since $(clock "$since") (1 hour 15 minutes)." ]] ||
    { echo "the back post: $back" >&2; return 1; }
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.ok, .failures, .since] | @json')" '[true,0,null]'
  assert_equal "$(outage conventioner/api)" null
  run_bin -0 team-uptime run
  assert_equal "$output" ""
  assert_equal "$(uptime_post_ids | wc -l)" 2
}

@test "two checks failing in the same runs arrive as one message, a line each in registry order" {
  # agent-team's check is written first, but conventioner comes first in the registry.
  uptime_check agent-team site "$base/site" 'agent-team'
  api_check 500 ''
  uptime_answer site 502 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  local api site
  api=$(uptime_state '.checks["conventioner/api"].since')
  site=$(uptime_state '.checks["agent-team/site"].since')
  assert_equal "$output" "conventioner/api: failed: HTTP 500 (2 in a row, since $api)
agent-team/site: failed: HTTP 502 (2 in a row, since $site)
posted to #coordinator (message 1569000000000000001): down: conventioner/api, agent-team/site"
  assert_equal "$(uptime_posts)" "Production down: conventioner api (<$base/api>) since $(clock "$api"), 2 checks in a row from home-pc: HTTP 500.
Production down: agent-team site (<$base/site>) since $(clock "$site"), 2 checks in a row from home-pc: HTTP 502."
}

@test "a failure's reason names the status, the text its answer lacks, or the time it gave no answer in" {
  api_check 503 ''
  uptime_check conventioner front-end "$base/front-end" '<div id="app">'
  uptime_answer front-end 200 '<html>Maintenance</html>'
  uptime_check conventioner slow "$base/slow" ok
  uptime_hang slow
  run_bin -0 team-uptime run
  assert_equal "$(sed -E 's/ \(1 in a row, since [^)]*\)$//' <<<"$output")" 'conventioner/api: failed: HTTP 503
conventioner/front-end: failed: HTTP 200, but its answer lacks `<div id="app">`
conventioner/slow: failed: no answer in 1 s'
}

@test "a failure the machine could not reach names curl's own reason" {
  uptime_check conventioner api "http://127.0.0.1:9/api" ok
  run_bin -0 team-uptime run
  [[ $output =~ ^conventioner/api:\ failed:\ (Failed\ to\ connect|Couldn\'t\ connect)[^\(]*\ \(1\ in\ a\ row ]] ||
    { echo "output: $output" >&2; return 1; }
}

@test "a restart mid-outage posts no second down, and the back post still comes" {
  api_check 503 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  # Everything but the lease record, the uptime state and the notice record is gone, as after a reboot.
  find "$HOME/.local/state/agent-team" -mindepth 1 ! -name lease.json ! -name uptime.json ! -name notices.json -delete
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 1
  uptime_answer api 200 '{"status":"ok"}'
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 2
  uptime_posts | sed -n 2p | grep -q '^Production back: conventioner api '
}

@test "a failure whose previous result is over 15 minutes old counts as the first" {
  api_check 503 ''
  run_bin -0 team-uptime run
  local old
  old=$(ago 20)
  edit_state '.checks["conventioner/api"] |= (.checked = $at | .since = $at)' "$old"
  run_bin -0 team-uptime run
  local since
  since=$(uptime_state '.checks["conventioner/api"].since')
  [[ $since != "$old" ]]
  assert_equal "$output" "conventioner/api: failed: HTTP 503 (1 in a row, since $since)"
  assert_equal "$(uptime_posts)" ""
}

@test "a posted outage stays down in status after a gap resets its streak, down since the outage began" {
  api_check 503 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  local old down
  old=$(ago 20)
  edit_state '.checks["conventioner/api"] |= (.checked = $at | .since = $at)' "$old"
  edit_outage conventioner/api '.since = $at' "$old"
  run_bin -0 team-uptime run
  assert_equal "$(uptime_state '.checks["conventioner/api"].failures')" 1
  assert_equal "$(outage conventioner/api .since)" "$old"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -r '.checks[0].state' <<<"$output")" down
  down=$(clock "$old")
  [[ $(jq -r .line <<<"$output") == "Production: conventioner api down since $down: HTTP 503, last checked "* ]]
  run_bin -0 team-uptime status
  [[ $output == "conventioner/api down since $down: HTTP 503, checked "* ]]
}

@test "a check is a plain GET, curl reading no curlrc, with only Host, its user agent and Accept" {
  api_check 200 '{"status":"ok"}'
  # A curlrc that would add a header, a cookie and a credential, which -q keeps out.
  printf 'header = "X-Secret: 1"\ncookie = "session=1"\nuser = "daniel:secret"\nlocation\n' >"$HOME/.curlrc"
  run_bin -0 team-uptime run
  assert_equal "$(uptime_requests | jq -c '[.method, .path, (.headers | keys)]')" '["GET","/api",["Accept","Host","User-Agent"]]'
  assert_equal "$(uptime_requests | jq -r '.headers["User-Agent"]')" agent-team-uptime/1
  assert_equal "$(stub_calls curl | jq -c 'index("--output") as $i | .[$i + 1] = "<file>"')" \
    "$(jq -nc --arg url "$base/api" '["-q", "--silent", "--show-error", "--proto", "=http,https", "--connect-timeout", "1",
      "--max-time", "1", "--max-filesize", "1048576", "--user-agent", "agent-team-uptime/1", "--output", "<file>",
      "--write-out", "%{http_code}", $url]')"
}

@test "a machine that does not hold the lease, or is fenced, checks nothing" {
  api_check 200 '{"status":"ok"}'
  rm "$HOME/.local/state/agent-team/lease.json"
  run_bin --separate-stderr -1 team-uptime run
  assert_equal "$stderr" "team-uptime: home-pc does not hold the lease, so it checks nothing"
  uptime_holder laptop
  echo home-pc >"$HOME/.config/agent-team/machine"
  run_bin --separate-stderr -1 team-uptime run
  assert_equal "$stderr" "team-uptime: home-pc does not hold the lease, so it checks nothing"
  uptime_holder home-pc
  echo '{"since": "2026-11-10T10:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin --separate-stderr -1 team-uptime run
  assert_equal "$stderr" "team-uptime: home-pc does not hold the lease, so it checks nothing"
  assert_equal "$(stub_calls curl)" ""
  [[ ! -e $state ]]
}

@test "a run while another holds the lock skips" {
  api_check 200 '{"status":"ok"}'
  exec {lock}>"$HOME/.local/state/agent-team/uptime.lock"
  flock -n "$lock"
  run_bin -0 team-uptime run
  exec {lock}>&-
  assert_equal "$output" "another team-uptime run is checking; skipped"
  assert_equal "$(stub_calls curl)" ""
}

@test "with every check up the known-good site is not fetched" {
  api_check 200 '{"status":"ok"}'
  run_bin -0 team-uptime run
  assert_equal "$(uptime_requests | jq -r .path)" /api
  [[ $(stub_calls curl) != *known-good* ]]
}

@test "a failure is counted when the known-good site answers, whatever its status" {
  api_check 503 ''
  uptime_answer known-good 500 'down for everyone but answering'
  run_bin -0 team-uptime run
  assert_equal "$(uptime_requests | jq -r .path)" "/api
/known-good"
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.ok, .failures, .reason] | @json')" '[false,1,"HTTP 503"]'
}

@test "with the known-good site unreachable a failure is not counted, nothing is posted, and the run fails" {
  api_check 503 ''
  run_bin -0 team-uptime run
  local since
  since=$(uptime_state '.checks["conventioner/api"].since')
  export TEAM_UPTIME_KNOWN_GOOD=http://127.0.0.1:9/
  edit_state '.written = $at' 2026-11-10T00:00:00Z
  local pattern='[^;)]+'
  for _ in 1 2; do
    run_bin --separate-stderr -1 team-uptime run
    [[ $output =~ ^cannot\ reach\ the\ internet:\ http://127\.0\.0\.1:9/:\ ${pattern}\;\ 1\ failing\ check\(s\)\ not\ counted$ ]] ||
      { echo "output: $output" >&2; return 1; }
    [[ $stderr =~ ^team-uptime:\ this\ machine\ cannot\ reach\ the\ internet\ \(http://127\.0\.0\.1:9/:\ ${pattern}\),\ so\ 1\ failing\ check\(s\)\ were\ not\ counted$ ]] ||
      { echo "stderr: $stderr" >&2; return 1; }
  done
  assert_equal "$(uptime_posts)" ""
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.failures, .since] | @json')" \
    "$(jq -nc --arg since "$since" '[1, $since]')"
  assert_equal "$(outage conventioner/api)" null
  uptime_state '.written | fromdateiso8601 > now - 60' | grep -qx true
}

@test "the default known-good site is GitHub's, named in the header" {
  run_bin -0 team-uptime --help
  assert_contains "$output" "https://github.com/"
  grep -qF 'KNOWN_GOOD=${TEAM_UPTIME_KNOWN_GOOD:-https://github.com/}' "$REPO_ROOT/bin/team-uptime"
}

@test "a check down 4 hours after its post is reminded once, and TEAM_UPTIME_REMIND_MINUTES replaces the 4 hours" {
  api_check 503 'Service Unavailable'
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  local old
  old=$(ago 240)
  edit_state '.checks["conventioner/api"].since = $at' "$old"
  edit_outage conventioner/api '.since = $at | .posted = $at' "$old"
  run_bin -0 team-uptime run
  assert_equal "$(sed -n 2p <<<"$output")" "posted to #coordinator (message 1569000000000000002): still down: conventioner/api"
  assert_equal "$(uptime_posts | sed -n 2p)" "Production still down: conventioner api (<$base/api>) since $(clock "$old"), 4 hours: HTTP 503."
  outage conventioner/api '.reminded | fromdateiso8601 > now - 60' | grep -qx true
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 2
  # Reminded 45 minutes ago: due at 30 minutes, not at the default 240.
  old=$(ago 45)
  edit_outage conventioner/api '.reminded = $at' "$old"
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 2
  TEAM_UPTIME_REMIND_MINUTES=30 run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 3
  uptime_posts | sed -n 3p | grep -q '^Production still down: conventioner api .*, 4 hours: HTTP 503\.$'
}

@test "a down post Discord refused keeps the alert unposted, fails the run, and is made at the next run" {
  api_check 503 ''
  run_bin -0 team-uptime run
  echo 503 >"$STUB_FIXTURES/inbox/fail"
  run_bin --separate-stderr -1 team-uptime run
  assert_equal "$stderr" "team-uptime: the post to #coordinator failed (curl: (22) The requested URL returned error: 503); it is tried again next run"
  assert_equal "$(uptime_posts)" ""
  assert_equal "$(outage conventioner/api '[.since != null, .posted, .message] | @json')" '[true,null,null]'
  rm "$STUB_FIXTURES/inbox/fail"
  run_bin -0 team-uptime run
  assert_equal "$(sed -n 2p <<<"$output")" "posted to #coordinator (message 1569000000000000001): down: conventioner/api"
  uptime_posts | grep -q '^Production down: conventioner api .* 3 checks in a row from home-pc: HTTP 503\.$'
  assert_equal "$(outage conventioner/api .message)" 1569000000000000001
}

@test "a back post Discord refused is made at the next run" {
  api_check 503 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  uptime_answer api 200 '{"status":"ok"}'
  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin --separate-stderr -1 team-uptime run
  local back
  back=$(outage conventioner/api .back)
  [[ $back != null ]]
  rm "$STUB_FIXTURES/inbox/fail"
  run_bin -0 team-uptime run
  assert_equal "$output" "posted to #coordinator (message 1569000000000000002): back: conventioner/api"
  uptime_posts | sed -n 2p | grep -qF "answers again at $(clock "$back"),"
  assert_equal "$(outage conventioner/api)" null
}

@test "a check that fails again before its back post went through stays the same outage and posts no new down" {
  api_check 503 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  local alert
  alert=$(outage conventioner/api '{since, posted, message} | @json')
  uptime_answer api 200 '{"status":"ok"}'
  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin -1 team-uptime run
  rm "$STUB_FIXTURES/inbox/fail"
  uptime_answer api 503 ''
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 1
  assert_equal "$(outage conventioner/api '{since, posted, message} | @json')" "$alert"
  assert_equal "$(outage conventioner/api .back)" null
  uptime_answer api 200 '{"status":"ok"}'
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 2
  uptime_posts | sed -n 2p | grep -q '^Production back: conventioner api '
}

@test "a check that answers again before its down post ever went through is closed with no post" {
  api_check 503 ''
  run_bin -0 team-uptime run
  echo 503 >"$STUB_FIXTURES/inbox/fail"
  run_bin -1 team-uptime run
  rm "$STUB_FIXTURES/inbox/fail"
  uptime_answer api 200 '{"status":"ok"}'
  run_bin -0 team-uptime run
  assert_equal "$output" "conventioner/api: answered again before its outage post went through; closed"
  assert_equal "$(uptime_posts)" ""
  assert_equal "$(outage conventioner/api)" null
}

@test "a check removed from the registry, or given a new URL, is dropped and its outage closed without a post" {
  api_check 503 ''
  uptime_check conventioner front-end "$base/front-end" '<div id="app">'
  uptime_answer front-end 502 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 1
  # The API check moves to a new URL that answers, and the front end is no longer checked.
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  uptime_check conventioner api "$base/api-v2" '"status":"ok"'
  uptime_answer api-v2 200 '{"status":"ok"}'
  run_bin -0 team-uptime run
  assert_equal "$output" "conventioner/api: no longer checked as it was; its open outage is closed without a post
conventioner/front-end: no longer checked as it was; its open outage is closed without a post"
  assert_equal "$(uptime_post_ids | wc -l)" 1
  assert_equal "$(uptime_state '.checks | keys | @json')" '["conventioner/api"]'
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.url, .ok, .failures] | @json')" \
    "$(jq -nc --arg url "$base/api-v2" '[$url, true, 0]')"
  assert_equal "$(jq -c '[.notices[] | select(.source == "uptime")]' "$notices")" '[]'
}

@test "a check whose expect changed starts fresh" {
  api_check 503 ''
  run_bin -0 team-uptime run
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  uptime_check conventioner api "$base/api" '"ok":true'
  run_bin -0 team-uptime run
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.expect, .failures] | @json')" '["\"ok\":true",1]'
  assert_equal "$(uptime_posts)" ""
}

# Stamp the lease record with the holding that began at <at>, as team-lease's take leaves it:
# take_lease <at>
take_lease() {
  local lease=$HOME/.local/state/agent-team/lease.json
  jq --arg at "$1" '.taken_at = $at' "$lease" >"$lease.new"
  mv "$lease.new" "$lease"
}

@test "an outage posted in an earlier holding of the lease is closed with no back post, and a check still down is posted down afresh" {
  take_lease "$(ago 60)"
  api_check 503 ''
  uptime_check conventioner front-end "$base/front-end" '<div id="app">'
  uptime_answer front-end 502 ''
  uptime_check conventioner admin "$base/admin" 'admin'
  uptime_answer admin 500 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 1
  # As if the admin check's down post had been refused: its outage opened, never posted.
  edit_outage conventioner/admin '.state = "open" | .posted = null | .message = null' ''
  # The lease went to another machine and came back to this one: a new holding.
  take_lease "$(date -u +%FT%TZ)"
  uptime_answer api 200 '{"status":"ok"}'
  run_bin -0 team-uptime run
  local front admin
  front=$(uptime_state '.checks["conventioner/front-end"].since')
  admin=$(uptime_state '.checks["conventioner/admin"].since')
  assert_equal "$output" "conventioner/front-end: failed: HTTP 502 (3 in a row, since $front)
conventioner/admin: failed: HTTP 500 (3 in a row, since $admin)
conventioner/api: its outage was posted in an earlier holding of the lease; closed without a post
conventioner/front-end: its outage was posted in an earlier holding of the lease; closed without a post
conventioner/admin: its outage was opened in an earlier holding of the lease and never posted; closed
posted to #coordinator (message 1569000000000000002): down: conventioner/front-end, conventioner/admin"
  assert_equal "$(uptime_posts | sed -n '4,$p')" "Production down: conventioner front-end (<$base/front-end>) since $(clock "$front"), 3 checks in a row from home-pc: HTTP 502.
Production down: conventioner admin (<$base/admin>) since $(clock "$admin"), 3 checks in a row from home-pc: HTTP 500."
  assert_equal "$(outage conventioner/api)" null
  assert_equal "$(outage conventioner/front-end '[.since, .message] | @json')" \
    "$(jq -nc --arg since "$front" '[$since, "1569000000000000002"]')"
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 2
}

@test "an uptime.json from before the notice record has its outages moved by the next run, which posts what it would have" {
  # api's down post was refused, front-end's went through, and admin answered again before its
  # back post went through.
  api_check 503 ''
  uptime_check conventioner front-end "$base/front-end" '<div id="app">'
  uptime_answer front-end 502 ''
  uptime_check conventioner admin "$base/admin" 'admin'
  uptime_answer admin 200 'admin'
  local at since posted back
  at=$(ago 3) since=$(ago 60) posted=$(ago 55) back=$(ago 5)
  mkdir -p "$(dirname "$state")"
  jq -n --arg base "$base" --arg checked "$at" --arg since "$since" --arg posted "$posted" --arg back "$back" '
    def check($name; $expect; $failures; $reason; $alert):
      {("conventioner/\($name)"): {project: "conventioner", name: $name, url: "\($base)/\($name)", expect: $expect,
        checked: $checked, ok: ($failures == 0), reason: $reason, failures: $failures,
        since: (if $failures == 0 then null else $since end), alert: $alert}};
    {schema: "team-uptime/1", written: $checked,
     checks: (check("api"; "\"status\":\"ok\""; 2; "HTTP 503"; {since: $since, posted: null, reminded: null, message: null, back: null})
       + check("front-end"; "<div id=\"app\">"; 3; "HTTP 502";
           {since: $since, posted: $posted, reminded: null, message: "1568000000000000001", back: null})
       + check("admin"; "admin"; 0; null; {since: $since, posted: $posted, reminded: null, message: "1568000000000000002", back: $back}))}' \
    >"$state"
  run_bin -0 team-uptime run
  assert_equal "$output" "conventioner/api: failed: HTTP 503 (3 in a row, since $since)
conventioner/front-end: failed: HTTP 502 (4 in a row, since $since)
posted to #coordinator (message 1569000000000000001): down: conventioner/api
posted to #coordinator (message 1569000000000000002): back: conventioner/admin"
  assert_equal "$(uptime_posts)" "Production down: conventioner api (<$base/api>) since $(clock "$since"), 3 checks in a row from home-pc: HTTP 503.
Production back: conventioner admin (<$base/admin>) answers again at $(clock "$back"), down since $(clock "$since") (55 minutes)."
  assert_equal "$(uptime_state '[.checks[] | has("alert")] | any')" false
  assert_equal "$(jq -c '.upgraded | index("uptime") != null' "$notices")" true
  assert_equal "$(outage conventioner/api '[.since, .message] | @json')" "$(jq -nc --arg since "$since" '[$since, "1569000000000000001"]')"
  assert_equal "$(outage conventioner/front-end '[.since, .posted, .message, .back] | @json')" \
    "$(jq -nc --arg since "$since" --arg posted "$posted" '[$since, $posted, "1568000000000000001", null]')"
  assert_equal "$(outage conventioner/admin)" null
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 2
}

@test "an outage of an uptime.json from before the notice record, posted before this holding of the lease, is closed with no back post, and its check still down is posted down afresh" {
  take_lease "$(date -u +%FT%TZ)"
  api_check 503 ''
  local at since posted
  at=$(ago 3) since=$(ago 60) posted=$(ago 55)
  mkdir -p "$(dirname "$state")"
  jq -n --arg url "$base/api" --arg checked "$at" --arg since "$since" --arg posted "$posted" '
    {schema: "team-uptime/1", written: $checked,
     checks: {"conventioner/api": {project: "conventioner", name: "api", url: $url, expect: "\"status\":\"ok\"",
       checked: $checked, ok: false, reason: "HTTP 503", failures: 3, since: $since,
       alert: {since: $since, posted: $posted, reminded: null, message: "1568000000000000001", back: null}}}}' \
    >"$state"
  run_bin -0 team-uptime run
  assert_equal "$output" "conventioner/api: failed: HTTP 503 (4 in a row, since $since)
conventioner/api: its outage was posted in an earlier holding of the lease; closed without a post
posted to #coordinator (message 1569000000000000001): down: conventioner/api"
  assert_equal "$(uptime_posts)" "Production down: conventioner api (<$base/api>) since $(clock "$since"), 4 checks in a row from home-pc: HTTP 503."
  assert_equal "$(uptime_state '.checks["conventioner/api"] | has("alert")')" false
  assert_equal "$(outage conventioner/api '.message')" 1569000000000000001
}

@test "an outage left in uptime.json after its move brings nothing back" {
  api_check 503 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  uptime_answer api 200 '{"status":"ok"}'
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 2
  # A crash between the move's two writes leaves the old field behind.
  edit_state '.checks["conventioner/api"].alert = {since: $at, posted: $at, reminded: null, message: "1569000000000000001", back: null}' "$(ago 30)"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -c '.checks[0] | [.state, .alert]' <<<"$output")" '["up",null]'
  run_bin -0 team-uptime run
  assert_equal "$output" ""
  assert_equal "$(uptime_post_ids | wc -l)" 2
  assert_equal "$(outage conventioner/api)" null
  assert_equal "$(uptime_state '.checks["conventioner/api"] | has("alert")')" false
}

@test "a notice record that cannot be written fails the run, and the outage is judged again at the next run" {
  api_check 503 ''
  run_bin -0 team-uptime run
  exec {lock}>"$HOME/.local/state/agent-team/notices.lock"
  flock -n "$lock"
  TEAM_NOTICES_LOCK_SECONDS=1 run_bin --separate-stderr -1 team-uptime run
  exec {lock}>&-
  assert_equal "$stderr" "team-uptime: cannot write $notices: another writer held $HOME/.local/state/agent-team/notices.lock for 1 s"
  assert_equal "$(uptime_posts)" ""
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 1
  uptime_posts | grep -q '^Production down: conventioner api .* 2 checks in a row from home-pc: HTTP 503\.$'
}

@test "a state file that is not JSON is set aside, and the run starts from an empty state and fails" {
  api_check 503 ''
  mkdir -p "$(dirname "$state")"
  echo 'not json {' >"$state"
  run_bin --separate-stderr -1 team-uptime run
  assert_equal "$stderr" "team-uptime: $state is not a team-uptime/1 state; it is set aside as $state.bad, and this run starts from an empty state"
  assert_equal "$(cat "$state.bad")" 'not json {'
  assert_equal "$(uptime_state '.checks["conventioner/api"].failures')" 1
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 1
}

@test "a notice record that is not team-notices/1 is set aside, the run goes on from an empty record and fails, and status refuses it" {
  api_check 503 ''
  run_bin -0 team-uptime run
  echo '{"schema": "team-notices/2", "notices": {}}' >"$notices"
  run_bin --separate-stderr -1 team-uptime status --json
  assert_equal "$stderr" "team-uptime: $notices is not a team-notices/1 record"
  assert_equal "$(cat "$notices")" '{"schema": "team-notices/2", "notices": {}}'
  run_bin --separate-stderr -1 team-uptime run
  assert_equal "$stderr" "team-uptime: $notices is not a team-notices/1 record; it is set aside as $notices.bad, and the notices start again from empty"
  assert_equal "$(cat "$notices.bad")" '{"schema": "team-notices/2", "notices": {}}'
  assert_equal "$(sed -n 2p <<<"$output")" "posted to #coordinator (message 1569000000000000001): down: conventioner/api"
  assert_equal "$(outage conventioner/api .message)" 1569000000000000001
}

@test "a post is cut to Discord's 2000 characters, and each reason to 200" {
  local long n
  long=$(printf 'x%.0s' $(seq 1 200))
  for n in 1 2 3 4 5 6 7 8; do
    uptime_check conventioner "check-$n" "$base/check-$n" "$long"
    uptime_answer "check-$n" 200 'nothing it expects'
  done
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  local content
  content=$(jq -r .content "$STUB_FIXTURES/inbox/1569000000000000001.json")
  assert_equal "${#content}" 2000
  [[ $content == *... ]]
  assert_equal "$(uptime_state '[.checks[].reason | length] | unique | @json')" '[200]'
  uptime_state '.checks["conventioner/check-1"].reason' | grep -q '^HTTP 200, but its answer lacks `x*\.\.\.$'
}

# A check's state as team-uptime run leaves it, one "<key>": {...} entry of the state's checks:
# check_state <project> <name> <url> <expect> <failures> [<reason> <since>], up when <failures>
# is 0, its checked time $checked, and down (an alert posted at its since) from 2 failures.
check_state() {
  jq -nc --arg project "$1" --arg name "$2" --arg url "$3" --arg expect "$4" --argjson failures "$5" \
    --arg reason "${6:-}" --arg since "${7:-}" --arg checked "$checked" '
    {("\($project)/\($name)"): {project: $project, name: $name, url: $url, expect: $expect,
      checked: $checked, ok: ($failures == 0), reason: (if $failures == 0 then null else $reason end),
      failures: $failures, since: (if $failures == 0 then null else $since end),
      alert: (if $failures < 2 then null
              else {since: $since, posted: $since, reminded: null, message: "1569000000000000001", back: null} end)}}'
}

# Write the state file from check_state's entries, written at $checked: put_state <entry>...
put_state() {
  mkdir -p "$(dirname "$state")"
  printf '%s\n' "$@" | jq -s --arg written "$checked" '{schema: "team-uptime/1", written: $written, checks: (add // {})}' >"$state"
}

@test "status --json gives a check per registry entry in registry order, up, failing, down or not checked, holder or not" {
  # agent-team's checks are written first, but conventioner comes first in the registry.
  uptime_check agent-team site "$base/site" 'agent-team'
  uptime_answer site 200 'agent-team'
  api_check 503 'Service Unavailable'
  uptime_check conventioner front-end "$base/front-end" '<div id="app">'
  uptime_answer front-end 200 '<div id="app"></div>'
  run_bin -0 team-uptime run
  uptime_answer site 502 ''
  run_bin -0 team-uptime run
  uptime_check agent-team docs "$base/docs" 'docs'
  local calls
  calls=$(stub_calls curl | wc -l)
  rm "$HOME/.local/state/agent-team/lease.json"
  run_bin -0 team-uptime status --json
  local status=$output
  assert_equal "$(jq -c keys_unsorted <<<"$status")" '["schema","written","line","checks"]'
  assert_equal "$(jq -c '[.schema, .written]' <<<"$status")" "$(uptime_state '["team-uptime/1", .written] | @json')"
  assert_equal "$(jq -c '[.checks[] | "\(.project)/\(.name) \(.state)"]' <<<"$status")" \
    '["conventioner/api down","conventioner/front-end up","agent-team/site failing","agent-team/docs unchecked"]'
  assert_equal "$(jq -c '.checks[0] | keys_unsorted' <<<"$status")" \
    '["project","name","url","expect","state","checked","since","failures","reason","alert"]'
  assert_equal "$(jq -c '.checks[0] | del(.state)' <<<"$status")" \
    "$(uptime_state '.checks["conventioner/api"] | {project, name, url, expect, checked, since, failures, reason} | @json' |
      jq -c --argjson alert "$(outage conventioner/api)" '. + {alert: $alert}')"
  assert_equal "$(jq -c '.checks[2] | [.failures, .reason, .alert]' <<<"$status")" '[1,"HTTP 502",null]'
  assert_equal "$(jq -c '.checks[3] | [.url, .checked, .since, .failures, .reason, .alert]' <<<"$status")" \
    "$(jq -nc --arg url "$base/docs" '[$url, null, null, 0, null, null]')"
  # Read-only: no fetch, no Discord call, the state as it was.
  assert_equal "$(stub_calls curl | wc -l)" "$calls"
  assert_equal "$(uptime_post_ids | wc -l)" 1
}

@test "status before any run shows an outage of an uptime.json from before the notice record, and writes nothing" {
  checked=$(ago 3)
  local down before
  down=$(ago 40)
  uptime_check conventioner api "$base/api" '"status":"ok"'
  put_state "$(check_state conventioner api "$base/api" '"status":"ok"' 3 'HTTP 503' "$down")"
  before=$(cat "$state")
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -c '.checks[0] | [.state, .alert]' <<<"$output")" \
    "$(jq -nc --arg down "$down" '["down", {since: $down, posted: $down, reminded: null, message: "1569000000000000001", back: null}]')"
  assert_equal "$(cat "$state")" "$before"
  [[ ! -e $notices ]]
}

@test "status counts a state written for another URL or expect as not checked yet" {
  checked=$(ago 3)
  uptime_check conventioner api "$base/api" '"status":"ok"'
  uptime_check conventioner front-end "$base/front-end" '<div id="app">'
  put_state "$(check_state conventioner api "$base/old-api" '"status":"ok"' 0)" \
    "$(check_state conventioner front-end "$base/front-end" '<div>' 3 'HTTP 502' "$(ago 30)")"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -c '[.checks[] | [.state, .checked, .failures, .alert]]' <<<"$output")" \
    '[["unchecked",null,0,null],["unchecked",null,0,null]]'
  assert_equal "$(jq -r .line <<<"$output")" \
    "Production: conventioner api not checked yet; conventioner front-end not checked yet, last checked $(clock "$checked")"
  assert_equal "$(stub_calls curl)" ""
}

@test "the status line says all up, a check down since, failed once or not checked yet, and how many more are up" {
  checked=$(ago 3)
  local down
  down=$(ago 40)
  uptime_check conventioner api "$base/api" '"status":"ok"'
  uptime_check conventioner front-end "$base/front-end" '<div id="app">'
  local api front
  api=$(check_state conventioner api "$base/api" '"status":"ok"' 0)
  front=$(check_state conventioner front-end "$base/front-end" '<div id="app">' 0)
  put_state "$api" "$front"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -r .line <<<"$output")" "Production: all 2 checks up, last checked $(clock "$checked")"

  put_state "$(check_state conventioner api "$base/api" '"status":"ok"' 3 'HTTP 503' "$down")" "$front"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -r .line <<<"$output")" "Production: conventioner api down since $(clock "$down"): HTTP 503; 1 more up, last checked $(clock "$checked")"

  put_state "$(check_state conventioner api "$base/api" '"status":"ok"' 1 'no answer in 10 s' "$checked")" "$front"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -r .line <<<"$output")" "Production: conventioner api failed once: no answer in 10 s; 1 more up, last checked $(clock "$checked")"

  put_state "$api"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -r .line <<<"$output")" "Production: conventioner front-end not checked yet; 1 more up, last checked $(clock "$checked")"

  rm "$state"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -r .line <<<"$output")" "Production: conventioner api not checked yet; conventioner front-end not checked yet"

  # A mix, in registry order: down, failed once and not checked yet, then the two up.
  uptime_check agent-team site "$base/site" 'agent-team'
  uptime_check agent-team docs "$base/docs" 'docs'
  uptime_check agent-team status "$base/status" 'ok'
  put_state "$(check_state conventioner api "$base/api" '"status":"ok"' 2 'HTTP 500' "$down")" "$front" \
    "$(check_state agent-team site "$base/site" 'agent-team' 1 'HTTP 200, but its answer lacks `agent-team`' "$checked")" \
    "$(check_state agent-team status "$base/status" 'ok' 0)"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -r .line <<<"$output")" "Production: conventioner api down since $(clock "$down"): HTTP 500; agent-team site failed once: HTTP 200, but its answer lacks \`agent-team\`; agent-team docs not checked yet; 2 more up, last checked $(clock "$checked")"

  # One check alone up is one check.
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  uptime_check conventioner api "$base/api" '"status":"ok"'
  put_state "$api"
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -r .line <<<"$output")" "Production: all 1 check up, last checked $(clock "$checked")"
}

@test "the status line is cut at 200 characters" {
  checked=$(ago 3)
  local n entries=()
  for n in 1 2 3 4; do
    uptime_check conventioner "check-$n" "$base/check-$n" ok
    entries+=("$(check_state conventioner "check-$n" "$base/check-$n" ok 1 'Could not resolve host: api.conventioner.io' "$checked")")
  done
  put_state "${entries[@]}"
  local line
  run_bin -0 team-uptime status --json
  line=$(jq -r .line <<<"$output")
  assert_equal "${#line}" 200
  [[ $line == "Production: conventioner check-1 failed once: Could not resolve host: api.conventioner.io; conventioner check-2 failed once: "*... ]] ||
    { echo "line: $line" >&2; return 1; }
}

@test "status with no checks gives a null line and no checks, and its text form prints nothing" {
  run_bin -0 team-uptime status --json
  assert_equal "$(jq -c . <<<"$output")" '{"schema":"team-uptime/1","written":null,"line":null,"checks":[]}'
  run_bin -0 team-uptime status
  assert_equal "$output" ""
  assert_equal "$(stub_calls curl)" ""
  [[ ! -e $state ]]
}

@test "status prints a line per check: its state, since when and why, when it was checked and its URL" {
  checked=$(ago 3)
  local down
  down=$(ago 40)
  uptime_check conventioner api "$base/api" '"status":"ok"'
  uptime_check conventioner front-end "$base/front-end" '<div id="app">'
  uptime_check agent-team site "$base/site" 'agent-team'
  uptime_check agent-team docs "$base/docs" 'docs'
  put_state "$(check_state conventioner api "$base/api" '"status":"ok"' 2 'HTTP 503' "$down")" \
    "$(check_state conventioner front-end "$base/front-end" '<div id="app">' 0)" \
    "$(check_state agent-team site "$base/site" 'agent-team' 1 'no answer in 10 s' "$checked")"
  run_bin -0 team-uptime status
  assert_equal "$output" "conventioner/api down since $(clock "$down"): HTTP 503, checked $(clock "$checked") ($base/api)
conventioner/front-end up, checked $(clock "$checked") ($base/front-end)
agent-team/site failing since $(clock "$checked"): no answer in 10 s, checked $(clock "$checked") ($base/site)
agent-team/docs not checked yet ($base/docs)"
  assert_equal "$(stub_calls curl)" ""
}

@test "status refuses a state file that is not a team-uptime/1 state, and leaves it as it is" {
  uptime_check conventioner api "$base/api" '"status":"ok"'
  mkdir -p "$(dirname "$state")"
  local bad
  for bad in 'not json {' '{"schema": "team-uptime/2", "checks": {}}' '{"schema": "team-uptime/1", "checks": []}'; do
    printf '%s\n' "$bad" >"$state"
    run_bin --separate-stderr -1 team-uptime status --json
    assert_equal "$output" ""
    assert_equal "$stderr" "team-uptime: $state is not a team-uptime/1 state"
    run_bin --separate-stderr -1 team-uptime status
    assert_equal "$stderr" "team-uptime: $state is not a team-uptime/1 state"
    assert_equal "$(cat "$state")" "$bad"
  done
  [[ ! -e $state.bad ]]
}

@test "team-uptime takes run and status [--json], and refuses anything else" {
  run_bin -0 team-uptime --help
  assert_contains "$output" "Usage: team-uptime run | status [--json]"
  local args
  for args in '' check 'run --json' 'status --text' 'status --json --json' 'status json'; do
    # shellcheck disable=SC2086 # each case's words are its arguments
    run_bin --separate-stderr -2 team-uptime $args
    assert_equal "$stderr" "team-uptime: usage: team-uptime run | status [--json]"
  done
}
