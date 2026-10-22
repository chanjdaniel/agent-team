# The team's shared library: every script in bin/ sources it first, passing its arguments.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"
#
# It sets TEAM_HOME (the directory above bin/, unless TEAM_HOME is already set), answers
# --help with the calling script's header, and provides die, usage_error and ledger_append.
# Exit codes: 0 done, 1 refused or a check failed, 2 usage error, 75 try again later.
# shellcheck shell=bash

TEAM_HOME=${TEAM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}

# Refuse with a reason on stderr.
die() {
  echo "${0##*/}: $*" >&2
  exit 1
}

# Refuse a malformed command line.
usage_error() {
  echo "${0##*/}: $*" >&2
  exit 2
}

# Print the calling script's header: the comment block under its shebang.
team_help() {
  sed -n '2,/^[^#]/{/^#/!q;s/^# \{0,1\}//;p}' "$0"
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  team_help
  exit 0
fi

[[ -d $TEAM_HOME ]] || die "team home $TEAM_HOME is not a directory"

# Append one JSON object as one line to the ledger, under an exclusive lock beside it, so two
# scripts never interleave a line.
ledger_append() {
  local line
  line=$(jq -ce 'select(type == "object")' <<<"$1") || die "not a JSON object for the ledger: $1"
  [[ $line != *$'\n'* ]] || die "not one JSON object for the ledger: $1"
  {
    flock -x 9
    printf '%s\n' "$line" >>"$TEAM_HOME/ledger.jsonl"
  } 9>>"$TEAM_HOME/ledger.jsonl.lock"
}
