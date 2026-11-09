# health        `team-timers health --json`, the heartbeat's health view: on the lease holder,
#               passes with the plain healthy line ("ok - last checkpoint <time> (2 minutes ago),
#               lease renewed <time> (2 minutes ago)"), fails on a heartbeat or checkpoint problem
#               (the heartbeat last ran long ago, a checkpoint failing or none good for 15
#               minutes), naming every problem, with the failures log and team-checkpoint --force
#               in its fix, and warns on any other problem (an unknown health, GitHub unreachable or
#               refusing the login, a ledger line no reader can parse, a step failing); passes on a
#               machine that does not hold the lease, saying it keeps no health, and fails when
#               team-timers prints no view.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's; machine and holding, from the machine and lease checks
# reads state from: 070-machine.sh 220-lease.sh

# Only the holder keeps health; the view reads the lease record too, so a holder the lease line
# could not confirm is asked.
if [[ ${holding:-} == no ]]; then
  report health PASS "this machine does not hold the lease, so it keeps no health"
elif [[ -z ${machine:-} ]]; then
  report health WARN "whether this machine keeps health waits on the machine line" "the machine line's fix, then run team-doctor again"
else
  # team-timers health exits 1 with problems, and prints the view either way.
  health=$(TEAM_HOME=$TEAM_HOME "$bin/team-timers" health --json 2>"$err" </dev/null) || true
  verdict='' reason=''
  json_vars verdict='if (.holding | not) then "none" elif .ok then "PASS"
      elif any(.problems[]; .key == "heartbeat" or .key == "checkpoint") then "FAIL" else "WARN" end' \
    reason='.text // "" | ltrimstr("Health: ")' \
    <<<"$(jq -c 'select(type == "object" and .schema == "team-health/1")' <<<"$health" 2>/dev/null)" 2>/dev/null || verdict=''
  case $verdict in
    none) report health PASS "this machine does not hold the lease, so it keeps no health" ;;
    PASS) report health PASS "$reason" ;;
    FAIL)
      report health FAIL "$reason" \
        "read ~/.local/state/agent-team/heartbeat-failures.log for each failed step's reason, fix what it names, then run team-checkpoint --force"
      ;;
    WARN) report health WARN "$reason" "fix what each problem names; team-timers health lists them" ;;
    *) report health FAIL "team-timers health printed no view: $(first_error)" "fix what team-timers names, then run team-doctor again" ;;
  esac
fi
