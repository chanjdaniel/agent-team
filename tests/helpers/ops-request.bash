# Daniel's message asking for an ops launch, for the tests of every script that launches one
# (team-worker and team-load-check's ops form): `load helpers/ops-request` after helpers/common.
#
# ops_request [--author <id>] [--ago <seconds>] <channel> prints the link to a new message in
# <channel>, by <id> (757, Daniel, by default), sent <seconds> ago (60 by default), whose id holds
# that time as Discord's ids do. Its first call puts Daniel (757) in the plugin's allowFrom, when
# no access.json is there, and installs a curl stub, when the test has none, that answers GET
# channels/<c>/messages/<m> with the message made, and fails any other call as curl -f does on a
# 404. Each message is $BATS_TEST_TMPDIR/ops-request/<c>-<m>.json, so a test may remove or rewrite one.
# shellcheck shell=bash

# The Discord channel #coordinator, as the library names it.
# shellcheck disable=SC2034 # read by the tests that load this helper
OPS_COORDINATOR=1562486564871995482

ops_request() {
  local author=757 ago=60 dir=$BATS_TEST_TMPDIR/ops-request n ms id
  while [[ $1 == --* ]]; do
    case $1 in
      --author) author=$2 ;;
      --ago) ago=$2 ;;
    esac
    shift 2
  done
  mkdir -p "$dir"
  [[ -f $HOME/.claude/channels/discord/access.json ]] ||
    echo '{"dmPolicy": "allowlist", "allowFrom": ["757"], "groups": {}, "pending": {}}' \
      >"$HOME/.claude/channels/discord/access.json"
  [[ -f $STUB_FIXTURES/curl.sh ]] || cat >"$STUB_FIXTURES/curl.sh" <<'EOF'
url=${*: -1} dir=$BATS_TEST_TMPDIR/ops-request
if [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)/messages/([0-9]+)$ &&
  -f $dir/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json ]]; then
  cat "$dir/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
EOF
  # A Discord id holds the milliseconds since 2015-01-01 above its low 22 bits; the low bits keep
  # each message of the test its own id.
  n=$(($(cat "$dir/count" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$dir/count"
  ms=$(($(date +%s%3N) - ago * 1000))
  id=$((((ms - 1420070400000) << 22) | n))
  jq -n --arg c "$1" --arg id "$id" --arg a "$author" \
    '{id: $id, channel_id: $c, content: "Please count the stalls.", author: {id: $a, username: "daniel"}}' >"$dir/$1-$id.json"
  echo "https://discord.com/channels/1560000000000000000/$1/$id"
}
