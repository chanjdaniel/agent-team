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
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.project, .name, .url, .expect, .ok, .failures, .since, .reason, .alert] | @json')" \
    "$(jq -nc --arg url "$base/api" '["conventioner", "api", $url, "\"status\":\"ok\"", true, 0, null, null, null]')"
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
  assert_equal "$(uptime_state '.checks["conventioner/api"].alert | [.since, .message, .reminded, .back] | @json')" \
    "$(jq -nc --arg since "$since" '[$since, "1569000000000000001", null, null]')"
  uptime_state '.checks["conventioner/api"].alert.posted | fromdateiso8601 > now - 60' | grep -qx true
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
  edit_state '.checks["conventioner/api"] |= (.since = $at | .alert.since = $at)' "$since"
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
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.ok, .failures, .since, .alert] | @json')" '[true,0,null,null]'
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
  # Everything but the lease record and the uptime state is gone, as after a reboot.
  find "$HOME/.local/state/agent-team" -mindepth 1 ! -name lease.json ! -name uptime.json -delete
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
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.failures, .since, .alert] | @json')" \
    "$(jq -nc --arg since "$since" '[1, $since, null]')"
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
  edit_state '.checks["conventioner/api"] |= (.since = $at | .alert.since = $at | .alert.posted = $at)' "$old"
  run_bin -0 team-uptime run
  assert_equal "$(sed -n 2p <<<"$output")" "posted to #coordinator (message 1569000000000000002): still down: conventioner/api"
  assert_equal "$(uptime_posts | sed -n 2p)" "Production still down: conventioner api (<$base/api>) since $(clock "$old"), 4 hours: HTTP 503."
  uptime_state '.checks["conventioner/api"].alert.reminded | fromdateiso8601 > now - 60' | grep -qx true
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 2
  # Reminded 45 minutes ago: due at 30 minutes, not at the default 240.
  old=$(ago 45)
  edit_state '.checks["conventioner/api"].alert.reminded = $at' "$old"
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
  assert_equal "$(uptime_state '.checks["conventioner/api"].alert | [.since != null, .posted, .message] | @json')" '[true,null,null]'
  rm "$STUB_FIXTURES/inbox/fail"
  run_bin -0 team-uptime run
  assert_equal "$(sed -n 2p <<<"$output")" "posted to #coordinator (message 1569000000000000001): down: conventioner/api"
  uptime_posts | grep -q '^Production down: conventioner api .* 3 checks in a row from home-pc: HTTP 503\.$'
  assert_equal "$(uptime_state '.checks["conventioner/api"].alert.message')" 1569000000000000001
}

@test "a back post Discord refused is made at the next run" {
  api_check 503 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  uptime_answer api 200 '{"status":"ok"}'
  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin --separate-stderr -1 team-uptime run
  local back
  back=$(uptime_state '.checks["conventioner/api"].alert.back')
  [[ $back != null ]]
  rm "$STUB_FIXTURES/inbox/fail"
  run_bin -0 team-uptime run
  assert_equal "$output" "posted to #coordinator (message 1569000000000000002): back: conventioner/api"
  uptime_posts | sed -n 2p | grep -qF "answers again at $(clock "$back"),"
  assert_equal "$(uptime_state '.checks["conventioner/api"].alert')" null
}

@test "a check that fails again before its back post went through stays the same outage and posts no new down" {
  api_check 503 ''
  run_bin -0 team-uptime run
  run_bin -0 team-uptime run
  local alert
  alert=$(uptime_state '.checks["conventioner/api"].alert | {since, posted, message} | @json')
  uptime_answer api 200 '{"status":"ok"}'
  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin -1 team-uptime run
  rm "$STUB_FIXTURES/inbox/fail"
  uptime_answer api 503 ''
  run_bin -0 team-uptime run
  assert_equal "$(uptime_post_ids | wc -l)" 1
  assert_equal "$(uptime_state '.checks["conventioner/api"].alert | {since, posted, message} | @json')" "$alert"
  assert_equal "$(uptime_state '.checks["conventioner/api"].alert.back')" null
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
  assert_equal "$(uptime_state '.checks["conventioner/api"].alert')" null
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
  assert_equal "$(uptime_state '.checks["conventioner/api"] | [.url, .ok, .failures, .alert] | @json')" \
    "$(jq -nc --arg url "$base/api-v2" '[$url, true, 0, null]')"
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

@test "team-uptime takes run, and refuses anything else" {
  run_bin -0 team-uptime --help
  assert_contains "$output" "team-uptime run"
  run_bin --separate-stderr -2 team-uptime
  run_bin --separate-stderr -2 team-uptime check
  assert_contains "$stderr" "usage: team-uptime run"
}
