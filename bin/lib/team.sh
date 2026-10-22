# The team's shared library: every script in bin/ sources it first, passing its arguments.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"
#
# It sets TEAM_HOME (the directory above bin/, unless TEAM_HOME is already set), answers
# --help with the calling script's header (then runs the script's help_more, if it defined one
# before sourcing), and provides die, usage_error, team_project, ledger_jq, ledger_append,
# task_events, known_task_events, open_task_events, task_status, task_worktrees,
# worktree_changes, non_records, commit_non_records, records_list, render_template, registered_pr,
# attribution_lines, strip_attribution, live_sessions, discord_token, discord_api, github, pr_part
# and task_state_json, and sets COORDINATOR_CHANNEL.
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

# All of a task's events, in ledger order, one compact object per line (lines that are not JSON
# objects are skipped): task_events T<n>
task_events() {
  [[ ! -e $TEAM_HOME/ledger.jsonl ]] ||
    jq -cR --arg task "$1" 'fromjson? | select(type == "object" and .task == $task)' "$TEAM_HOME/ledger.jsonl"
}

# A task's events as one JSON array in ledger order, refusing a task the ledger has no events for:
# known_task_events T<n>
known_task_events() {
  local events
  events=$(task_events "$1" | jq -cs .)
  [[ $events != '[]' ]] || die "unknown task $1: the ledger has no events for it"
  printf '%s\n' "$events"
}

# A task's events as one JSON array in ledger order, refusing a task that is not open: one with
# no opened event, or a closed one: open_task_events T<n>
open_task_events() {
  local events
  events=$(task_events "$1" | jq -cs .)
  case $(task_status "$events") in
    open) printf '%s\n' "$events" ;;
    closed) die "$1 is closed" ;;
    *) die "$1 is not open: the ledger has no opened event for it" ;;
  esac
}

# A task's status from its events (one JSON array): open, closed, legacy or unknown, as
# task_status in ledger.jq tells it: task_status '<events>'
task_status() {
  ledger_jq task_status -r <<<"$1"
}

# Read the live session list (claude agents --json, a JSON array) into LIVE_SESSIONS, once per
# run: later calls keep the first read.
LIVE_SESSIONS=''
live_sessions() {
  [[ -z ${LIVE_SESSIONS:-} ]] || return 0
  LIVE_SESSIONS=$(claude agents --json | jq -ce 'select(type == "array")' 2>/dev/null) ||
    die "cannot read the live session list (claude agents --json)"
}

# A task's open worktrees (opened and added, minus returned), one compact
# {task, project, branch, worktree} per line: task_worktrees T<n>
task_worktrees() {
  [[ ! -e $TEAM_HOME/ledger.jsonl ]] ||
    ledger_jq 'open_worktrees(inputs | select(.task == $task))' -nc --arg task "$1" "$TEAM_HOME/ledger.jsonl"
}

# What is not committed in the worktree <wt>, one line per kind, nothing when it is clean (files
# git ignores are fine): "changes to tracked files: <files>", "untracked files: <files>".
worktree_changes() {
  local list
  list=$(git -C "$1" diff --name-only HEAD | paste -sd ' ')
  [[ -z $list ]] || echo "changes to tracked files: $list"
  list=$(git -C "$1" ls-files --others --exclude-standard | paste -sd ' ')
  [[ -z $list ]] || echo "untracked files: $list"
}

# The records as a reader's list: "ledger.jsonl, manual-steps.md, tasks/, ...".
records_list() {
  local globs
  globs=$(grep -v -e '^#' -e '^$' "$TEAM_LIB/records" | sed 's/\*\*$//' | paste -sd ,)
  printf '%s\n' "${globs//,/, }"
}

# The paths of the NUL-separated list on stdin that are not records (bin/lib/records), one per
# line, in order: non_records
non_records() {
  local path record
  local -a records
  mapfile -t records < <(grep -v -e '^#' -e '^$' "$TEAM_LIB/records")
  while IFS= read -r -d '' path; do
    for record in "${records[@]}"; do
      # shellcheck disable=SC2053 # the record is a glob
      [[ $path != $record ]] || continue 2
    done
    printf '%s\n' "$path"
  done
}

# The paths <commit> touches against its first parent (a root commit: all its paths) that are not
# records, one per line, in order: commit_non_records <commit>
commit_non_records() {
  if git rev-parse -q --verify "$1^1" >/dev/null; then
    git diff --name-only --no-renames -z "$1^1" "$1" | non_records
  else
    git diff-tree -r --root --no-commit-id --name-only --no-renames -z "$1" | non_records
  fi
}

# The agent attribution lines no commit message may carry, one case-insensitive ERE over whole
# lines: a Co-Authored-By naming Claude, Anthropic or an anthropic.com address (human co-authors
# stay), a Claude-Session trailer, and the "Generated with Claude Code" line with or without its
# emoji and link.
ATTRIBUTION_RE='^[[:space:]]*(co-authored-by:(.*[^[:alnum:]])?(claude|anthropic)([^[:alnum:]].*)?|claude-session:.*|(🤖[[:space:]]*)?generated with (claude code|\[claude code\])([[:space:]]*\([^)]*\))?\.?)[[:space:]]*$'

# Messages are matched as bytes (LC_ALL=C), so one in another encoding is read whole, never as
# binary; a grep that fails (exit 2) fails the caller.
# The attribution lines of the message on stdin, nothing when it has none.
attribution_lines() {
  LC_ALL=C grep -aEi -- "$ATTRIBUTION_RE" || (($? == 1))
}

# The message on stdin without its attribution lines and the blank lines that leaves at its end.
strip_attribution() {
  { LC_ALL=C grep -aEiv -- "$ATTRIBUTION_RE" || (($? == 1)); } |
    LC_ALL=C awk '{ line[NR] = $0 } END { n = NR; while (n > 0 && line[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print line[i] }'
}

# A template's text with each {{key}} filled from the JSON object <values>, in one pass, so a
# value is never read for placeholders itself; a key with no value stays as it is:
# render_template <text> '<values>'
render_template() {
  jq -nr --arg text "$1" --argjson values "$2" \
    '$text | gsub("\\{\\{(?<key>[a-z][a-z0-9_]*)\\}\\}"; $values[.key] // "{{\(.key)}}")'
}

# The Discord channel #coordinator, under which every task's thread is opened.
# shellcheck disable=SC2034 # read by the scripts that source this library
COORDINATOR_CHANNEL=${TEAM_COORDINATOR_CHANNEL:-1562486564871995482}

# Print the Discord bot token from ~/.claude/channels/discord/.env, or fail with nothing printed.
# Callers keep it in a variable or test for it (discord_token >/dev/null); never print it.
discord_token() {
  local token
  token=$(sed -n 's/^DISCORD_BOT_TOKEN=//p' "$HOME/.claude/channels/discord/.env" 2>/dev/null || true)
  [[ -n $token ]] || return 1
  printf '%s\n' "$token"
}

# Call the Discord API with the bot token: discord_api <path under /api/v10/> [curl options...]
# The token reaches curl on stdin (-H @-), so it never shows in a process list. Prints the
# response; fails with curl's reason on stderr, or with "no DISCORD_BOT_TOKEN ..." without one.
discord_api() {
  local token
  token=$(discord_token) || {
    echo "no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env" >&2
    return 1
  }
  curl -fsS -H @- "${@:2}" "https://discord.com/api/v10/$1" <<<"Authorization: Bot $token"
}

# The project registry, through this checkout's team-project: team_project [<arguments>...]
# team-project refuses a broken registry itself, with every problem on stderr.
team_project() {
  TEAM_HOME=$TEAM_HOME "$(dirname "$TEAM_LIB")/team-project" "$@"
}

# The project, its repo as the registry spells it, and the number of a pull request URL, one
# per line, refusing any URL but https://github.com/<owner>/<name>/pull/<n> in a registered
# project's repo: registered_pr <url>
registered_pr() {
  local project
  [[ $1 =~ ^https://github\.com/([A-Za-z0-9-]+/[A-Za-z0-9._-]+)/pull/([1-9][0-9]*)$ ]] ||
    usage_error "not a GitHub pull request URL: $1"
  project=$(team_project --find repo "${BASH_REMATCH[1]}") || exit 1
  [[ -n $project ]] || die "${BASH_REMATCH[1]} is no registered project's repo"
  project=${project%%$'\n'*}
  printf '%s\n' "$project" "$(team_project "$project" repo)" "${BASH_REMATCH[2]}"
}

# Run gh, keeping its JSON in <dir>/<name>: github <dir> <name> <gh arguments...>
# On failure, false with the reason in <dir>/error. "No checks reported" is an empty list,
# and gh pr checks' exit 8 (checks pending) is a success when it printed the list.
github() {
  local dir=$1 name=$2 status=0
  shift 2
  gh "$@" >"$dir/$name" 2>"$dir/$name.stderr" || status=$?
  if [[ $status -eq 8 && $1 == pr && $2 == checks ]] && jq -e 'type == "array"' "$dir/$name" >/dev/null 2>&1; then
    status=0
  elif [[ $status -ne 0 && $1 == pr && $2 == checks ]] && grep -Eq '^no (required )?checks reported' "$dir/$name.stderr"; then
    echo '[]' >"$dir/$name"
    status=0
  fi
  if [[ $status -eq 0 ]] && jq -e . "$dir/$name" >/dev/null 2>&1; then return 0; fi
  {
    printf 'gh %s %s: ' "$1" "$2"
    grep -m1 . "$dir/$name.stderr" || if [[ $status -eq 0 ]]; then echo "not JSON"; else echo "exit $status"; fi
  } >"$dir/error"
  return 1
}

# The pr part of a task's state: its latest pr event joined with GitHub, using <dir> for gh's
# answers: pr_part '<events>' '<pr event>' <dir>
pr_part() {
  local events=$1 pr=$2 dir=$3 url project repo='' number required_checks='[]' facts
  url=$(jq -r .url <<<"$pr") || return 1
  project=$(jq -r '.project // empty' <<<"$pr") || return 1
  if [[ $url =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)/?$ ]]; then
    repo=${BASH_REMATCH[1]} number=${BASH_REMATCH[2]}
  else
    jq -cn --arg url "$url" '{url: $url, error: "not a GitHub pull request URL: \($url)"}'
    return
  fi
  if [[ -z $project ]]; then
    # A legacy pr event names no project: the registered project whose repo is the URL's.
    project=$(team_project --find repo "$repo") || return 1
    project=${project%%$'\n'*}
  fi
  if [[ -n $project ]]; then
    repo=$(team_project "$project" repo) || return 1
    required_checks=$(team_project "$project" required_checks) || return 1
  fi
  facts=$(ledger_jq '{url: $url, number: $number, repo: $repo, project: $project,
      ledger_head: pr_head($url),
      merge_approved: any(.[]; .event == "merge-approved" and (.url | strings | rtrimstr("/")) == ($url | rtrimstr("/")))}' \
    -c --arg url "$url" --argjson number "$number" --arg repo "$repo" \
    --argjson project "$(jq -n --arg p "$project" 'if $p == "" then null else $p end')" <<<"$events") || return 1
  if github "$dir" view pr view "$number" --repo "$repo" --json number,state,baseRefName,headRefOid &&
    github "$dir" checks pr checks "$number" --repo "$repo" --json name,bucket,state &&
    github "$dir" required pr checks "$number" --repo "$repo" --required --json name,bucket,state; then
    ledger_jq '
      $view[0] as $view | $checks[0] as $checks
      | ($checks | map(.name)) as $present
      | (($required[0] | map(.name)) + $project_required | unique) as $required
      | . + {state: ($view.state | ascii_downcase), base: $view.baseRefName, head: $view.headRefOid,
          head_moved: (same_head($view.headRefOid; .ledger_head) | not),
          checks: {
            passed: [$checks[] | select(.bucket == "pass" or .bucket == "skipping") | .name] | unique,
            failing: [$checks[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | unique,
            pending: [$checks[] | select(.bucket == "pending") | .name] | unique},
          required: $required,
          required_missing: [$required[] | select(IN($present[]) | not)],
          agent_review: ([$checks[] | select(.name == "agent-review") | .state | ascii_downcase] | first // "missing")}
      | {url, number, repo, project, state, base, head, ledger_head, head_moved, checks, required,
         required_missing, agent_review, merge_approved}' \
      -c --slurpfile view "$dir/view" --slurpfile checks "$dir/checks" \
      --slurpfile required "$dir/required" --argjson project_required "$required_checks" <<<"$facts"
  else
    jq -c --rawfile error "$dir/error" '. + {error: ($error | rtrimstr("\n"))}' <<<"$facts"
  fi
}

# A task's state, as team-state --json prints it but compact, from its events (one JSON array in
# ledger order), the live session list and, when it has a pr event, GitHub. GitHub failures are
# carried in the pr part; a broken registry or an unreadable session list fails with the reason
# on stderr: task_state_json '<events>'
task_state_json() (
  local events=$1 state pr dir
  live_sessions
  state=$(ledger_jq 'task_state($sessions)' -c --argjson sessions "$LIVE_SESSIONS" <<<"$events") || exit 1
  pr=$(jq -c 'map(select(.event == "pr")) | last' <<<"$events") || exit 1
  if [[ $pr != null ]]; then
    dir=$(mktemp -d) || exit 1
    trap 'rm -rf "$dir"' EXIT
    pr=$(pr_part "$events" "$pr" "$dir") || exit 1
    state=$(jq -c --argjson pr "$pr" '.pr = $pr' <<<"$state") || exit 1
  fi
  printf '%s\n' "$state"
)

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  team_help
  if declare -F help_more >/dev/null; then help_more; fi
  exit 0
fi

[[ -d $TEAM_HOME ]] || die "team home $TEAM_HOME is not a directory"
