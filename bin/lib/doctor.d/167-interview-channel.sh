# interview channel
#               Fails unless the interview channel (INTERVIEW_CHANNEL in bin/lib/team.sh) is set,
#               has no group in the Discord plugin's access.json (so the plugin delivers none of
#               its threads' messages to the coordinator), is a text channel, and lets the bot see
#               it, read its history, open public threads and post in them: the bot's roles and
#               the channel's overwrites, read with the bot token through the Discord API. Warns
#               when Discord does not answer.
# shellcheck shell=bash

access=$HOME/.claude/channels/discord/access.json
# The permissions team-thread and team-post use there, as Discord numbers their bits.
declare -A interview_bits=([View Channel]=10 [Read Message History]=16 [Create Public Threads]=35 [Send Messages in Threads]=38)
interview_names=("View Channel" "Read Message History" "Create Public Threads" "Send Messages in Threads")
interview_err=$(mktemp)
# GET <path> through the Discord API into $interview_reply, or report the line and fail.
interview_get() {
  if interview_reply=$(discord_api "$1" --max-time 20 2>"$interview_err") && jq -e 'type == "object" or type == "array"' <<<"$interview_reply" >/dev/null 2>&1; then
    return 0
  fi
  local why
  why=$(grep -m1 . "$interview_err" || echo "no JSON in its answer")
  if [[ $why == *"(22)"* ]]; then
    report "interview channel" FAIL "Discord refused the bot's read of $1 ($why), so the bot cannot reach the interview channel $INTERVIEW_CHANNEL" \
      "Daniel gives the bot's role $(printf '%s, ' "${interview_names[@]}" | sed 's/, $//') in the interview channel's permissions"
  else
    report "interview channel" WARN "Discord did not answer ($why), so the bot's access to the interview channel is unchecked" \
      "check the network, then run team-doctor again"
  fi
  return 1
}

interview_check() {
  local channel guild bot member base=0 kind a d admin=$((1 << 3)) name missing=()
  if [[ -z $INTERVIEW_CHANNEL ]]; then
    report "interview channel" FAIL "no interview channel is set, so no planner can interview Daniel" \
      "Daniel makes a text channel for interviews, with no access.json group, and a PR sets its id as INTERVIEW_CHANNEL in bin/lib/team.sh"
    return 0
  fi
  if jq -e --arg c "$INTERVIEW_CHANNEL" '(.groups // {}) | has($c)' "$access" >/dev/null 2>&1; then
    report "interview channel" FAIL "access.json has a group for the interview channel $INTERVIEW_CHANNEL, so the plugin delivers every interview to the coordinator" \
      "Daniel runs /discord:access group rm $INTERVIEW_CHANNEL in their own Claude Code session"
    return 0
  fi
  if ! discord_token >/dev/null; then
    report "interview channel" FAIL "no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, so the bot's access to the interview channel cannot be checked" \
      "the secret discord-bot-env line's fix"
    return 0
  fi
  interview_get "channels/$INTERVIEW_CHANNEL" || return 0
  channel=$interview_reply
  if ! jq -e '.type == 0' <<<"$channel" >/dev/null; then
    report "interview channel" FAIL "$INTERVIEW_CHANNEL is not a text channel (type $(jq -r '.type // "none"' <<<"$channel")), so no thread opens under it" \
      "Daniel makes a text channel for interviews, with no access.json group, and a PR sets its id as INTERVIEW_CHANNEL in bin/lib/team.sh"
    return 0
  fi
  guild=$(jq -r '.guild_id | strings | select(test("^[0-9]+$"))' <<<"$channel")
  interview_get "users/@me" || return 0
  bot=$(jq -r '.id | strings | select(test("^[0-9]+$"))' <<<"$interview_reply")
  if [[ -z $guild || -z $bot ]]; then
    report "interview channel" WARN "Discord named no server for the channel or no id for the bot, so the bot's access to the interview channel is unchecked" \
      "run team-doctor again"
    return 0
  fi
  interview_get "guilds/$guild/members/$bot" || return 0
  member=$interview_reply
  interview_get "guilds/$guild/roles" || return 0
  # Discord's order: @everyone's role (the guild's id) and the bot's roles together; then the
  # channel's overwrites for @everyone, for the bot's roles together, and for the bot itself, each
  # denying, then allowing; Administrator allows everything.
  local -A allows=() denies=()
  while read -r kind a d; do
    # Bash arithmetic would run an expression, so only digits reach it.
    [[ $a =~ ^[0-9]{1,18}$ && $d =~ ^[0-9]{1,18}$ ]] || continue
    if [[ $kind == role ]]; then
      base=$((base | a))
    else
      allows[$kind]=$((${allows[$kind]:-0} | a)) denies[$kind]=$((${denies[$kind]:-0} | d))
    fi
  done < <(jq -rn --argjson channel "$channel" --argjson member "$member" --argjson roles "$interview_reply" \
    --arg guild "$guild" --arg bot "$bot" '
    ([$guild] + $member.roles) as $mine
    | ($roles[] | select(.id | IN($mine[])) | "role \(.permissions) 0"),
      ($channel.permission_overwrites // [] | .[]
        | if .id == $guild then "everyone \(.allow) \(.deny)"
          elif .type == 0 and (.id | IN($member.roles[])) then "roles \(.allow) \(.deny)"
          elif .type == 1 and .id == $bot then "bot \(.allow) \(.deny)"
          else empty end)')
  if ! ((base & admin)); then
    for kind in everyone roles bot; do
      base=$(((base & ~${denies[$kind]:-0}) | ${allows[$kind]:-0}))
    done
  fi
  for name in "${interview_names[@]}"; do
    ((base & admin || base & (1 << ${interview_bits[$name]}))) || missing+=("$name")
  done
  if ((${#missing[@]})); then
    report "interview channel" FAIL "the bot lacks $(printf '%s, ' "${missing[@]}" | sed 's/, $//') in the interview channel $INTERVIEW_CHANNEL" \
      "Daniel gives the bot's role $(printf '%s, ' "${missing[@]}" | sed 's/, $//') in the interview channel's permissions"
  else
    report "interview channel" PASS "$INTERVIEW_CHANNEL has no access.json group, so the coordinator never hears an interview, and the bot may read it, open threads and post in them"
  fi
}

interview_check
rm -f "$interview_err"
