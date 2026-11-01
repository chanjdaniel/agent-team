# The stow steps team-handoff and team-stow share, sourced after team.sh by both:
#
#   source "$TEAM_LIB/stow.sh"
#
# The caller sets machine (machine_name), err (a file each sibling's stderr goes to), NET_ERR and
# NET_TIMEOUT (origin_git's), STOW_UNDONE (what a refusal of the run adds: "; nothing was
# released"), and STOW_ELSEWHERE and STOW_BY_TASK as stow_end_ops and stow_session_prefix say,
# and defines team <script> <arguments...> (a sibling of this checkout run with TEAM_HOME) and
# first_error (the first line of $err without its "<script>: " prefix). It provides:
#   stow_open [T<n>...]          STOW_OPEN, one {task, worktrees: [{project, branch, worktree}]}
#                                per open task in task number order: the named ones, or all.
#   stow_branches [quiet]        checks each STOW_OPEN task's branches against origin's.
#   stow_push                    pushes STOW_PUSHES.
#   stow_live [T<n>...]          STOW_LIVE, the live worker sessions of those tasks, or of all.
#   stow_end_ops                 ends STOW_LIVE's ops sessions with team-ops-end, STOW_ENDED.
#   stow_stop                    stops and removes STOW_LIVE's other sessions.
#   stow_record <task> <workers> [<cause>]
#                                logs the task's stowed, unless it is stowed already.
# A failure of one task is kept as STOW_REFUSED[<task>]=<reason>, which the caller turns into a
# refusal of the whole handoff (team-handoff) or of that task alone (team-stow).
# shellcheck shell=bash disable=SC2154 # machine and err are the caller's

# A team worker's session name.
STOW_WORKER='^T[0-9]+-[a-z][a-z0-9-]*$'
declare -gA STOW_REFUSED=() STOW_WORKTREES=() STOW_NOTES=()
STOW_OPEN=() STOW_PUSHES=() STOW_PROBLEMS=() STOW_STOPPED=()
STOW_LIVE='[]'

stow_open() {
  STOW_OPEN=()
  [[ -e $TEAM_HOME/ledger.jsonl ]] || return 0
  mapfile -t STOW_OPEN < <(ledger_jq 'ledger_events | by_task | . as $tasks | open_tasks[]
      | select($named == [] or IN($named[]; .))
      | {task: ., worktrees: [open_worktrees($tasks[.][]; $home) | {project, branch, worktree}]}' \
    -nRc --argjson named "$(jq -cn '$ARGS.positional' --args -- "$@")" "$TEAM_HOME/ledger.jsonl")
}

# A line of stow_branches, unless it is quiet.
stow_say() {
  ((STOW_QUIET)) || printf '%s\n' "$*"
}

# The task branches of STOW_OPEN, every one checked before any is pushed, with nothing printed
# but a refusal when <quiet> is 1: each task's stowed worktrees in STOW_WORKTREES, its notes in
# STOW_NOTES, the branches to push in STOW_PUSHES ("<label>\t<repo>\t<branch>\t<head>"); a branch
# that is neither here nor on origin, or has diverged from origin's, refuses its task
# (STOW_REFUSED, and "<task>: <reason>" in STOW_PROBLEMS). An origin that cannot be read refuses
# the run (die). stow_branches [quiet]
stow_branches() {
  STOW_QUIET=${1:-0}
  local entry task list note project branch wt label repo mine rc remote origin_head head
  local uncommitted left problem
  STOW_WORKTREES=() STOW_NOTES=() STOW_PROBLEMS=() STOW_PUSHES=()
  for entry in "${STOW_OPEN[@]}"; do
    task=$(jq -r .task <<<"$entry")
    list='[]' note=''
    while IFS=$'\t' read -r project branch wt; do
      label="$task $project"
      repo=$wt
      git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || repo=$(team_project "$project" path)
      mine=$(git -C "$repo" rev-parse -q --verify "refs/heads/$branch^{commit}") || mine=''
      rc=0
      remote=$(origin_git -C "$repo" ls-remote origin "refs/heads/$branch") || rc=$?
      ((rc == 0)) || die "$label: cannot read $branch on origin: $(origin_reason "$rc")$STOW_UNDONE"
      origin_head=${remote%%[[:space:]]*}
      if [[ -n $origin_head ]] && ! git -C "$repo" cat-file -e "$origin_head^{commit}" 2>/dev/null; then
        origin_git -C "$repo" fetch -q --no-write-fetch-head origin "+refs/heads/$branch:refs/remotes/origin/$branch" || rc=$?
        ((rc == 0)) || die "$label: cannot fetch $branch from origin: $(origin_reason "$rc")$STOW_UNDONE"
      fi
      head=$origin_head problem=''
      if [[ -z $mine && -z $origin_head ]]; then
        problem="$branch ($project) is neither here nor on origin"
      elif [[ -z $mine ]]; then
        stow_say "branches: $label: $branch is not here; origin has it at ${origin_head:0:7}"
      elif [[ $mine == "$origin_head" ]]; then
        stow_say "branches: $label: $branch is on origin at ${mine:0:7}"
      elif [[ -z $origin_head ]] || git -C "$repo" merge-base --is-ancestor "$origin_head" "$mine"; then
        head=$mine
        STOW_PUSHES+=("$label"$'\t'"$repo"$'\t'"$branch"$'\t'"$mine")
      elif git -C "$repo" merge-base --is-ancestor "$mine" "$origin_head"; then
        stow_say "branches: $label: origin's $branch is ahead of this machine's, at ${origin_head:0:7}"
      else
        problem="$branch ($project) has diverged from origin: $(git -C "$repo" rev-list --count "$origin_head..$mine") commits here and $(git -C "$repo" rev-list --count "$mine..$origin_head") there"
      fi
      if [[ -n $problem ]]; then
        STOW_PROBLEMS+=("$task: $problem")
        [[ -n ${STOW_REFUSED[$task]:-} ]] || STOW_REFUSED[$task]=$problem
        continue
      fi
      uncommitted=false
      if ((!STOW_QUIET)) && [[ -d $wt && -n $(worktree_changes "$wt") ]]; then
        if stow_kept_in_wip "$task" "$project" "$wt"; then
          uncommitted=true
          stow_say "branches: $label: uncommitted changes in $wt go with the checkpoint's wip/$project/$task, which team-resume applies"
        else
          stow_say "branches: $label: uncommitted changes in $wt stay on $machine: the checkpoint's wip/$project/$task does not hold them"
          note+="uncommitted changes in $wt stay on $machine; "
        fi
        left=$(snapshot_left_out "$wt" | paste -sd ' ')
        if [[ -n $left ]]; then
          stow_say "branches: $label: untracked files that may hold a secret, left out of wip/$project/$task, stay on $machine: $left"
          note+="untracked files left out of wip/$project/$task stay on $machine in $wt: $left; "
        fi
      fi
      list=$(jq -c --arg p "$project" --arg b "$branch" --arg h "$head" --argjson u "$uncommitted" \
        '. + [{project: $p, branch: $b, head: $h} + if $u then {uncommitted: true} else {} end]' <<<"$list")
    done < <(jq -r '.worktrees[] | [.project, .branch, .worktree] | @tsv' <<<"$entry")
    STOW_WORKTREES[$task]=$list
    STOW_NOTES[$task]=${note%; }
  done
}

# Whether wip/<project>/<task> on the team home's origin is the checkpoint's snapshot of the
# worktree <wt> as it is now: a snapshot whose parent is its HEAD and whose tree is its tree:
# stow_kept_in_wip <task> <project> <wt>
stow_kept_in_wip() {
  local task=$1 project=$2 wt=$3 url remote wip
  url=$(wip_origin) || return 1
  remote=$(origin_git -C "$wt" ls-remote "$url" "refs/heads/wip/$project/$task") || return 1
  wip=${remote%%[[:space:]]*}
  [[ -n $wip ]] && git -C "$wt" cat-file -e "$wip^{commit}" 2>/dev/null && is_snapshot "$wt" "$wip" "$task" &&
    [[ $(git -C "$wt" rev-parse "$wip^1") == "$(git -C "$wt" rev-parse HEAD)" ]] &&
    [[ $(git -C "$wt" rev-parse "$wip^{tree}") == "$(worktree_tree "$wt")" ]]
}

# Push each of STOW_PUSHES, saying each; one that fails refuses its task (STOW_REFUSED), and the
# others are still pushed.
stow_push() {
  local push label repo branch mine rc
  for push in "${STOW_PUSHES[@]}"; do
    IFS=$'\t' read -r label repo branch mine <<<"$push"
    [[ -z ${STOW_REFUSED[${label%% *}]:-} ]] || continue
    rc=0
    origin_git -C "$repo" push -q origin "refs/heads/$branch:refs/heads/$branch" || rc=$?
    if ((rc)); then
      STOW_REFUSED[${label%% *}]="cannot push $branch: $(origin_reason "$rc")"
      continue
    fi
    echo "branches: $label: pushed $branch at ${mine:0:7}"
  done
}

# The live worker sessions (claude agents --json) of the tasks named, or of every task, ops
# included, into STOW_LIVE as one JSON array: stow_live [T<n>...]
stow_live() {
  local sessions
  sessions=$(claude agents --json 2>"$err" | jq -ce 'select(type == "array")' 2>/dev/null) ||
    die "cannot read the live session list (claude agents --json)"
  STOW_LIVE=$(jq -c --arg pattern "$STOW_WORKER" --argjson named "$(jq -cn '$ARGS.positional' --args -- "$@")" \
    '[.[] | select(.name | strings | test($pattern))
      | select($named == [] or IN($named[]; .name | sub("-.*"; "")))]' <<<"$sessions")
}

# The prefix of a session step's line about <name>: "sessions: " for team-handoff, "sessions:
# T<n>: " when STOW_BY_TASK is 1, for team-stow.
STOW_BY_TASK=0
stow_session_prefix() {
  if ((STOW_BY_TASK)); then printf 'sessions: %s: ' "${1%%-*}"; else printf 'sessions: '; fi
}

# End each ops session of STOW_LIVE with team-ops-end (an ops session holds production query
# results: ended, never stowed), then take them off STOW_LIVE; STOW_ENDED says whether any was
# ended, and one that cannot be ended refuses its task. The line ends with STOW_ELSEWHERE (" on
# the other machine" for a handoff).
stow_end_ops() {
  local name
  # shellcheck disable=SC2034 # STOW_ENDED is the caller's to read
  STOW_ENDED=0
  while read -r name; do
    if team team-ops-end "${name%-ops}" </dev/null >/dev/null 2>"$err"; then
      echo "$(stow_session_prefix "$name")ended $name with team-ops-end, its transcript and answer deleted; if its answer had not reached Daniel, Daniel asks again${STOW_ELSEWHERE:-}"
      # shellcheck disable=SC2034 # STOW_ENDED is the caller's to read
      STOW_ENDED=1
    else
      STOW_REFUSED[${name%-ops}]="could not end $name with team-ops-end ($(first_error))"
    fi
  done < <(jq -r '.[].name | select(test("^T[0-9]+-ops$"))' <<<"$STOW_LIVE")
  STOW_LIVE=$(jq -c '[.[] | select(.name | test("^T[0-9]+-ops$") | not)]' <<<"$STOW_LIVE")
}

# Stop and remove each session of STOW_LIVE but those of a refused task, saying each; their names
# go in STOW_STOPPED. One that will not stop refuses its task; one stopped whose removal fails is
# said on stderr, and stays stopped.
stow_stop() {
  local id name task stop_ok rm_ok
  STOW_STOPPED=()
  while read -r id name; do
    task=${name%%-*}
    [[ -z ${STOW_REFUSED[$task]:-} ]] || continue
    stop_ok=1 rm_ok=1
    claude stop "$id" </dev/null >/dev/null 2>"$err" || stop_ok=''
    claude rm "$id" </dev/null >/dev/null 2>>"$err" || rm_ok=''
    if [[ -n $rm_ok ]]; then
      echo "$(stow_session_prefix "$name")stopped and removed $name ($id)"
      STOW_STOPPED+=("$name")
    elif [[ -n $stop_ok ]]; then
      echo "${0##*/}: $(stow_session_prefix "$name")stopped $name ($id), but claude rm failed ($(first_error)); remove it by hand" >&2
      STOW_STOPPED+=("$name")
    else
      STOW_REFUSED[$task]="could not stop $name ($id): $(first_error)"
    fi
  done < <(jq -r '.[] | "\(.id // ((.sessionId // "")[:8])) \(.name)"' <<<"$STOW_LIVE")
}

# Log one stowed for <task> from this machine (stow_branches' worktrees and notes for it, its
# unfinished roles, and as sessions the roles of <workers>, a JSON array of the session names
# stopped), with cause <cause> when given, and say it; none when the task's latest machine event
# (stowed, launch, worktree-moved) is already a stowed from this machine with the same
# worktrees: stow_record <task> <workers> [<cause>]
stow_record() {
  local task=$1 workers=$2 cause=${3:-} event
  event=$(task_events "$task" | ledger_jq '{ts: (now | todate), task: $task, event: "stowed", machine: $machine,
      worktrees: $worktrees, roles: unfinished_roles,
      sessions: [$workers[] | select(startswith("\($task)-")) | ltrimstr("\($task)-") | select(. != "ops")] | unique}
     + if $note == "" then {} else {note: $note} end
     + if $cause == "" then {} else {cause: $cause} end' \
    -sc --arg task "$task" --arg machine "$machine" --argjson worktrees "${STOW_WORKTREES[$task]}" \
    --argjson workers "$workers" --arg note "${STOW_NOTES[$task]:-}" --arg cause "$cause")
  if task_events "$task" | jq -se --argjson new "$event" \
    'map(select(.event | IN("stowed", "launch", "worktree-moved"))) | last
      | .event == "stowed" and .machine == $new.machine and .worktrees == $new.worktrees' >/dev/null; then
    echo "stowed: $task already stowed from $machine"
  else
    ledger_append "$event"
    echo "stowed: $task $(jq -r '"roles \(.roles | join(", ") | if . == "" then "none" else . end); " + ([.worktrees[] | "\(.project) \(.branch) at \(.head[:7])" + if .uncommitted then " with uncommitted changes" else "" end] | join(", ") | if . == "" then "no worktree" else . end) + if .cause then "; cause \(.cause)" else "" end' <<<"$event")"
  fi
}
