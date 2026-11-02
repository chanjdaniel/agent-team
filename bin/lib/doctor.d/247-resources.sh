# resources     `team-capacity check --json`: whether this machine can hold the team's work in its
#               slice at its level, the level's words first ("manual, minor (30%): 9.2 GiB and 3.6
#               cores for the team; 6.1 GiB reserved"). On Linux it fails when systemctl --user
#               does not answer or the user manager's cgroup does not delegate the cpu and memory
#               controllers, since the level's limits need the slice; it warns when
#               agent-team.slice is not installed, a gate daemon unit lacks its drop-in, a running
#               gate daemon is outside the slice, a live team session runs outside its task's
#               slice, or the limits applied are not the recorded level's or the slice's CPU quota
#               not theirs, each naming its fix (team-capacity install, Daniel's yes,
#               team-capacity place, or team-level apply); else passes, naming the live team
#               sessions in it. On macOS passes with "no hard limits on macOS: admission and stow
#               only". On any OS, fails on a malformed capacity.json or level.jsonl line, naming
#               it, and warns while this machine holds the lease (on the lease line's answer) and
#               has no reading of the machine's load of the last 15 minutes, which its
#               heartbeat's capacity step takes.
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
