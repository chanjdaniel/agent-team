# resources     `team-capacity check --json`: whether this machine can hold the team's work in its
#               slice. On Linux it warns, never fails, since no limit needs the slice yet: when
#               systemctl --user does not answer or the user manager's cgroup does not delegate the
#               cpu and memory controllers, agent-team.slice is not installed, a gate daemon unit
#               lacks its drop-in, a running gate daemon is outside the slice, or a live team
#               session runs outside its task's slice, each naming its fix (team-capacity install,
#               Daniel's yes, or team-capacity place); else passes, naming the live team sessions
#               in it. On macOS passes with "no hard limits on macOS: admission and stow only". On
#               any OS, warns while this machine holds the lease (on the lease line's answer) and
#               has no reading of the machine's load of the last 15 minutes, which its heartbeat's
#               capacity step takes.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's; os, holding and heartbeat, from the os, lease and heartbeat checks

# On a supported OS.
if [[ -n $os ]]; then
  rc=0 resources_args=(--json --heartbeat "${heartbeat:-enabled}")
  [[ ${holding:-} != yes ]] || resources_args+=(--holding)
  resources=$(TEAM_HOME=$TEAM_HOME "$bin/team-capacity" check "${resources_args[@]}" 2>"$err" </dev/null) || rc=$?
  if ((rc)); then
    report resources FAIL "team-capacity failed: $(first_error)" "fix what team-capacity names, then run team-doctor again"
  else
    report resources "$(jq -r .verdict <<<"$resources")" "$(jq -r .reason <<<"$resources")" "$(jq -r .fix <<<"$resources")"
  fi
fi
