# A fake Discord for team-inbox, and for the heartbeat's alerts too, for the tests of every script
# that runs them: `load helpers/inbox`, then call inbox_discord (inbox_discord alerts for the
# heartbeat's suites) after the test's own curl stub, if it has one.
#
# inbox_discord writes $STUB_FIXTURES/inbox.sh, which answers team-inbox's calls and exits, and
# returns at once for any other call. A curl stub of the test's own sources it first, with the line
#   [[ ! -f $STUB_FIXTURES/inbox.sh ]] || source "$STUB_FIXTURES/inbox.sh"
# and without one, inbox_discord installs a curl stub that fails every other call as curl -f does
# on a 404. The fake answers:
#   GET   channels/<c>                         {id: <c>, guild_id: <INBOX_GUILD>}
#   POST  channels/<c>/messages, flags 4       keeps the body as $STUB_FIXTURES/inbox/<id>.json,
#                                              the ids 1569000000000000001 and on; answers {id}
#   POST  channels/<c>/messages, an alert      with alerts given: the same, its id also a line of
#         (allowed_mentions, no flags 4)       $STUB_FIXTURES/inbox/alerts (without, other
#                                              scripts' posts that name allowed_mentions too
#                                              reach the test's own stub)
#   PATCH channels/<c>/messages/<m>            replaces <m>'s body, or fails 404 when it is gone
# A body is read from --data-binary @<file> (team-inbox's) or -d <json> (the heartbeat's).
# Each call is a line "<method> <path under /api/v10/>" in $STUB_FIXTURES/inbox/calls. With
# $STUB_FIXTURES/inbox/fail holding "<status> [<retry-after>]", every one of them fails so, its
# status in the header dump after -D as curl writes it; with $STUB_FIXTURES/inbox/fail-post holding
# "<k> <status> [<retry-after>]", the k-th post (a POST, counted from 1) and every later one fail
# so, and every other call goes through.
# shellcheck shell=bash

INBOX_GUILD=1560000000000000000

inbox_discord() {
  mkdir -p "$STUB_FIXTURES/inbox"
  printf 'inbox_alerts=%s\n' "$([[ ${1:-} == alerts ]] && echo 1 || echo 0)" >"$STUB_FIXTURES/inbox.sh"
  cat >>"$STUB_FIXTURES/inbox.sh" <<'EOF'
inbox_dir=$STUB_FIXTURES/inbox inbox_method=GET inbox_body='' inbox_headers=/dev/null inbox_args=("$@")
for ((inbox_i = 0; inbox_i < ${#inbox_args[@]} - 1; inbox_i++)); do
  case ${inbox_args[inbox_i]} in
    -X) inbox_method=${inbox_args[inbox_i + 1]} ;;
    --data-binary) inbox_body=${inbox_args[inbox_i + 1]#@} ;;
    -d)
      inbox_body=$inbox_dir/body.$$
      printf '%s\n' "${inbox_args[inbox_i + 1]}" >"$inbox_body"
      ;;
    -D) inbox_headers=${inbox_args[inbox_i + 1]} ;;
  esac
done
if [[ ${*: -1} =~ ^https://discord\.com/api/v10/(channels/([0-9]+)(/messages(/([0-9]+))?)?)$ ]] &&
  { [[ $inbox_method == GET && -z ${BASH_REMATCH[3]} ]] ||
    [[ $inbox_method == PATCH && -n ${BASH_REMATCH[5]} ]] ||
    { [[ $inbox_method == POST && -n ${BASH_REMATCH[3]} && -z ${BASH_REMATCH[5]} ]] && [[ -f $inbox_body ]] && jq -e --argjson alerts "$inbox_alerts" '.flags == 4 or ($alerts == 1 and has("allowed_mentions"))' "$inbox_body" >/dev/null 2>&1; }; }; then
  inbox_path=${BASH_REMATCH[1]} inbox_channel=${BASH_REMATCH[2]} inbox_message=${BASH_REMATCH[5]}
  echo "$inbox_method $inbox_path" >>"$inbox_dir/calls"
  inbox_status=''
  if [[ -s $inbox_dir/fail ]]; then
    read -r inbox_status inbox_retry <"$inbox_dir/fail"
  elif [[ $inbox_method == POST && -s $inbox_dir/fail-post ]] && read -r inbox_from inbox_fail <"$inbox_dir/fail-post" &&
    (($(cat "$inbox_dir/posts" 2>/dev/null || echo 0) + 1 >= inbox_from)); then
    read -r inbox_status inbox_retry <<<"$inbox_fail"
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
      echo $(($(cat "$inbox_dir/posts" 2>/dev/null || echo 0) + 1)) >"$inbox_dir/posts"
      inbox_n=$(($(cat "$inbox_dir/count" 2>/dev/null || echo 0) + 1))
      echo "$inbox_n" >"$inbox_dir/count"
      inbox_message=$((1569000000000000000 + inbox_n))
      cp "$inbox_body" "$inbox_dir/$inbox_message.json"
      ! jq -e 'has("allowed_mentions") and .flags != 4' "$inbox_body" >/dev/null || echo "$inbox_message" >>"$inbox_dir/alerts"
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

# The waiting list as team-inbox last wrote it, the team home's waiting.md.
waiting_shown() {
  cat "$TEAM_HOME/waiting.md"
}

# The list's lines but its title: the items and section headings and the standing word lines.
waiting_items_shown() {
  waiting_shown | sed '1d'
}

# The latest post of team-inbox --post, its messages' contents joined by newlines, as the fake
# Discord holds the messages waiting.json's posted names.
posted_shown() {
  local id
  jq -r '.posted.messages[]?' "$TEAM_HOME/waiting.json" | while read -r id; do
    jq -r .content "$STUB_FIXTURES/inbox/$id.json"
  done
}

# The latest post's resources line, none when it has none.
inbox_resources_shown() {
  posted_shown | sed -n '/^Resources: /p'
}

# The latest post's health line, none when it has none.
inbox_health_shown() {
  posted_shown | sed -nE '/^(-# Health|\*\*Health\*\*): /p'
}

# team-inbox's calls to the fake Discord, one "<method> <path>" per line.
inbox_calls() {
  cat "$STUB_FIXTURES/inbox/calls" 2>/dev/null || true
}

# The old Waiting on you message, kept in inbox.json by a team-inbox from before waiting.md:
# 1569000000000000000 in #coordinator, which the next run retires with one edit.
inbox_kept() {
  mkdir -p "$HOME/.local/state/agent-team"
  jq -n --arg guild "$INBOX_GUILD" '{channel: "1562486564871995482", guild: $guild, message: "1569000000000000000"}' \
    >"$HOME/.local/state/agent-team/inbox.json"
  echo '{"content": ""}' >"$STUB_FIXTURES/inbox/1569000000000000000.json"
}

# The heartbeat's alerts in #coordinator, in the order they were posted, each as the fake Discord
# now holds it ({id, content, allowed_mentions}), one JSON object per line.
alerts_shown() {
  local id
  [[ -f $STUB_FIXTURES/inbox/alerts ]] || return 0
  while read -r id; do
    jq -c --arg id "$id" '{id: $id} + .' "$STUB_FIXTURES/inbox/$id.json"
  done <"$STUB_FIXTURES/inbox/alerts"
}

# #coordinator's guild kept in inbox.json, as team-inbox keeps it, so a run calls Discord for
# nothing.
inbox_guild_kept() {
  mkdir -p "$HOME/.local/state/agent-team"
  jq -n --arg guild "$INBOX_GUILD" '{channel: "1562486564871995482", guild: $guild}' \
    >"$HOME/.local/state/agent-team/inbox.json"
}

# Make the team home's waiting.md a directory, so team-inbox cannot write the list.
waiting_unwritable() {
  rm -f "$TEAM_HOME/waiting.md"
  mkdir "$TEAM_HOME/waiting.md"
}
