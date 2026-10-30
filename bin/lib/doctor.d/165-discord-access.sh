# discord access
#               Fails unless #coordinator's group in the Discord plugin's access.json lets in only
#               Daniel's id (the top-level allowFrom's): with an empty group allowFrom the plugin
#               delivers any server member's message there or in a task thread to the coordinator.
#               Reads that file's allowFrom lists alone, and prints no member's id.
# shellcheck shell=bash

access=$HOME/.claude/channels/discord/access.json
group_fix="Daniel runs /discord:access group add $COORDINATOR_CHANNEL --no-mention --allow <their id> in their own Claude Code session"
# The plugin's reading: a missing allowFrom or groups is an empty one. Prints one word, with the
# number of ids beside Daniel's for "other": nobody, nogroup, empty, other <n> <whether Daniel's is
# among them>, or only.
verdict=''
if [[ -s $access ]]; then
  verdict=$(jq -r --arg channel "$COORDINATOR_CHANNEL" '
    (.allowFrom // [] | map(tostring)) as $daniel
    | (.groups // {})[$channel] as $group
    | ($group.allowFrom // [] | map(tostring)) as $allowed
    | if ($daniel | length) == 0 then "nobody"
      elif $group == null then "nogroup"
      elif ($allowed | length) == 0 then "empty"
      elif ($allowed - $daniel | length) > 0
      then "other \($allowed - $daniel | length) \(any($allowed[]; IN($daniel[])))"
      else "only" end' "$access" 2>/dev/null) || verdict=''
fi
case $verdict in
  only)
    report "discord access" PASS "#coordinator's group allowFrom names only Daniel's id, so only their messages there and in task threads reach the coordinator"
    ;;
  other\ *)
    read -r _ others daniel_too <<<"$verdict"
    ids="$others other id"
    ((others == 1)) || ids+=s
    if [[ $daniel_too == true ]]; then ids="Daniel's id and $ids"; else ids+=" and not Daniel's"; fi
    report "discord access" FAIL "#coordinator's group allowFrom names $ids, so another member's messages there and in task threads reach the coordinator" "$group_fix"
    ;;
  empty)
    report "discord access" FAIL "#coordinator's group allowFrom is empty, so any server member's message there or in a task thread reaches the coordinator" "$group_fix"
    ;;
  nogroup)
    report "discord access" FAIL "access.json has no group for #coordinator, so the plugin delivers nothing from it or its threads" "$group_fix"
    ;;
  nobody)
    report "discord access" FAIL "access.json's top-level allowFrom is empty, so no id is known as Daniel's" \
      "Daniel runs /discord:access allow <their id>, then /discord:access group add $COORDINATOR_CHANNEL --no-mention --allow <their id>, in their own Claude Code session"
    ;;
  *)
    if [[ ! -e $access ]]; then
      report "discord access" FAIL "$(tilde "$access") is missing, so the plugin delivers nothing from #coordinator" "the secret discord-access-json line's fix"
    elif [[ ! -s $access ]]; then
      report "discord access" FAIL "$(tilde "$access") is empty, so the plugin delivers nothing from #coordinator" "the secret discord-access-json line's fix"
    elif ! jq -e . "$access" >/dev/null 2>&1; then
      report "discord access" FAIL "$(tilde "$access") is not JSON, so the plugin moves it aside and delivers nothing from #coordinator" \
        "Daniel moves it aside and runs team-secrets restore in their own terminal"
    else
      report "discord access" FAIL "$(tilde "$access") is not the plugin's access file (an object whose allowFrom lists are arrays), so the line cannot tell who #coordinator lets in" \
        "Daniel moves it aside and runs team-secrets restore in their own terminal"
    fi
    ;;
esac
