# Production checks for the tests of team-uptime and the heartbeat's uptime step: `load
# helpers/inbox` and `load helpers/uptime`, then in setup, after the sandbox:
#   inbox_discord alerts            the fake Discord (tests/helpers/inbox.bash)
#   uptime_curl                     curl as the fake Discord, else the machine's own curl
#   base=$(uptime_server)           the stub production, http://127.0.0.1:<port>
#   uptime_check conventioner api "$base/api" '"status":"ok"'
#   uptime_answer api 200 '{"status":"ok"}'
# and kill the servers in teardown with uptime_teardown (or a teardown that kills every pid in
# $BATS_TEST_TMPDIR/http.pids, as tests/team-timers.bats' does).
#
# uptime_server            starts tests/helpers/http-check.py on a free port of 127.0.0.1, serving
#                          $UPTIME_DIR ($BATS_TEST_TMPDIR/uptime), its pid a line of
#                          $BATS_TEST_TMPDIR/http.pids, and prints its base URL
# uptime_answer <name> <status> <body>
#                          GET /<name> answers <status> with <body>, from the next request on
# uptime_hang <name>       GET /<name> answers only after 60 s
# uptime_requests          each request the stub served, one JSON line {path, method, headers}
# uptime_check <project> <name> <url> <expect>
#                          appends an [[<project>.uptime]] table to the sandbox's registry
# uptime_curl [answers]    installs a curl stub that answers the fake Discord's calls
#                          ($STUB_FIXTURES/inbox.sh), refuses any other call to discord.com (with
#                          answers, answers it with a message id, as tests/team-timers.bats'
#                          discord_answers does), and runs the machine's own curl for the rest, its
#                          argv still logged as every stub's (stub_calls curl)
# uptime_posts             the content of each post that reached the fake Discord, in order (a
#                          post of several checks is a line each)
# uptime_bodies            each post's whole body, one compact JSON line per post, in order
# uptime_holder [<machine>]
#                          names this machine <machine> (default home-pc) and writes the lease
#                          record team-lease leaves on its holder, with no origin
# uptime_state <filter>    jq <filter> on the state file, ~/.local/state/agent-team/uptime.json
# shellcheck shell=bash

UPTIME_DIR=$BATS_TEST_TMPDIR/uptime

uptime_server() {
  local port=$BATS_TEST_TMPDIR/uptime.port
  mkdir -p "$UPTIME_DIR"
  rm -f "$port"
  python3 -I "$REPO_ROOT/tests/helpers/http-check.py" "$UPTIME_DIR" "$port" </dev/null >/dev/null 2>"$port.err" 3>&- &
  echo $! >>"$BATS_TEST_TMPDIR/http.pids"
  for _ in $(seq 1 200); do
    [[ ! -s $port ]] || break
    sleep 0.05
  done
  if [[ ! -s $port ]]; then
    echo "uptime_server: the server wrote no port in 10 s: $(cat "$port.err")" >&2
    return 1
  fi
  echo "http://127.0.0.1:$(cat "$port")"
}

uptime_answer() {
  mkdir -p "$UPTIME_DIR"
  jq -n --argjson status "$2" --arg body "$3" '{status: $status, body: $body, hang: false}' >"$UPTIME_DIR/$1.json"
}

uptime_hang() {
  mkdir -p "$UPTIME_DIR"
  jq -n '{status: 200, body: "", hang: true}' >"$UPTIME_DIR/$1.json"
}

uptime_requests() {
  cat "$UPTIME_DIR/requests.jsonl" 2>/dev/null || true
}

uptime_check() {
  printf '\n[[%s.uptime]]\nname = %s\nurl = %s\nexpect = %s\n' "$1" \
    "$(jq -n --arg v "$2" '$v')" "$(jq -n --arg v "$3" '$v')" "$(jq -n --arg v "$4" '$v')" >>"$TEAM_HOME/projects.toml"
}

uptime_teardown() {
  [[ ! -f $BATS_TEST_TMPDIR/http.pids ]] || xargs kill <"$BATS_TEST_TMPDIR/http.pids" 2>/dev/null || true
}

uptime_curl() {
  local real
  real=$(PATH=${PATH//"$BATS_TEST_TMPDIR/stubs:"/} command -v curl)
  {
    echo '[[ ! -f $STUB_FIXTURES/inbox.sh ]] || source "$STUB_FIXTURES/inbox.sh"'
    echo 'if [[ ${*: -1} == https://discord.com/* ]]; then'
    if [[ ${1:-} == answers ]]; then
      echo "  echo '{\"id\":\"1563000000000000001\"}'"
      echo '  exit 0'
    else
      echo '  echo "curl: (22) The requested URL returned error: 404" >&2'
      echo '  exit 22'
    fi
    echo 'fi'
    printf 'exec %q "$@"\n' "$real"
  } | stub_script curl
}

# The posts' ids, in order: the fake Discord numbers them from 1569000000000000001.
uptime_post_ids() {
  local n count
  count=$(cat "$STUB_FIXTURES/inbox/count" 2>/dev/null || echo 0)
  for ((n = 1; n <= count; n++)); do echo $((1569000000000000000 + n)); done
}

uptime_posts() {
  local id
  for id in $(uptime_post_ids); do
    jq -r .content "$STUB_FIXTURES/inbox/$id.json"
  done
}

uptime_bodies() {
  local id
  for id in $(uptime_post_ids); do jq -c . "$STUB_FIXTURES/inbox/$id.json"; done
}

uptime_holder() {
  local machine=${1:-home-pc}
  mkdir -p "$HOME/.config/agent-team" "$HOME/.local/state/agent-team"
  echo "$machine" >"$HOME/.config/agent-team/machine"
  jq -n --arg machine "$machine" '{holder: $machine, state: "held", epoch: 1, renewed_at: (now | floor | todate)}' \
    >"$HOME/.local/state/agent-team/lease.json"
}

uptime_state() {
  jq -r "$1" "$HOME/.local/state/agent-team/uptime.json"
}
