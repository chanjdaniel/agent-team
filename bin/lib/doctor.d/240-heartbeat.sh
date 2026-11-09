# heartbeat     `team-timers status`: passes enabled on the lease holder, or disabled on any
#               other machine; fails the other way round, with the command that puts it right;
#               warns while the lease line cannot say whether this machine holds it, and when it is
#               enabled on the holder but the installed job is not the one this checkout defines.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's, and holding, from the lease check
# shellcheck disable=SC2034 # heartbeat, for the resources check
# reads state from: 220-lease.sh

# Enabled exactly when this machine holds the lease, as this checkout defines it.
rc=0
timers=$(TEAM_HOME=$TEAM_HOME "$bin/team-timers" status --json 2>"$err" </dev/null) || rc=$?
if ((rc)); then
  report heartbeat FAIL "$(first_error)" "fix what team-timers names, then run team-doctor again"
else
  heartbeat=disabled
  [[ $(jq -r .enabled <<<"$timers") != true ]] || heartbeat=enabled
  case $heartbeat-$holding in
    enabled-yes)
      if [[ $(jq -r .current <<<"$timers") == false ]]; then
        report heartbeat WARN "enabled, but the installed job is not the one this checkout defines" "team-timers enable"
      else
        report heartbeat PASS "enabled, and this machine holds the lease"
      fi
      ;;
    disabled-no) report heartbeat PASS "disabled, and this machine does not hold the lease" ;;
    enabled-no) report heartbeat FAIL "enabled, but this machine does not hold the lease" "team-timers disable" ;;
    disabled-yes) report heartbeat FAIL "disabled, but this machine holds the lease" "team-timers enable" ;;
    *) report heartbeat WARN "$heartbeat, but whether it should be waits on the lease line" "the lease line's fix, then run team-doctor again" ;;
  esac
fi
