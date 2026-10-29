# slots         `team-slots status --stored --json`, which takes no reading: the cap and where it
#               came from, the effective cap, the slots held, those kept for the reserved
#               project and the latest reading ("cap 10 (slots.json), effective 10, 7 held, 1
#               kept for agent-team; other programs use 9.8 GiB of 30.6 GiB and 1.1 of 12 cores
#               (13:10)"), noting each project whose pool is smaller than the cap lets it take
#               (the cap less the slots kept, or the whole cap for the reserved project). Warns,
#               the facts after the problems, on no ~/.config/agent-team/slots.json or no cap in
#               it, a slots.json team-slots refuses, more held than the effective cap, and no
#               reading in the last 15 minutes while this machine holds the lease (on the lease
#               line's answer, so never on a machine whose heartbeat should not run).
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's; os, holding and heartbeat, from the os, lease and heartbeat checks

# The slots line, for the registered projects <projects> (one per line).
slots_line() {
  local project status line file=$HOME/.config/agent-team/slots.json state=missing pools='{}' rc=0
  while IFS= read -r project; do
    [[ -n $project ]] || continue
    pools=$(team_project "$project" | jq -c --argjson pools "$pools" --arg project "$project" \
      '$pools + {($project): (.pool.slots | length)}')
  done <<<"$1"
  status=$(TEAM_HOME=$TEAM_HOME "$bin/team-slots" status --stored --json 2>"$err" </dev/null) || rc=$?
  if ((rc)); then
    if grep -qF "$file" "$err"; then
      report slots WARN "$(first_error | sed "s#$HOME/#~/#g")" "correct it as team-slots --help describes"
    else
      report slots WARN "team-slots failed: $(first_error)" "fix what team-slots names, then run team-doctor again"
    fi
    return
  fi
  if [[ -e $file ]]; then
    state='set'
    [[ $(jq -s 'add | length' "$file") != 0 ]] || state=empty
  fi
  line=$(jq -c -L "$TEAM_LIB" --argjson pools "$pools" --arg file "$state" --arg holding "$holding" \
    --arg heartbeat "$heartbeat" 'include "slots"; doctor_line($pools; $file; $holding; $heartbeat)' <<<"$status")
  report slots "$(jq -r .verdict <<<"$line")" "$(jq -r .reason <<<"$line")" "$(jq -r .fix <<<"$line")"
}

# On a supported OS, once the registry is read (the projects line reports a registry it refuses).
if [[ -n $os ]] && projects=$(team_project --list 2>/dev/null); then
  slots_line "$projects"
fi
