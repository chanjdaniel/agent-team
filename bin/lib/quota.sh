# The one Bash reader of team-quota status --json, for team-capacity status and the heartbeat's
# quota step; team-tokens, in Python, keeps the same contract in its read_quota. Sourced after
# team.sh: source "$TEAM_LIB/quota.sh"
#
# quota_read <seconds> [<kill seconds>]: runs this checkout's team-quota status --json, with
# TEAM_HOME passed and stdin closed, stopped after <seconds> and killed <kill seconds> later
# (default 10), and sets QUOTA_STATUS to its team-quota/1 object and QUOTA_ERROR empty; or
# QUOTA_STATUS null and QUOTA_ERROR why: team-quota's first line on stderr, its leading
# "team-quota: " cut; "team-quota status exited <n> with no message"; "team-quota status timed
# out after <seconds> s"; or "team-quota status printed no team-quota/1 object". Returns 0 either
# way. A caller holding a descriptor no child may keep closes it on the call (quota_read 60
# {run_fd}>&-).

# shellcheck shell=bash
# How long a report waits for team-quota status, which reads a few files.
# shellcheck disable=SC2034 # read by the scripts that source this file
QUOTA_SECONDS=30

quota_read() {
  local quota_seconds=$1 quota_kill=${2:-10} quota_rc=0 quota_out quota_errors
  quota_errors=$(mktemp)
  quota_out=$(TEAM_HOME=$TEAM_HOME timeout --kill-after="$quota_kill" "$quota_seconds" "${TEAM_LIB%/*}/team-quota" status --json 2>"$quota_errors" </dev/null) || quota_rc=$?
  QUOTA_STATUS=null QUOTA_ERROR=''
  case $quota_rc in
    0)
      QUOTA_STATUS=$(jq -ce 'select(type == "object" and .schema == "team-quota/1" and (.windows | type) == "array")' \
        <<<"$quota_out" 2>/dev/null) || QUOTA_STATUS=null QUOTA_ERROR="team-quota status printed no team-quota/1 object"
      ;;
    124 | 137) QUOTA_ERROR="team-quota status timed out after $quota_seconds s" ;;
    *)
      QUOTA_ERROR=$(grep -m1 . "$quota_errors" || true)
      QUOTA_ERROR=${QUOTA_ERROR#team-quota: }
      QUOTA_ERROR=${QUOTA_ERROR:-team-quota status exited $quota_rc with no message}
      ;;
  esac
  rm -f -- "$quota_errors"
}
