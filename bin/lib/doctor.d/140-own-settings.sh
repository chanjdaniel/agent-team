# own settings  `team-config own`: warns while a setting each machine keeps for itself
#               (autoMode.environment, what auto mode's classifier knows of this machine) is not
#               set here.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's

# The ones team-config keeps per machine.
rc=0
own=$(TEAM_HOME=$TEAM_HOME bounded 30 "$bin/team-config" own --json 2>"$err" </dev/null) || rc=$?
# Whether it is an array, the settings not set here and every setting, in one jq run.
own_ok='' unset_settings='' own_settings=''
((rc)) || json_vars own_ok='type == "array"' unset_settings='[.[] | select(.set | not) | .setting] | join(", ")' \
  own_settings='[.[].setting] | join(", ")' <<<"$own" 2>/dev/null || own_ok=''
if [[ $own_ok != true ]]; then
  report "own settings" WARN "$(first_error)" "fix what team-config names, then run team-doctor again"
else
  if [[ -z $unset_settings ]]; then
    report "own settings" PASS "$own_settings set for this machine"
  else
    report "own settings" WARN "$unset_settings not set here, so auto mode's classifier knows nothing of this machine" \
      "write this machine's own in ~/.claude/settings.json (\`claude auto-mode defaults\` shows the form); team-config keeps it"
  fi
fi
