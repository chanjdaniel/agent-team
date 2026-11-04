# captures      Warns while the team home's git does not ignore tasks/*/ui/ (team-ui's captures
#               stay on the machine that took them, never committed or handed off), or a task
#               that is not open (closed, or unknown to the ledger) left a capture there, which
#               team-close removes, or an archive holds one (tasks/*/scratch*/ui/, which archives
#               leave out); the fix removes those, whatever their age. Warns too on a non-empty
#               .scratch/shots/ in a project's slot held by no open task, which team-close removes
#               from each worktree it returns, the fix removing it: a slot of an open task, a
#               kept worktree still on a branch, another clone's worktree and a slot whose .scratch
#               is a link are left alone, and no slot is judged without a ledger and a registry to
#               read.
# shellcheck shell=bash
# shellcheck disable=SC2154 # registry_reply, the doctor's

# What team-ui keeps stays on this machine, ignored by the team home's git, and goes with its
# task's close.
captures_problems=() captures_fixes=()
if [[ -n $TEAM_HOME ]] && git -C "$TEAM_HOME" rev-parse --git-dir >/dev/null 2>&1 && ! git -C "$TEAM_HOME" check-ignore -q tasks/T1/ui/ui-pick.md; then
  captures_problems+=("the team home's git does not ignore tasks/*/ui/, so a checkpoint or handoff could carry a capture off this machine")
  captures_fixes+=("add tasks/*/ui/ to the team home's .gitignore, a records commit on dev")
fi
left=()
for dir in "$TEAM_HOME"/tasks/T*/ui "$TEAM_HOME"/tasks/T*/scratch*/ui; do
  [[ -d $dir && -n $(find "$dir" -mindepth 1 -print -quit) ]] || continue
  task=${dir#"$TEAM_HOME"/tasks/} task=${task%%/*}
  # One in an archive (scratch*/ui) is left whatever its task; archives leave ui/ out.
  [[ $dir == */scratch*/ui || $(task_status "$(task_event_array "$task")") != open ]] && left+=("$dir")
done
if ((${#left[@]})); then
  verb=are
  ((${#left[@]} > 1)) || verb=is
  captures_problems+=("$(printf '%s/, ' "${left[@]#"$TEAM_HOME"/}" | sed 's/, $//') $verb left behind, by a task that is not open or in an archive (team-close removes a task's captures, and archives leave them out)")
  captures_fixes+=("rm -rf $(printf '%q ' "${left[@]}" | sed 's/ $//')")
fi

# The .scratch/shots/ of each slot of each project that no open task holds, one path per line. A
# slot is judged only when the ledger says who holds it, and only a worktree of the project's own
# checkout, since a clone sharing a treehouse pool keeps its slots and what is in them.
idle_shots() {
  local holders projects project facts primary mine common how where slot held=() kept=() slots=()
  if [[ ! -f $TEAM_HOME/ledger.jsonl ]] || ! project_registry --list 2>/dev/null; then return 0; fi
  projects=$registry_reply
  holders=$(ledger_jq 'ledger_events | by_task | .[]
    | if is_open then
        (open_worktrees(.[]; $home) | ["held", .worktree]),
        (select(task_status == "legacy") | .[] | select(.event == "launch") | local_worktree($home) | .worktree // empty | ["held", .])
      else
        .[] | select(.event == "closed") | .kept[]? | ["kept", local_path($home)]
      end
    | @tsv' -nRr "$TEAM_HOME/ledger.jsonl" 2>/dev/null) || return 0
  while IFS=$'\t' read -r how where; do
    case $how in
      held) held+=("$where") ;;
      kept) kept+=("$where") ;;
    esac
  done <<<"$holders"
  while IFS= read -r project; do
    if [[ -z $project ]] || ! project_registry "$project" 2>/dev/null; then continue; fi
    facts=$registry_reply
    primary=$(jq -r .path <<<"$facts")
    mine=$(git -C "$primary" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
    mapfile -t slots < <(jq -r '.pool.slots[]' <<<"$facts")
    [[ $(jq -r .pool.provider <<<"$facts") != treehouse ]] || mapfile -t slots < <(treehouse_slots "${slots[@]}")
    for slot in "${slots[@]}"; do
      # Through a linked .scratch the folder may be another worktree's, which the fix must not remove.
      [[ ! -L $slot/.scratch ]] || continue
      [[ -n $(find "$slot/.scratch/shots" -mindepth 1 -print -quit 2>/dev/null) ]] || continue
      ! pool_slot "$slot" "${held[@]}" >/dev/null || continue
      common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
      same_path "$common" "$mine" || continue
      # A kept worktree keeps what it has, until it leaves its branch by a return no close sees.
      if pool_slot "$slot" "${kept[@]}" >/dev/null && git -C "$slot" symbolic-ref -q HEAD >/dev/null; then continue; fi
      echo "$slot/.scratch/shots"
    done
  done <<<"$projects"
}
mapfile -t left < <(idle_shots)
if ((${#left[@]})); then
  where="are left behind, in slots held by no open task"
  ((${#left[@]} > 1)) || where="is left behind, in a slot held by no open task"
  captures_problems+=("$(for dir in "${left[@]}"; do printf '%s/, ' "$(tilde "$dir")"; done | sed 's/, $//') $where (team-close removes .scratch/shots/ from each worktree it returns)")
  captures_fixes+=("rm -rf $(printf '%q ' "${left[@]}" | sed 's/ $//')")
fi
if ((${#captures_problems[@]} == 0)); then
  report captures PASS "the team home's git ignores tasks/*/ui/, every capture belongs to an open task, and no slot held by no open task holds .scratch/shots/"
else
  report captures WARN "$(printf '%s; ' "${captures_problems[@]}" | sed 's/; $//')" "$(printf '%s; ' "${captures_fixes[@]}" | sed 's/; $//')"
fi
