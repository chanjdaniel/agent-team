# lease         `team-lease status`: passes held here, warns held elsewhere or released, fails
#               when GitHub is unreachable or team-lease refuses, and fails on a fenced
#               machine ("fenced since <time> (holder seen <name>, epoch <n>)"), reachable or not.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's
# shellcheck disable=SC2034 # holding, for the heartbeat check

# team-lease needs the machine's name, whose own line says how to write it.
rc=0
if [[ -z $machine ]]; then
  rc=no-name
elif fenced=$(fence_reason); then
  rc=fenced
else
  lease=$(TEAM_HOME=$TEAM_HOME "$bin/team-lease" status --json 2>"$err" </dev/null) || rc=$?
fi
case $rc in
  no-name) report lease FAIL "this machine has no team name to read the lease with" "the machine line's fix, then run team-doctor again" ;;
  fenced)
    holding=no
    report lease FAIL "$fenced" "hand off on the machine that holds the lease, then team-resume here (its take clears the fence)"
    ;;
  0)
    read -r state holder epoch age mine < <(jq -r '[.state, .holder // "-", .epoch, .age_minutes // "-", .mine]
      | map(tostring) | join(" ")' <<<"$lease")
    holding=no
    if [[ $state == held && $mine == true ]]; then
      holding=yes
      report lease PASS "held here, epoch $epoch"
    elif [[ $state == held ]]; then
      report lease WARN "held by $holder, epoch $epoch, renewed $age minutes ago" "hand off on $holder, then team-resume here"
    else
      report lease WARN "released, epoch $epoch" "team-lease take, with Daniel's yes"
    fi
    ;;
  75) report lease FAIL "GitHub unreachable, so the lease is unconfirmed" "check the network, then run team-doctor again" ;;
  *) report lease FAIL "$(first_error)" "fix what team-lease names, then run team-doctor again" ;;
esac
