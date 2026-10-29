# heartbeat     `team-timers status`: passes enabled on the lease holder, or disabled on any
#               other machine; fails the other way round, with the command that puts it right;
#               warns while the lease line cannot say whether this machine holds it.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's, and holding, from the lease check
# shellcheck disable=SC2034 # heartbeat, for the slots check

# Enabled exactly when this machine holds the lease.
rc=0
timers=$(TEAM_HOME=$TEAM_HOME "$bin/team-timers" status --json 2>"$err" </dev/null) || rc=$?
if ((rc)); then
  report heartbeat FAIL "$(first_error)" "fix what team-timers names, then run team-doctor again"
else
  heartbeat=disabled
  [[ $(jq -r .enabled <<<"$timers") != true ]] || heartbeat=enabled
  case $heartbeat-$holding in
    enabled-yes) report heartbeat PASS "enabled, and this machine holds the lease" ;;
    disabled-no) report heartbeat PASS "disabled, and this machine does not hold the lease" ;;
    enabled-no) report heartbeat FAIL "enabled, but this machine does not hold the lease" "team-timers disable" ;;
    disabled-yes) report heartbeat FAIL "disabled, but this machine holds the lease" "team-timers enable" ;;
    *) report heartbeat WARN "$heartbeat, but whether it should be waits on the lease line" "the lease line's fix, then run team-doctor again" ;;
  esac
fi
