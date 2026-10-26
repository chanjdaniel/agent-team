# offline       Warns while the heartbeat holds the team for an outage ("offline since <time>
#               (<n> minutes)"): it resumes on its own once GitHub answers.
# shellcheck shell=bash

# The heartbeat's flag, written when a probe of GitHub failed twice.
offline=$HOME/.local/state/agent-team/offline
if [[ -e $offline ]]; then
  since=$(jq -er '.since | strings' "$offline" 2>/dev/null) || since=$(date -u -r "$offline" +%FT%TZ)
  report offline WARN "offline since $since ($((($(date +%s) - $(date -d "$since" +%s)) / 60)) minutes)" \
    "check this machine's network; the heartbeat resumes the team when GitHub answers"
else
  report offline PASS "the team is not holding for an outage"
fi
