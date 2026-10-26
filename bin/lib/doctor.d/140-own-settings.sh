# own settings  `team-config own`: warns while a setting each machine keeps for itself
#               (autoMode.environment, what auto mode's classifier knows of this machine) is not
#               set here.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's

# The ones team-config keeps per machine.
rc=0
own=$(TEAM_HOME=$TEAM_HOME bounded 30 "$bin/team-config" own --json 2>"$err" </dev/null) || rc=$?
if ((rc)) || ! jq -e 'type == "array"' <<<"$own" >/dev/null 2>&1; then
  report "own settings" WARN "$(first_error)" "fix what team-config names, then run team-doctor again"
else
  unset_settings=$(jq -r '[.[] | select(.set | not) | .setting] | join(", ")' <<<"$own")
  if [[ -z $unset_settings ]]; then
    report "own settings" PASS "$(jq -r '[.[].setting] | join(", ")' <<<"$own") set for this machine"
  else
    report "own settings" WARN "$unset_settings not set here, so auto mode's classifier knows nothing of this machine" \
      "write this machine's own in ~/.claude/settings.json (\`claude auto-mode defaults\` shows the form); team-config keeps it"
  fi
fi
