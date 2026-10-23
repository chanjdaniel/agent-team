# The team's shared library: every script in bin/ sources it first, passing its arguments.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"
#
# It first applies bin/lib/platform.sh (Bash 5 or later; on macOS, Homebrew's GNU tools first on
# PATH). It sets TEAM_HOME (the directory above bin/, unless TEAM_HOME is already set), answers
# --help with the calling script's header (then runs the script's help_more, if it defined one
# before sourcing), and provides die, usage_error, team_project, ledger_jq, ledger_append,
# task_events, known_task_events, open_task_events, task_status, task_worktrees, local_path,
# archive_task_dir, machine_name, os_release, team_os, fence_reason, lease_gate, worktree_changes, worktree_tree, snapshot_message, is_snapshot, non_records, commit_non_records,
# records_list, origin_git, origin_reason, commit_records, render_template, registered_pr,
# attribution_lines, strip_attribution, live_sessions, discord_token, discord_api, github, pr_part
# and task_state_json, and sets COORDINATOR_CHANNEL.
# Exit codes: 0 done, 1 refused or a check failed, 2 usage error, 75 try again later.
# shellcheck shell=bash

# shellcheck source=bin/lib/platform.sh
source "$(dirname "${BASH_SOURCE[0]}")/platform.sh"

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

# Run jq with the ledger contract as $contract, this machine's home directory as $home, and the
# definitions of ledger.jq: ledger_jq <filter> [jq options and files...]
ledger_jq() {
  jq -L "$TEAM_LIB" --slurpfile contract "$TEAM_LIB/ledger-contract.json" --arg home "$HOME" \
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
# {task, project, branch, worktree} per line, each worktree a path on this machine (local_path):
# task_worktrees T<n>
task_worktrees() {
  [[ ! -e $TEAM_HOME/ledger.jsonl ]] ||
    ledger_jq 'open_worktrees(inputs | select(.task == $task); $home)' -nc --arg task "$1" "$TEAM_HOME/ledger.jsonl"
}

# A recorded path as the same path on this machine: one under /home/<name> or /Users/<name> is
# re-rooted to this HOME, since every machine keeps the same layout under its home; any other
# path is printed unchanged. Recorded paths stay as written; readers map them: local_path <path>
local_path() {
  ledger_jq '$path | local_path($home)' -nr --arg path "$1"
}

# Mirror the task directory <dir> of a worktree of <project> into <archive> under the team home
# (tasks/T<n>/scratch or tasks/T<n>/scratch-<project>), so the archive is the task directory as
# it is now; a missing or empty task directory archives nothing and is reported on stderr,
# failing: archive_task_dir <dir> <project> <archive>
archive_task_dir() {
  if [[ ! -d $1 ]]; then
    echo "${0##*/}: $1 is missing, so nothing was archived from $2" >&2
    return 1
  elif [[ -z $(find "$1" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo "${0##*/}: $1 is empty, so nothing was archived from $2" >&2
    return 1
  fi
  mkdir -p "$TEAM_HOME/$3"
  rsync -a --delete -- "$1/" "$TEAM_HOME/$3/" || die "cannot mirror $1 into $3"
}

# Print this machine's team name, the first line of ~/.config/agent-team/machine (lower-case
# kebab case, like home-pc or laptop), or fail saying how to write one.
machine_name() {
  local file=$HOME/.config/agent-team/machine name='' fix='write one with: echo <name> > ~/.config/agent-team/machine'
  if [[ ! -f $file ]]; then
    echo "${0##*/}: this machine has no team name; $fix" >&2
    return 1
  fi
  IFS= read -r name <"$file" || true
  if [[ ! $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "${0##*/}: ~/.config/agent-team/machine names '$name', not a lower-case kebab-case name like home-pc; $fix" >&2
    return 1
  fi
  printf '%s\n' "$name"
}

# A value of the os-release file, unquoted: os_release <key>. TEAM_OS_RELEASE names the file to
# read instead of /etc/os-release (the tests' seam).
os_release() {
  sed -n "s/^$1=//p" "${TEAM_OS_RELEASE:-/etc/os-release}" 2>/dev/null | head -n1 |
    sed -E "s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/"
}

# This machine's OS as the team names it: arch (Arch Linux, or a derivative whose ID_LIKE names
# arch, like EndeavourOS) or macos; fails on any other.
team_os() {
  case $(uname -s) in
    Darwin) echo macos ;;
    Linux) [[ $(os_release ID) == arch || " $(os_release ID_LIKE) " == *" arch "* ]] && echo arch ;;
    *) return 1 ;;
  esac
}

# Print why this machine is fenced, "fenced since <time> (holder seen <name>, epoch <n>)", from
# ~/.local/state/agent-team/fenced, which team-lease writes when it finds the lease lost; fails
# when this machine is not fenced. A fence file without a since dates from its modification time.
fence_reason() {
  local file=$HOME/.local/state/agent-team/fenced since
  [[ -e $file ]] || return 1
  since=$(jq -er '.since | strings' "$file" 2>/dev/null) || since=$(date -u -r "$file" +%FT%TZ)
  jq -r --arg since "$since" '"fenced since \($since)"
    + if (.holder | type) == "string" then " (holder seen \(.holder), epoch \(.epoch // "?"))" else "" end' \
    "$file" 2>/dev/null || echo "fenced since $since"
}

# Refuse to start <what> ("a coordinator", "a worker") unless this machine holds the lease,
# confirmed against origin by team-lease check, whose reason comes first on stderr: the team runs
# on the lease holder alone, and never starts offline.
lease_gate() {
  local lease=$TEAM_LIB/../team-lease rc=0 holder
  TEAM_HOME=$TEAM_HOME "$lease" check >/dev/null || rc=$?
  case $rc in
    0) return 0 ;;
    75) die "GitHub unreachable; $1 never starts offline" ;;
  esac
  holder=$(TEAM_HOME=$TEAM_HOME "$lease" status --json 2>/dev/null |
    jq -r 'select(.confirmed and .state == "held" and (.mine | not)) | .holder') || holder=''
  [[ -z $holder ]] || die "$holder holds the lease: hand off there, then team-resume here"
  die "$1 starts only on the machine that holds the lease"
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

# The tree of the worktree <wt> as it is, uncommitted changes and untracked files included (files
# git ignores are not), built in a copy of its index so the worktree's own index is never
# touched; it equals HEAD's tree when the worktree is clean: worktree_tree <wt>
worktree_tree() {
  local wt=$1 index copy tree
  index=$(git -C "$wt" rev-parse --path-format=absolute --git-path index) || return 1
  copy=$(mktemp)
  # A copy of the real index keeps what git knows of each file's state; with none, HEAD's.
  if [[ -f $index ]]; then cp "$index" "$copy"; else GIT_INDEX_FILE=$copy git -C "$wt" read-tree HEAD; fi
  if GIT_INDEX_FILE=$copy git -C "$wt" add -A && tree=$(GIT_INDEX_FILE=$copy git -C "$wt" write-tree); then
    rm -f "$copy"
    printf '%s\n' "$tree"
  else
    rm -f "$copy"
    return 1
  fi
}

# The message of a checkpoint's snapshot commit, which marks it as one (is_snapshot):
# snapshot_message <task> <machine> <UTC time>
snapshot_message() {
  printf 'wip: %s checkpoint on %s at %s\n' "$1" "$2" "$3"
}

# Whether <commit> in the repository <dir> is a checkpoint's snapshot of <task>'s uncommitted
# changes (one parent, snapshot_message's subject) rather than a branch head that a checkpoint of
# a clean worktree pushed as wip/<task>: is_snapshot <dir> <commit> <task>
is_snapshot() {
  local subject
  [[ $(git -C "$1" rev-list --parents -n 1 "$2" | wc -w) == 2 ]] || return 1
  subject=$(git -C "$1" log -1 --format=%s "$2")
  [[ $subject =~ ^wip:\ $3\ checkpoint\ on\ [a-z0-9-]+\ at\ [0-9T:-]+Z$ ]]
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

# Run git against an origin: no credential prompt, at most NET_TIMEOUT seconds (the caller's
# constant, 60 when unset), stdin closed, stderr into the file NET_ERR (the caller's), and the
# caller's lock, the file descriptor in lock_fd when it is set, closed for it, so a credential
# helper or ssh master left running never holds the lock: origin_git <git arguments...>
origin_git() {
  if [[ -n ${lock_fd:-} ]]; then
    GIT_TERMINAL_PROMPT=0 timeout "${NET_TIMEOUT:-60}" git "$@" 2>"$NET_ERR" </dev/null {lock_fd}>&-
  else
    GIT_TERMINAL_PROMPT=0 timeout "${NET_TIMEOUT:-60}" git "$@" 2>"$NET_ERR" </dev/null
  fi
}

# Why the last origin_git failed: its first fatal or error line (credentials in a URL cut out),
# else its exit status: origin_reason <exit status>
origin_reason() {
  local why
  why=$(sed -nE 's/^(fatal|error): //p' "$NET_ERR" | head -n 1 | sed -E 's#//[^/@[:space:]]*@#//#g')
  if [[ -n $why ]]; then
    printf '%s\n' "$why"
  elif (($1 == 124)); then
    echo "no answer in ${NET_TIMEOUT:-60}s"
  else
    echo "exit $1"
  fi
}

# Commit the records among <pathspec>... in the team home as <message>, on the branch checked out,
# then push the branch when it is ahead of origin's (or origin's is unknown). The commit is made
# under the ledger's lock and holds those paths alone, so whatever else is staged stays staged; the
# team home's hooks run. A push origin rejects fetches its branch and replays the commits it lacks
# onto it, when they apply cleanly and no local change is in the way (a branch switch's two-tree
# merge, so what is staged stays staged), then pushes again once. Prints one line on stdout, like
# "team home: committed <sha> <message> and pushed dev" or "team home: nothing to commit"; a
# failure adds its reason on stderr and returns 1. Network calls go through origin_git, so
# NET_ERR must name a file: commit_records <message> <pathspec>...
commit_records() {
  local message=$1 branch committed upstream out rc=0
  local -a record_paths
  shift
  if ! branch=$(git -C "$TEAM_HOME" symbolic-ref -q --short HEAD); then
    echo "${0##*/}: team home: not on a branch, so the records are not committed" >&2
    return 1
  fi
  committed="nothing to commit"
  {
    flock -x 9
    mapfile -d '' -t record_paths < <(git -C "$TEAM_HOME" ls-files -z -m -d -o --exclude-standard -- "$@")
    ((${#record_paths[@]} == 0)) || GIT_LITERAL_PATHSPECS=1 git -C "$TEAM_HOME" add -A -- "${record_paths[@]}"
    mapfile -d '' -t record_paths < <(git -C "$TEAM_HOME" diff --cached -z --name-only --no-renames HEAD -- "$@")
    if ((${#record_paths[@]})); then
      if GIT_LITERAL_PATHSPECS=1 git -C "$TEAM_HOME" commit -q -m "$message" --only -- "${record_paths[@]}" >"$NET_ERR" 2>&1; then
        committed="committed $(git -C "$TEAM_HOME" rev-parse --short HEAD) $message"
      else
        committed=''
        echo "${0##*/}: team home: cannot commit the records: $(grep -m1 . "$NET_ERR" || echo "git commit failed")" >&2
      fi
    fi
  } 9>>"$TEAM_HOME/ledger.jsonl.lock"
  [[ -n $committed ]] || return 1
  upstream=refs/remotes/origin/$branch
  if git -C "$TEAM_HOME" rev-parse -q --verify "$upstream" >/dev/null &&
    [[ -z $(git -C "$TEAM_HOME" rev-list -n 1 "$upstream..HEAD") ]]; then
    echo "team home: $committed"
    return 0
  fi
  out=$(origin_git -C "$TEAM_HOME" push --porcelain origin "refs/heads/$branch:refs/heads/$branch") || rc=$?
  if ((rc == 0)); then
    echo "team home: $committed and pushed $branch"
    return 0
  fi
  if ! grep -q '^!' <<<"$out"; then
    echo "${0##*/}: team home: $committed; cannot push $branch: $(origin_reason "$rc")" >&2
    return 1
  fi
  if ! replay_records "$branch"; then
    echo "team home: $committed"
    echo "${0##*/}: team home: origin's $branch has moved and the commits not on it cannot be replayed onto it ($REPLAY_REASON); they stay unpushed" >&2
    return 1
  fi
  rc=0
  origin_git -C "$TEAM_HOME" push -q origin "refs/heads/$branch:refs/heads/$branch" || rc=$?
  if ((rc)); then
    echo "${0##*/}: team home: $committed; replayed onto origin's $branch, but cannot push it: $(origin_reason "$rc")" >&2
    return 1
  fi
  echo "team home: $committed; origin's $branch had moved; replayed onto it and pushed $branch"
}

# The local paths in the way of moving the team home from HEAD to <commit>: changed there and
# here (staged, unstaged or untracked), on one line.
records_in_the_way() {
  local their_paths=()
  mapfile -d '' -t their_paths < <(git -C "$TEAM_HOME" diff -z --name-only --no-renames HEAD "$1")
  ((${#their_paths[@]})) || return 0
  git -C "$TEAM_HOME" -c core.quotePath=false status --porcelain --untracked-files=all -- "${their_paths[@]}" | cut -c4- | paste -sd ' '
}

# Replay the commits on the team home's <branch> that origin's lacks onto origin's, moving the
# branch, index and working tree as a branch switch would (commit_records); fails with the reason
# in REPLAY_REASON.
replay_records() {
  local branch=$1 base old onto commit tree conflicts way rc=0
  local -a replayed replay_author
  origin_git -C "$TEAM_HOME" fetch -q origin "refs/heads/$branch:refs/remotes/origin/$branch" || rc=$?
  if ((rc)); then
    REPLAY_REASON="cannot fetch it: $(origin_reason "$rc")"
    return 1
  fi
  base=$(git -C "$TEAM_HOME" rev-parse "refs/remotes/origin/$branch")
  old=$(git -C "$TEAM_HOME" rev-parse HEAD)
  if [[ -n $(git -C "$TEAM_HOME" rev-list --merges "$base..$old") ]]; then
    REPLAY_REASON="a merge commit is among them"
    return 1
  fi
  mapfile -t replayed < <(git -C "$TEAM_HOME" rev-list --reverse "$base..$old")
  onto=$base
  for commit in "${replayed[@]}"; do
    rc=0
    tree=$(git -C "$TEAM_HOME" merge-tree --write-tree --name-only --no-messages --merge-base="$commit^" "$onto" "$commit") || rc=$?
    if ((rc)); then
      conflicts=$(tail -n +2 <<<"$tree" | paste -sd ' ')
      REPLAY_REASON="a conflict in ${conflicts:-what $(git -C "$TEAM_HOME" rev-parse --short "$commit") changes}"
      return 1
    fi
    mapfile -t replay_author < <(git -C "$TEAM_HOME" log -1 --format='%an%n%ae%n%aI' "$commit")
    onto=$(git -C "$TEAM_HOME" log -1 --format=%B "$commit" |
      GIT_AUTHOR_NAME=${replay_author[0]} GIT_AUTHOR_EMAIL=${replay_author[1]} GIT_AUTHOR_DATE=${replay_author[2]} \
        git -C "$TEAM_HOME" commit-tree "$tree" -p "$onto" -F -)
  done
  {
    flock -x 9
    git -C "$TEAM_HOME" update-index -q --refresh || true
    way=$(records_in_the_way "$onto")
    if [[ -n $way ]]; then
      REPLAY_REASON="local changes to $way are in the way"
      return 1
    fi
    if ! git -C "$TEAM_HOME" read-tree -m -u HEAD "$onto" 2>"$NET_ERR"; then
      REPLAY_REASON="moving the working tree failed: $(grep -m1 . "$NET_ERR" | sed -E 's/^(fatal|error): //')"
      return 1
    fi
    git -C "$TEAM_HOME" update-ref -m "${0##*/}: replayed onto origin/$branch" "refs/heads/$branch" "$onto" "$old"
  } 9>>"$TEAM_HOME/ledger.jsonl.lock"
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
  state=$(ledger_jq 'task_state($sessions; $home)' -c --argjson sessions "$LIVE_SESSIONS" <<<"$events") || exit 1
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
