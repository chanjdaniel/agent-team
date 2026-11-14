# The launchers' shared parts, for the scripts that start one long-lived session of the team
# (claude-coordinator), sourced after team.sh:
#
#   # shellcheck source=bin/lib/launch.sh
#   source "$TEAM_LIB/launch.sh"
#
# Each refusal is the library's die (exit 1, prefixed with the script's name). It provides:
#   launch_lock <name>           takes a non-blocking flock on
#                                ~/.local/state/agent-team/<name>-launch.lock, held on the fd
#                                LAUNCH_LOCK_FD until the script exits, refusing at once while
#                                another launch holds it; LAUNCH_LOCK is its path.
#   launch_unlocked <command...> runs the command with the lock's file closed, so nothing it
#                                starts holds the next launch's lock; with no lock taken, runs it
#                                as it is.
#   launch_singleton <name>      refuses while `claude agents --json --all` lists a session named
#                                <name> in any state but stopped, naming its id.
#   launch_settings <template> <mcp template> <out settings> <out mcp> [@<KEY>@=<value>...]
#                                writes the session's MCP config and settings, the servers its
#                                list names but its own denied.
#
# The lock only serialises launches: `claude --bg` returns at once, so the session list, not the
# lock, says whether a session is alive. Each function after launch_lock runs what it calls with
# the lock's file closed.
# shellcheck shell=bash

# The team's state directory, where the locks and the written settings live.
LAUNCH_STATE=$HOME/.local/state/agent-team

# launch_lock <name>: takes ~/.local/state/agent-team/<name>-launch.lock without waiting, on the
# fd LAUNCH_LOCK_FD, kept open until the script exits; dies "another <script> is launching right
# now (it holds <lock>)" while another launch holds it.
launch_lock() {
  LAUNCH_LOCK=$LAUNCH_STATE/$1-launch.lock
  mkdir -p "$LAUNCH_STATE"
  exec {LAUNCH_LOCK_FD}>"$LAUNCH_LOCK"
  flock -n "$LAUNCH_LOCK_FD" || die "another ${0##*/} is launching right now (it holds $LAUNCH_LOCK)"
}

# launch_unlocked <command...>: runs the command, a function or a program, with the lock's file
# closed, so no process it leaves running (a git helper, the session itself) holds the lock.
launch_unlocked() {
  if [[ -n ${LAUNCH_LOCK_FD:-} ]]; then
    "$@" {LAUNCH_LOCK_FD}>&-
  else
    "$@"
  fi
}

# launch_singleton <name>: dies "a(n) <name> is already live: session <id>; stop it with claude
# stop <id> first" while a session named exactly <name> is in any state but stopped, and "cannot
# read the session list (claude agents --json --all)" when the list is not a JSON array.
# Without --all, the list leaves out a background session with no process that is neither
# working nor blocked, as one is once its turn ends (done) or it failed and the daemon settles its
# process, though a message or a finished shell of its wakes it. --all lists every job the daemon
# still keeps, so only a stopped one, which nothing wakes on its own, is gone. The id is the
# job's, else the first 8 characters of its session id.
launch_singleton() {
  local name=$1 sessions live article=a
  sessions=$(launch_unlocked claude agents --json --all | jq -ce 'select(type == "array")' 2>/dev/null) ||
    die "cannot read the session list (claude agents --json --all)"
  live=$(jq -r --arg name "$name" 'map(select(.name == $name and .state != "stopped")) | first
    | if . then .id // ((.sessionId // "")[:8]) else empty end' <<<"$sessions")
  [[ $name != [aeiouAEIOU]* ]] || article=an
  [[ -z $live ]] || die "$article $name is already live: session $live; stop it with claude stop $live first"
}

# launch_settings <template> <mcp template> <out settings> <out mcp> [@<KEY>@=<value>...]:
# writes <out mcp>, the MCP template, and <out settings>, the settings template with
# deniedMcpServers set, each written whole and then moved into place. In every string of both,
# @TEAM_CODE@ names this checkout, and each extra @<KEY>@ its value.
# The servers denied are every one that `claude mcp list`, run in the working directory, names,
# but the MCP template's own, those of a plugin the settings enable (plugin:<plugin>:<server>),
# and the claude.ai connectors the connectors.json beside the MCP template keeps, by exact name
# (none without one). Each line of the list is "<name>: <what it runs> - <health>", and a name
# holds no ": ". Dies when the list fails, and when it printed a line but named no server in its
# format, naming its first line, since a changed format would deny nothing; an empty list, or
# Claude Code's "No MCP servers configured." line, denies none. The list's health check starts
# the servers, so they get no lock.
launch_settings() {
  local template=$1 mcp_template=$2 settings=$3 mcp=$4 code listed line first='' empty='' pair subs kept
  local -a servers=() named=()
  shift 4
  code=$(dirname "$(dirname "$TEAM_LIB")")
  named=(--arg @TEAM_CODE@ "$code")
  for pair; do
    [[ $pair =~ ^(@[A-Z_]+@)=(.*)$ ]] || die "launch_settings: not a substitution @<KEY>@=<value>: $pair"
    named+=(--arg "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
  done
  # {placeholder: value}, each placeholder replaced as written, not as a pattern.
  subs=$(jq -cn '$ARGS.named' "${named[@]}")
  local substitute='walk(if type == "string"
    then reduce ($subs | to_entries[]) as $s (.; split($s.key) | join($s.value)) else . end)'

  jq --argjson subs "$subs" "$substitute" "$mcp_template" >"$mcp.$$"
  mv -f "$mcp.$$" "$mcp"

  listed=$(launch_unlocked claude mcp list) || die "claude mcp list failed, so the servers to deny are unknown"
  while IFS= read -r line; do
    if [[ $line =~ ^(([^:]|:[^ ])+):\ .+\ -\ .+$ ]]; then servers+=("${BASH_REMATCH[1]}"); fi
    [[ -n $first || $line != *[![:space:]]* ]] || first=$line
    [[ $line != 'No MCP servers configured.'* ]] || empty=1
  done <<<"$listed"
  # A list whose lines name no server is one this parse cannot read, unless it says it is empty.
  [[ ${#servers[@]} -gt 0 || -z $first || -n $empty ]] ||
    die "claude mcp list printed lines but named no server in its format (\"<name>: <what it runs> - <health>\"), so the servers to deny are unknown; its first line: $first"

  kept='[]'
  [[ ! -e ${mcp_template%/*}/connectors.json ]] || kept=$(jq -c . "${mcp_template%/*}/connectors.json")
  jq --argjson subs "$subs" --slurpfile mcp "$mcp" --argjson connectors "$kept" \
    "$substitute"' as $settings
    | (($mcp[0].mcpServers // {} | keys) + $connectors) as $own
    | [$settings.enabledPlugins // {} | to_entries[] | select(.value == true) | "plugin:\(.key | split("@")[0]):"] as $plugins
    | $settings
    | .deniedMcpServers = [$ARGS.positional | unique[]
        | select(. as $name | (IN($own[]) | not) and all($plugins[]; . as $p | $name | startswith($p) | not))
        | {serverName: .}]' "$template" --args "${servers[@]}" >"$settings.$$"
  mv -f "$settings.$$" "$settings"
}
