# salvage records
#               On a fenced machine only: fails when the team home holds commits its origin
#               branch lacks (its remote-tracking branch as it is, with no fetch) or uncommitted
#               changes to records, naming the count of commits and the changed paths (the ledger
#               with its count of new lines); the fix is the commands that commit them as
#               "wip: salvage records from <machine>" and push the head to the team home's origin
#               as salvage/records/<machine>-<epoch>, the epoch of the lease this machine last held,
#               for Daniel to run before the team home is brought level with origin. Passes when
#               there is neither, or that branch holds the head and nothing is uncommitted.
# salvage       On a fenced machine only: fails for each open task's worktree here with
#               commits on no origin branch (a checkpoint's wip/<project>/T<n> aside) or
#               uncommitted changes, the fix being the commands that push them to the team
#               home's origin (never the project's, which may be public) as
#               salvage/<project>/T<n>-<machine> (after committing, for uncommitted changes),
#               for Daniel to run; a clean worktree whose head that branch holds is salvaged.
#               Passes when there is none.
# shellcheck shell=bash
# shellcheck disable=SC2154 # machine, from the machine check
# reads state from: 070-machine.sh 220-lease.sh

# On a fenced machine, the team home and each open task's worktree here holding what origin
# lacks. The salvage goes to the team home's origin, as a snapshot does, since the project's may
# be public; a clean head that its salvage branch holds is salvaged.
if [[ -n $fenced ]]; then
  salvage_url=$(git -C "$TEAM_HOME" remote get-url origin 2>/dev/null) || salvage_url="<the team home's origin>"
  salvaged=$(GIT_TERMINAL_PROMPT=0 git -C "$TEAM_HOME" ls-remote "$salvage_url" 'refs/heads/salvage/*' 2>/dev/null) || salvaged=''

  # The team home's own records origin lacks: its commits not on origin's branch as this machine
  # last saw it, and its uncommitted records, the ledger lines of its last minutes among them.
  if git -C "$TEAM_HOME" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    branch=$(git -C "$TEAM_HOME" symbolic-ref -q --short HEAD) || branch=HEAD
    if git -C "$TEAM_HOME" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
      count=$(git -C "$TEAM_HOME" rev-list --count "refs/remotes/origin/$branch..HEAD")
    else
      count=$(git -C "$TEAM_HOME" rev-list --count HEAD)
    fi
    mapfile -t record_specs < <(records_pathspecs)
    mapfile -d '' -t changed < <(git -C "$TEAM_HOME" status --porcelain -z --no-renames -- "${record_specs[@]}")
    changed=("${changed[@]#???}")
    held_epoch=$(jq -er '.epoch' "$HOME/.local/state/agent-team/lease.json" 2>/dev/null) || held_epoch=unknown
    ref=salvage/records/$machine-$held_epoch
    kept=$(awk -v ref="refs/heads/$ref" '$2 == ref { print $1 }' <<<"$salvaged")
    if ((count == 0 && ${#changed[@]} == 0)) ||
      { ((${#changed[@]} == 0)) && [[ -n $kept ]] && git -C "$TEAM_HOME" merge-base --is-ancestor HEAD "$kept" 2>/dev/null; }; then
      report "salvage records" PASS "the team home holds no records that neither origin's $branch nor a salvage branch keeps"
    else
      shown=$(tilde "$TEAM_HOME")
      what=() paths=()
      ((count == 0)) || what+=("$count commit$( ((count == 1)) || echo s) origin's $branch lacks")
      for path in "${changed[@]}"; do
        if [[ $path == ledger.jsonl ]]; then
          lines=$(git -C "$TEAM_HOME" diff --no-ext-diff --numstat HEAD -- ledger.jsonl | cut -f1)
          paths+=("ledger.jsonl: ${lines:-0} new line$( ((${lines:-0} == 1)) || echo s)")
        else
          paths+=("$path")
        fi
      done
      ((${#changed[@]} == 0)) || what+=("uncommitted records ($(printf '%s; ' "${paths[@]}" | sed 's/; $//'))")
      push="git -C $shown push $salvage_url HEAD:refs/heads/$ref"
      ((${#changed[@]} == 0)) ||
        push="git -C $shown add -A --$(printf ' %q' "${changed[@]}") && git -C $shown commit -m \"wip: salvage records from $machine\", then $push"
      report "salvage records" FAIL "$shown has $(printf '%s and ' "${what[@]}" | sed 's/ and $//')" "$push"
    fi
  fi

  salvage=0
  if [[ -e $TEAM_HOME/ledger.jsonl ]]; then
    while IFS=$'\t' read -r task project wt; do
      top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || continue
      same_path "$top" "$wt" || continue
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
