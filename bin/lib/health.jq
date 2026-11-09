# The health module: the one place that says what unhealthy means. team-timers run folds each
# run's results into the health record (health_fold) and reads the ledger with ledger_scan;
# team-timers health turns the record, the lease record and now into the view (health_view).
# jq 1.7, no includes. Included as: jq -L bin/lib 'include "health"; ...'
#
# The record, ~/.local/state/agent-team/health.json, is team-health/1:
#   {schema, machine, written (when it was last written),
#    last_run: {start, end, ended, holding} (end and ended null while the run goes on; ended is
#      ok, failed, offline, login-refused, not-holder, fenced or timed-out),
#    last_good_run (the start of the last run that ended ok), lease_renewed (the lease's last
#    renewal, as team-lease status gave it or the run's renew made it), last_checkpoint (the time
#    of last-checkpoint), offline ({since}) and login_refused ({since, reason}), the heartbeat's
#    flags as the run left them,
#    steps: {<step>: {since, runs, reason, more, run}}, each step failing now: since when, for how
#      many runs in a row, its latest reason, how many more failure lines it gave, and the id of
#      the last run that counted it,
#    ledger: {count, bad_lines, last_event}, the lines that are not JSON objects (the first 100
#      line numbers) and the time of the last event that is not a denied,
#    alerts: {<key>: {since, text, posted, message}}, each open alert: since when its problem
#      stands, its text, when it was posted to #coordinator (null until a post went through) and
#      the message that carries it (null until then, or when Discord gave no id); written by
#      team-timers as it posts and resolves, never by health_fold}
# Keys it does not name are kept as they are.

# The thresholds, each defined here once: a checkpoint failing for `runs` runs in a row alerts, a
# heartbeat or a good checkpoint older than `stale_minutes` alerts, and any other step alerts
# after `step_runs` runs in a row.
def health_limits: {runs: 2, stale_minutes: 15, step_runs: 12};

# The thresholds with team-timers' seams laid over them, each a number given as a string, or
# empty for the default: health_limits($seams)
def health_limits($seams):
  health_limits + ($seams | with_entries(select(.value != null and .value != "") | .value |= tonumber));

# The heartbeat's steps in their order, for the view's problems; a step not named here comes after
# them, by name.
def health_steps:
  ["run", "probe", "lease", "checkpoint", "ledger", "usage", "coordinator", "inbox", "finished",
   "capacity", "level", "stacks", "pack", "janitor"];

# The ledger read in one pass, over its raw lines (jq -nR): the lines that are not JSON objects,
# counted, the first 100 of them by line number, and the ts of the last event that is not a
# denied.
def ledger_scan:
  reduce inputs as $line ({n: 0, count: 0, bad_lines: [], last_event: null};
    .n += 1
    | ($line | try fromjson catch null) as $event
    | if ($event | type) == "object" then
        if $event.event != "denied" and ($event.ts | type) == "string" then .last_event = $event.ts else . end
      else
        .count += 1 | if (.bad_lines | length) < 100 then .bad_lines += [.n] else . end
      end)
  | del(.n);

# The ledger step's reason for a scan with bad lines: ledger_reason
def ledger_reason:
  "\(.count) line\(if .count == 1 then " is not a JSON object" else "s are not JSON objects" end): line "
  + (.bad_lines[:10] | map(tostring) | join(", "))
  + (if .count > 10 then ", and \(.count - 10) more" else "" end);

# Fold one run's results into the record (the input, null or anything else for none):
# health_fold($run; $results), where $run is {machine, id (unique to the run, so two runs that
# start in one second are two), start, now, ended (null while the run goes on), last_checkpoint,
# offline, login_refused} and $results the run's result entries, in order:
# {step, reason (null when it went well), more}, {holding}, {lease_renewed} and {ledger}. A step
# fails in a run when any entry of it failed, with the first failure's reason; a step with no
# entry did not run and keeps its entry; a failure counts once per run however often it is folded.
def health_fold($run; $results):
  (if type == "object" and .schema == "team-health/1" then . else {} end) as $prev
  | (reduce ($results[] | select(.step)) as $r ({};
      if .[$r.step] == null or (.[$r.step].failed | not) and $r.reason != null then
        .[$r.step] = {failed: ($r.reason != null), reason: $r.reason, more: ($r.more // 0)}
      else . end)) as $ran
  | (reduce ($ran | to_entries[]) as $e ($prev.steps // {};
      if $e.value.failed then
        .[$e.key] = ((.[$e.key] // null) as $old
          | if $old == null then {since: $run.now, runs: 1}
            elif $old.run == $run.id then $old
            else $old + {runs: ($old.runs + 1)} end
          | . + {reason: $e.value.reason, more: $e.value.more, run: $run.id})
      else del(.[$e.key]) end)) as $steps
  | ([$results[] | select(has("holding")) | .holding] | last // false) as $holding
  | $prev + {
      schema: "team-health/1",
      machine: $run.machine,
      written: $run.now,
      last_run: {start: $run.start, end: (if $run.ended == null then null else $run.now end),
        ended: $run.ended, holding: $holding},
      last_good_run: (if $run.ended == "ok" then $run.start else $prev.last_good_run end),
      lease_renewed: ([$results[] | select(has("lease_renewed")) | .lease_renewed] | last // $prev.lease_renewed),
      last_checkpoint: $run.last_checkpoint,
      offline: $run.offline,
      login_refused: $run.login_refused,
      steps: $steps,
      ledger: ([$results[] | select(has("ledger")) | .ledger] | last // $prev.ledger)
    };

# A text cut to <n> characters, its end marked: health_cut($n)
def health_cut($n): if length > $n then .[:$n - 3] + "..." else . end;

def health_epoch: fromdateiso8601;

# Minutes since the UTC time (the input) at $now: health_age($now)
def health_age($now): ($now - health_epoch) / 60 | floor;

# A UTC time in Discord's markup, relative or as a clock time, and in plain text.
def health_rel: "<t:\(health_epoch):R>";
def health_at: "<t:\(health_epoch):t>";
def health_plain_rel($now): "\(.) (\(health_age($now)) minutes ago)";

def health_runs: "\(.) run\(if . == 1 then "" else "s" end)";

# A UTC time as this machine's local hours and minutes (TZ's), as the heartbeat's other posts
# write it: health_clock
def health_clock: health_epoch | strflocaltime("%H:%M");

# Discord's limit on a message, less room for the line an alert's edit adds when it resolves.
def health_alert_limit: 2000 - ("\n-# Resolved at 00:00." | length);

# A reason as the end of a sentence: its own last full stop left off.
def health_sentence: rtrimstr(".");

# The view for a machine that keeps no health, one whose record is unknown, and one whose
# problems are known, with or without problems.
def health_not_holding($machine):
  {schema: "team-health/1", machine: $machine, holding: false, ok: true, line: null, text: null, problems: []};

def health_unknown($machine; $why):
  {schema: "team-health/1", machine: $machine, holding: true, ok: false,
   line: "**Health**: unknown - \($why | health_cut(150))",
   text: "Health: unknown - \($why | health_cut(150))",
   problems: [{key: "record", since: null, text: "health unknown: \($why | health_cut(150))", alerting: false, sweep: null}]};

# Each problem of the record (the input) at $now, in the view's order, as {key, since, alerting,
# sweep, line, text}; $lease is the lease record: health_problems($lease; $now; $limits)
def health_problems($lease; $now; $limits):
  . as $rec
  | ($limits.stale_minutes * 60) as $stale
  | ($rec.steps // {}) as $steps
  | ([$rec.last_run.start, $lease.written_at] | map(strings) | max) as $seen
  # A run of this holding whose record has no end yet is still going, or was killed before it
  # could say so; the record is first written after the lease step, so a renewal in that run
  # may be later than its start.
  | ($rec.last_run.start | strings) as $start
  | ($start != null and $rec.last_run.end == null
      and (($lease.taken_at | type) != "string" or $start >= $lease.taken_at)) as $going
  | (if $seen == null or $now - ($seen | health_epoch) > $stale then
      [{key: "heartbeat", since: $seen, alerting: true, sweep: "checkpoint-stale",
        line: (if $going then "a heartbeat run started \($start | health_rel) has not ended"
               else "the heartbeat last ran \(if $seen then $seen | health_rel else "never" end)" end),
        text: (if $going then "a heartbeat run started \($start | health_plain_rel($now)) has not ended"
               else "the heartbeat last ran \(if $seen then $seen | health_plain_rel($now) else "never" end)" end)}]
    else [] end) as $heartbeat
  | (if $rec.offline then
      [{key: "offline", since: $rec.offline.since, alerting: false, sweep: null,
        line: "GitHub unreachable since \($rec.offline.since | health_at), the team is holding",
        text: "GitHub unreachable since \($rec.offline.since), the team is holding"}]
    else [] end) as $offline
  | (if $rec.login_refused then
      [{key: "login-refused", since: $rec.login_refused.since, alerting: true, sweep: "health",
        line: "GitHub refuses \($rec.machine)'s login since \($rec.login_refused.since | health_at)",
        text: "GitHub refuses \($rec.machine)'s login since \($rec.login_refused.since)"}]
    else [] end) as $refused
  # A record written before this holding began (the lease's taken_at, which a take or a steal
  # sets and a renewal keeps) says nothing of its checkpoints until the first run is overdue,
  # which the heartbeat problem says; a lease record with no taken_at hides nothing.
  | (($lease.taken_at | type) == "string" and ($rec.written // "") < $lease.taken_at) as $before
  | (if ($heartbeat + $offline + $refused | length) > 0 or $before then []
    else
      $steps.checkpoint as $failing
      | $rec.last_checkpoint as $good
      | ($good == null or $now - ($good | health_epoch) > $stale) as $old
      | (first(health_steps[:index("checkpoint")][] as $s | $steps[$s] // empty | "\($s): \(.reason)")
          // "the checkpoint step did not run") as $why
      | if $failing then
          [{key: "checkpoint", since: $failing.since, alerting: ($failing.runs >= $limits.runs or $old),
            sweep: "checkpoint-stale",
            line: "checkpoint failing since \($failing.since | health_at) (\($failing.runs | health_runs)): \($failing.reason | health_cut(150))",
            text: "checkpoint failing since \($failing.since) (\($failing.runs | health_runs)): \($failing.reason | health_cut(150))",
            alert: ("Checkpoints are failing on \($rec.machine) since \($failing.since | health_clock) (\($failing.runs | health_runs)): "
              + ($failing.reason // "no reason given" | health_sentence)
              + (if ($failing.more // 0) > 0 then ", and \($failing.more) more" else "" end) + ". "
              + (if $good then "Work since the last good one (\($good | health_clock)) is on this machine only."
                 else "No checkpoint has worked yet, so all work is on this machine only." end))}]
        elif $old then
          [{key: "checkpoint", since: $good, alerting: true, sweep: "checkpoint-stale",
            line: "no good checkpoint \(if $good then "since \($good | health_rel)" else "yet" end): \($why | health_cut(150))",
            text: "no good checkpoint \(if $good then "since \($good | health_plain_rel($now))" else "yet" end): \($why | health_cut(150))",
            alert: ("No good checkpoint on \($rec.machine) "
              + (if $good then "since \($good | health_clock) (\($good | health_age($now)) minutes)" else "yet" end)
              + ": \($why | health_sentence).")}]
        else [] end
    end) as $checkpoint
  | (($rec.ledger.count // 0) > 0 and $steps.ledger != null) as $unparsed
  | (if $unparsed then
      $rec.ledger as $l
      | ("\($l.count) ledger line\(if $l.count == 1 then "" else "s" end) no reader can parse") as $what
      | ("line \($l.bad_lines[:10] | map(tostring) | join(", "))\(if $l.count > 10 then ", and \($l.count - 10) more" else "" end)") as $where
      | [{key: "ledger", since: $steps.ledger.since, alerting: true, sweep: "health", line: $what,
          text: "\($what) (\($where))",
          alert: ((if $l.count == 1 then ["", "it"] else ["s", "them"] end) as [$s, $it]
            | "ledger.jsonl on \($rec.machine) holds \($l.count) line\($s) no reader can parse (\($where)), so every reader skips \($it): team-log --check names \($it).")}]
    else [] end) as $ledger
  | ($steps | keys_unsorted
      | map(select(. != "checkpoint" and . != "coordinator" and (. != "ledger" or ($unparsed | not))))
      | sort_by(. as $name | (health_steps | index($name)) // 999, .)
      | map(. as $name | $steps[$name]
          | (.runs >= $limits.step_runs) as $alerting
          | {key: "step-\($name)", since: .since, alerting: $alerting, sweep: (if $alerting then "health" else null end),
             line: "\($name) failing since \(.since | health_at) (\(.runs | health_runs)): \(.reason // "no reason given" | health_cut(150))",
             text: "\($name) failing since \(.since) (\(.runs | health_runs)): \(.reason // "no reason given" | health_cut(150))",
             alert: "The heartbeat's \($name) step has failed \(.runs | health_runs) in a row on \($rec.machine), since \(.since | health_clock): \(.reason // "no reason given" | health_sentence)."})) as $others
  | $heartbeat + $offline + $refused + $checkpoint + $ledger + $others
  | map(.sweep = (if .alerting then .sweep else null end));

# The alerts the record (the input) calls for at $now: each alerting problem that has an alert
# text (checkpoint, ledger and step-<name>; heartbeat, offline and login-refused post none here),
# as {key, since, text}, the text cut to health_alert_limit: health_alerts($lease; $now; $limits)
def health_alerts($lease; $now; $limits):
  [health_problems($lease; $now; $limits)[] | select(.alerting and (.alert | type) == "string")
    | {key, since, text: (.alert | health_cut(health_alert_limit))}];

# What to post and what to resolve at $now, from the record (the input) and its open alerts:
# {post: [{key, since, text}], resolve: [{key, since, text, posted, message}]}. An alert called for
# with no open one, or with one never posted, is posted (its since the open one's, its text this
# run's); one open whose problem is no longer alerting is resolved; one open and posted while its
# problem stands is left alone, whatever its reason becomes. Only on the holder, so a machine that
# does not hold plans nothing, and nothing while a heartbeat, offline or login-refused problem
# stands (a run that has outlasted the stale minutes, say), since each hides the checkpoint
# problem without saying it has ended: health_alert_plan($lease; $fenced; $machine; $now; $limits)
def health_alert_plan($lease; $fenced; $machine; $now; $limits):
  if ($lease | type) != "object" or $lease.holder != $machine or $lease.state != "held" or $fenced
    or type != "object" or .schema != "team-health/1" then
    {post: [], resolve: []}
  elif any(health_problems($lease; $now; $limits)[]; .key == "heartbeat" or .key == "offline" or .key == "login-refused") then
    {post: [], resolve: []}
  else
    (.alerts // {}) as $open
    | health_alerts($lease; $now; $limits) as $wanted
    | {post: [$wanted[] | select($open[.key].posted == null) | .since = ($open[.key].since // .since)],
       resolve: [$open | to_entries[] | select(.key as $key | all($wanted[]; .key != $key))
         | {key, since: .value.since, text: .value.text, posted: .value.posted, message: .value.message}]}
  end;

# The view (team-timers health --json) from the record's text $raw (null when there is none), the
# lease record $lease (null when there is none), whether $fenced, this $machine, $now (seconds)
# and $limits: {schema, machine, holding, ok, line (Discord's markup), text (plain), problems,
# each {key, since, text, alerting, sweep}}. Read-only: computed, never stored.
def health_view($raw; $lease; $fenced; $machine; $now; $limits):
  if ($lease | type) != "object" or $lease.holder != $machine or $lease.state != "held" or $fenced then
    health_not_holding($machine)
  elif $raw == null then
    health_unknown($machine; "no health record yet; the heartbeat writes one each run")
  else
    ($raw | try fromjson catch null) as $rec
    | if ($rec | type) != "object" or $rec.schema != "team-health/1" then
        health_unknown($machine; "the health record is not a team-health/1 record (the heartbeat's next run writes it again)")
      else
        ($rec | health_problems($lease; $now; $limits)) as $problems
        | if $problems == [] then
            {schema: "team-health/1", machine: $machine, holding: true, ok: true,
             line: ("-# Health: ok - last checkpoint \($rec.last_checkpoint | if . then health_rel else "never" end), lease renewed \($rec.lease_renewed | if . then health_rel else "never" end)"
               | health_cut(500)),
             text: ("Health: ok - last checkpoint \($rec.last_checkpoint | if . then health_plain_rel($now) else "never" end), lease renewed \($rec.lease_renewed | if . then health_plain_rel($now) else "never" end)"
               | health_cut(500)),
             problems: []}
          else
            {schema: "team-health/1", machine: $machine, holding: true, ok: false,
             line: ("**Health**: " + ($problems | map(.line) | join("; ")) | health_cut(500)),
             text: ("Health: " + ($problems | map(.text) | join("; ")) | health_cut(500)),
             problems: ($problems | map({key, since, text, alerting, sweep}))}
          end
      end
  end;
