# Worker lifetimes: how long each worker lived, from its launch to its end, from the ledger. Used
# by team-time as jq -L bin/lib -nR 'include "workers"; workers_report(...)' over the ledger's lines.
# Includes ledger.jq for the events and time.jq for a task's phase segments, the clipping and the
# percentiles.
include "ledger";
include "time";

# The roles in report order; any other role comes after them, by name.
def role_rank: .role as $role | [(["builder", "reviewer", "planner", "ops"] | index($role)) // 4, $role];

# A lifetime's minutes, unrounded, from its start to its end, or to $hi while it runs.
def span_minutes($hi): (((if .end then .end | fromdate else $hi end) - (.start | fromdate)) / 60);

# A task's worker lifetimes (input: its events in ledger order, only those at or before $hi): one
# per launch with a session. Its project is the launch's, else the task's opened; its path the
# opened's, else "-" (a legacy task); its model the launch's, else "default". It ends at its
# session's last done (done); else, for a reviewer, at the task's last review after its launch and
# before the task's next reviewer launch (review); else at the first after its launch of the task's
# next launch of the same role (replaced), its stowed (stowed) or its closed (closed); else it is
# running (ended "running", end null). Its rounds are its session's dones, its first done the
# minutes to the first of them; its phases the minutes per phase of the task's segments (gate runs
# included) over its span, null for a legacy task.
def task_lifetimes($hi):
  . as $events
  | (map(select(.event == "opened")) | first) as $opened
  | (if $opened then task_segments($hi) | with_gate_runs($events | gate_intervals) else null end) as $segments
  | range(length) as $k
  | $events[$k] as $l
  | select($l.event == "launch" and ($l.session | type) == "string" and $l.session != "")
  | $events[$k + 1:] as $after
  | ($l.ts | fromdate) as $start
  | [$events[] | select(.event == "done" and .session == $l.session)] as $dones
  | ((if $dones != [] then {end: $dones[-1].ts, ended: "done"} else null end)
     // (if $l.role == "reviewer" then
           ((([range($after | length) as $j | select($after[$j] | .event == "launch" and .role == "reviewer") | $j] | first) // ($after | length)) as $n
            | [$after[:$n][] | select(.event == "review")] | last | if . then {end: .ts, ended: "review"} else null end)
         else null end)
     // ([$after[] | select((.event == "launch" and .role == $l.role) or .event == "stowed" or .event == "closed")] | first
         | if . then {end: .ts, ended: (if .event == "launch" then "replaced" else .event end)} else null end)
     // {end: null, ended: "running"}) as $end
  | ((if $end.end then $end.end | fromdate else $hi end)) as $stop
  | {task: $l.task, project: ($l.project // $opened.project // "-"), path: ($opened.path // "-"), role: $l.role,
     session: $l.session, model: ($l.model // "default"), start: $l.ts, end: $end.end, ended: $end.ended,
     minutes: (if $end.end then ($stop - $start) / 60 | tenths else null end),
     rounds: ($dones | length),
     first_done_minutes: (if $dones == [] then null else (($dones[0].ts | fromdate) - $start) / 60 | tenths end),
     phases: (if $segments == null then null
       else (reduce ($segments[] | clip($start; $stop)) as $s ({}; .[$s.class] += $s.to - $s.from)) as $seconds
         | [time_phases[] | .[0] | select($seconds[.]) | {(.): ($seconds[.] / 60 | tenths)}] | add // {} end),
     transcript: null}
  | if .ended == "running" then . + {age_minutes: (($stop - $start) / 60 | tenths)} else . end;

# The stats of a group of lifetimes, in minutes to one decimal: workers, mean, median and 90th
# percentile by nearest rank, and longest.
def lifetime_stats($hi):
  map(span_minutes($hi)) as $m
  | {workers: ($m | length), mean: ($m | add / length | tenths), median: ($m | nearest_rank(0.5) | tenths),
     p90: ($m | nearest_rank(0.9) | tenths), longest: ($m | max | tenths)};

# Lifetimes grouped by role and $key (a field name, or null for the role alone), each group's
# stats, in role order, then most workers first, then by the key.
def stats_by($key; $hi):
  group_by([.role, (if $key then .[$key] else null end)])
  | map({role: .[0].role} + (if $key then {($key): .[0][$key]} else {} end) + lifetime_stats($hi))
  | sort_by(role_rank, -.workers, (if $key then .[$key] else null end));

# The workers report over the ledger's lines (jq -nR inputs), for the window [$lo, $hi] (seconds)
# of every task or only $task: lifetimes (ended in the window, by start), running (started by $hi,
# with age_minutes), stats (by_role, by_role_path, by_role_project, by_role_model, over the ended
# ones) and longest (the ten longest ended lifetimes' sessions, longest first).
def workers_report($lo; $hi; $task):
  [ledger_events | by_task | .[]
    | select($task == null or .[0].task == $task)
    | map(select(.ts | fromdate <= $hi))
    | task_lifetimes($hi)]
  | sort_by(.start) as $all
  | [$all[] | select(.end != null and (.end | fromdate) >= $lo)] as $ended
  | {lifetimes: $ended,
     running: [$all[] | select(.end == null)],
     stats: {by_role: ($ended | stats_by(null; $hi)), by_role_path: ($ended | stats_by("path"; $hi)),
       by_role_project: ($ended | stats_by("project"; $hi)), by_role_model: ($ended | stats_by("model"; $hi))},
     longest: ($ended | sort_by(-span_minutes($hi)) | .[:10] | map(.session))};

# A number of minutes to one decimal as text, or "-" for null.
def m1: if . == null then "-" else h1 end;

# The workers report (team-time/1's workers) as text.
def workers_text:
  .workers as $w
  | ($w.lifetimes | length) as $n
  | "Worker lifetimes ended in the window: \($n)\(if $n > 0 then " (\($w.stats.by_role | map("\(.workers) \(.role)\(if .workers == 1 then "" else "s" end)") | join(", ")))" else "" end), \($w.running | length) running",
    (if $n == 0 then empty
     else
       def stats_rows($key): [.[] | [.role, .[$key], (.workers | tostring), (.mean, .median, .p90, .longest | m1)]];
       "",
       "Lifetimes by role and path, minutes",
       ([["role", "path", "workers", "mean", "median", "p90", "longest"]]
         + [$w.stats.by_role[] | .role as $role
             | ([. + {path: "all"}] | stats_rows("path")[]), ($w.stats.by_role_path | map(select(.role == $role)) | stats_rows("path")[])]
         | table),
       "",
       "Lifetimes by role and project, minutes",
       ([["role", "project", "workers", "mean", "median", "p90", "longest"]] + ($w.stats.by_role_project | stats_rows("project")) | table),
       "",
       "Lifetimes by role and model, minutes",
       ([["role", "model", "workers", "mean", "median", "p90", "longest"]] + ($w.stats.by_role_model | stats_rows("model")) | table),
       "",
       "Longest lifetimes",
       (($w.lifetimes | map({(.session): .}) | add) as $by
         | [["task", "role", "session", "path", "project", "minutes", "ended", "rounds", "first done"]]
           + [$w.longest[] | $by[.] | [.task, .role, .session, .path, .project, (.minutes | m1), .ended, (.rounds | tostring), (.first_done_minutes | m1)]]
         | table)
     end),
    "",
    (if $w.running == [] then "Running at the window's end: none"
     else "Running at the window's end",
       ([["task", "role", "session", "minutes so far"]] + [$w.running[] | [.task, .role, .session, (.age_minutes | m1)]] | table) end);
