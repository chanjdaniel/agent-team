# discord       Fails while `claude plugin list` (run from /, so user settings decide) shows the
#               Discord plugin enabled: every session that loads it logs in to Discord, so only
#               the coordinator turns it on.
# shellcheck shell=bash

# The plugins as claude sees them outside any project.
rc=0
plugins=$(cd / && bounded 30 claude plugin list --json 2>/dev/null </dev/null) || rc=$?
discord=$(jq -r 'map(select(.id == "discord@claude-plugins-official" and .scope == "user"))
  | if length == 0 then "absent" else (.[0].enabled | tostring) end' <<<"$plugins" 2>/dev/null) || discord=''
case $discord in
  false) report discord PASS "the Discord plugin is off in user settings" ;;
  absent) report discord PASS "the Discord plugin is not installed, so it is off (the plugins line says whether it should be)" ;;
  true) report discord FAIL "the Discord plugin is on in user settings, so every session logs in to Discord" \
    "claude plugin disable discord@claude-plugins-official --scope user" ;;
  *) report discord FAIL "\`claude plugin list\` printed no plugin list (exit $rc)" "install Claude Code and sign in (the tool claude and claude login lines)" ;;
esac
