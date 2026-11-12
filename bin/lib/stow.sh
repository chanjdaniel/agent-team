# team-stow's steps, which team-handoff takes through team-stow, sourced after team.sh:
#
#   source "$TEAM_LIB/stow.sh"
#
# The caller sets machine (machine_name), err (a file each sibling's stderr goes to), NET_ERR and
# NET_TIMEOUT (origin_git's), and defines team <script> <arguments...> (a sibling of this
# checkout run with TEAM_HOME) and first_error (the first line of $err without its "<script>: "
# prefix). It provides:
#   stow_open [T<n>...]          STOW_OPEN, one {task, worktrees: [{project, branch, worktree,
#                                ticket}]} per open task in task number order: the named ones, or
#                                all; ticket is a ticket worktree's NN, else null.
#   stow_branches [quiet]        checks each STOW_OPEN task's branches against origin's, and each
#                                ticket worktree's work against its wip ref.
#   stow_push                    pushes STOW_PUSHES.
#   stow_live [T<n>...]          STOW_LIVE, the live worker sessions of those tasks, or of all.
#   stow_end_ops                 ends STOW_LIVE's ops sessions with team-ops-end, STOW_ENDED.
#   stow_stop                    stops and removes STOW_LIVE's other sessions.
#   stow_stowing <task>          the time of the task's stowing standing (a stow under way), or
#                                nothing with none.
#   stow_begin <task> <cause>    logs the task's stowing, unless one stands, and says it.
#   stow_record <task> <workers> [<cause>]
#                                logs the task's stowed, unless it is stowed already.
#   stow_fail <task> <reason>    logs the task's stow-failed, and says it.
# A failure of one task is kept as STOW_REFUSED[<task>]=<reason>, a refusal of that task alone.
# STOW_STOWING[<task>]=<since> holds each stowing standing that the run must end: stow_begin sets
# it, and stow_record and stow_fail unset it once they log the stowed or the stow-failed.
# shellcheck shell=bash disable=SC2154 # machine and err are the caller's

# A team worker's session name.
STOW_WORKER='^T[0-9]+-[a-z][a-z0-9-]*$'
declare -gA STOW_REFUSED=() STOW_WORKTREES=() STOW_NOTES=() STOW_STOWING=()
STOW_OPEN=() STOW_PUSHES=() STOW_PROBLEMS=() STOW_STOPPED=()
STOW_LIVE='[]'

stow_open() {
  STOW_OPEN=()
  [[ -e $TEAM_HOME/ledger.jsonl ]] || return 0
  mapfile -t STOW_OPEN < <(ledger_jq 'ledger_events | by_task | . as $tasks | open_tasks[]
      | select($named == [] or IN($named[]; .))
      | {task: ., worktrees: [open_worktrees($tasks[.][]; $home) | {project, branch, worktree, ticket}]}' \
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
# the run (die). A ticket worktree's branch is never pushed, nor read on origin: unless <quiet>,
# once the checkpoint has run, its wip/<project>/T<n>--NN on the team home's origin must hold its
# head, or its snapshot (stow_wip_holds), with the worktree on its ticket branch, or its task is
# refused as stow_ticket says. stow_branches [quiet]
stow_branches() {
  STOW_QUIET=${1:-0}
  local entry task list note project branch wt ticket label repo mine rc remote origin_head head
  local uncommitted left problem
  STOW_WORKTREES=() STOW_NOTES=() STOW_PROBLEMS=() STOW_PUSHES=()
  for entry in "${STOW_OPEN[@]}"; do
    task=$(jq -r .task <<<"$entry")
    list='[]' note=''
    while IFS=$'\t' read -r project branch wt ticket; do
      if [[ -n $ticket ]]; then
        ((STOW_QUIET)) || stow_ticket "$task" "$project" "$branch" "$wt" "$ticket"
        continue
      fi
      label="$task $project"
      repo=$wt
      git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || repo=$(team_project "$project" path)
      mine=$(git -C "$repo" rev-parse -q --verify "refs/heads/$branch^{commit}") || mine=''
      rc=0
      remote=$(origin_git -C "$repo" ls-remote origin "refs/heads/$branch") || rc=$?
      ((rc == 0)) || die "$label: cannot read $branch on origin: $(origin_reason "$rc"); nothing was stowed"
      origin_head=${remote%%[[:space:]]*}
      if [[ -n $origin_head ]] && ! git -C "$repo" cat-file -e "$origin_head^{commit}" 2>/dev/null; then
        origin_git -C "$repo" fetch -q --no-write-fetch-head origin "+refs/heads/$branch:refs/remotes/origin/$branch" || rc=$?
        ((rc == 0)) || die "$label: cannot fetch $branch from origin: $(origin_reason "$rc"); nothing was stowed"
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
    done < <(jq -r '.worktrees[] | [.project, .branch, .worktree, .ticket // ""] | @tsv' <<<"$entry")
    STOW_WORKTREES[$task]=$list
    STOW_NOTES[$task]=${note%; }
  done
}

# Whether wip/<project>/<task> on the team home's origin is the checkpoint's snapshot of the
# worktree <wt> as it is now: a snapshot whose parent is its HEAD and whose tree is its tree:
# stow_kept_in_wip <task> <project> <wt>
stow_kept_in_wip() {
  stow_wip_holds "$1" "wip/$2/$1" "$3" && [[ ${REPLY%% *} == snapshot ]]
}

# Whether the ref <wip> on the team home's origin holds the worktree <wt> as it is now, by the
# checkpoint's snapshot rule: its HEAD, with nothing uncommitted (but the files left out as
# secrets), REPLY head; or a snapshot of <task> whose parent is its HEAD and whose tree is its
# tree, REPLY snapshot; REPLY the ref's commit either way: stow_wip_holds <task> <wip> <wt>
stow_wip_holds() {
  local task=$1 wip=$2 wt=$3 url remote ref head tree
  REPLY=''
  url=$(wip_origin) || return 1
  remote=$(origin_git -C "$wt" ls-remote "$url" "refs/heads/$wip") || return 1
  ref=${remote%%[[:space:]]*}
  [[ -n $ref ]] && git -C "$wt" cat-file -e "$ref^{commit}" 2>/dev/null || return 1
  head=$(git -C "$wt" rev-parse HEAD) && tree=$(worktree_tree "$wt") || return 1
  if [[ $ref == "$head" && $tree == "$(git -C "$wt" rev-parse "$head^{tree}")" ]]; then
    REPLY='head'
  elif is_snapshot "$wt" "$ref" "$task" && [[ $(git -C "$wt" rev-parse "$ref^1") == "$head" ]] &&
    [[ $(git -C "$wt" rev-parse "$ref^{tree}") == "$tree" ]]; then
    REPLY=snapshot
  else
    return 1
  fi
  REPLY+=" $ref"
}

# The ticket worktree <wt> of <task>'s ticket <NN>, on its ticket branch <branch>, never pushed:
# kept when wip/<project>/<task>--<NN> on the team home's origin holds its work (stow_wip_holds)
# with the worktree on <branch>, added to the caller's list (with ticket, and uncommitted for a
# snapshot) and note, else its task refused ("<branch> (<project>, ticket <NN>) is not kept: ...").
# stow_ticket <task> <project> <branch> <wt> <NN>
stow_ticket() {
  local task=$1 project=$2 branch=$3 wt=$4 ticket=$5 label="$1 $2--$5" wip="wip/$2/$1--$5" mine kind ref
  local left problem
  if [[ -d $wt && $(git -C "$wt" symbolic-ref -q HEAD 2>/dev/null) == "refs/heads/$branch" ]] &&
    mine=$(git -C "$wt" rev-parse -q --verify "refs/heads/$branch^{commit}") && stow_wip_holds "$task" "$wip" "$wt"; then
    kind=${REPLY%% *} ref=${REPLY#* }
  else
    problem="$branch ($project, ticket $ticket) is not kept: $wip on the team home's origin does not hold the head and uncommitted changes of $wt on $branch, and a ticket branch is never pushed"
    STOW_PROBLEMS+=("$task: $problem")
    [[ -n ${STOW_REFUSED[$task]:-} ]] || STOW_REFUSED[$task]=$problem
    return 0
  fi
  if [[ $kind == snapshot ]]; then
    stow_say "branches: $label: $branch with its uncommitted changes in $wt is kept as $wip at ${ref:0:7}, never pushed"
  else
    stow_say "branches: $label: $branch is kept as $wip at ${ref:0:7}, never pushed"
  fi
  left=$(snapshot_left_out "$wt" | paste -sd ' ')
  if [[ -n $left ]]; then
    stow_say "branches: $label: untracked files that may hold a secret, left out of $wip, stay on $machine: $left"
    note+="untracked files left out of $wip stay on $machine in $wt: $left; "
  fi
  list=$(jq -c --arg p "$project" --arg b "$branch" --arg h "$mine" --arg t "$ticket" --argjson u "$([[ $kind == snapshot ]] && echo true || echo false)" \
    '. + [{project: $p, branch: $b, head: $h} + (if $u then {uncommitted: true} else {} end) + {ticket: $t}]' <<<"$list")
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

# The prefix of a session step's line about the session <name>: "sessions: T<n>: ".
stow_session_prefix() {
  printf 'sessions: %s: ' "${1%%-*}"
}

# End each ops session of STOW_LIVE with team-ops-end (an ops session holds production query
# results: ended, never stowed), then take them off STOW_LIVE; STOW_ENDED says whether any was
# ended, and one that cannot be ended refuses its task.
stow_end_ops() {
  local name
  # shellcheck disable=SC2034 # STOW_ENDED is the caller's to read
  STOW_ENDED=0
  while read -r name; do
    if team team-ops-end "${name%-ops}" </dev/null >/dev/null 2>"$err"; then
      echo "$(stow_session_prefix "$name")ended $name with team-ops-end, its transcript and answer deleted; if its answer had not reached Daniel, Daniel asks again"
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

# The ts of <task>'s stowing standing (the lifecycle fold's stow under way), or nothing with none:
# stow_stowing <task>
stow_stowing() {
  task_events "$1" | ledger_jq 'lifecycle | lifecycle_stowing | .since // empty' -sr
}

# Log a stowing of <task> from this machine (cause <cause>, roles its unfinished roles) unless one
# stands, saying "stowing: T<n> since <ts>", or "stowing: T<n> already since <ts>" with one
# standing; either way it is STOW_STOWING's, for the run to end: stow_begin <task> <cause>
stow_begin() {
  local task=$1 cause=$2 since event
  since=$(stow_stowing "$task")
  if [[ -n $since ]]; then
    echo "stowing: $task already since $since"
  else
    event=$(task_events "$task" | ledger_jq '{ts: (now | todate), task: $task, event: "stowing", machine: $machine,
        cause: $cause, roles: unfinished_roles}' -sc --arg task "$task" --arg machine "$machine" --arg cause "$cause")
    ledger_append "$event"
    since=$(jq -r .ts <<<"$event")
    echo "stowing: $task since $since"
  fi
  STOW_STOWING[$task]=$since
}

# Log a stow-failed of <task> from this machine with <reason>, in a subshell so a refused append
# is said and stops nothing (it runs from the caller's exit trap too), and say it:
# stow_fail <task> <reason>
stow_fail() {
  local task=$1 reason=$2 event
  event=$(jq -cn --arg task "$task" --arg machine "$machine" --arg reason "$reason" \
    '{ts: (now | todate), task: $task, event: "stow-failed", machine: $machine, reason: $reason}')
  if (ledger_append "$event"); then
    echo "stow-failed: $task: $reason"
  else
    echo "${0##*/}: stow-failed: $task: could not log it ($reason)" >&2
  fi
  unset 'STOW_STOWING[$task]'
}

# Log one stowed for <task> from this machine (stow_branches' worktrees and notes for it, its
# unfinished roles, and as sessions the roles of <workers>, a JSON array of the session names
# stopped), with cause <cause> when given, and say it; none when the task's latest machine event
# (stowed, launch, worktree-moved) is already a stowed from this machine with the same
# worktrees and no stowing of it stands (STOW_STOWING): stow_record <task> <workers> [<cause>]
stow_record() {
  local task=$1 workers=$2 cause=${3:-} event
  event=$(task_events "$task" | ledger_jq '{ts: (now | todate), task: $task, event: "stowed", machine: $machine,
      worktrees: $worktrees, roles: unfinished_roles,
      sessions: [$workers[] | select(startswith("\($task)-")) | ltrimstr("\($task)-") | sub("-[0-9]{2}$"; "")
        | select(. != "ops")] | unique}
     + if $note == "" then {} else {note: $note} end
     + if $cause == "" then {} else {cause: $cause} end' \
    -sc --arg task "$task" --arg machine "$machine" --argjson worktrees "${STOW_WORKTREES[$task]}" \
    --argjson workers "$workers" --arg note "${STOW_NOTES[$task]:-}" --arg cause "$cause")
  if [[ -z ${STOW_STOWING[$task]:-} ]] && task_events "$task" | jq -se --argjson new "$event" \
    'map(select(.event | IN("stowed", "launch", "worktree-moved"))) | last
      | .event == "stowed" and .machine == $new.machine and .worktrees == $new.worktrees' >/dev/null; then
    echo "stowed: $task already stowed from $machine"
  else
    ledger_append "$event"
    unset 'STOW_STOWING[$task]'
    echo "stowed: $task $(jq -r '"roles \(.roles | join(", ") | if . == "" then "none" else . end); " + ([.worktrees[] | "\(.project) \(.branch) at \(.head[:7])" + (if .ticket then " (ticket \(.ticket))" else "" end) + if .uncommitted then " with uncommitted changes" else "" end] | join(", ") | if . == "" then "no worktree" else . end) + if .cause then "; cause \(.cause)" else "" end' <<<"$event")"
  fi
}
