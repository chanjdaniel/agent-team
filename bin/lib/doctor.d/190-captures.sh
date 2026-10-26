# captures      Warns while the team home's git does not ignore tasks/*/ui/ (team-ui's captures
#               stay on the machine that took them, never committed or handed off), or a task
#               that is not open (closed, or unknown to the ledger) left a capture there, which
#               team-close removes, or an archive holds one (tasks/*/scratch*/ui/, which archives
#               leave out); the fix removes those, whatever their age.
# shellcheck shell=bash

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
  [[ $dir == */scratch*/ui || $(task_status "$(task_events "$task" | jq -cs .)") != open ]] && left+=("$dir")
done
if ((${#left[@]})); then
  verb=are
  ((${#left[@]} > 1)) || verb=is
  captures_problems+=("$(printf '%s/, ' "${left[@]#"$TEAM_HOME"/}" | sed 's/, $//') $verb left behind, by a task that is not open or in an archive (team-close removes a task's captures, and archives leave them out)")
  captures_fixes+=("rm -rf $(printf '%q ' "${left[@]}" | sed 's/ $//')")
fi
if ((${#captures_problems[@]} == 0)); then
  report captures PASS "the team home's git ignores tasks/*/ui/, and every capture belongs to an open task"
else
  report captures WARN "$(printf '%s; ' "${captures_problems[@]}" | sed 's/; $//')" "$(printf '%s; ' "${captures_fixes[@]}" | sed 's/; $//')"
fi
