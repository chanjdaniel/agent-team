# The drills module: the one place that says what a drill record is, when a drill is due and how
# team-drill status shows it (sops/drills.md). No includes. Included as:
# jq -L bin/lib 'include "drills"; ...'
#
# The registry is bin/lib/drills.json: {max_age_days, drills: [{name, what, by, proves,
# workflow_job?}]}. The record is the team home's drills.jsonl, one run per line: {at, drill,
# machine, commit, dirty, claude, verdict, detail, run?}, appended by team-drill and never
# rewritten.

# A UTC time as a record writes it, YYYY-MM-DDTHH:MM:SSZ.
def drills_time: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
  and (try (fromdate | true) catch false);

# Whether . (one parsed line) is a drill record of a drill named in $names: every field of its
# type, the detail one line of at most 300 characters, and run, when present, a string.
def drills_record($names):
  type == "object"
  and (.at | drills_time)
  and (.drill as $drill | $drill | type == "string" and any($names[]; . == $drill))
  and (.machine | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$"))
  and (.commit | type == "string" and test("^[0-9a-f]{40}$"))
  and (.dirty | type == "boolean")
  and (.claude | type == "null" or type == "string")
  and (.verdict == "pass" or .verdict == "fail")
  and (.detail | type == "string" and length <= 300 and (contains("\n") | not))
  and ((has("run") | not) or (.run | type == "string"));

# The record read in one pass, over its raw lines (jq -nR): each drill's last record in file order,
# and the count of lines that are no drill record, which are skipped: drills_scan($registry)
def drills_scan($registry):
  ($registry.drills | map(.name)) as $names
  | reduce inputs as $line ({last: {}, malformed: 0};
      ($line | try fromjson catch null) as $record
      | if $record | drills_record($names) then .last[$record.drill] = $record else .malformed += 1 end);

# The view team-drill status --json prints, from the registry, drills_scan's result, what the code
# checkout says of each drill's last commit ($git: {<drill>: {known, changed_by}}, known false when
# the checkout lacks the commit, changed_by the last commit after it that touches a proves path, or
# null) and now, in seconds: drills_status($registry; $scan; $git; $now)
# A drill's due reasons, in this order: never (no record), failed (its last run failed),
# unknown-commit, dirty (it ran on uncommitted changes), changed, ahead (its at over a day after
# now: a clock ahead, whose run would otherwise read as fresh for 30 days past that time) and old
# (over max_age_days).
def drills_status($registry; $scan; $git; $now):
  {schema: "team-drill/1", max_age_days: $registry.max_age_days, malformed: $scan.malformed,
   drills: [$registry.drills[] | . as $drill
     | $scan.last[$drill.name] as $last
     | ($git[$drill.name] // {known: true, changed_by: null}) as $code
     | (if $last == null then null else [0, ($now - ($last.at | fromdate)) / 86400 | floor] | max end) as $age
     | (if $last != null and $code.known then $code.changed_by else null end) as $changed_by
     | {drill: $drill.name, by: $drill.by, what: $drill.what, last: $last, age_days: $age,
        due: (if $last == null then ["never"] else
          [if $last.verdict == "fail" then "failed" else empty end,
           if $code.known | not then "unknown-commit" else empty end,
           if $last.dirty then "dirty" else empty end,
           if $changed_by != null then "changed" else empty end,
           if ($last.at | fromdate) - $now > 86400 then "ahead" else empty end,
           if $age > $registry.max_age_days then "old" else empty end] end),
        changed_by: $changed_by}]};

# Why one drill of the status view (.) is due, its first reason in words, after its name: "never
# ran", "failed on 2026-11-10", "ran on a commit this checkout lacks (1a2b3c4)", "ran on uncommitted
# changes", "ran before 1a2b3c4 changed the code it proves", "ran at 2026-12-20, over a day ahead of
# this machine's clock" or "last ran 31 days ago"; null when it is not due. The doctor's drills
# line words each due drill as its name and this.
def drills_reason:
  .due[0] as $reason
  | if $reason == null then null
    elif $reason == "never" then "never ran"
    elif $reason == "failed" then "failed on \(.last.at[0:10])"
    elif $reason == "unknown-commit" then "ran on a commit this checkout lacks (\(.last.commit[0:7]))"
    elif $reason == "dirty" then "ran on uncommitted changes"
    elif $reason == "changed" then "ran before \(.changed_by[0:7]) changed the code it proves"
    elif $reason == "ahead" then "ran at \(.last.at[0:10]), over a day ahead of this machine's clock"
    elif $reason == "old" then "last ran \(.age_days) days ago"
    else $reason end;

# team-drill status's text, from the status view (.): a header and one row per drill in the
# registry's order, its columns padded to line up (the drill, its last run's date and age, machine,
# short commit, Claude Code version or none, verdict, then ok or "due: <drills_reason>"), a drill
# with no record showing only "due: never ran"; then, with skipped lines, how many.
def drills_text:
  ([["drill", "last run", "age", "machine", "commit", "claude", "verdict", "state"]]
   + [.drills[] | . as $drill
      | (if .due == [] then "ok" else "due: \(drills_reason)" end) as $state
      | if .last == null then [.drill, "", "", "", "", "", "", $state]
        else [.drill, .last.at[0:10], "\(.age_days) day\(if .age_days == 1 then "" else "s" end)",
              .last.machine, .last.commit[0:7], (.last.claude // "none"), .last.verdict, $state] end]) as $rows
  | [range(0; $rows[0] | length) as $i | [$rows[][$i] | length] | max] as $widths
  | ($rows[] | [to_entries[]
       | if .key == ($widths | length) - 1 then .value
         else .value + ([range(0; $widths[.key] - (.value | length))] | map(" ") | join("")) end]
     | join("  ")),
    (.malformed as $m | if $m == 0 then empty
     elif $m == 1 then "1 line of drills.jsonl is no drill record; it is skipped"
     else "\($m) lines of drills.jsonl are no drill record; they are skipped" end);
