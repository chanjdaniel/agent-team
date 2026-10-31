# Worker lifetimes: how long each worker lived, from its launch to its end, from the ledger, and
# where its time went, from its time rows. Used by team-time as jq -L bin/lib -nR 'include
# "workers"; include "time"; include "ledger"; workers_report(...)' over the ledger's lines, then
# workers_join(...) on its rows.
# Includes ledger.jq for the events and time.jq for a task's phase segments, the clipping and the
# percentiles.
include "ledger";
include "time";

# The roles in report order; any other role comes after them, by name.
def role_rank: .role as $role | [(["builder", "reviewer", "planner", "ops"] | index($role)) // 4, $role];

# A lifetime's minutes, unrounded, from its start to its end, or to $hi while it runs.
def span_minutes($hi): (((if .end then .end | fromdate else $hi end) - (.start | fromdate)) / 60);

# The index of a list of events' first launch of $role, else its length.
def first_launch($role): . as $events | ([range(length) as $j | select($events[$j] | .event == "launch" and .role == $role) | $j] | first) // length;

# A worker's rounds (input: its round events in time order, then ledger order): each a list of
# them with at, the time of its report. A done or a pr is a report, which ends a round; the
# ticket-dones before it join that round, and the coordinator logs a report's done with its
# ticket-done or pr, so an event within 5 minutes after a round's last joins it, unless both are
# dones. A round of ticket-dones alone is at its last.
def worker_rounds:
  reduce .[] as $e ([];
    ($e.event == "ticket-done" | not) as $report
    | (.[-1]) as $round
    | if $round != null and $round.at == null then
        .[-1] |= (.events += [$e] | .at = (if $report then $e.ts else null end))
      elif $round != null and ($e.ts | fromdate) - ($round.events[-1].ts | fromdate) <= 300
        and ($e.event == "done" and any($round.events[]; .event == "done") | not) then
        .[-1].events += [$e]
      else . + [{events: [$e], at: (if $report then $e.ts else null end)}] end)
  | map(.at //= .events[-1].ts);

# A task's worker lifetimes (input: its events in ledger order, only those at or before $hi): one
# per launch with a session. Its project is the launch's, else the task's opened; its path the
# opened's, else "-" (a legacy task); its model the launch's, else "default". Its rounds
# (worker_rounds) are of its session's dones and, for a builder, the task's pr and ticket-done
# events after its launch and before the task's next builder launch (which name no session:
# ends_worker in ledger.jq); it ends at its last round's last event (ended done when that round
# holds a done, else pr or ticket-done); else, for a reviewer, at the task's last review after its
# launch and before the task's next reviewer launch (review); else at the first after its launch of
# the task's next launch of the same role (replaced), its stowed (stowed) or its closed (closed);
# else it is running (ended "running", end null). Its first done is the minutes to its first
# round's report; its phases the minutes per phase of the task's segments (gate runs included)
# over its span, null for a legacy task. Its segments, those over its span, are for workers_join,
# which drops them.
def task_lifetimes($hi):
  . as $events
  | (map(select(.event == "opened")) | first) as $opened
  | (if $opened then task_segments($hi) | with_gate_runs($events | gate_intervals) else null end) as $segments
  | range(length) as $k
  | $events[$k] as $l
  | select($l.event == "launch" and ($l.session | type) == "string" and $l.session != "")
  | $events[$k + 1:] as $after
  | ($l.ts | fromdate) as $start
  | ($k + 1 + (if $l.role == "builder" then $after | first_launch("builder") else 0 end)) as $delivered
  | ([$events | to_entries[] | select(.key > $k)
      | select((.value.event == "done" and .value.session == $l.session)
          or (.key < $delivered and (.value.event == "pr" or .value.event == "ticket-done")))]
     | sort_by(.value.ts, .key) | map(.value) | worker_rounds) as $rounds
  | ((if $rounds != [] then $rounds[-1]
        | {end: .events[-1].ts, ended: (if any(.events[]; .event == "done") then "done" elif any(.events[]; .event == "pr") then "pr" else "ticket-done" end)}
      else null end)
     // (if $l.role == "reviewer" then
           [$after[:$after | first_launch("reviewer")][] | select(.event == "review")] | last | if . then {end: .ts, ended: "review"} else null end
         else null end)
     // ([$after[] | select((.event == "launch" and .role == $l.role) or .event == "stowed" or .event == "closed")] | first
         | if . then {end: .ts, ended: (if .event == "launch" then "replaced" else .event end)} else null end)
     // {end: null, ended: "running"}) as $end
  | ((if $end.end then $end.end | fromdate else $hi end)) as $stop
  | {task: $l.task, project: ($l.project // $opened.project // "-"), path: ($opened.path // "-"), role: $l.role,
     session: $l.session, model: ($l.model // "default"), start: $l.ts, end: $end.end, ended: $end.ended,
     minutes: (if $end.end then ($stop - $start) / 60 | tenths else null end),
     rounds: ($rounds | length),
     first_done_minutes: (if $rounds == [] then null else (($rounds[0].at | fromdate) - $start) / 60 | tenths end),
     phases: (if $segments == null then null
       else (reduce ($segments[] | clip($start; $stop)) as $s ({}; .[$s.class] += $s.to - $s.from)) as $seconds
         | [time_phases[] | .[0] | select($seconds[.]) | {(.): ($seconds[.] / 60 | tenths)}] | add // {} end),
     transcript: null,
     segments: (if $segments == null then null else [$segments[] | clip($start; $stop)] end)}
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

# The classes of a time row's key in report order, with their labels; unseen is the part of a
# lifetime its transcript never saw.
def worker_classes: [
  ["model", "the model's turns"], ["compaction", "compactions"], ["wait:message", "waiting for a message"],
  ["wait:other", "other waits"], ["wait:error", "waiting after an API error"], ["checks", "local checks"], ["gate", "the gate"], ["ci", "waiting on CI"],
  ["tests", "tests"], ["stacks", "stacks"], ["browser", "the browser"], ["subagents", "subagents"],
  ["files", "reading and editing"], ["git", "git and GitHub"], ["other", "other commands and tools"],
  ["unseen", "not in the transcript"]
];

# A time row's key's class, first match wins, looking through "background " and the key's kind
# (bash, monitor or tool): model, compaction, the three waits; then a command's: checks
# (team-checks, or a name naming a linter, formatter or type checker, go vet), gate (no-mistakes,
# git push no-mistakes), ci (gh or gh-axi pr checks, run watch or run view), tests (tests/run,
# bats, playwright, pytest, vitest, jest, go test, cargo test, npm test or npm run test and the
# like, a program with test in its name), stacks (team-stack, docker), browser
# (chrome-devtools-axi, team-ui), git (any other git, gh or gh-axi); a tool's: browser (Chrome
# DevTools' MCP tools), subagents (Agent), files (Read, Edit, Write, Grep, Glob, NotebookEdit);
# else other.
def key_class:
  sub("^background "; "") as $key
  | ($key | capture("^(?<kind>bash|monitor|tool) (?<name>.+)$") // {kind: null, name: $key}) as {$kind, $name}
  | ($name | split(" ")) as $words
  | if $kind == null then
      {"model": "model", "compaction": "compaction", "wait message": "wait:message", "wait other": "wait:other",
       "wait error": "wait:error"}[$key] // "other"
    elif $kind == "tool" then
      if $name | test("chrome[-_]devtools"; "i") then "browser"
      elif $name == "Agent" then "subagents"
      elif IN($name; "Read", "Edit", "Write", "Grep", "Glob", "NotebookEdit") then "files"
      else "other" end
    elif $words[0] == "team-checks" or ($name | test("lint|format|fmt|type-?check|tsc|eslint|prettier|shellcheck|ruff|mypy|^go vet")) then "checks"
    elif $words[0] == "no-mistakes" or $name == "git push no-mistakes" then "gate"
    elif IN($name; "gh pr checks", "gh run watch", "gh run view", "gh-axi pr checks", "gh-axi run watch", "gh-axi run view") then "ci"
    elif any($words[]; IN(.; "bats", "playwright", "pytest", "vitest", "jest"))
      or ($name | test("^((go|cargo|npm|pnpm|yarn|bun) test|(npm|pnpm|yarn|bun) run test)"))
      or ($words[0] != "test" and ($words[0] | test("test"))) then "tests"
    elif IN($words[0]; "team-stack", "docker") then "stacks"
    elif IN($words[0]; "chrome-devtools-axi", "team-ui") then "browser"
    elif IN($words[0]; "git", "gh", "gh-axi") then "git"
    else "other" end;

# A time row's time ("2026-10-30T07:02:30.095Z", its fraction optional) in seconds since the epoch.
def instant: capture("^(?<s>[^.]+?)(?<f>\\.[0-9]+)?Z$") | (.s + "Z" | fromdate) + ("0\(.f // "")" | tonumber);

# An object's entries in the order of $keys, only the keys it has.
def ordered($keys): . as $o | [$keys[] | select($o[.] != null) | {(.): $o[.]}] | add // {};

# An object of seconds as minutes to one decimal, in the order of $keys, only the keys it has.
def minutes_in($keys): map_values(. / 60 | tenths) | ordered($keys);

# The phase keys in report order: time_phases', then "-" for a legacy task, which has none.
def phase_keys: [time_phases[] | .[0]] + ["-"];

# Time rows' keys summed over the rows: {key: {seconds, calls, longest}}.
def key_totals:
  reduce (.[] | .keys | to_entries[]) as $e ({};
    .[$e.key] |= {seconds: (.seconds + $e.value.seconds), calls: (.calls + $e.value.calls), longest: ([.longest // 0, $e.value.longest] | max)});

# Summed keys as seconds per class.
def class_seconds: reduce to_entries[] as $e ({}; .[$e.key | key_class] += $e.value.seconds);

# Each lifetime joined to its time rows ($rows, the rows whose session begins with its own):
# {lifetime, keys (null with no row), seconds, unseen and waits (seconds by wait class and phase,
# each wait cut to the lifetime's span, then to its task's segments, all under "-" for a legacy
# task)}.
def joined($rows):
  .[] as $l
  | [$rows[] | select(.session | startswith($l.session))] as $mine
  | ($l.start | fromdate) as $start | ($l.end | fromdate) as $stop
  | if $mine == [] then {lifetime: $l, keys: null}
    else ($mine | key_totals) as $keys
      | ([$keys[].seconds] | add) as $seconds
      | {lifetime: $l, keys: $keys, seconds: $seconds, first: ($mine | map(.first) | min), last: ($mine | map(.last) | max),
         unseen: ([($stop - $start) - $seconds, 0] | max),
         waits: (reduce ($mine[].waits[] | {from: (.from | instant), to: (.to | instant), class: (.key | key_class)} | clip($start; $stop)) as $w ({};
           if $l.segments == null then .[$w.class]["-"] += $w.to - $w.from
           else reduce ($l.segments[] | clip($w.from; $w.to)) as $s (.; .[$w.class][$s.class] += $s.to - $s.from) end))}
    end;

# A joined lifetime's transcript part: its minutes, first and last, class minutes, top three keys
# (minutes, calls, longest), unseen minutes and its waits' minutes by class and phase; null with no
# row.
def transcript_part:
  if .keys == null then null
  else {minutes: (.seconds / 60 | tenths), first, last,
    classes: (.keys | class_seconds | minutes_in(worker_classes | map(.[0]))),
    top: (.keys | to_entries | sort_by(-.value.seconds, .key) | .[:3]
      | map({key, minutes: (.value.seconds / 60 | tenths), calls: .value.calls, longest: (.value.longest / 60 | tenths)})),
    unseen: (.unseen / 60 | tenths),
    waits: (.waits | map_values(minutes_in(phase_keys)) | ordered(worker_classes | map(.[0])))}
  end;

# The breakdown over joined lifetimes: coverage (lifetimes and those with a transcript, in all and
# per role); per role, and all, the minutes of each class (unseen included) and its share of them
# in percent to one decimal; the fifteen keys with the most time (key, class, minutes, calls,
# longest, lifetimes); and per role the minutes waiting for a message by the task's phase.
def breakdown:
  . as $all
  | [$all[] | select(.keys)] as $with
  | ([$all[].lifetime] | group_by(.role) | sort_by(.[0] | role_rank) | map(.[0].role)) as $roles
  | ([$with[].lifetime] | group_by(.role) | sort_by(.[0] | role_rank) | map(.[0].role)) as $seen
  | (worker_classes | map(.[0])) as $classes
  | ([$seen[] as $role | {($role): (reduce ($with[] | select(.lifetime.role == $role)) as $j ({};
       reduce ($j.keys | class_seconds | to_entries[]) as $c (.; .[$c.key] += $c.value) | .unseen += $j.unseen))}] | add // {}) as $by_role
  | ($by_role | if . == {} then {} else . + {all: (reduce .[] as $r ({}; reduce ($r | to_entries[]) as $c (.; .[$c.key] += $c.value)))} end) as $seconds
  | {coverage: {lifetimes: ($all | length), transcripts: ($with | length),
       roles: [$roles[] as $role | {role: $role, lifetimes: ([$all[] | select(.lifetime.role == $role)] | length),
         transcripts: ([$with[] | select(.lifetime.role == $role)] | length)}]},
     classes: ($seconds | map_values(with_entries(select(.value > 0)) | minutes_in($classes))),
     share: ($seconds | map_values(with_entries(select(.value > 0)) | ([.[]] | add) as $total
       | map_values(. * 100 / $total | tenths) | ordered($classes))),
     top: ([$with[] | .keys | to_entries[]] | group_by(.key)
       | map({key: .[0].key, class: (.[0].key | key_class), seconds: (map(.value.seconds) | add),
           calls: (map(.value.calls) | add), longest: (map(.value.longest) | max), lifetimes: length})
       | sort_by(-.seconds, .key) | .[:15]
       | map({key, class, minutes: (.seconds / 60 | tenths), calls, longest: (.longest / 60 | tenths), lifetimes})),
     waits: ([$seen[] as $role | {($role): (reduce ($with[] | select(.lifetime.role == $role) | .waits["wait:message"] // {} | to_entries[]) as $p ({};
       .[$p.key] += $p.value) | minutes_in(phase_keys))}] | add // {})};

# The workers report (input: team-time/1's workers) joined to team-tokens time's rows ($rows), or,
# when it could not run, with its error ($error, null when it ran or was not needed): each
# lifetime's transcript, the breakdown (null with $error) and transcripts {rows, error}; the
# lifetimes' segments are dropped.
def workers_join($rows; $error):
  [.lifetimes | if $error then .[] | {lifetime: ., keys: null} else joined($rows) end] as $joined
  | .lifetimes = [$joined[] | .lifetime + {transcript: transcript_part} | del(.segments)]
  | .running |= map(del(.segments))
  | .breakdown = (if $error then null else $joined | breakdown end)
  | .transcripts = {rows: (if $error then null else $rows | length end), error: $error};

# A number of minutes to one decimal as text, or "-" for null.
def m1: if . == null then "-" else h1 end;

# A phase key's label: time_phases' row, or the legacy task's.
def phase_label: . as $p | ((time_phases[] | select(.[0] == $p) | .[2]) // "no phases (a legacy task)");

# Where the workers' time went (input: team-time/1's workers) as text: per class each role's
# minutes and the share of all, the top time sinks, and the waits for a message by the task's
# phase; or one line when team-tokens could not run.
def breakdown_text:
  if .transcripts.error then "Where workers' time went: unavailable: \(.transcripts.error)"
  else .breakdown as $b
    | ($b.classes | keys_unsorted - ["all"]) as $roles
    | if $b.coverage.transcripts == 0 then "Where workers' time went: no transcript for any of the \($b.coverage.lifetimes) lifetimes"
      else "Where workers' time went (transcripts for \($b.coverage.transcripts) of \($b.coverage.lifetimes) lifetimes), minutes",
        ([["class"] + $roles + ["share"]]
          + [worker_classes[] | .[0] as $c | select($b.classes.all[$c]) | [.[1]] + [$roles[] | $b.classes[.][$c] // 0 | m1] + ["\($b.share.all[$c] | m1)%"]]
          + [["all"] + [$roles[] | [$b.classes[.][]] | add | m1] + ["100.0%"]]
          | table),
        "",
        "Top time sinks",
        ([["key", "class", "minutes", "calls", "longest", "lifetimes"]]
          + [$b.top[] | [.key, .class, (.minutes | m1), (.calls | tostring), (.longest | m1), (.lifetimes | tostring)]]
          | table),
        "",
        ([phase_keys[] as $p | select(any($b.waits[]; .[$p])) | $p] as $phases
          | if $phases == [] then "Waiting for a message, by what the task was doing: none"
            else "Waiting for a message, by what the task was doing, minutes",
              ([["phase"] + $roles] + [$phases[] as $p | [$p | phase_label] + [$roles[] | $b.waits[.][$p] // 0 | m1]] | table) end)
      end
  end;

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
         | [["task", "role", "session", "path", "project", "minutes", "ended", "rounds", "first done", "top sinks"]]
           + [$w.longest[] | $by[.] | [.task, .role, .session, .path, .project, (.minutes | m1), .ended, (.rounds | tostring), (.first_done_minutes | m1),
               (.transcript.top // [] | map("\(.key) \(.minutes | round)") | if . == [] then "-" else join(", ") end)]]
         | table),
       "",
       ($w | breakdown_text)
     end),
    "",
    (if $w.running == [] then "Running at the window's end: none"
     else "Running at the window's end",
       ([["task", "role", "session", "minutes so far"]] + [$w.running[] | [.task, .role, .session, (.age_minutes | m1)]] | table) end);
