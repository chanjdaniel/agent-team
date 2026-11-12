#!/usr/bin/env bats
# team-review-check: the coordinator's post of agent-review as the reviewer App's check run, on a
# head whose review the ledger holds, with a one-repository, checks-only token minted from the
# App's key and revoked after, the JWT and the token given to curl on stdin alone. The App is on
# only in a copy of bin/ that holds a bin/lib/review-app, and its key is made at run time, never
# committed, since gitleaks reads every commit.

load helpers/common

HEAD_SHA=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
URL=https://github.com/owner/agent-team/pull/5

setup_file() {
  openssl genrsa -out "$BATS_FILE_TMPDIR/key.pem" 2048 2>/dev/null
  openssl rsa -in "$BATS_FILE_TMPDIR/key.pem" -pubout -out "$BATS_FILE_TMPDIR/public.pem" 2>/dev/null
}

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[agent-team]
repo = "Owner/agent-team"
path = "projects/agent-team"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[agent-team.pool]
provider = "git"
slots = ["slots/agent-team/1"]
TOML
  # The App is on: a copy of bin/ with the App's id and slug, run in place of this checkout's.
  export CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm -f "$CODE_CHECKOUT/bin/lib/review-app"
  printf 'id=123456\nslug=team-reviewer\n' >"$CODE_CHECKOUT/bin/lib/review-app"
  KEY=$HOME/.config/agent-team/review-app.pem
  mkdir -p "$HOME/.config/agent-team"
  cp "$BATS_FILE_TMPDIR/key.pem" "$KEY"
  chmod 600 "$KEY"
  export HEAD_SHA
  # T9's PR, its head reviewed and passed.
  ledger_line '{"task":"T9","event":"opened","project":"agent-team"}'
  ledger_line "{\"task\":\"T9\",\"event\":\"pr\",\"url\":\"$URL\",\"project\":\"agent-team\",\"head\":\"$HEAD_SHA\"}"
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$HEAD_SHA\",\"ts\":\"2026-11-12T09:00:00Z\"}"
  stub_reply gh "$HEAD_SHA"
  # curl answers as GitHub would, each call by its method and path: its stdin (the config), its
  # environment and its body file are kept per call, numbered by its line in curl.log. A fixture
  # curl.<call> (installation, mint, check-run or revoke) holds "<http code> <body>" to answer
  # instead, or "exit <n>" for a call curl cannot make.
  stub_script curl <<'SH'
method=GET url='' out='' body=''
n=$(wc -l <"$STUB_CALLS/curl.log")
printf '%s\n' "${1-}" >"$STUB_CALLS/curl.first.$n"
# With TOKEN_WATCH set, every file under it that holds the minted token, at each call.
if [[ -n ${TOKEN_WATCH:-} ]]; then grep -rlF -- "$(<"$STUB_FIXTURES/token")" "$TOKEN_WATCH" >>"$STUB_CALLS/curl.disk" || true; fi
while (($#)); do
  case $1 in
    --request) method=$2; shift ;;
    --output) out=$2; shift ;;
    --data-binary) body=${2#@}; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
config=''
IFS= read -r -d '' config || true
printf '%s' "$config" >"$STUB_CALLS/curl.config.$n"
env >"$STUB_CALLS/curl.env.$n"
if [[ -n $body ]]; then cp "$body" "$STUB_CALLS/curl.body.$n"; fi
path=${url#https://api.github.com/}
printf '%s %s\n' "$method" "$path" >>"$STUB_CALLS/curl.calls"
case "$method $path" in
  "GET repos/Owner/agent-team/installation") call=installation answer='200 {"id": 777}' ;;
  "POST app/installations/777/access_tokens") call=mint answer="201 {\"token\": \"$(<"$STUB_FIXTURES/token")\", \"expires_at\": \"2026-11-12T13:00:00Z\"}" ;;
  "POST repos/Owner/agent-team/check-runs")
    call=check-run answer='201 {"id": 4242, "name": "agent-review"}'
    # With CHECK_RUN_HOLD set, the post says it started and waits for the test's go, up to 10 s.
    if [[ -n ${CHECK_RUN_HOLD:-} ]]; then
      : >"$CHECK_RUN_HOLD.started"
      for _ in $(seq 100); do [[ ! -e $CHECK_RUN_HOLD.go ]] || break; sleep 0.1; done
    fi
    ;;
  "DELETE installation/token") call=revoke answer='204 ' ;;
  *) echo "curl stub: no answer for $method $url" >&2; exit 99 ;;
esac
if [[ -f $STUB_FIXTURES/curl.$call ]]; then answer=$(<"$STUB_FIXTURES/curl.$call"); fi
if [[ $answer == exit\ * ]]; then
  echo "curl: (7) Failed to connect to api.github.com port 443: Connection refused" >&2
  exit "${answer#exit }"
fi
if [[ -n $out && $out != - ]]; then
  printf '%s' "${answer#* }" >"$out"
  printf '%s' "${answer%% *}"
else
  # The body to stdout, then the HTTP code on a line of its own, as --write-out '\n%{http_code}'.
  printf '%s\n%s' "${answer#* }" "${answer%% *}"
fi
SH
  # The installation token GitHub mints, made at run time.
  TOKEN=fake-installation-token-$RANDOM$RANDOM
  printf '%s' "$TOKEN" >"$STUB_FIXTURES/token"
}

ledger_line() {
  printf '%s\n' "$1" >>"$TEAM_HOME/ledger.jsonl"
}

# The bearer curl was given on call <n>, from its config on stdin.
bearer() {
  sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p' "$STUB_CALLS/curl.config.$1"
}

# A base64url text decoded to stdout.
unbase64url() {
  local text=${1//-/+}
  text=${text//_//}
  while ((${#text} % 4)); do text+='='; done
  printf '%s' "$text" | openssl base64 -d -A
}

curl_calls() {
  cat "$STUB_CALLS/curl.calls" 2>/dev/null || true
}

@test "posts agent-review as the App's check run on the reviewed head, with a token for one repository, then revokes it" {
  run_bin --separate-stderr -0 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" 4242
  assert_equal "$stderr" ""
  # The installation read, the mint, the check run and the revoke, in order.
  assert_equal "$(curl_calls)" "GET repos/Owner/agent-team/installation
POST app/installations/777/access_tokens
POST repos/Owner/agent-team/check-runs
DELETE installation/token"
  # The mint names the one repository and checks: write, nothing more.
  assert_equal "$(jq -c . "$STUB_CALLS/curl.body.2")" '{"repositories":["agent-team"],"permissions":{"checks":"write"}}'
  # The check run: agent-review on the exact head, completed, with the conclusion and the summary.
  assert_equal "$(jq -c 'del(.completed_at)' "$STUB_CALLS/curl.body.3")" "$(jq -cn --arg head "$HEAD_SHA" '{name: "agent-review",
    head_sha: $head, status: "completed", conclusion: "success",
    output: {title: "no blocking findings", summary: "no blocking findings"}}')"
  [[ $(jq -r .completed_at "$STUB_CALLS/curl.body.3") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  # The installation read and the mint carry the App's JWT, the check run and the revoke the token.
  local jwt
  jwt=$(bearer 1)
  assert_equal "$(bearer 2)" "$jwt"
  assert_equal "$(bearer 3)" "$TOKEN"
  assert_equal "$(bearer 4)" "$TOKEN"
  # Neither is in any argument of any call, nor in curl's environment.
  run ! grep -qF -e "$jwt" -e "$TOKEN" "$STUB_CALLS/curl.log" "$STUB_CALLS/gh.log" "$STUB_CALLS"/curl.env.*
}

@test "the JWT is RS256, signed by the App's key, issued by the App 60 seconds back and expiring 9 minutes on" {
  local before after jwt header payload
  before=$(date +%s)
  run_bin -0 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  after=$(date +%s)
  jwt=$(bearer 1)
  IFS=. read -r header payload signature <<<"$jwt"
  assert_equal "$(unbase64url "$header" | jq -c .)" '{"alg":"RS256","typ":"JWT"}'
  assert_equal "$(unbase64url "$payload" | jq -r .iss)" 123456
  local iat exp
  iat=$(unbase64url "$payload" | jq .iat) exp=$(unbase64url "$payload" | jq .exp)
  ((iat >= before - 60 && iat <= after - 60 && exp == iat + 600))
  unbase64url "$signature" >"$BATS_TEST_TMPDIR/signature"
  printf '%s.%s' "$header" "$payload" |
    openssl dgst -sha256 -verify "$BATS_FILE_TMPDIR/public.pem" -signature "$BATS_TEST_TMPDIR/signature"
}

@test "failure posts the check run with conclusion failure on a head whose latest review found something" {
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$HEAD_SHA\"}"
  run_bin -0 team-review-check "$URL" "$HEAD_SHA" failure "2 blocking"
  assert_equal "$(jq -r .conclusion "$STUB_CALLS/curl.body.3")" failure
  assert_equal "$(jq -r .output.summary "$STUB_CALLS/curl.body.3")" "2 blocking"
}

@test "a head team-catch-up made stands on the review of the head it was made from" {
  local merge=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  ledger_line "{\"task\":\"T9\",\"event\":\"caught-up\",\"url\":\"$URL\",\"from\":\"$HEAD_SHA\",\"head\":\"$merge\",\"base\":\"cccccccccccccccccccccccccccccccccccccccc\"}"
  stub_reply gh "$merge"
  run_bin -0 team-review-check "$URL" "$merge" success "clean merge of dev onto a1b2c3d, reviewed"
  assert_equal "$(jq -r .head_sha "$STUB_CALLS/curl.body.3")" "$merge"
}

@test "a worker session is refused before anything is read" {
  worker_refused team-review-check "posts no agent-review check" "$URL" "$HEAD_SHA" success "no blocking findings"
}

@test "a malformed command line is refused, exit 2, before any call" {
  local -a cases=(
    "$URL $HEAD_SHA success"
    "$URL ${HEAD_SHA:0:7} success x"
    "$URL $HEAD_SHA pass x"
    "$URL $HEAD_SHA success "
  )
  local line
  for line in "${cases[@]}"; do
    read -r -a args <<<"$line"
    [[ $line != *' ' ]] || args+=('')
    run_bin -2 team-review-check "${args[@]}"
  done
  run_bin -2 team-review-check "$URL" "$HEAD_SHA" success $'two\nlines'
  assert_equal "$output" "team-review-check: the summary is one non-empty line"
  run_bin -2 team-review-check "$URL" "$HEAD_SHA" success "$(printf 'x%.0s' {1..141})"
  assert_equal "$output" "team-review-check: the summary is at most 140 characters, got 141"
  run_bin -2 team-review-check https://example.com/owner/agent-team/pull/5 "$HEAD_SHA" success x
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "with no bin/lib/review-app the App is off, and nothing is posted" {
  rm "$CODE_CHECKOUT/bin/lib/review-app"
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: the reviewer App is off: no bin/lib/review-app names it, so there is no App to post agent-review as"
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a bin/lib/review-app of any other form is refused, naming the file" {
  local -a bodies=('id=123456' 'id=0\nslug=team-reviewer' 'id=12x\nslug=team-reviewer' 'slug=team-reviewer\nid=123456'
    'id=123456\nslug=team-reviewer\nid=7' 'id=123456\nslug=Team Reviewer' '# the App\nid=123456\nslug=team-reviewer')
  local body
  for body in "${bodies[@]}"; do
    printf '%b\n' "$body" >"$CODE_CHECKOUT/bin/lib/review-app"
    run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
    assert_equal "$output" "team-review-check: $CODE_CHECKOUT/bin/lib/review-app is not one id=<n> line and one slug=<s> line"
  done
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a missing key, or one not mode 600, is refused before any call" {
  chmod 644 "$KEY"
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: the reviewer App's key ~/.config/agent-team/review-app.pem is mode 644, not 600: Daniel restores it with team-secrets restore"
  rm "$KEY"
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: the reviewer App's key ~/.config/agent-team/review-app.pem is missing: Daniel restores it with team-secrets restore"
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a sha that is not the PR's head is refused, and nothing is minted" {
  stub_reply gh dddddddddddddddddddddddddddddddddddddddd
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: $URL moved past $HEAD_SHA: its head is now dddddddddddddddddddddddddddddddddddddddd; nothing posted"
  assert_equal "$(stub_calls curl)" ""
}

@test "a verdict the ledger's latest review of the head does not hold is refused, and nothing is read from GitHub" {
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" failure "2 blocking"
  assert_equal "$output" "team-review-check: T9's latest review of a1b2c3d, at 2026-11-12T09:00:00Z, is pass, so agent-review on it is success, not failure; nothing posted"
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$HEAD_SHA\",\"ts\":\"2026-11-12T10:00:00Z\"}"
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: T9's latest review of a1b2c3d, at 2026-11-12T10:00:00Z, is findings, so agent-review on it is failure, not success; nothing posted"
  # A head no review names, and no catch-up made, has none.
  local other=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  run_bin -1 team-review-check "$URL" "$other" success "no blocking findings"
  assert_equal "$output" "team-review-check: T9 logged no review of eeeeeee, so no reviewer's verdict is there to post; nothing posted"
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a PR no task's pr event names is refused" {
  run_bin -1 team-review-check https://github.com/owner/agent-team/pull/6 "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: no task's pr event names https://github.com/owner/agent-team/pull/6, so no review of it is logged; nothing posted"
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a failed installation read or mint posts nothing and has no token to revoke" {
  echo '404 {"message": "Not Found"}' >"$STUB_FIXTURES/curl.installation"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: reading the App's installation on Owner/agent-team failed: GitHub answered HTTP 404: Not Found; nothing posted"
  assert_equal "$(curl_calls)" "GET repos/Owner/agent-team/installation"
  rm "$STUB_FIXTURES/curl.installation" "$STUB_CALLS/curl.calls"
  echo 'exit 7' >"$STUB_FIXTURES/curl.mint"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: minting the App's token for Owner/agent-team failed: curl: (7) Failed to connect to api.github.com port 443: Connection refused; nothing posted"
  assert_equal "$(curl_calls)" "GET repos/Owner/agent-team/installation
POST app/installations/777/access_tokens"
}

@test "a failed check run still revokes the token, and says the post failed" {
  echo '422 {"message": "No commit found for SHA"}' >"$STUB_FIXTURES/curl.check-run"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" ""
  assert_equal "$stderr" "team-review-check: posting the agent-review check run on Owner/agent-team@$HEAD_SHA failed: GitHub answered HTTP 422: No commit found for SHA; nothing posted"
  assert_equal "$(curl_calls | tail -n 1)" "DELETE installation/token"
  assert_equal "$(bearer 4)" "$TOKEN"
  rm "$STUB_FIXTURES/curl.check-run" "$STUB_CALLS/curl.calls"
  echo 'exit 28' >"$STUB_FIXTURES/curl.check-run"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: posting the agent-review check run on Owner/agent-team@$HEAD_SHA failed: curl: (7) Failed to connect to api.github.com port 443: Connection refused; whether GitHub took it is unknown: read the head's agent-review check runs before posting again"
  assert_equal "$(curl_calls | tail -n 1)" "DELETE installation/token"
}

@test "a failed revoke after the post prints the check run and says the token was not revoked" {
  echo '500 {"message": "Server Error"}' >"$STUB_FIXTURES/curl.revoke"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" 4242
  assert_equal "$stderr" "team-review-check: revoking the App's token failed: GitHub answered HTTP 500: Server Error; it expires on its own within the hour"
}

@test "a token GitHub answers in any other form is refused, and nothing is posted or sent with it" {
  printf '%s' 'bad token' >"$STUB_FIXTURES/token"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: minting the App's token for Owner/agent-team failed: GitHub's answer holds no token of the expected form; nothing posted"
  assert_equal "$(curl_calls | tail -n 1)" "POST app/installations/777/access_tokens"
}

@test "the minted token is written to no file while the script runs" {
  export TOKEN_WATCH=$BATS_TEST_TMPDIR/tmp
  mkdir "$TOKEN_WATCH"
  TMPDIR=$TOKEN_WATCH run_bin -0 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$(curl_calls | wc -l)" 4
  assert_equal "$(cat "$STUB_CALLS/curl.disk" 2>/dev/null)" ""
}

@test "curl reads no user config: -q is its first argument on every call" {
  run_bin -0 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$(cat "$STUB_CALLS"/curl.first.* | sort -u)" "-q"
}

@test "a review logged on a short head does not stand for a full sha that shares its prefix" {
  local ground=a1b2c3d999999999999999999999999999999999
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"a1b2c3d\",\"ts\":\"2026-11-12T10:00:00Z\"}"
  stub_reply gh "$ground"
  run_bin -1 team-review-check "$URL" "$ground" success "no blocking findings"
  assert_equal "$output" "team-review-check: T9's review of a1b2c3d, at 2026-11-12T10:00:00Z, names its head by a prefix, not in full, so it stands for no full sha; nothing posted"
  assert_equal "$(stub_calls curl)" ""
}

@test "a TERM while the check run is posted still revokes the token" {
  export CHECK_RUN_HOLD=$BATS_TEST_TMPDIR/hold
  "$CODE_CHECKOUT/bin/team-review-check" "$URL" "$HEAD_SHA" success "no blocking findings" \
    >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err" 3>&- &
  local pid=$!
  for _ in $(seq 100); do [[ ! -e $CHECK_RUN_HOLD.started ]] || break; sleep 0.1; done
  [[ -e $CHECK_RUN_HOLD.started ]]
  kill -TERM "$pid"
  : >"$CHECK_RUN_HOLD.go"
  wait "$pid" || true
  assert_equal "$(curl_calls | tail -n 1)" "DELETE installation/token"
  assert_equal "$(bearer "$(($(curl_calls | wc -l) - 1))")" "$TOKEN"
}

@test "GitHub's message is read from a pretty-printed answer, as its REST API answers" {
  printf '404 {\n  "message": "Not Found"\n}\n' >"$STUB_FIXTURES/curl.installation"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: reading the App's installation on Owner/agent-team failed: GitHub answered HTTP 404: Not Found; nothing posted"
  rm "$STUB_FIXTURES/curl.installation"
  printf '500 {\n  "message": "Server Error"\n}\n' >"$STUB_FIXTURES/curl.revoke"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" 4242
  assert_equal "$stderr" "team-review-check: revoking the App's token failed: GitHub answered HTTP 500: Server Error; it expires on its own within the hour"
}
