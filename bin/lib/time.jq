# Task time: where each task's time went, from its ledger events, and the counts beside it. Used
# by team-time as jq -L bin/lib -nR 'include "time"; time_report(...)' over the ledger's lines.
# Times are seconds since the epoch until the report turns them into hours.
include "ledger";

# The phases in report order: the key, the per-task table's column and the per-phase table's row.
def time_phases: [
  ["planning", "plan", "planning"],
  ["building", "build", "building"],
  ["gate", "gate", "gate"],
  ["review", "review", "review"],
  ["merging", "merge", "merging"],
  ["unattributed", "unattr", "unattributed"],
  ["wait:daniel", "daniel", "waiting on Daniel"],
  ["wait:task", "on-task", "waiting on another task"],
  ["wait:external", "outside", "waiting on an outside party"],
  ["wait:machine", "load", "the machine's load"],
  ["wait:limit", "limit", "the usage limit"],
  ["wait:off", "off", "the machine off or handed over"],
  ["wait:denial", "denial", "denials"],
  ["wait:other", "other", "other waits"]
];

# What a park event (waiting, blocked, paused, held) waits on, first match wins: the usage limit
# (or a token, weekly or session limit), the machine off or handed over; then its on, when given,
# in any case: Daniel, another task (T<n>), the coordinator's turn (unattributed), the gate,
# a schedule (another wait), and any other party an outside one; then its reason: an outside
# party, another task, a denial (blocked only), Daniel named, the machine's load, the gate (a
# pause while a gate run goes on, which is work), Daniel for a waiting, or another wait.
def park_class:
  (.on // "" | tostring) as $on
  | ($on | ascii_downcase) as $who
  | ((.reason // "" | tostring) + " " + $on) as $reason
  | .event as $kind
  | if $reason | test("usage limit|token limit|weekly limit|session limit"; "i") then "wait:limit"
    elif IN($kind; "paused", "held", "waiting") and ($reason | test("stowed|shutdown|OS update|handoff"; "i")) then "wait:off"
    elif $who == "daniel" then "wait:daniel"
    elif $who | test("^t[0-9]+$") then "wait:task"
    elif $who == "coordinator" then "unattributed"
    elif $who == "gate" then "gate"
    elif $who == "schedule" then "wait:other"
    elif $who != "" then "wait:external"
    elif $reason | test("GitHub Support|Dependabot|Support #"; "i") then "wait:external"
    elif $reason | test("\\b(waits? (for|on|behind)|after|once|until) T[0-9]+|T[0-9]+('s)? (PR|merge|merges|publish)|both merge|unblocked: T[0-9]+"; "i") then "wait:task"
    elif $kind == "blocked" and ($reason | test("denied|refused|deny rule|denial|permission prompt|auto mode|auto-mode"; "i")) then "wait:denial"
    elif $reason | test("\\bDaniel\\b") then "wait:daniel"
    elif $reason | test("load|memory|docker|daemon|restart|machine is quiet|outage"; "i") then "wait:machine"
    elif $kind == "paused" and ($reason | test("\\bgate\\b"; "i")) then "gate"
    elif $kind == "waiting" then "wait:daniel"
    else "wait:other" end;

# A task's events up to $end as segments {from, to, class}, from its opened. A park sets a class
# that the next launch or resumed clears, and so does a merge-approved for a wait on Daniel; an
# asked with no park standing opens a wait on Daniel that ends once every ask it noted (that one
# and any asked while it stands) is settled (settles), and an answered ends nothing else. With no
# park standing, the class is the phase the last marker set: a planner or ops launch planning, a
# builder's building, a reviewer's review, merge-approved merging, and a done or merged
# unattributed (the coordinator's turn, or a gate run the ledger did not see). A park logged after
# the fact with since takes effect at since, held to the span from the event before it to its own
# ts. The task starts unattributed, and the walk stops at the first event after $end.
def is_park: IN(.event; "waiting", "blocked", "paused", "held");
def task_segments($end):
  ([.[] | select(.event == "opened") | .ts | fromdate] | first) as $t0
  | (([range(length) as $i | select(.[$i].ts | fromdate > $end) | $i] | first) // length) as $n
  | reduce .[:$n][] as $e ({phase: "unattributed", park: null, asks: null, cur: $t0, segments: []};
      ($e.ts | fromdate) as $ts
      | (if ($e | is_park) and ($e.since | type) == "string" then
          [([(try ($e.since | fromdate) catch $ts), $ts] | min), .cur] | max
        else $ts end) as $t
      | .segments += [{from: .cur, to: $t, class: (.park // .phase)}]
      | .cur = $t
      | if $e.event == "launch" then
          .park = null | .asks = null
          | .phase = ({planner: "planning", ops: "planning", builder: "building", reviewer: "review"}[$e.role // ""] // .phase)
        elif $e.event == "resumed" then .park = null | .asks = null
        elif $e.event == "asked" and .park == null then .park = "wait:daniel" | .asks = [$e]
        elif $e.event == "asked" and .asks != null then .asks += [$e]
        elif $e | is_park then .park = ($e | park_class) | .asks = null
        else
          (if .asks != null then
            .asks |= map(select(. as $ask | $e | settles($ask) | not))
            | if .asks == [] then .park = null | .asks = null else . end
          else . end)
          | if $e.event == "done" or $e.event == "merged" then .phase = "unattributed"
            elif $e.event == "merge-approved" then
              .phase = "merging" | if .park == "wait:daniel" then .park = null | .asks = null else . end
            else . end
        end)
  | .segments + [{from: .cur, to: $end, class: (.park // .phase)}]
  | map(select(.to > .from));

# The task's gate runs as intervals {from, to}: each gate-run ends at its ts and lasts its steps'
# minutes; one with no minutes has no interval.
def gate_intervals:
  [.[] | select(.event == "gate-run")
    | ([.minutes | objects | .[] | numbers] | add // 0) as $minutes
    | select($minutes > 0)
    | (.ts | fromdate) as $t | {from: ($t - $minutes * 60), to: $t}];

# Segments with the time of the gate runs ($runs) taken out of building and unattributed, as gate.
def with_gate_runs($runs):
  map(if IN(.class; "building", "unattributed") then
      . as $s
      | ([$s.from, $s.to] + [$runs[] | .from, .to | select(. > $s.from and . < $s.to)] | unique) as $cuts
      | range(($cuts | length) - 1) as $i
      | {from: $cuts[$i], to: $cuts[$i + 1]}
      | ((.from + .to) / 2) as $mid
      | .class = (if any($runs[]; .from <= $mid and $mid <= .to) then "gate" else $s.class end)
    else . end);

# A segment cut to the window [$lo, $hi], or nothing when it lies outside it.
def clip($lo; $hi):
  ([.from, $lo] | max) as $from | ([.to, $hi] | min) as $to
  | select($to > $from) | {from: $from, to: $to, class};

# Seconds as hours, to three decimals.
def hours: (. / 3.6 | round) / 1000;

# A task's time in the window [$lo, $hi] (its events, ledger order): {task, project, path, closed,
# wall, seconds: {class: seconds}}, or nothing for a legacy task (no opened) or one whose life
# misses the window. An open task runs to $hi.
def task_time($lo; $hi):
  ([.[] | select(.event == "opened")] | first) as $opened
  | select($opened != null)
  | ($opened.ts | fromdate) as $t0
  | ([.[] | select(.event == "closed") | .ts | fromdate] | first) as $closed
  | ([$closed // $hi, $hi] | min) as $end
  | select($t0 < $hi and $end > $lo and $end >= $t0)
  | gate_intervals as $runs
  | [task_segments($end) | with_gate_runs($runs)[] | clip($lo; $hi)] as $segments
  | {task: $opened.task, project: $opened.project, path: $opened.path,
     closed: ($closed != null and $closed <= $hi),
     wall: ([$end - ([$t0, $lo] | max), 0] | max),
     seconds: (reduce $segments[] as $s ({}; .[$s.class] += $s.to - $s.from))};

# The value at percentile $p of a list of numbers, by nearest rank, or null for none.
def nearest_rank($p): sort | if length == 0 then null else .[(($p * length) | ceil) - 1] end;

# A number to one decimal.
def tenths: (. * 10 | round) / 10;

# Counts of a list of strings, in the order each first appears.
def tally: reduce .[] as $k ({}; .[$k] += 1);

# The PR an event at index $i belongs to, from the task's pr events $prs ([{i, url}]): a gate run's
# is the first PR logged after it (the one it opened, or the head it pushed), else the latest one
# before it; a review's is the latest before it, else the first after it (a gated review comes
# before the gate opens the PR).
def gate_pr($prs; $i): (([$prs[] | select(.i > $i)] | first) // ($prs | map(select(.i < $i)) | last)) | .url;
def review_pr($prs; $i): (($prs | map(select(.i < $i)) | last) // ([$prs[] | select(.i > $i)] | first)) | .url;

# The report over the ledger's lines (jq -nR), for the window [$lo, $hi] (seconds) named $since
# (or null) and $until, of every measured task or only $task: team-time/1.
def time_report($lo; $hi; $since; $until; $task):
  [ledger_events | by_task | .[]
    | select($task == null or .[0].task == $task)
    | . as $events
    | task_time($lo; $hi) as $time
    | {time: $time, events: [to_entries[] | .value.i = .key | .value]}
    | .window = [.events[] | select(.ts | fromdate | . >= $lo and . <= $hi)]]
  | sort_by(.time.task | ltrimstr("T") | tonumber)
  | (time_phases | map(.[0])) as $keys
  | def phase_hours: . as $s | [$keys[] | {(.): ($s[.] // 0 | hours)}] | add;
    def total: reduce .[] as $s ({}; reduce ($s | to_entries[]) as $kv (.; .[$kv.key] += $kv.value));
  (map(.time.seconds) | total) as $all
  | ($all | to_entries | map(.value) | add // 0) as $all_seconds
  | [.[] | . as $t | [.events[] | select(.event == "pr") | {i, url}] as $prs
     | .window[] | select(.event == "gate-run") | . + {task: $t.time.task, pr: gate_pr($prs; .i)}] as $runs
  | [.[] | . as $t | [.events[] | select(.event == "pr") | {i, url}] as $prs
     | .window[] | select(.event == "review") | . + {task: $t.time.task, pr: review_pr($prs; .i)}] as $reviews
  | [.[] | .events as $events
     | .window[] | select(.event == "asked") | . as $ask
     | ([$events[$ask.i + 1:][] | select(settles($ask) and (.ts | fromdate) <= $hi)] | first) as $answer
     | {answered: ($answer != null), minutes: (if $answer then (($answer.ts | fromdate) - ($ask.ts | fromdate)) / 60 else null end)}] as $asks
  | [.[] | .events as $events
     | .window[] | select(.event == "done") | $events[.i + 1] as $next | . as $done
     | select($next != null and ($next.ts | fromdate) <= $hi)
     | ($next.ts | fromdate) - ($done.ts | fromdate)] as $dones
  | {schema: "team-time/1", since: $since, until: $until,
     wall: (map(.time.wall) | add // 0 | hours),
     tasks: map(.time | {task, project, path, closed, wall: (.wall | hours), hours: (.seconds | phase_hours)}),
     phases: {
       all: ($all | phase_hours),
       share: ($all | . as $s | [$keys[] | {(.): (if $all_seconds > 0 then ($s[.] // 0) / $all_seconds * 100 | tenths else 0 end)}] | add),
       projects: (group_by(.time.project) | map({key: .[0].time.project, value: (map(.time.seconds) | total | phase_hours)}) | from_entries)},
     gate_runs: {
       per_pr: ($runs | group_by([.task, .pr]) | sort_by(.[0].i) | sort_by(.[0].task | ltrimstr("T") | tonumber)
         | map({task: .[0].task, pr: .[0].pr, runs: length, causes: (map(.cause // "none") | tally)})),
       by_cause: ($runs | map(.cause // "none") | tally),
       by_outcome: ($runs | map(.outcome) | tally),
       step_minutes: ([$runs[] | .minutes | objects] as $minutes
         | [$minutes[] | keys_unsorted[]] | reduce .[] as $k ([]; if IN(.[]; $k) then . else . + [$k] end)
         | map({(.): ([$minutes[][.] | numbers] | nearest_rank(0.5))}) | add // {})},
     reviews: ($reviews | group_by([.task, .pr]) | sort_by(.[0].task | ltrimstr("T") | tonumber)
       | map({task: .[0].task, pr: .[0].pr, reviews: length, findings: map(select(.verdict == "findings")) | length})),
     builders: map({task: .time.task, builders: ([.window[] | select(.event == "launch" and .role == "builder")] | length),
       tickets: ([.window[] | select(.event == "ticket-done") | .ticket] | unique | length)}),
     denials: ([.[].window[] | select(.event == "blocked" and park_class == "wait:denial")] | length),
     answers: {answered: ($asks | map(select(.answered)) | length), unanswered: ($asks | map(select(.answered | not)) | length),
       median_minutes: ([$asks[] | .minutes | numbers] | nearest_rank(0.5) | if . then tenths else . end),
       p90_minutes: ([$asks[] | .minutes | numbers] | nearest_rank(0.9) | if . then tenths else . end)},
     done_to_next: {count: ($dones | length), median_seconds: ($dones | nearest_rank(0.5)),
       p90_seconds: ($dones | nearest_rank(0.9)), within_minute: ($dones | map(select(. <= 60)) | length)}};

# Rows of strings as lines, each column padded to its widest cell, two spaces apart.
def table: (transpose | map(map(length) | max)) as $widths
  | .[] | [range(length) as $i | .[$i] | pad($widths[$i])] | join("  ") | sub(" +$"; "");

# Hours to one decimal, as text.
def h1: (. * 10 | round) as $n | "\($n / 10 | floor).\($n % 10)";

# Counts as "a 1, b 2", or "-" for none.
def counts_text: to_entries | map("\(.key) \(.value)") | if . == [] then "-" else join(", ") end;

# A number or "-" for null, with a unit.
def or_dash($unit): if . == null then "-" else "\(.)\($unit)" end;

# team-time/1 as text.
def time_text:
  . as $r
  | (.phases.projects | keys) as $projects
  | ([.phases.all[]] | add // 0) as $total
  | "Task time \(if .since then "from \(.since) " else "" end)to \(.until): \(.tasks | length) task\(if (.tasks | length) == 1 then "" else "s" end), \(.wall | h1) hours",
    "",
    "Per task, hours",
    ([["task", "project", "path", "closed", "wall"] + (time_phases | map(.[1]))]
      + [.tasks[] | . as $t | [.task, .project, .path, (if .closed then "y" else "open" end), (.wall | h1)]
          + [time_phases[] | $t.hours[.[0]] | h1]]
      | table),
    "",
    "Per phase, hours",
    ([["phase", "hours", "share"] + $projects]
      + [time_phases[] | .[0] as $k
          | [.[2], ($r.phases.all[$k] | h1), "\(($r.phases.share[$k]) | round)%"] + [$projects[] | $r.phases.projects[.][$k] | h1]]
      + [["all", ($total | h1), "100%"] + [$projects[] | [$r.phases.projects[.][]] | add | h1]]
      | table),
    "",
    (if .gate_runs.per_pr == [] then "Gate runs per PR: none"
     else "Gate runs per PR", ([["task", "pr", "runs", "causes"]] + [.gate_runs.per_pr[] | [.task, (.pr // "-"), (.runs | tostring), (.causes | counts_text)]] | table) end),
    "Gate runs by cause: \(.gate_runs.by_cause | counts_text)",
    "Gate runs by outcome: \(.gate_runs.by_outcome | counts_text)",
    "Gate minutes per step (median): \(.gate_runs.step_minutes | counts_text)",
    "",
    (if .reviews == [] then "Reviews per PR: none"
     else "Reviews per PR", ([["task", "pr", "reviews", "findings"]] + [.reviews[] | [.task, (.pr // "-"), (.reviews | tostring), (.findings | tostring)]] | table) end),
    "",
    "Builders per ticket",
    ([["task", "builders", "tickets"]] + [.builders[] | [.task, (.builders | tostring), (.tickets | tostring)]] | table),
    "",
    "Denials: \(.denials)",
    (.answers | "Daniel's answers: \(.answered) (\(.unanswered) unanswered), median \(.median_minutes | if . then h1 else null end | or_dash(" min")), 90th percentile \(.p90_minutes | if . then h1 else null end | or_dash(" min"))"),
    (.done_to_next | "DONE to the task's next event: \(.count), median \(.median_seconds | or_dash(" s")), 90th percentile \(.p90_seconds | or_dash(" s")), \(.within_minute) within a minute");
