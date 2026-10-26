# per project   For each project of projects.toml (`projects` fails when team-project refuses
#               the registry), the lines below with the project's name after the check's;
#               a missing checkout is its one line:
#   checkout    The primary checkout at its registry path: a git checkout of its own, not a
#               worktree of another; missing, the fix is the clone.
#   origin      Exactly https://github.com/<repo>.git, the URL the bootstrap clones from.
#   task dir    git ignores the task directory, as team-open requires.
#   gate        no-mistakes projects only: `no-mistakes status` in the checkout shows a gate.
#   slots       treehouse pools only: every slot is in the pool treehouse names from origin,
#               <checkout's folder name>-<the first 3 bytes of the SHA-256 of origin's URL,
#               in hex>, so the registry's slots hold on any machine with that origin. Then
#               each slot of that pool (the registry's, each other numbered slot in their
#               folder, and each numbered folder there) is a worktree of the checkout or
#               missing (treehouse makes it); warns on one that is a worktree of another
#               clone (a clone with the same folder name and origin shares the pool, and
#               treehouse leases its slots only to it), naming it and how many slots are the
#               team's, with git -C <clone> worktree remove <slot> as Daniel's fix; on an empty
#               folder, which treehouse numbers new slots past, with its rmdir; and on a
#               folder holding no worktree.
#   leases      treehouse pools only: `treehouse status --json` in the checkout; warns naming
#               each slot of the pool leased to a closed task, to an open task whose worktree in
#               the project is not that slot (a lease a failed team-open left), or to a holder
#               that is no task of the ledger (another clone's agent, say), with the return
#               command for Daniel to run in their own terminal, which asks before discarding
#               changes; warns when treehouse does not answer.
#   trust       `claude --bg --name team-doctor-trust-<project>` with no prompt in the checkout
#               fails on "Workspace not trusted"; the probe session (by the id it printed, and
#               any session of that name) is stopped and removed either way, and one left
#               behind turns a pass into a warning.
#   branches    Warns on each local branch with commits on no origin branch (no upstream and
#               never pushed, or ahead of what was pushed; a checkpoint's wip/<project>/T<n>
#               on the team home's origin is no branch), with their count.
#   changes     Warns while the primary checkout has changes to tracked files or untracked files.
# shellcheck shell=bash
# shellcheck disable=SC2154 # err, the doctor's

# team-project refuses a missing or broken registry itself, the first problem first.
# The pool treehouse names for the checkout <path> with origin <url>: <path's folder name>-<the
# first 3 bytes of the SHA-256 of the URL, in hex> (treehouse's ResolvePoolDir).
pool_name() {
  printf '%s-%s\n' "${1##*/}" "$(printf '%s' "$2" | sha256sum | cut -c1-6)"
}

# The slots line of <project>, whose registered slots <slot>... are all in the treehouse pool
# <pool> of the checkout <path>: each slot of the pool (treehouse_slots) and each other numbered
# folder beside them, by number. A slot that is a worktree of the checkout, or missing (treehouse
# makes it), is the team's; one that is a worktree of another clone, which treehouse leases only
# to that clone, warns, with how many are the team's; so does an empty folder, which treehouse
# numbers new slots past, and a folder holding no worktree.
check_slot_owners() {
  local project=$1 path=$2 pool=$3 slot n dir mine common clone ours=0 all=0 found=() others='' rest='' reason fix
  mine=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)
  mapfile -t found < <(treehouse_slots "${@:4}")
  for slot in "${@:4}"; do
    for dir in "${slot%/*/*}"/*/; do
      dir=${dir%/}
      [[ -d $dir && ${dir##*/} =~ ^[0-9]+$ ]] || continue
      pool_slot "$dir/${slot##*/}" "${found[@]}" >/dev/null || found+=("$dir/${slot##*/}")
    done
  done
  # One "<n> TAB <reason> TAB <fix>" line per problem: another clone's slots in others, the rest
  # in rest.
  for slot in "${found[@]}"; do
    dir=${slot%/*} n=${dir##*/}
    if [[ -e $slot/.git ]] && common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
      all=$((all + 1))
      if same_path "$common" "$mine"; then
        ours=$((ours + 1))
        continue
      fi
      clone=$common
      [[ ${common##*/} != .git ]] || clone=${common%/*}
      others+="$n"$'\t'"slot $n is a worktree of $(tilde "$clone")"$'\t'"git -C $(tilde "$clone") worktree remove $(tilde "$slot")"$'\n'
    elif [[ -d $slot && -z $(ls -A "$slot") ]]; then
      fix="rmdir $(tilde "$slot")"
      [[ -n $(find "$dir" -mindepth 1 -maxdepth 1 ! -samefile "$slot" -print -quit) ]] || fix+=" $(tilde "$dir")"
      rest+="$n"$'\t'"slot $n is an empty folder, so treehouse numbers new slots past it"$'\t'"$fix"$'\n'
    elif [[ -e $slot || (-d $dir && -n $(ls -A "$dir")) ]]; then
      [[ -e $slot ]] || slot=$dir
      rest+="$n"$'\t'"slot $n holds no git worktree"$'\t'"Daniel looks at $(tilde "$slot") and moves it aside"$'\n'
    elif [[ -d $dir ]]; then
      rest+="$n"$'\t'"slot $n is an empty folder, so treehouse numbers new slots past it"$'\t'"rmdir $(tilde "$dir")"$'\n'
    else
      # Missing: treehouse makes it for this checkout.
      all=$((all + 1)) ours=$((ours + 1))
    fi
  done
  if [[ -z $others$rest ]]; then
    report "slots $project" PASS "every slot is in the pool $pool, as treehouse names it from origin"
    return
  fi
  others=$(sort -t$'\t' -k1,1n <<<"${others%$'\n'}") rest=$(sort -t$'\t' -k1,1n <<<"${rest%$'\n'}")
  reason=$(cut -f2 <<<"$others" | paste -sd ';' | sed 's/;/; /g')
  fix=$(cut -f3 <<<"$others" | paste -sd ';' | sed 's/;/; /g')
  if [[ -n $others ]]; then
    reason+=", so $ours of $all slots are the team's"
    fix="Daniel's, once nothing in it is needed by that clone: $fix"
  fi
  if [[ -n $rest ]]; then
    reason+="${reason:+; }$(cut -f2 <<<"$rest" | paste -sd ';' | sed 's/;/; /g')"
    fix+="${fix:+; }$(cut -f3 <<<"$rest" | paste -sd ';' | sed 's/;/; /g')"
  fi
  report "slots $project" WARN "$reason" "$fix"
}

# The leases line of <project>, whose treehouse pool is that of the checkout <path>, returned
# through <return>.
check_leases() {
  local project=$1 path=$2 return_cmd=$3 shown leases problems count fix entry wt open=() ledger=$TEAM_HOME/ledger.jsonl
  shown=$(tilde "$path")
  # No ledger is the records line's FAIL; here it holds no task.
  [[ -f $ledger ]] || ledger=/dev/null
  if ! leases=$(pool_status "$path"); then
    report "leases $project" WARN "\`treehouse status --json\` in $shown did not answer" "the tool treehouse line's fix"
    return
  fi
  count=$(jq -s 'map(select(.holder != "")) | length' <<<"$leases")
  # Each slot that is an open worktree of the project, spelled as the ledger spells it, since the
  # comparison below is by text and the two may spell one directory otherwise (same_path).
  mapfile -t open < <(ledger_jq 'ledger_events as $events | ($events | by_task) as $tasks
    | open_worktrees($events[] | select($tasks[.task] | is_open); $home) | select(.project == $project) | .worktree' \
    -nRr --arg project "$project" "$ledger")
  leases=$(while IFS= read -r entry; do
    for wt in "${open[@]}"; do
      if same_path "$wt" "$(jq -r .path <<<"$entry")"; then entry=$(jq -c --arg wt "$wt" '.path = $wt' <<<"$entry") && break; fi
    done
    echo "$entry"
  done <<<"$leases")
  problems=$(ledger_jq 'ledger_events as $events | ($events | by_task) as $tasks
    | [open_worktrees($events[] | select($tasks[.task] | is_open); $home) | select(.project == $project)] as $open
    | $leases[] | select(.holder != "") | . as $slot
    | ($tasks[.holder] // null) as $held
    | (.path | if startswith($home + "/") then "~" + .[($home | length):] else . end) as $shown
    | if $held == null then "\($shown) is leased to \(.holder), no task of the ledger"
      elif ($held | is_open | not) then "\($shown) is leased to \(.holder), which is closed"
      elif any($open[]; .task == $slot.holder and .worktree == $slot.path) | not then
        "\($shown) is leased to \(.holder), whose worktree in \($project) is not there"
      else empty end
    | [., $slot.path] | @tsv' -nRr --arg project "$project" --argjson leases "$(jq -s . <<<"$leases")" \
    "$ledger")
  if [[ -z $problems ]]; then
    if ((count == 0)); then
      report "leases $project" PASS "no slot of the pool is leased"
    else
      report "leases $project" PASS "every leased slot ($count) is an open task's worktree here"
    fi
    return
  fi
  fix=$(cut -f2 <<<"$problems" | while IFS= read -r slot; do
    printf 'cd %s && %s %s; ' "$shown" "$(tilde "$return_cmd")" "$(tilde "$slot")"
  done)
  report "leases $project" WARN "$(cut -f1 <<<"$problems" | paste -sd ';' | sed 's/;/; /g')" \
    "once nothing in it is needed, Daniel returns each in their own terminal, which asks before discarding changes: ${fix%; }"
}

# The lines of the registered project <name> (see the header).
check_project() {
  local project=$1 facts path shown repo url top common origin task_dir exclude out rc pool slot
  local wrong=() registered=() unpushed=() found=() branch count
  facts=$(team_project "$project")
  path=$(jq -r .path <<<"$facts") repo=$(jq -r .repo <<<"$facts") task_dir=$(jq -r .task_dir <<<"$facts")
  shown=$(tilde "$path") url=https://github.com/$repo.git

  # checkout
  if [[ ! -e $path ]]; then
    report "checkout $project" FAIL "$shown is missing" "git clone $url $shown"
    return
  fi
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || top=''
  if ! same_path "$top" "$path"; then
    report "checkout $project" FAIL "$shown is not a git checkout" "move it aside, then git clone $url $shown"
    return
  fi
  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)
  if ! same_path "$common" "$(git -C "$path" rev-parse --absolute-git-dir)"; then
    report "checkout $project" FAIL "$shown is a worktree of $(tilde "$(dirname "$(realpath -m -- "$common")")"), not a primary checkout" \
      "move it aside, then git clone $url $shown"
    return
  fi
  report "checkout $project" PASS "$shown, a primary checkout"

  # origin
  origin=$(git -C "$path" remote get-url origin 2>/dev/null) || origin=''
  if [[ $origin == "$url" ]]; then
    report "origin $project" PASS "$url"
  elif [[ -z $origin ]]; then
    report "origin $project" FAIL "no remote origin" "git -C $shown remote add origin $url"
  else
    report "origin $project" FAIL "origin is $origin, not $url" "git -C $shown remote set-url origin $url"
  fi

  # task dir: with its trailing slash, so a pattern for folders only matches one not made yet.
  if git -C "$path" check-ignore -q -- "$task_dir/"; then
    report "task dir $project" PASS "git ignores $task_dir/"
  else
    exclude=$(git -C "$path" rev-parse --path-format=absolute --git-path info/exclude)
    report "task dir $project" FAIL "git does not ignore $task_dir/" "echo /$task_dir/ >> $(tilde "$exclude")"
  fi

  # gate
  if [[ $(jq -r .delivery <<<"$facts") == no-mistakes ]]; then
    rc=0
    out=$(cd "$path" && bounded 30 no-mistakes status 2>&1 </dev/null) || rc=$?
    if ((rc == 127)); then
      report "gate $project" FAIL "no-mistakes is not installed" "the tool no-mistakes line's fix, then cd $shown && no-mistakes init"
    elif grep -qE '^[[:space:]]*gate:[[:space:]]' <<<"$out"; then
      report "gate $project" PASS "no-mistakes has a gate for it"
    elif [[ $out == *"not initialized"* ]]; then
      report "gate $project" FAIL "no-mistakes has no gate for $shown" "cd $shown && no-mistakes init"
    else
      report "gate $project" FAIL "\`no-mistakes status\` printed no gate: $(grep -m1 . <<<"$out" || echo "exit $rc")" \
        "cd $shown && no-mistakes init"
    fi
  fi

  # slots: a treehouse slot is <root>/<pool>/<n>/<folder>.
  if [[ $(jq -r .pool.provider <<<"$facts") == treehouse ]]; then
    if [[ -z $origin ]]; then
      report "slots $project" FAIL "unknown, since treehouse names the pool from origin, which is missing" "the origin line's fix"
    else
      pool=$(pool_name "$path" "$origin")
      mapfile -t registered < <(jq -r '.pool.slots[]' <<<"$facts")
      for slot in "${registered[@]}"; do
        [[ $(basename "$(dirname "$(dirname "$slot")")") == "$pool" ]] || wrong+=("$(tilde "$slot")")
      done
      if ((${#wrong[@]} == 0)); then
        check_slot_owners "$project" "$path" "$pool" "${registered[@]}"
      elif [[ $origin != "$url" ]]; then
        report "slots $project" FAIL "not in the pool $pool, as treehouse names it from origin $origin: $(printf '%s, ' "${wrong[@]}" | sed 's/, $//')" \
          "the origin line's fix"
      else
        report "slots $project" FAIL "not in the pool $pool, as treehouse names it from origin: $(printf '%s, ' "${wrong[@]}" | sed 's/, $//')" \
          "put $project's pool.slots in projects.toml under the pool's directory, ~/.treehouse/$pool/ unless its treehouse.toml sets another root"
      fi
    fi
  fi

  # leases: each slot the pool leases is an open task's worktree in this project.
  if [[ $(jq -r .pool.provider <<<"$facts") == treehouse ]]; then
    check_leases "$project" "$path" "$(jq -r .pool.return <<<"$facts")"
  fi

  probe_trust "$project" "$path"

  # branches: commits no remote-tracking branch of origin has, as of the last fetch. A checkpoint's
  # wip/<project>/T<n> is none, since the next checkpoint replaces it and team-close deletes it:
  # team-open --resume fetches it into refs/remotes/team-home/, and origin/wip/* is left out for a
  # project whose origin is the team home's (or a snapshot from before they moved there).
  while IFS= read -r branch; do
    count=$(git -C "$path" rev-list --count "refs/heads/$branch" --not --exclude='origin/wip/*' --remotes=origin)
    ((count == 0)) || unpushed+=("$branch ($count commit$( ((count == 1)) || echo s))")
  done < <(git -C "$path" for-each-ref --format='%(refname:lstrip=2)' refs/heads)
  if ((${#unpushed[@]} == 0)); then
    report "branches $project" PASS "every local branch is on origin"
  else
    report "branches $project" WARN "$(printf '%s, ' "${unpushed[@]}" | sed 's/, $//') on no origin branch" \
      "push each (git -C $shown push -u origin <branch>) or delete it"
  fi

  # changes
  mapfile -t found < <(worktree_changes "$path")
  if ((${#found[@]} == 0)); then
    report "changes $project" PASS "the primary checkout is clean"
  else
    report "changes $project" WARN "$(printf '%s; ' "${found[@]}" | sed 's/; $//')" "commit, stash or remove them in $shown"
  fi
}

if projects=$(team_project --list 2>"$err"); then
  while IFS= read -r project; do check_project "$project"; done <<<"$projects"
else
  report projects FAIL "$(first_error)" "fix what team-project names (team-project --check), then run team-doctor again"
fi
