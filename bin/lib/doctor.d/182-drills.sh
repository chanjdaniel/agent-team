# drills        `team-drill status --json`: passes when every drill of bin/lib/drills.json passed
#               within 30 days on the code it proves; warns, never fails, so the load check and
#               team-resume go on, naming each due drill's first reason in the registry's order
#               ("load-check-planner ran before 1a2b3c4 changed the code it proves") and how many
#               lines of drills.jsonl are no drill record, which warn by themselves; warns when
#               team-drill status does not answer, naming its first error.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's

# One jq reads team-drill's view into the verdict and the reason, each drill worded as its name and
# the module's drills_reason, so the doctor and team-drill status give a due drill the same words.
drills_verdict=''
if drills_view=$(TEAM_HOME=$TEAM_HOME "$bin/team-drill" status --json 2>"$err" </dev/null) &&
  drills_view=$(jq -r -L "$TEAM_LIB" 'include "drills";
    (.drills | length) as $n
    | [.drills[] | select(.due != []) | "\(.drill) \(drills_reason)"] as $due
    | (.malformed as $m | if $m == 0 then []
       elif $m == 1 then ["1 line of drills.jsonl is no drill record"]
       else ["\($m) lines of drills.jsonl are no drill record"] end) as $skipped
    | if $due == [] then
        ["\($n) drills, each passed within \(.max_age_days) days on the code it proves"] + $skipped
      else
        ["\($due | length) of \($n) drills \(if ($due | length) == 1 then "is" else "are" end) due: \($due[0])"]
          + $due[1:] + $skipped
      end
    | (if $due == [] and $skipped == [] then "PASS" else "WARN" end), join("; ")' \
    <<<"$drills_view" 2>"$err"); then
  { read -r drills_verdict && read -r drills_reason; } <<<"$drills_view"
fi
case $drills_verdict in
  PASS) report drills PASS "$drills_reason" ;;
  WARN) report drills WARN "$drills_reason" "team-drill status lists them, and sops/drills.md has each one's runbook" ;;
  *) report drills WARN "\`team-drill status\` did not answer: $(first_error)" "fix what it names, then run team-doctor again" ;;
esac
