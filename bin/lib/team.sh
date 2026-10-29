# The team's shared library: every script in bin/ sources it first, passing its arguments.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"
#
# Before anything else, a working directory that no longer exists (a folder deleted under the
# caller's shell) is left for HOME, saying so on stderr, since Claude Code, Node and others fail
# without one. It then applies bin/lib/platform.sh (Bash 5 or later; on macOS, Homebrew's GNU tools first on
# PATH), and after --help puts the tool directories of bin/lib/tools.lock on PATH (team_tool_path),
# exported, so every script and every session it starts runs with that one PATH. It sets
# TEAM_HOME (unless already set, the first line of ~/.config/agent-team/home under
# HOME) and TEAM_HOME_FROM, answers --help with the calling script's header (then runs
# the script's help_more, if it defined one before sourcing), and provides die, usage_error, team_project, ledger_jq, ledger_append,
# task_events, known_task_events, open_task_events, task_status, task_worktrees, local_path,
# archive_left_out, rsync_rule, archive_task_dir, machine_name, os_release, team_os, tool_dirs,
# team_tool_path, fence_reason, offline_hold, lease_refusal, worker_refusal, lease_gate, worktree_changes, same_path, bounded, trust_probe,
# pool_status, pool_entry, pool_slot, treehouse_slots, slot_changes, secret_paths, snapshot_left_out, worktree_tree, snapshot_message, is_snapshot, wip_origin,
# only_records, records_list, origin_git, origin_reason, commit_records, fast_forward, follow_base, render_template,
# registered_pr, attribution_lines, strip_attribution, live_sessions, machine_slots, discord_token, discord_api,
# daniel_message, refresh_inbox, github, pr_part and task_state_json, and sets IMAGE_TYPE, COORDINATOR_CHANNEL and
# INTERVIEW_CHANNEL.
# Exit codes: 0 done, 1 refused or a check failed, 2 usage error, 75 try again later.
# shellcheck shell=bash

# PWD names a directory other than ".", or none, once the one the shell is in is deleted. Read by
# Bash 3.2 too, before platform.sh's version check.
if [[ -z ${PWD:-} || ! $PWD -ef . ]]; then
  echo "${0##*/}: the current directory no longer exists; running from ~" >&2
  cd "$HOME" || exit 1
fi

# shellcheck source=bin/lib/platform.sh
source "$(dirname "${BASH_SOURCE[0]}")/platform.sh"

# The team home, where the records live: TEAM_HOME when set; else the first line of
# ~/.config/agent-team/home, a path relative to HOME unless it is absolute; never the code
# checkout. TEAM_HOME_FROM says which (variable, setting, or none, where TEAM_HOME is empty).
# TEAM_HOME_PROBLEM is the refusal when neither names a directory, given after --help has had its
# chance; a script that sets team_home_report before sourcing (team-doctor, and the git hooks,
# the records hook, data-check, tests/run, team-heavy and servers/install, which need none) is
# not refused, and reports it itself, and one that sets team_home_unnamed (team-bootstrap, which
# names it) is not refused while nothing names one.
TEAM_HOME_PROBLEM='' TEAM_HOME_FIX='name its checkout there, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home'
TEAM_HOME_FROM=variable
# shellcheck disable=SC2034 # TEAM_HOME_FROM is read by team-doctor and team-bootstrap
if [[ -z ${TEAM_HOME:-} && -f $HOME/.config/agent-team/home ]]; then
  TEAM_HOME_FROM=setting
  IFS= read -r TEAM_HOME <"$HOME/.config/agent-team/home" || true
  if [[ -z $TEAM_HOME ]]; then
    TEAM_HOME_PROBLEM="the setting ~/.config/agent-team/home names no team home; $TEAM_HOME_FIX"
  else
    [[ $TEAM_HOME == /* ]] || TEAM_HOME=$HOME/$TEAM_HOME
    [[ -d $TEAM_HOME ]] ||
      TEAM_HOME_PROBLEM="the team home $TEAM_HOME, named by ~/.config/agent-team/home, is not a directory; $TEAM_HOME_FIX"
  fi
elif [[ -z ${TEAM_HOME:-} ]]; then
  TEAM_HOME_FROM=none TEAM_HOME=''
  TEAM_HOME_PROBLEM="neither TEAM_HOME nor ~/.config/agent-team/home names the team home; $TEAM_HOME_FIX"
fi
# This library's directory, which holds the ledger contract: code, never the team home's data.
TEAM_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The extensions of an image, an extended regular expression's alternatives matched in any case:
# the records hook refuses them (data-check) and a task's archive leaves them out
# (archive_left_out), so a screenshot never reaches the team home's history.
IMAGE_TYPE='png|jpe?g|gif|webp|bmp|tiff?|ico|svg|heic|heif|avif'

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

# The machine's task slots as one compact line: team-slots status --stored --json's object, read
# from the stored readings only (it takes none, so it writes nothing), or {error} with the last
# line team-slots said on stderr (~ for the home directory) when it fails: machine_slots
machine_slots() {
  local out err line
  out=$(mktemp) err=$(mktemp)
  if TEAM_HOME=$TEAM_HOME "$(dirname "$TEAM_LIB")/team-slots" status --stored --json >"$out" 2>"$err" </dev/null; then
    jq -c . "$out"
  else
    line=$(grep . "$err" | tail -n 1) || line="team-slots failed with no reason given"
    jq -cn --arg error "${line//"$HOME/"/"~/"}" '{error: $error}'
  fi
  rm -f "$out" "$err"
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

# The paths of the task directory <dir> that have no place in the team home's history, so its
# archive leaves them out, each as "<why>\t<path>" (relative to <dir>), NUL-terminated, in this
# order, sorted within each:
#   UI capture         a top-level ui/ (a frontend capture stays on the machine that took it)
#   Lighthouse reports a ui-check run's lighthouse/, ui-check/<run>/lighthouse (its failing
#                      audits are in the run's findings.md, which is kept)
#   nested repository  a directory holding .git, or a bare repository's HEAD, objects/ and refs/
#   dependencies       a directory named node_modules, .venv, venv or __pycache__
#   over 200 files     any other directory holding more than 200 files through its
#                      subdirectories, the outermost one only
#   link               a symbolic link
#   image              a file whose extension IMAGE_TYPE names, in any case (a screenshot is
#                      never kept in git; the records hook refuses one)
#   over 1 MiB         a file over 1 MiB
#   may hold a secret  a path secret_paths names
# Nothing is looked for inside a path named by an earlier reason. This is the one place the list
# is written; the scripts that archive, and their docs, point here.
# A missing directory has none: archive_left_out <dir>
archive_left_out() {
  (
    export LC_ALL=C
    cd "$1" 2>/dev/null || exit 0
    local skip=(-path ./ui) dir
    # skip_path <path>: look for nothing inside <path>, its find wildcards escaped.
    skip_path() {
      local pattern=${1//\\/\\\\}
      pattern=${pattern//\*/\\*} pattern=${pattern//\?/\\?} pattern=${pattern//\[/\\[}
      skip+=(-o -path "./$pattern")
    }
    [[ ! -d ui ]] || printf 'UI capture\tui\0'
    if [[ -d ui-check && ! -L ui-check ]]; then
      while IFS= read -r -d '' dir; do
        printf 'Lighthouse reports\t%s\0' "$dir"
        skip_path "$dir"
      done < <(find ui-check -mindepth 2 -maxdepth 2 -type d -name lighthouse -print0 | sort -z)
    fi
    local is_repo=(-type d \( -exec test -e '{}/.git' ';' -o -exec test -f '{}/HEAD' ';' -exec test -d '{}/objects' ';' -exec test -d '{}/refs' ';' \))
    local is_deps=(-type d \( -name node_modules -o -name .venv -o -name venv -o -name __pycache__ \))
    local is_image=(-regextype posix-extended -iregex ".*\\.($IMAGE_TYPE)")
    # walk <from> <expression>: find under <from>, never inside what skip, is_repo or is_deps match; the
    # expression applies to every other path.
    walk() { find "$1" -mindepth 1 \( \( "${skip[@]}" \) -o \( "${is_repo[@]}" \) -o \( "${is_deps[@]}" \) \) -prune -o "${@:2}"; }
    find . -mindepth 1 \( "${skip[@]}" \) -prune -o \( "${is_repo[@]}" \) -printf 'nested repository\t%P\0' -prune | sort -z
    find . -mindepth 1 \( \( "${skip[@]}" \) -o \( "${is_repo[@]}" \) \) -prune -o \( "${is_deps[@]}" \) -printf 'dependencies\t%P\0' -prune | sort -z
    # A directory never holds more files than its parent, so the outermost crowded directories are
    # among the top-level ones.
    while IFS= read -r -d '' dir; do
      (($(walk "./$dir" ! -type d -printf . | wc -c) > 200)) || continue
      printf 'over 200 files\t%s\0' "$dir"
      skip_path "$dir"
    done < <(find . -mindepth 1 -maxdepth 1 -type d ! \( \( "${skip[@]}" \) -o \( "${is_repo[@]}" \) -o \( "${is_deps[@]}" \) \) -printf '%P\0' | sort -z)
    walk . -type l -printf 'link\t%P\0' | sort -z
    walk . -type f "${is_image[@]}" -printf 'image\t%P\0' | sort -z
    walk . -type f ! \( "${is_image[@]}" \) -size +1048576c -printf 'over 1 MiB\t%P\0' | sort -z
    walk . -type f ! \( "${is_image[@]}" \) -size -1048577c -printf '%P\0' |
      secret_paths | sort | tr '\n' '\0' | sed -z 's/^/may hold a secret\t/'
  )
}

# The rsync rule, NUL-terminated (for --from0), that matches the relative <path> alone, anchored
# at the transfer's root: rsync reads backslash escapes only in a rule with a wildcard, so in one
# with a wildcard every wildcard and backslash is escaped: rsync_rule <path>
rsync_rule() {
  local path=$1
  if [[ $path == *[*?[]* ]]; then
    path=${path//\\/"\\\\"} path=${path//\*/"\\*"} path=${path//\?/"\\?"} path=${path//\[/"\\["}
  fi
  printf '/%s\0' "$path"
}

# Mirror the task directory <dir> of a worktree of <project> into <archive> under the team home
# (tasks/T<n>/scratch or tasks/T<n>/scratch-<project>), so the archive is the task directory as
# it is now, less what archive_left_out names, each named on stderr as "left out of <archive>:
# <path> (<why>)", and removed from an archive made before it was left out. A missing or empty
# task directory archives nothing and is reported on stderr, failing:
# archive_task_dir <dir> <project> <archive>
archive_task_dir() {
  local dir=$1 why path rules
  if [[ ! -d $dir ]]; then
    echo "${0##*/}: $dir is missing, so nothing was archived from $2" >&2
    return 1
  elif [[ -z $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo "${0##*/}: $dir is empty, so nothing was archived from $2" >&2
    return 1
  fi
  rules=$(mktemp)
  while IFS=$'\t' read -r -d '' why path; do
    echo "${0##*/}: left out of $3: $path ($why)" >&2
    rsync_rule "$path" >>"$rules"
  done < <(archive_left_out "$dir")
  mkdir -p "$TEAM_HOME/$3"
  if ! rsync -a --delete --delete-excluded --from0 --exclude-from="$rules" -- "$dir/" "$TEAM_HOME/$3/"; then
    rm -f "$rules"
    die "cannot mirror $dir into $3"
  fi
  rm -f "$rules"
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

# The directories the tools of bin/lib/tools.lock are installed into on this OS, in the lock's
# order, one per line, whether or not they exist (tool_dirs in bin/lib/tools.jq): nvm's under
# NVM_DIR, else ~/.nvm, and Homebrew's under the prefix bin/lib/platform.sh found. None without jq
# (a fresh machine's preflight) or on an OS the team does not run on. Test seam: TEAM_SYSTEM_ROOT
# stands for / in a system directory (treehouse's /usr/local/bin on Arch), so the test sandbox,
# which sets it, never puts the machine's own system tools (its 1Password CLI) back on a PATH a
# test trimmed.
tool_dirs() {
  local os
  command -v jq >/dev/null && os=$(team_os) || return 0
  jq -L "$TEAM_LIB" -r --arg os "$os" --arg home "$HOME" --arg nvm "${NVM_DIR:-$HOME/.nvm}" \
    --arg brew "$TEAM_BREW_PREFIX" --arg root "${TEAM_SYSTEM_ROOT:-}" \
    'include "tools"; tool_dirs($os; $home; $nvm; $brew; $root)' "$TEAM_LIB/tools.lock"
}

# Put the tool directories that exist on PATH, exported, so every script, the sessions it starts
# and the tools they run find the pinned tools whatever shell called them: those under HOME or
# Homebrew's prefix first, right after Homebrew's GNU tools, once; a system directory (treehouse's
# /usr/local/bin on Arch) keeps its place, or comes last when PATH lacks it; TEAM_PATH_FIRST, when
# set, goes before all of them (bin/lib/platform.sh). The library runs it once; team-bootstrap
# again after each install.
team_tool_path() {
  local dir front='' back=''
  team_path_without_first
  while IFS= read -r dir; do
    [[ -d $dir ]] || continue
    if [[ $dir == "$HOME"/* || (-n $TEAM_BREW_PREFIX && $dir == "$TEAM_BREW_PREFIX"/*) ]]; then
      front+=$dir:
    elif [[ :$PATH: != *:"$dir":* ]]; then
      back+=:$dir
    fi
  done < <(tool_dirs)
  front=$TEAM_PLATFORM_FRONT$front
  [[ $PATH == "$front"* ]] || PATH=$front${PATH#"$TEAM_PLATFORM_FRONT"}
  PATH+=$back
  [[ -z ${TEAM_PATH_FIRST:-} ]] || PATH=$TEAM_PATH_FIRST:$PATH
  export PATH
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

# Print the hold while the team holds offline (team-timers' ~/.local/state/agent-team/offline,
# {"since": "<UTC time>", ...}, dated from its modification time without one): "GitHub is
# unreachable (since 13:05); the team is holding: commit locally, write handoff.md, send T<n>
# PAUSED offline, and wait.", or fail when it does not hold. The lease-fence hook and
# team-thread wait give it: offline_hold
offline_hold() {
  local file=$HOME/.local/state/agent-team/offline since
  [[ -e $file ]] || return 1
  since=$(jq -er '.since | strings' "$file" 2>/dev/null) || since=$(date -u -r "$file" +%FT%TZ)
  echo "GitHub is unreachable (since $(date -d "$since" +%H:%M)); the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait."
}

# Print why this machine must not <does> ("posts nothing to Discord; ..."), or fail when it may:
# "<machine> is fenced since ...: a fenced machine <does>" (fence_reason), else "<machine> no
# longer holds the lease: origin names <holder> (<state>, epoch <n>): a machine that lost the
# lease <does>", when the lease on origin is not this machine's last write (team-lease's
# lease.json) and names another holder or a higher epoch, so an old coordinator or worker acts on
# nothing the holder owns, even before its heartbeat fences it. Origin is asked at most once a
# minute (git ls-remote, cached in ~/.local/state/agent-team/probe.json: {"checked_at": "<UTC
# time>", "reachable": true, "tip": "<commit>"}); a machine with no name or no origin, or an
# unreachable origin, passes the lease part, since the heartbeat owns offline. The lease-fence
# hook and team-post call it: lease_refusal <does>
lease_refusal() {
  local machine named=1 why
  machine=$(machine_name 2>/dev/null) || machine="this machine" named=0
  if why=$(fence_reason); then
    printf '%s is %s: a fenced machine %s\n' "$machine" "$why" "$1"
  elif ((named)) && why=$(lease_lost "$machine"); then
    printf '%s: a machine that lost the lease %s\n' "$why" "$1"
  else
    return 1
  fi
}

# Print why this session may not <does> on Discord, or fail when it may: a worker session (its
# settings' AGENT_TEAM_ROLE names a role other than the coordinator; Daniel's own shell and the
# heartbeat set none) may not, except a planner on its own task (its settings' AGENT_TEAM_TASK)
# when the caller passes --interview, for the interview thread's post and wait. Worker settings
# deny the same commands; this holds where a deny pattern misses a spelling:
# worker_refusal <task or ""> <does> [--interview]
worker_refusal() {
  local role=${AGENT_TEAM_ROLE:-} own=${AGENT_TEAM_TASK:-}
  [[ -n $role && $role != coordinator ]] || return 1
  if [[ ${3:-} == --interview && $role == planner ]]; then
    [[ -z $1 || $1 != "$own" ]] || return 1
    echo "a planner session of ${own:-no task} $2 for $1: a planner talks with Daniel only in its own task's interview thread"
  else
    echo "a $role session $2: that is the coordinator's; send it your message"
  fi
}

# Why <machine> no longer holds the lease on origin, or fail when it does or cannot tell
# (lease_refusal's lease part): lease_lost <machine>
lease_lost() {
  local state=$HOME/.local/state/agent-team NET_ERR=/dev/null NET_TIMEOUT=20 tip record lease
  git -C "$TEAM_HOME" remote get-url origin >/dev/null 2>&1 || return 1
  lease_origin_tip "$state/probe.json" || return 1
  tip=$LEASE_TIP
  [[ -n $tip ]] || return 1
  record=$(jq -c 'select(type == "object")' "$state/lease.json" 2>/dev/null) || record=''
  [[ -n $record ]] || record='{}'
  [[ $tip != "$(jq -r '.commit // empty' <<<"$record")" ]] || return 1
  # Fetched without moving a ref (no FETCH_HEAD, no refmap), so team-lease's refs are never raced.
  git -C "$TEAM_HOME" cat-file -e "$tip^{commit}" 2>/dev/null ||
    { ((LEASE_PROBED)) && origin_git -C "$TEAM_HOME" fetch -q --no-tags --no-write-fetch-head --refmap= origin refs/heads/lease; } ||
    return 1
  lease=$(git -C "$TEAM_HOME" show "$tip:lease.json" 2>/dev/null) || return 1
  jq -er --arg machine "$1" --argjson record "$record" '
    select(.holder != $machine or ($record.holder == $machine and .epoch > $record.epoch))
    | "\($machine) no longer holds the lease: origin names \(.holder) (\(.state), epoch \(.epoch))"' \
    <<<"$lease" 2>/dev/null
}

# Set LEASE_TIP to the tip of origin's lease branch (empty when there is none), from the probe
# file <probe> when it is at most a minute old, else from a new probe written there, and
# LEASE_PROBED to 1 when this call asked origin; fails when origin was unreachable. Network
# calls go through origin_git (NET_ERR and NET_TIMEOUT are the caller's): lease_origin_tip <probe>
lease_origin_tip() {
  local out reachable=true
  LEASE_PROBED=0
  if jq -e 'now - (.checked_at | fromdateiso8601) < 60' "$1" >/dev/null 2>&1; then
    LEASE_TIP=$(jq -er 'select(.reachable == true) | .tip // ""' "$1") || return 1
    return 0
  fi
  LEASE_PROBED=1
  out=$(origin_git -C "$TEAM_HOME" ls-remote origin refs/heads/lease) || reachable=false
  LEASE_TIP=${out%%[[:space:]]*}
  mkdir -p "$(dirname "$1")"
  jq -n --argjson reachable "$reachable" --arg tip "$LEASE_TIP" \
    '{checked_at: (now | floor | todate), reachable: $reachable} + if $reachable then {tip: $tip} else {} end' \
    >"$1.$$"
  mv -f "$1.$$" "$1"
  [[ $reachable == true ]]
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
  [[ -z $holder ]] || die "$holder holds the lease: run team-resume --wait here, then hand off there once it says this machine is ready"
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

# Whether the paths <a> and <b> name one file. Both existing, by identity (-ef), so two spellings
# of one directory are one: through a symlink, or in another case on a case-insensitive filesystem
# (APFS), where realpath keeps the case it is given. Neither existing (a slot not made yet), when
# their realpath -m has the same last name, as text, under one directory, so compared. One
# existing and the other not, or either empty, never: same_path <a> <b>
same_path() {
  local a b
  [[ -n $1 && -n $2 ]] || return 1
  [[ $1 -ef $2 ]] && return 0
  [[ ! -e $1 && ! -e $2 ]] || return 1
  a=$(realpath -m -- "$1") b=$(realpath -m -- "$2")
  [[ $a != / && ${a##*/} == "${b##*/}" ]] && same_path "$(dirname "$a")" "$(dirname "$b")"
}

# Run <command...> for at most <seconds>, or unbounded where there is no timeout (macOS
# without coreutils): bounded <seconds> <command...>
bounded() {
  if command -v timeout >/dev/null; then timeout "$@"; else "${@:2}"; fi
}

# Whether Claude Code trusts the root <path>, from a promptless background session named <name>
# started there, which it refuses in an untrusted root with "Workspace not trusted". The probe
# goes either way: the session it printed, and any session of its name (one an earlier probe
# left), are stopped and removed. Sets trust_verdict (trusted, untrusted, or unknown when the
# start printed no session id), trust_left (the sessions claude rm left), trust_rc and trust_out
# (the start's exit code and output): trust_probe <path> <name>
# shellcheck disable=SC2034 # trust_verdict is read by the caller
trust_probe() {
  local name=$2 ids id
  trust_rc=0 trust_left=()
  trust_out=$(cd "$1" && bounded 60 claude --bg --name "$name" 2>&1 </dev/null) || trust_rc=$?
  ids=$({
    [[ $trust_out == *"Workspace not trusted"* ]] || grep -oE '\b[0-9a-f]{8}\b' <<<"$trust_out" | head -n 1
    bounded 30 claude agents --json 2>/dev/null </dev/null | jq -r --arg name "$name" 'arrays | .[] | objects
      | select(.name == $name) | .id // ((.sessionId // "")[:8]) | strings' 2>/dev/null || true
  } | awk 'NF && !seen[$0]++')
  for id in $ids; do
    bounded 30 claude stop "$id" >/dev/null 2>&1 </dev/null || true
    bounded 30 claude rm "$id" >/dev/null 2>&1 </dev/null || trust_left+=("$id")
  done
  if [[ $trust_out == *"Workspace not trusted"* ]]; then
    trust_verdict=untrusted
  elif ((trust_rc == 0)) && [[ -n $ids ]]; then
    trust_verdict=trusted
  else
    trust_verdict=unknown
  fi
}

# The treehouse pool of the primary checkout <primary>, as `treehouse status --json` run there
# reports it: one compact {path, status, holder} per slot, path its real path and holder its lease
# holder ("" while nobody leases it; status leased, available, dirty or another of treehouse's).
# Fails, printing nothing, when treehouse does not answer within 30 s with a JSON array: pool_status <primary>
pool_status() {
  local out path resolved=()
  out=$(cd "$1" && bounded 30 treehouse status --json 2>/dev/null </dev/null) ||
    return 1
  jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || return 1
  out=$(jq -c '.[] | objects | {path: (.path | strings), status: (.status // ""), holder: (.lease_holder // "")}' <<<"$out")
  while IFS= read -r path; do resolved+=("$(realpath -m -- "$path")"); done < <(jq -r .path <<<"$out")
  jq -cn '[inputs] as $slots | $ARGS.positional as $real | range($slots | length) | $slots[.] + {path: $real[.]}' \
    --args "${resolved[@]}" <<<"$out"
}

# Of the pool's slots <slot>..., the one that is <path>, as the registry spells it; fails, printing
# nothing, when <path> is none of them: pool_slot <path> <slot>...
pool_slot() {
  local slot
  for slot in "${@:2}"; do
    if same_path "$slot" "$1"; then echo "$slot" && return 0; fi
  done
  return 1
}

# A treehouse pool's slots: its registered slots <slot>..., then each other <dir>/<n>/<folder> that
# exists (<n> a number) beside a registered <dir>/<m>/<folder>, by number. treehouse numbers a new
# slot past a folder it finds in the way, an empty one too, so the registry may not list every
# slot it makes: treehouse_slots <slot>...
treehouse_slots() {
  local slot found extra=()
  for slot in "$@"; do
    echo "$slot"
    for found in "${slot%/*/*}"/*/"${slot##*/}"; do
      [[ -d $found && $(basename "${found%/*}") =~ ^[0-9]+$ ]] || continue
      pool_slot "$found" "$@" "${extra[@]}" >/dev/null || extra+=("$found")
    done
  done
  ((${#extra[@]} == 0)) || printf '%s\n' "${extra[@]}" | awk -F/ '{ print $(NF - 1) "\t" $0 }' | sort -n -k1,1 | cut -f2-
}

# The slot of the pool <pool> (pool_status' lines) that is the path <path>; fails, printing
# nothing, when none is: pool_entry <pool> <path>
pool_entry() {
  local entry
  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    if same_path "$(jq -r .path <<<"$entry")" "$2"; then echo "$entry" && return 0; fi
  done <<<"$1"
  return 1
}

# What keeps the leased slot <slot> from taking a task, as team-open checks it: worktree_changes'
# lines, then "a non-empty task directory <task_dir>: <names>"; nothing when it is clean. Fails,
# printing why, when <slot> is no worktree of the primary checkout <primary>:
# slot_changes <primary> <slot> <task_dir>
slot_changes() {
  local primary=$1 slot=$2 task_dir=$3 common list
  common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "the leased slot $slot is not a git worktree"
    return 1
  }
  same_path "$common" "$(git -C "$primary" rev-parse --path-format=absolute --git-common-dir)" || {
    echo "the leased slot $slot is not a worktree of $primary"
    return 1
  }
  worktree_changes "$slot"
  if [[ -d $slot/$task_dir ]]; then
    list=$(find "$slot/$task_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd ' ')
    [[ -z $list ]] || echo "a non-empty task directory $task_dir: $list"
  fi
}

# Of the relative paths on stdin, NUL-separated, those that may hold a secret, one per line: a
# name that starts with .env or ends with .pem or .key, or a path that a secret file's target in
# the team home's machine/secrets.json ends with. A snapshot and a task directory's archive both
# leave them out: secret_paths
secret_paths() {
  local targets
  targets=$(jq -c '[.secrets[]?.target | strings]' "$TEAM_HOME/machine/secrets.json" 2>/dev/null) || targets='[]'
  jq -Rrs --argjson targets "$targets" 'split("\u0000")[] | select(. != "") | . as $path
    | select((split("/") | last | test("^\\.env|\\.(pem|key)$"))
      or any($targets[]; . == $path or endswith("/" + $path)))'
}

# The untracked files of the worktree <wt> that may hold a secret (secret_paths), one per line,
# which a snapshot leaves out (files git ignores are never in one): snapshot_left_out <wt>
snapshot_left_out() {
  git -C "$1" ls-files -z --others --exclude-standard | secret_paths
}

# The tree of the worktree <wt> as it is, uncommitted changes and untracked files included (files
# git ignores, and those snapshot_left_out names, are not), built in a copy of its index so the
# worktree's own index is never touched; it equals HEAD's tree when the worktree is clean:
# worktree_tree <wt>
worktree_tree() {
  local wt=$1 index copy tree
  index=$(git -C "$wt" rev-parse --path-format=absolute --git-path index) || return 1
  copy=$(mktemp)
  # A copy of the real index keeps what git knows of each file's state; with none, HEAD's.
  if [[ -f $index ]]; then cp "$index" "$copy"; else GIT_INDEX_FILE=$copy git -C "$wt" read-tree HEAD; fi
  if GIT_INDEX_FILE=$copy git -C "$wt" add -A &&
    snapshot_left_out "$wt" | GIT_INDEX_FILE=$copy git -C "$wt" update-index --force-remove --stdin &&
    tree=$(GIT_INDEX_FILE=$copy git -C "$wt" write-tree); then
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
# a clean worktree pushed as wip/<project>/<task>: is_snapshot <dir> <commit> <task>
is_snapshot() {
  local subject
  [[ $(git -C "$1" rev-list --parents -n 1 "$2" | wc -w) == 2 ]] || return 1
  subject=$(git -C "$1" log -1 --format=%s "$2")
  [[ $subject =~ ^wip:\ $3\ checkpoint\ on\ [a-z0-9-]+\ at\ [0-9T:-]+Z$ ]]
}

# The URL of the team home's origin, where team-checkpoint keeps each worktree's work in flight as
# wip/<project>/T<n>, so a snapshot never reaches a project's own origin, which may be public:
# wip_origin
wip_origin() {
  git -C "$TEAM_HOME" remote get-url origin 2>/dev/null || die "the team home $TEAM_HOME has no remote origin"
}

# The records as a reader's list: "ledger.jsonl, manual-steps.md, tasks/, ...".
records_list() {
  local globs
  globs=$(grep -v -e '^#' -e '^$' "$TEAM_LIB/records" | sed 's/\*\*$//' | paste -sd ,)
  printf '%s\n' "${globs//,/, }"
}

# The paths of the NUL-separated list on stdin that are records (bin/lib/records), one per line,
# in order: only_records
only_records() {
  local path record
  local -a records
  mapfile -t records < <(grep -v -e '^#' -e '^$' "$TEAM_LIB/records")
  while IFS= read -r -d '' path; do
    for record in "${records[@]}"; do
      # shellcheck disable=SC2053 # the record is a glob
      if [[ $path == $record ]]; then printf '%s\n' "$path" && break; fi
    done
  done
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

# The local paths in the way of moving <checkout> from HEAD to <commit>: changed there and here
# (staged, unstaged or untracked), on one line: in_the_way <checkout> <commit>
in_the_way() {
  local their_paths=()
  mapfile -d '' -t their_paths < <(git -C "$1" diff -z --name-only --no-renames HEAD "$2")
  ((${#their_paths[@]})) || return 0
  git -C "$1" -c core.quotePath=false status --porcelain --untracked-files=all -- "${their_paths[@]}" | cut -c4- | paste -sd ' '
}

# Fast-forward <branch>, the branch checked out in <checkout>, to origin's: fetch it, then move
# the branch, index and working tree, local changes that are not in the way staying as they are.
# FF_RESULT says what it did: "<branch> fast-forwarded to <sha>" or "<branch> is up to date at
# <sha>" (also when it is ahead of origin's, FF_AHEAD then counting the commits origin's lacks). On
# failure FF_REASON says why, and it returns 75 when origin cannot be fetched, 1 when origin has no
# <branch>, the branch has diverged from origin's or local changes are in the way. With --check it
# fetches and checks the same, but moves nothing: FF_RESULT is then "<branch> can fast-forward to
# <sha>" where it would have moved. The fetch goes through origin_git, so NET_ERR must name a file:
# fast_forward <checkout> <branch> [--check]
# shellcheck disable=SC2034 # FF_RESULT, FF_REASON and FF_AHEAD are the caller's to read
fast_forward() {
  local checkout=$1 branch=$2 check=${3:-} theirs way rc=0
  FF_RESULT='' FF_REASON='' FF_AHEAD=0
  origin_git -C "$checkout" fetch -q --no-write-fetch-head origin "+refs/heads/$branch:refs/remotes/origin/$branch" || rc=$?
  if ((rc)) && grep -q "couldn't find remote ref" "$NET_ERR"; then
    FF_REASON="origin has no $branch"
    return 1
  elif ((rc)); then
    FF_REASON="cannot fetch $branch: $(origin_reason "$rc")"
    return 75
  fi
  theirs=$(git -C "$checkout" rev-parse "refs/remotes/origin/$branch")
  if git -C "$checkout" merge-base --is-ancestor "$theirs" HEAD; then
    FF_RESULT="$branch is up to date at $(git -C "$checkout" rev-parse --short=7 HEAD)"
    FF_AHEAD=$(git -C "$checkout" rev-list --count "$theirs..HEAD")
    return 0
  fi
  if ! git -C "$checkout" merge-base --is-ancestor HEAD "$theirs"; then
    FF_REASON="$branch has diverged from origin's"
    return 1
  fi
  git -C "$checkout" update-index -q --refresh || true
  way=$(in_the_way "$checkout" "$theirs")
  if [[ -n $way ]]; then
    FF_REASON="local changes to $way are in the way"
    return 1
  fi
  if [[ -n $check ]]; then
    FF_RESULT="$branch can fast-forward to ${theirs:0:7}"
    return 0
  fi
  if ! git -C "$checkout" merge -q --ff-only "$theirs" >/dev/null 2>"$NET_ERR"; then
    FF_REASON=$(grep -m1 . "$NET_ERR" | sed -E 's/^(fatal|error): //')
    return 1
  fi
  FF_RESULT="$branch fast-forwarded to ${theirs:0:7}"
}

# Bring <checkout> level with origin's <base> (fast_forward) when it is on <base>, has no local
# changes to tracked files and has no commits origin's lacks, untracked files aside unless in the
# way. FF_RESULT then says what it did; else it returns 1, moving nothing, with the reason in
# FOLLOW_REASON ("it is on <branch>, not <base>", "it has local changes to <paths>", "<base> has
# <n> commits origin's lacks", or fast_forward's). NET_ERR must name a file:
# follow_base <checkout> <base>
# shellcheck disable=SC2034 # FOLLOW_REASON is the caller's to read
follow_base() {
  local on changes s
  FOLLOW_REASON=''
  if ! on=$(git -C "$1" symbolic-ref -q --short HEAD); then
    FOLLOW_REASON="it is on a detached HEAD, not $2"
  elif [[ $on != "$2" ]]; then
    FOLLOW_REASON="it is on $on, not $2"
  elif changes=$(git -C "$1" -c core.quotePath=false status --porcelain --untracked-files=no | cut -c4- | paste -sd ' ') &&
    [[ -n $changes ]]; then
    FOLLOW_REASON="it has local changes to $changes"
  elif ! fast_forward "$1" "$2"; then
    FOLLOW_REASON=$FF_REASON
  elif ((FF_AHEAD)); then
    s=s
    ((FF_AHEAD > 1)) || s=''
    FOLLOW_REASON="$2 has $FF_AHEAD commit$s origin's lacks"
  fi
  [[ -z $FOLLOW_REASON ]]
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
    way=$(in_the_way "$TEAM_HOME" "$onto")
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

# The Discord channel under which each interviewed task's interview thread is opened: Daniel's,
# kept out of the plugin's access.json groups, so the plugin delivers none of its messages to the
# coordinator (it keys a thread on its parent). TEAM_INTERVIEW_CHANNEL overrides it, an empty one
# included, which the scripts refuse as none set.
# shellcheck disable=SC2034 # read by the scripts that source this library
INTERVIEW_CHANNEL=${TEAM_INTERVIEW_CHANNEL-1565336720998928556}

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

# Read Daniel's word from Discord: message <id> from the first of the places that has it, through
# discord_api, its author one of Daniel's ids (the top-level allowFrom of the Discord plugin's
# ~/.claude/channels/discord/access.json), so a decision of theirs is read from Discord, never
# taken on a model's word. Each place is a name ending in its channel id, as "#coordinator 1562...".
# Prints {place, channel, who: "<username> (<author id>)", message: <Discord's message>}. Fails
# with the one reason on stderr: no allowFrom or no token ("..., so <what> cannot be checked"),
# no place has the message (each place's error), or its author is not in allowFrom.
# daniel_message <message id> <what> <place>...
daniel_message() {
  local message=$1 what=$2 allow found='' place reply miss misses=() tried who
  allow=$(jq -ce '.allowFrom | select(type == "array") | map(tostring)' \
    "$HOME/.claude/channels/discord/access.json" 2>/dev/null) || {
    echo "cannot read allowFrom from ~/.claude/channels/discord/access.json, so $what cannot be checked" >&2
    return 1
  }
  discord_token >/dev/null || {
    echo "no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, so $what cannot be checked" >&2
    return 1
  }
  miss=$(mktemp)
  for place in "${@:3}"; do
    if reply=$(discord_api "channels/${place##* }/messages/$message" 2>"$miss") &&
      jq -e --arg m "$message" 'type == "object" and .id == $m and (.author.id | type) == "string"' <<<"$reply" >/dev/null 2>&1; then
      found=$place
      break
    fi
    misses+=("$(grep -m1 . "$miss" || echo "not that message")")
  done
  rm -f "$miss"
  if [[ -z $found ]]; then
    tried=$(printf '%s\n' "${@:3}" | sed '$!s/$/ or/' | paste -sd ' ')
    echo "Discord message $message cannot be fetched from $tried: $(printf '%s\n' "${misses[@]}" | sort -u | paste -sd ';' | sed 's/;/; /g')" >&2
    return 1
  fi
  who="$(jq -r '.author.username // "unknown"' <<<"$reply") ($(jq -r '.author.id' <<<"$reply"))"
  if jq -e --argjson allow "$allow" '.author.id as $a | $allow | index($a) | not' <<<"$reply" >/dev/null; then
    echo "Discord message $message is by $who, who is not in allowFrom of ~/.claude/channels/discord/access.json" >&2
    return 1
  fi
  jq -c --arg place "$found" --arg channel "${found##* }" --arg who "$who" \
    '{place: $place, channel: $channel, who: $who, message: .}' <<<"$reply"
}

# Bring the Waiting on you message in #coordinator up to date with this checkout's team-inbox, at
# the end of a script that changed what waits on Daniel; a failure is one line on stderr, "<script>:
# the Waiting on you message is not updated: <why>", and never the caller's: refresh_inbox
refresh_inbox() {
  local error
  error=$(TEAM_HOME=$TEAM_HOME "$TEAM_LIB/../team-inbox" 2>&1 >/dev/null) && return 0
  echo "${0##*/}: the Waiting on you message is not updated: $(grep -m 1 . <<<"$error" | sed 's/^team-inbox: //' || echo "team-inbox failed")" >&2
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

team_tool_path

if [[ -z ${team_home_report:-} && ! ($TEAM_HOME_FROM == none && -n ${team_home_unnamed:-}) ]]; then
  [[ -z $TEAM_HOME_PROBLEM ]] || die "$TEAM_HOME_PROBLEM"
  [[ -d $TEAM_HOME ]] || die "team home $TEAM_HOME is not a directory"
fi
