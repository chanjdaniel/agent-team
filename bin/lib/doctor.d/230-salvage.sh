# salvage       On a fenced machine only: fails for each open task's worktree here with
#               commits on no origin branch (a checkpoint's wip/<project>/T<n> aside) or
#               uncommitted changes, the fix being the commands that push them to the team
#               home's origin (never the project's, which may be public) as
#               salvage/<project>/T<n>-<machine> (after committing, for uncommitted changes),
#               for Daniel to run; a clean worktree whose head that branch holds is salvaged.
#               Passes when there is none.
# shellcheck shell=bash
# shellcheck disable=SC2154 # machine, from the machine check

# On a fenced machine, each open task's worktree here holding what origin lacks. The salvage
# goes to the team home's origin, as a snapshot does, since the project's may be public; a
# clean worktree whose head that salvage holds is salvaged.
if [[ -n $fenced ]]; then
  salvage=0
  if [[ -e $TEAM_HOME/ledger.jsonl ]]; then
    salvage_url=$(git -C "$TEAM_HOME" remote get-url origin 2>/dev/null) || salvage_url="<the team home's origin>"
    salvaged=$(GIT_TERMINAL_PROMPT=0 git -C "$TEAM_HOME" ls-remote "$salvage_url" 'refs/heads/salvage/*' 2>/dev/null) || salvaged=''
    while IFS=$'\t' read -r task project wt; do
      top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || continue
      [[ $(realpath -m -- "$top") == "$(realpath -m -- "$wt")" ]] || continue
      # Commits on no origin branch: a checkpoint's wip/<project>/T<n> is not one, since the next
      # checkpoint replaces it and team-close deletes it.
      count=$(git -C "$wt" rev-list --count HEAD --not --exclude='origin/wip/*' --remotes=origin)
      mapfile -t found < <(worktree_changes "$wt")
      ((count > 0 || ${#found[@]} > 0)) || continue
      ref=salvage/$project/$task-$machine
      kept=$(awk -v ref="refs/heads/$ref" '$2 == ref { print $1 }' <<<"$salvaged")
      if ((${#found[@]} == 0)) && [[ -n $kept ]] && git -C "$wt" merge-base --is-ancestor HEAD "$kept" 2>/dev/null; then
        continue
      fi
      salvage=1
      shown=$(tilde "$wt")
      what=()
      ((count == 0)) || what+=("$count commit$( ((count == 1)) || echo s) on no origin branch")
      ((${#found[@]} == 0)) || what+=("uncommitted changes ($(printf '%s; ' "${found[@]}" | sed 's/; $//'))")
      push="git -C $shown push $salvage_url HEAD:refs/heads/$ref"
      ((${#found[@]} == 0)) ||
        push="git -C $shown add -A && git -C $shown commit -m \"wip: salvage from $machine\", then $push"
      report "salvage $task $project" FAIL "$shown has $(printf '%s and ' "${what[@]}" | sed 's/ and $//')" "$push"
    done < <(ledger_jq 'ledger_events | by_task | to_entries | sort_by(.key[1:] | tonumber) | .[]
      | select(.value | task_status == "open") | .key as $task | open_worktrees(.value[]; $home)
      | [$task, .project, .worktree] | @tsv' -nRr "$TEAM_HOME/ledger.jsonl")
  fi
  ((salvage)) || report salvage PASS "no task worktree here holds work that neither origin nor a salvage branch keeps"
fi
