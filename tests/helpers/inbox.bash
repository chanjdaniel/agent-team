# A fake Discord for team-inbox, for the tests of every script that runs it: `load helpers/inbox`,
# then call inbox_discord after the test's own curl stub, if it has one.
#
# inbox_discord writes $STUB_FIXTURES/inbox.sh, which answers team-inbox's calls and exits, and
# returns at once for any other call. A curl stub of the test's own sources it first, with the line
#   [[ ! -f $STUB_FIXTURES/inbox.sh ]] || source "$STUB_FIXTURES/inbox.sh"
# and without one, inbox_discord installs a curl stub that fails every other call as curl -f does
# on a 404. The fake answers:
#   GET   channels/<c>                         {id: <c>, guild_id: <INBOX_GUILD>}
#   POST  channels/<c>/messages, flags 4       keeps the body as $STUB_FIXTURES/inbox/<id>.json,
#                                              the ids 1569000000000000001 and on; answers {id}
#   PATCH channels/<c>/messages/<m>            replaces <m>'s body, or fails 404 when it is gone
# Each call is a line "<method> <path under /api/v10/>" in $STUB_FIXTURES/inbox/calls. With
# $STUB_FIXTURES/inbox/fail holding "<status> [<retry-after>]", every one of them fails so, its
# status in the header dump after -D as curl writes it.
# shellcheck shell=bash

INBOX_GUILD=1560000000000000000

inbox_discord() {
  mkdir -p "$STUB_FIXTURES/inbox"
  cat >"$STUB_FIXTURES/inbox.sh" <<'EOF'
inbox_dir=$STUB_FIXTURES/inbox inbox_method=GET inbox_body='' inbox_headers=/dev/null inbox_args=("$@")
for ((inbox_i = 0; inbox_i < ${#inbox_args[@]} - 1; inbox_i++)); do
  case ${inbox_args[inbox_i]} in
    -X) inbox_method=${inbox_args[inbox_i + 1]} ;;
    --data-binary) inbox_body=${inbox_args[inbox_i + 1]#@} ;;
    -D) inbox_headers=${inbox_args[inbox_i + 1]} ;;
  esac
done
if [[ ${*: -1} =~ ^https://discord\.com/api/v10/(channels/([0-9]+)(/messages(/([0-9]+))?)?)$ ]] &&
  { [[ $inbox_method == GET && -z ${BASH_REMATCH[3]} ]] ||
    [[ $inbox_method == PATCH && -n ${BASH_REMATCH[5]} ]] ||
    { [[ $inbox_method == POST && -n ${BASH_REMATCH[3]} && -z ${BASH_REMATCH[5]} ]] && [[ -f $inbox_body ]] && jq -e '.flags == 4' "$inbox_body" >/dev/null 2>&1; }; }; then
  inbox_path=${BASH_REMATCH[1]} inbox_channel=${BASH_REMATCH[2]} inbox_message=${BASH_REMATCH[5]}
  echo "$inbox_method $inbox_path" >>"$inbox_dir/calls"
  inbox_status=''
  if [[ -s $inbox_dir/fail ]]; then
    read -r inbox_status inbox_retry <"$inbox_dir/fail"
  elif [[ $inbox_method == PATCH && ! -f $inbox_dir/$inbox_message.json ]]; then
    inbox_status=404 inbox_retry=''
  fi
  if [[ -n $inbox_status ]]; then
    { echo "HTTP/1.1 $inbox_status Failed"; [[ -z $inbox_retry ]] || echo "Retry-After: $inbox_retry"; } >"$inbox_headers"
    echo "curl: (22) The requested URL returned error: $inbox_status" >&2
    exit 22
  fi
  echo "HTTP/1.1 200 OK" >"$inbox_headers"
  case $inbox_method in
    GET) jq -n --arg c "$inbox_channel" '{id: $c, guild_id: "1560000000000000000", type: 0}' ;;
    PATCH) cp "$inbox_body" "$inbox_dir/$inbox_message.json" && jq -n --arg m "$inbox_message" '{id: $m}' ;;
    POST)
      inbox_n=$(($(cat "$inbox_dir/count" 2>/dev/null || echo 0) + 1))
      echo "$inbox_n" >"$inbox_dir/count"
      inbox_message=$((1569000000000000000 + inbox_n))
      cp "$inbox_body" "$inbox_dir/$inbox_message.json"
      jq -n --arg m "$inbox_message" '{id: $m}'
      ;;
  esac
  exit 0
fi
EOF
  [[ -f $STUB_FIXTURES/curl.sh || -f $STUB_FIXTURES/curl.out || -f $STUB_FIXTURES/curl.status ]] ||
    stub_script curl <<'EOF'
source "$STUB_FIXTURES/inbox.sh"
echo "curl: (22) The requested URL returned error: 404" >&2
exit 22
EOF
}

# The Waiting on you message as the fake Discord now holds it: the message kept in inbox.json.
inbox_shown() {
  local message
  message=$(jq -r .message "$HOME/.local/state/agent-team/inbox.json")
  jq -r .content "$STUB_FIXTURES/inbox/$message.json"
}

# The message's lines between its title and its time, the items and section headings.
inbox_items_shown() {
  inbox_shown | sed '1d;$d'
}

# team-inbox's calls to the fake Discord, one "<method> <path>" per line.
inbox_calls() {
  cat "$STUB_FIXTURES/inbox/calls" 2>/dev/null || true
}

# A Waiting on you message kept from an earlier run, 1569000000000000000 in #coordinator, so a run
# only edits it.
inbox_kept() {
  mkdir -p "$HOME/.local/state/agent-team"
  jq -n --arg guild "$INBOX_GUILD" '{channel: "1562486564871995482", guild: $guild, message: "1569000000000000000"}' \
    >"$HOME/.local/state/agent-team/inbox.json"
  echo '{"content": ""}' >"$STUB_FIXTURES/inbox/1569000000000000000.json"
}
