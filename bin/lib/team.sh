# The team's shared library: every script in bin/ sources it first, passing its arguments.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"
#
# It sets TEAM_HOME (the directory above bin/, unless TEAM_HOME is already set), answers
# --help with the calling script's header (then runs the script's help_more, if it defined one
# before sourcing), and provides die, usage_error, ledger_jq, ledger_append and task_worktrees.
# Exit codes: 0 done, 1 refused or a check failed, 2 usage error, 75 try again later.
# shellcheck shell=bash

TEAM_HOME=${TEAM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
# This library's directory, which holds the ledger contract: code, never the team home's data.
TEAM_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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

# Run jq with the ledger contract as $contract and the definitions of ledger.jq:
# ledger_jq <filter> [jq options and files...]
ledger_jq() {
  jq -L "$TEAM_LIB" --slurpfile contract "$TEAM_LIB/ledger-contract.json" \
    "include \"ledger\"; \$contract[0] as \$contract | $1" "${@:2}"
}

# Append one JSON object as one line to the ledger, under an exclusive lock beside it, so two
# scripts never interleave a line. The event must meet the ledger contract, and the calling
# script must be its kind's writer.
ledger_append() {
  local line problems
  line=$(jq -ce 'select(type == "object")' <<<"$1") || die "not a JSON object for the ledger: $1"
  [[ $line != *$'\n'* ]] || die "not one JSON object for the ledger: $1"
  problems=$(ledger_jq '[append_problems($contract; $writer)] | join("; ")' -r --arg writer "${0##*/}" <<<"$line")
  [[ -z $problems ]] || die "refusing a ledger event: $problems"
  {
    flock -x 9
    printf '%s\n' "$line" >>"$TEAM_HOME/ledger.jsonl"
  } 9>>"$TEAM_HOME/ledger.jsonl.lock"
}

# A task's open worktrees (opened and added, minus returned), one compact
# {task, project, branch, worktree} per line: task_worktrees T<n>
task_worktrees() {
  [[ ! -e $TEAM_HOME/ledger.jsonl ]] ||
    ledger_jq 'open_worktrees(inputs | select(.task == $task))' -nc --arg task "$1" "$TEAM_HOME/ledger.jsonl"
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  team_help
  if declare -F help_more >/dev/null; then help_more; fi
  exit 0
fi

[[ -d $TEAM_HOME ]] || die "team home $TEAM_HOME is not a directory"
