# A sibling script's failure as the {error} a view holds in its place, for team-queue's
# capacity_json, team-snapshot's queue_status and team-sweep's script_view, sourced after the
# library:
#
#   # shellcheck source=bin/lib/error-view.sh
#   source "$TEAM_LIB/error-view.sh"
#
# It provides:
#   error_view <err file> <fallback> [<prefix>]
#                          prints {"error": <why>} on one line: why is the last non-empty line of
#                          <err file> (the script's stderr), <prefix> taken off its start when
#                          given, else <fallback>; either with ~/ for the home directory.
# shellcheck shell=bash

error_view() {
  local line
  line=$(grep . "$1" | tail -n 1) || line=$2
  line=${line#"${3:-}"}
  jq -cn --arg error "${line//"$HOME/"/"~/"}" '{error: $error}'
}
