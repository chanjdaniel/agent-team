# Checking ledger lines against the ledger contract (ledger-contract.json, passed as $contract),
# and reading state from them. Used through ledger_jq in team.sh. Each *_problems def yields one
# string per problem found.

# A jq type, or a field type of the contract, as a noun: "a list", "a number", "null".
def noun:
  {array: "a list", object: "an object", boolean: "a boolean", number: "a number", string: "a string", null: "null"}[.];

# What every line must meet, legacy lines included: an object with ts, task and event.
def line_problems:
  if type != "object" then "not a JSON object"
  else
    (("ts", "task", "event") as $key | select(has($key) | not) | "missing \($key)"),
    (select(has("ts")) | .ts | select(type != "string" or (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not))
      | "ts must be a UTC time like 2026-10-22T01:00:00Z"),
    (select(has("task")) | .task | select(type != "string" or (test("^T[1-9][0-9]*$") | not)) | "task must look like T<n>"),
    (select(has("event")) | .event | select(type != "string" or . == "") | "event must be a kind's name")
  end;

# How the value breaks field <name>'s contract type (a type name, or a list of allowed strings).
# (A parameter named $type would shadow the builtin type inside the def.)
def type_problems($name; $want):
  if ($want | type) == "array" then
    select(IN($want[]) | not) | "\($name) must be one of \($want | join(", "))"
  elif type != $want then
    "\($name) must be \($want | noun), got \(type | noun)"
  else empty end;

# The field types a kind's line may carry: its required and optional fields, and note.
def field_types($kind): $kind.required + ($kind.optional // {}) + {note: "string"};

# What a line of a known kind must meet: its required fields present and not empty, and every
# field the contract types holding that type.
def kind_problems($contract):
  . as $line
  | .event as $event
  | $contract.kinds[$event] as $kind
  | if $kind == null then "unknown event kind '\($event)'"
    else
      ($kind.required | keys_unsorted[] | select($line[.] == null or $line[.] == "") | "\($event) needs \(.)"),
      (field_types($kind) | to_entries[] | .key as $name | .value as $type
        | $line[$name] | select(. != null and . != "") | type_problems($name; $type))
    end;

# What a line in an existing ledger must meet: legacy lines (before strict_from) only the basics.
def check_problems($contract):
  [line_problems] as $basic
  | if $basic != [] then $basic[]
    elif .ts >= $contract.strict_from then kind_problems($contract)
    else empty end;

# What an event must meet to be appended by script $writer: the basics, then that $writer is
# the kind's writer, then the kind's fields, whatever its ts. Only the first failing step is told.
def append_problems($contract; $writer):
  (if type == "object" then .event else null end) as $event
  | ([line_problems] | select(. != []))
    // ([$contract.kinds[$event].writer // empty | select(. != $writer) | "\($event) events are written by \(.), not \($writer)"]
      | select(. != []))
    // [kind_problems($contract)]
  | .[];

# The report of checking a ledger read as raw lines (jq -nR): {total, bad: [{line, problems}]}.
def check_ledger($contract):
  [inputs
    | (if test("^\\s*$") then null else (try {value: fromjson} catch null) end) as $parsed
    | if $parsed == null then ["not JSON"] else [$parsed.value | check_problems($contract)] end]
  | {total: length, bad: [to_entries[] | select(.value != []) | {line: (.key + 1), problems: .value}]};

# Pad a string with spaces to $width.
def pad($width): . + ([range($width - length)] | map(" ") | add // "");

# How a field type reads in the contract table: "commits (list)", "verdict (pass|findings)".
def field_text($want):
  if ($want | type) == "array" then "\(.) (\($want | join("|")))"
  elif $want == "string" then .
  else "\(.) (\($want | noun | ltrimstr("a ")))" end;

# The contract as a table, one row per kind: event, writer, fields, and what the kind is about.
def contract_table:
  .kinds | to_entries
  | (map(.key | length) | max) as $event_width
  | (map(.value.writer | length) | max) as $writer_width
  | "  \("event" | pad($event_width))  \("written by" | pad($writer_width))  fields",
    (.[] | .value as $kind
      | ([$kind.required | to_entries[] | .value as $type | .key | field_text($type)] as $fields
         | [($kind.optional // {}) | to_entries[] | .value as $type | .key | field_text($type)] as $optional
         | if $fields == [] then "-" else $fields | join(", ") end
           + if $optional == [] then "" else "; optional \($optional | join(", "))" end) as $text
      | "  \(.key | pad($event_width))  \($kind.writer | pad($writer_width))  \($text)"
        + if $kind.about then "  (\($kind.about))" else "" end);

# A recorded path as a path on this machine, whose home directory is $home: every machine keeps
# the same layout under its home, so one under /home/<name> or /Users/<name> is the same path
# under $home. Any other path, or a value that is not a string, is unchanged.
def local_path($home):
  if type == "string" then
    (capture("^/(home|Users)/[^/]+(?<rest>/.*)?$") | ($home | rtrimstr("/")) + (.rest // "")) // .
  else . end;

# An event with its recorded worktree, and the from of a worktree-moved, as paths on this machine
# (local_path).
def local_worktree($home):
  if type == "object" then
    (if has("worktree") then .worktree |= local_path($home) else . end)
    | if has("from") then .from |= local_path($home) else . end
  else . end;

# The open worktrees among a stream of ledger events: one {task, project, branch, worktree} per
# opened or worktree-added event with no later worktree-returned of the same task, project and
# worktree, in the order they were added; a worktree-moved gives the task's open worktree in its
# project its new path. Worktrees are paths on this machine (local_worktree).
def open_worktrees(events; $home):
  reduce (events | local_worktree($home)) as $e ([];
    if $e.event == "opened" or $e.event == "worktree-added" then
      . + [$e | {task, project, branch, worktree}]
    elif $e.event == "worktree-moved" then
      map(if [.task, .project] == [$e.task, $e.project] then .worktree = $e.worktree else . end)
    elif $e.event == "worktree-returned" then
      map(select([.task, .project, .worktree] != [$e.task, $e.project, $e.worktree]))
    else . end)
  | .[];

# A task's open worktrees (open_worktrees, over its events as an array), each with the folder
# under tasks/T<n>/ its task directory is archived to: scratch for the project the task was
# opened in, scratch-<project> for one added later.
def archived_worktrees($home):
  (map(select(.event == "opened")) | first | .project) as $opened
  | open_worktrees(.[]; $home)
  | . + {archive: (if .project == $opened then "scratch" else "scratch-\(.project)" end)};

# Whether two heads name the same commit: compared by the shorter one's prefix, which must be at
# least 7 characters, since the ledger holds both short and full SHAs.
def same_head($a; $b):
  if ($a | type) == "string" and ($b | type) == "string" then
    ([($a | length), ($b | length)] | min) as $n
    | $n >= 7 and ($a[:$n] | ascii_downcase) == ($b[:$n] | ascii_downcase)
  else false end;

# The following defs read a task's events, in ledger order, as an array.

# The task's status: open (opened by team-open, not closed), closed, legacy (from before
# team-open: events but no opened, not closed) or unknown (no events).
def task_status:
  if length == 0 then "unknown"
  elif any(.[]; .event == "closed") then "closed"
  elif any(.[]; .event == "opened") then "open"
  else "legacy" end;

# The task's PRs, one per repo, as {url, number, head}, in the order of their latest pr events. A
# task has one branch per repo, so a later pr event in the same repo is that branch's new PR and
# replaces the earlier one. A PR's head is its pr event's, moved by each later history-rewritten
# whose old_head is that head; one whose old_head is no PR's head (fixes pushed with no pr event
# since, or a legacy one with no old_head) moves every PR's head.
def task_prs:
  reduce .[] as $e ([];
    if $e.event == "pr" then
      (first($e.url | strings | capture("^https://github\\.com/(?<r>[^/]+/[^/]+)/") | .r | ascii_downcase) // $e.url) as $repo
      | map(select(.repo != $repo))
        + [{url: $e.url, repo: $repo, head: $e.head,
            number: (first($e.url | strings | capture("/pull/(?<n>[0-9]+)/?$") | .n | tonumber) // null)}]
    elif $e.event == "history-rewritten" then
      any(.[]; same_head($e.old_head; .head)) as $named
      | map(if ($named | not) or same_head($e.old_head; .head) then .head = $e.head else . end)
    else . end)
  | map(del(.repo));

# The head the ledger knows for the PR at $url, from task_prs.
def pr_head($url): task_prs | map(select(.url == $url)) | last | .head;

# Whether a PR of task_prs (the input) has a merged event among $events: by its URL when the
# event names one; a legacy event names only the number, and then, when another of the task's
# PRs ($prs) has the same number in another repo, its head must be the PR's.
def pr_merged($events; $prs):
  . as $pr
  | any($events[]; .event == "merged"
      and if .url != null then .url == $pr.url
        else $pr.number != null and (.pr | tostring) == ($pr.number | tostring)
          and (([$prs[] | select(.number == $pr.number)] | length) == 1 or same_head(.head; $pr.head)) end);

# Whether the latest event of $kind stands: none of the kinds $clears after it.
def standing($kind; $clears):
  ([to_entries[] | select(.value.event == $kind) | .key] | last) as $i
  | $i != null and all(.[$i + 1:][]; .event | IN($clears[]) | not);

# Whether the latest event of $kind stands: no resumed after it.
def standing($kind): standing($kind; ["resumed"]);

# Whether the latest event of $kind stands until a worker is launched: no resumed and no launch
# after it.
def standing_until_launch($kind): standing($kind; ["resumed", "launch"]);

# What the task is waiting on, from its latest waiting while it stands, or null.
def waiting:
  if standing_until_launch("waiting") then
    map(select(.event == "waiting")) | last | {on, reason, since: .ts}
  else null end;

# The task's phase, first match wins. Merged needs every PR of task_prs merged; awaiting-merge
# needs each PR not merged yet to have, as the latest review of its head, a pass.
def phase:
  . as $events
  | task_prs as $prs
  | [$prs[] | select(pr_merged($events; $prs) | not)] as $open
  | if any(.[]; .event == "closed") then "closed"
    elif any(.[]; .event == "merged") and $open == [] then "merged"
    elif standing("held") then "held"
    elif standing_until_launch("blocked") then "blocked"
    elif $open != [] and all($open[]; . as $pr
      | ($events | map(select(.event == "review" and same_head(.head; $pr.head))) | last | .verdict) == "pass") then "awaiting-merge"
    elif any(.[]; .event == "pr") then "in-review"
    elif any(.[]; .event == "plan-approved") then "building"
    else "planning" end;

# The index of the task's latest stowed, or -1 when it has none.
def latest_stowed: [to_entries[] | select(.value.event == "stowed") | .key] | last // -1;

# Whether the task crashed on a machine switch: a launch after its latest stowed, or a launch and
# no stowed at all, so the machine it last ran on stopped without handing it off.
def crashed: latest_stowed as $stowed | any(.[$stowed + 1:][]; .event == "launch");

# Whether the task's worktree in <project> resumes from the last checkpoint's snapshot: the task
# crashed, or its latest stowed recorded that worktree with uncommitted changes, which the
# handoff's checkpoint kept as wip/T<n>.
def snapshot_due($project):
  crashed or (latest_stowed as $stowed | $stowed >= 0
    and any(.[$stowed].worktrees[]?; .project == $project and .uncommitted == true));

# Whether the event ends the worker of <role>: its DONE, which the coordinator logs as a done of
# that role, a review (a reviewer's) or a ticket-done (a builder's).
def ends_worker($role):
  (.event == "done" and .role == $role) or (.event == "review" and $role == "reviewer")
  or (.event == "ticket-done" and $role == "builder");

# The roles to relaunch after a crash: each role launched since the task's latest stowed whose
# latest launch no later event ends (ends_worker), in the order of those launches. Never ops: an
# ops session runs only on Daniel's request, so after a crash Daniel asks again.
def crash_roles:
  . as $events
  | latest_stowed as $stowed
  | [to_entries[] | select(.key > $stowed and .value.event == "launch" and .value.role != "ops")
    | {i: .key, role: .value.role}]
  | group_by(.role) | map(max_by(.i)) | sort_by(.i)
  | map(.i as $i | .role as $role | select(all($events[$i + 1:][]; ends_worker($role) | not)) | .role);

# Every worktree the task was given (opened or added), at its latest path (worktree-moved), and
# whether it was returned since.
def worktree_list:
  . as $events
  | [to_entries[] | select(.value.event == "opened" or .value.event == "worktree-added")
    | .key as $i | .value as $w
    | reduce ($events[$i + 1:][] | select(.project == $w.project)) as $e
        ($w | {project, branch, worktree, returned: false};
         if .returned then .
         elif $e.event == "worktree-moved" then .worktree = $e.worktree
         elif $e.event == "worktree-returned" and $e.worktree == .worktree then .returned = true
         else . end)];

# A launch's session in the session list ($sessions, from claude agents --json), or null: by the
# short id, or by the start of the full session id (interactive sessions have no short id).
def live_session($session; $sessions):
  if ($session | type) == "string" and $session != "" then
    $sessions | map(select(.id == $session or ((.sessionId // "") | startswith($session)))) | first
  else null end;

# Every launch of the task, live when the session list has its session.
def workers($sessions):
  [.[] | select(.event == "launch") | live_session(.session; $sessions) as $live
    | {role, session, launched: .ts, worktree, live: ($live != null), status: $live.status, state: $live.state}];

# The asks put to Daniel with no answer yet.
def pending_asks:
  [.[] | select(.event == "answered") | .id] as $answered
  | [.[] | select(.event == "asked" and (.id | IN($answered[]) | not)) | {id, text, ts}];

# A task's state from its events and the session list, its worktrees as paths on this machine,
# whose home directory is $home (local_worktree); team-state adds the pr part.
def task_state($sessions; $home):
  map(local_worktree($home))
  | (map(select(.event == "opened")) | first) as $opened
  | {schema: "team-state/1", task: .[0].task, title: $opened.title, project: $opened.project,
     path: $opened.path, phase: phase, worktrees: worktree_list,
     thread: (map(select(.event == "thread") | .discord_thread) | last),
     workers: workers($sessions), last_event: last, pending_asks: pending_asks, waiting: waiting, pr: null};

# A task's state (team-state's JSON) as one line of text:
# T14 agent-team feature building | T14-builder idle | PR #5 a1b2c3d checks 2/2 agent-review missing
def state_line:
  .task as $task
  | ([.task, .project, .path, .phase] | map(select(. != null)) | join(" "))
  + " | "
  + ([.workers[] | select(.live)
      | "\($task)-\(.role) \(.status)" + if .state == null or .state == "working" then "" else " \(.state)" end]
     | if . == [] then "no live worker" else join(", ") end)
  + (if .pr == null then "" else
     .pr | if .number == null then " | PR \(.url) unreadable"
       else " | PR #\(.number)" end
       + if .number == null then ""
         elif .error then " GitHub unavailable"
         else
           (if .state == "open" then "" else " \(.state)" end)
           + " \(.head[:7])"
           + (if .head_moved then " (head moved)" else "" end)
           + " checks \(.checks.passed | length)/\(.checks | map(length) | add)"
           + " agent-review \(.agent_review)"
         end
     end)
  + (if .waiting == null then "" else " | waiting on \(.waiting.on): \(.waiting.reason)" end);

# Whether a task is parked, waiting on something other than a worker: held, blocked or awaiting
# merge, an ask with no answer, or a pause or a wait still standing.
def parked:
  IN(phase; "held", "blocked", "awaiting-merge") or pending_asks != [] or standing_until_launch("paused")
  or waiting != null;

# One of team-sweep's findings: {task, kind, session, name, next, text}, text being its one line.
def finding($task; $kind; $session; $name; $detail; $next):
  {task: $task, kind: $kind, session: $session, name: $name, next: $next,
   text: "\($task) \($kind): \($detail); next: \($next)"};

# The no-worker, waiting-input and silent findings of an open task that is not parked. A live
# session is judged by its latest launch, and one waiting for input is not also called silent.
# A live session is at work while it is busy, waiting for input, or idle with no ledger event
# since its launch (silent); idle with an event since, it has handed the next step back to the
# coordinator, so a task with no session at work is no-worker however many are live.
def task_findings($sessions):
  .[0].task as $task
  | length as $count
  | [to_entries[] | select(.value.event == "launch") | {i: .key, launch: .value}] as $launches
  | ([$launches | reverse | .[] | . + {live: live_session(.launch.session; $sessions)} | select(.live != null)
      | . + {short: (.live.id // .launch.session), name: (.live.name // "\($task)-\(.launch.role)")}]
     | unique_by(.short) | sort_by(.i)) as $live
  | ($live | map(select(.live.state == "blocked" or .live.status != "idle" or .i == $count - 1))) as $at_work
  | ($launches | last) as $latest
  | if $at_work == [] and any(.[]; .event == "opened" or .event == "launch") then
      if $latest == null then
        finding($task; "no-worker"; null; null; "opened with no worker launched";
          "launch one with team-worker, or log what is known with team-log")
      else
        "\($task)-\($latest.launch.role)" as $name | $latest.launch.session as $session
        | (if $live == [] then "with no live worker" else "with every live worker idle" end) as $how
        | if phase == "merged" then
            finding($task; "no-worker"; $session; $name;
              "merged and not closed, \($how) (latest \($name) \($session))"; "close it with team-close \($task)")
          elif $live == [] then
            finding($task; "no-worker"; $session; $name;
              "no live session among its \($launches | length) launch\(if ($launches | length) == 1 then "" else "es" end) (latest \($name) \($session))";
              "read claude logs \($session) for how it ended, then launch the next worker with team-worker or log what is known with team-log")
          else
            finding($task; "no-worker"; $session; $name;
              "every live worker is idle with a ledger event since its launch (latest \($name) \($session))";
              "send it its next step or launch the next worker with team-worker, or log why the task waits with team-log")
          end
      end
    else empty end,
    ($live[]
      | if .live.state == "blocked" then
          finding($task; "waiting-input"; .short; .name; "\(.name) \(.short) is waiting for input";
            "read claude logs \(.short), then answer it in one line or put the question to Daniel with team-log \($task) asked")
        elif .live.status == "idle" and .i == $count - 1 then
          finding($task; "silent"; .short; .name;
            "\(.name) \(.short) is idle with no ledger event since its launch at \(.launch.ts)";
            "read claude logs \(.short), then send it one line or log what is known with team-log")
        else empty end);

# The following defs read the whole ledger.

# Every ledger event of a task T<n>, read as raw lines (jq -nR), as one array in ledger order;
# lines that are not JSON objects with such a task are skipped.
def ledger_events:
  [inputs | fromjson? | select(type == "object" and (.task | type) == "string" and (.task | test("^T[1-9][0-9]*$")))];

# Ledger events as an object of each task's events, keyed by task id.
def by_task: group_by(.task) | map({key: .[0].task, value: .}) | from_entries;

# Whether a task's events (an array, or null for a task not in the ledger) are an open task's,
# opened by team-open or legacy: it has events and no closed.
def is_open: . != null and (task_status | IN("open", "legacy"));

# The live sessions named like team workers (T<n>-<role>), from the session list and every
# task's events by id: {task, role, name, session (the short id), status, state, logged (a launch
# of the task names it), task_state (open, closed, unknown when not in the ledger, or load-check for
# T0, team-load-check's task, which is never in the ledger)}.
def team_sessions($tasks; $sessions):
  [$sessions[] | . as $session
    | ((.name // "") | capture("^(?<task>T(0|[1-9][0-9]*))-(?<role>.+)$")) as $name
    | ($tasks[$name.task] // null) as $events
    | {task: $name.task, role: $name.role, name, session: (.id // ((.sessionId // "")[:8])), status, state,
       logged: ($events != null and any($events[]; .event == "launch" and live_session(.session; [$session]) != null)),
       task_state: (if $name.task == "T0" then "load-check" elif $events == null then "unknown"
         elif $events | is_open then "open" else "closed" end)}];

# Sort by task number.
def by_task_number: sort_by(.task[1:] | tonumber);

# Why a team session is a stray, from team_sessions: "T4 is closed", "T9 is not in the ledger",
# "T0 is the load check's, stray unless one is running".
def stray_reason:
  "\(.task) is \({unknown: "not in the ledger", "load-check": "the load check's, stray unless one is running"}[.task_state] // "closed")";

# The following defs serve team-retro status and team-sweep's retro-due finding, over every ledger
# event as one array.

# Whether an event opens a retro task: an opened event with the path retro.
def retro_opened: .event == "opened" and .path == "retro";

# The retro tasks' opened events in ledger order, each with its place in the ledger as i.
def retros: [to_entries[] | select(.value | retro_opened) | .value + {i: .key}];

# team-retro status's JSON. The schedule is the latest retro-schedule, on while every_hours is
# above 0; the next retro is due every_hours after the later of its time and the latest retro
# task's opening, unless a retro task is still open.
def retro_status:
  . as $events
  | retros as $retros
  | ($events | map(select(.event == "retro-schedule")) | last
     | if . != null and (.every_hours | type) == "number" and .every_hours > 0 then {every_hours, since: .ts, discord_message, task}
       else null end) as $schedule
  | ($retros | last) as $last
  | ([$retros[] | .task as $task | select($events | map(select(.task == $task)) | task_status == "open")] | last | .task) as $running
  | (if $schedule == null then null
     else ([$schedule.since, ($last.ts // empty)] | max | fromdate) + $schedule.every_hours * 3600 | floor | todate end) as $next
  | {schema: "team-retro-status/1",
     schedule: $schedule,
     last: ($last | if . == null then null else .task as $task
       | {task: $task, opened: .ts, status: ($events | map(select(.task == $task)) | task_status)} end),
     running: $running,
     next: $next,
     due: ($schedule != null and $running == null and now >= ($next | fromdate))};

# team-sweep's retro-due finding, from team-retro status's JSON: one while a retro is due, else none.
def retro_due_finding:
  select(.due)
  | {task: null, kind: "retro-due", session: null, name: null, next: "run the retro skill",
     text: "retro due since \(.next) (every \(.schedule.every_hours)h, last retro \(.last.task // "none")): run the retro skill"};

# team-sweep's findings, over every ledger event as one array and the session list: each open
# task's unless it is parked, then the stray sessions (named like a team worker whose task is
# closed or not in the ledger, never the load check's T0, whose session the coordinator waits on
# for up to 30 minutes), in task number order; then the retro-due finding.
def sweep($sessions):
  . as $events
  | by_task as $tasks
  | ([($tasks[] | select(is_open) | select(parked | not) | task_findings($sessions)),
      (team_sessions($tasks; $sessions)[] | select(.task_state | IN("closed", "unknown"))
        | finding(.task; "stray"; .session; .name;
            "\(.name) \(.session) is live but \(stray_reason)";
            "read claude logs \(.session) for anything left to log, then stop it with claude stop \(.session)"))]
     | by_task_number)
    + [$events | retro_status | retro_due_finding];

# The ids of the open tasks among every task's events by id, in task number order.
def open_tasks: [to_entries[] | select(.value | is_open) | .key] | sort_by(.[1:] | tonumber);

# team-snapshot's JSON from every task's events by id ($tasks), the open tasks' team-state JSON
# in task number order ($states; {task, error} for a task whose state could not be told), the
# session list, and each registered project's open PRs ($prs).
def snapshot($tasks; $states; $sessions; $prs):
  team_sessions($tasks; $sessions) as $team
  | {schema: "team-snapshot/1",
     tasks: $states,
     sessions: [$team[] | select(.task_state == "open") | del(.task_state)],
     strays: [$team[] | select(.task_state != "open") | del(.logged)],
     prs: $prs,
     pending_asks: [$states[] | .task as $task | (.pending_asks // [])[] | {task: $task} + .]};

# Cut a line to $n characters, showing the cut.
def clip($n): if length > $n then .[:$n - 3] + "..." else . end;

# A live session as text: its name, short id, status, and state unless working.
def session_text:
  "\(.name) \(.session) \(.status)" + if .state == null or .state == "working" then "" else " \(.state)" end;

# team-snapshot's text form, one line per string, from its JSON. Lines are cut at 120 columns, so
# ten open tasks fit one screen.
def snapshot_text:
  def section($title; $lines):
    if $lines == [] then "\($title): none" else "\($title) (\($lines | length)):", ($lines[] | "  " + . | clip(120)) end;
  section("Open tasks"; [.tasks[] | if .error then "\(.task) state unreadable: \(.error)" else state_line end]),
  section("Live team sessions";
    [.sessions[] | session_text + if .logged then "" else " (no launch of it in the ledger)" end]),
  section("Stray sessions";
    [.strays[] | session_text + ": \(stray_reason)"]),
  (if .prs == [] then "Open PRs: no registered projects"
   else "Open PRs:",
     (.prs[] | "  \(.project) (\(.repo)):" as $heading
       | if .error then "\($heading) GitHub unavailable (\(.error))" | clip(120)
         elif .prs == [] then "\($heading) none"
         else $heading,
           (.prs[] | "    #\(.number) \(.branch)" + (if .draft then " (draft)" else "" end) + ": \(.title)" | clip(120))
         end)
   end),
  section("Pending asks"; [.pending_asks[] | "\(.task) \(.id): \(.text)"]);

# The following defs serve team-retro, over every ledger event as one array.

# The hours from one UTC time to another, to two decimals.
def hours($from; $to): (($to | fromdate) - ($from | fromdate)) / 3600 * 100 | round / 100;

# team-retro status's text form, one line, from its JSON.
def retro_status_text:
  (if .last == null then "" else " Last: \(.last.task), opened \(.last.opened), \(.last.status)." end) as $last
  | (if .running == null then "" else " Running \(.running)." end) as $running
  | if .schedule == null then "Retros are not scheduled." + $last + $running
    else "Retros every \(.schedule.every_hours)h since \(.schedule.since) (Discord \(.schedule.discord_message))."
      + (if .last == null then " No retro yet." else $last end)
      + if .running != null then $running elif .due then " Due since \(.next)." else " Next due \(.next)." end
    end;

# A retro's window as {task, previous, since, until, start, end}, start and end being places in
# the ledger (end exclusive). For the retro task $task: after the opening of the retro opened
# before it, or from the first event, up to and including its own opening. For a dry run ($task
# null): after the latest retro's opening, up to now.
def retro_window($task):
  . as $events
  | retros as $retros
  | (if $task == null then {this: null, previous: ($retros | last)}
     else ($retros | map(.task == $task) | index(true)) as $k
       | {this: $retros[$k], previous: (if $k > 0 then $retros[$k - 1] else null end)} end) as $w
  | {task: $task, previous: $w.previous.task,
     since: ($w.previous.ts // $events[0].ts), until: ($w.this.ts // (now | todate)),
     start: (if $w.previous == null then 0 else $w.previous.i + 1 end),
     end: (if $w.this == null then length else $w.this.i + 1 end)};

# Every span that parks a task, over one task's events (each with its place i) in ledger order:
# {task, kind, on, reason, start, end}, end being the event that clears it, or null. waiting,
# paused and blocked clear at the next resumed or launch, held at the next resumed, asked at the
# answered of its id, and every one at the task's closed.
def wait_spans:
  . as $events
  | range(length) as $k | $events[$k] as $s
  | {waiting: ["resumed", "launch"], paused: ["resumed", "launch"], blocked: ["resumed", "launch"], held: ["resumed"], asked: []}[$s.event | tostring] as $clears
  | select($clears != null)
  | {task: $s.task, kind: $s.event,
     on: (if $s.event == "waiting" then $s.on // "unknown" elif $s.event == "asked" then "Daniel" else $s.event end),
     reason: (if $s.event == "asked" then $s.text else $s.reason end),
     start: $s,
     end: (first($events[$k + 1:][] | select(.event == "closed" or (.event | IN($clears[]))
       or ($s.event == "asked" and .event == "answered" and .id == $s.id))) // null)};

# The hours covered by the union of the spans ({from, to}), overlapping spans counted once.
def wall_hours:
  map([(.from | fromdate), (.to | fromdate)]) | sort
  | reduce .[] as [$from, $to] ([];
      if . != [] and $from <= .[length - 1][1] then .[length - 1][1] = ([.[length - 1][1], $to] | max)
      else . + [[$from, $to]] end)
  | map(.[1] - .[0]) | add / 3600 * 100 | round / 100;

# Whether a blocked or failed reason says an action was refused.
def denial: (. // "") | tostring | test("denied|denies|refused|refuses|auto mode"; "i");

# Events grouped by task, the groups in the order of each task's first event.
def task_groups: group_by(.task) | sort_by(.[0].i);

# team-retro digest's JSON for the retro task $task (null for a dry run), the team home $home
# naming each task's record directory. Every section is in ledger order.
def retro_digest($task; $home):
  . as $events
  | retro_window($task) as $w
  | [to_entries[] | .value + {i: .key}] as $placed
  | $placed[$w.start:$w.end] as $in
  | ([$placed | task_groups[] | wait_spans | .end as $end
      | select(.start.i < $w.end and ($end == null or $end.i >= $w.start))
      | (.start.i < $w.start) as $clipped
      | ($end == null or $end.i >= $w.end) as $open
      | (if $clipped then $w.since else .start.ts end) as $from
      | (if $open then $w.until else $end.ts end) as $to
      | {task, kind, on, reason, from: $from, to: $to, hours: hours($from; $to), open: $open, clipped: $clipped, i: .start.i}]
     | sort_by(.i) | map(del(.i))) as $spans
  | ($events | by_task) as $tasks
  | {schema: "team-retro-digest/1",
     window: ($w | {task, previous, since, until}
       + {events: ($in | length), kinds: ($in | group_by(.event) | map({key: (.[0].event | tostring), value: length}) | from_entries)}),
     blocks: [$in[] | select(.event == "blocked" or .event == "failed") | {ts, task, kind: .event, reason, denial: (.reason | denial)}],
     questions: [$in | map(select(.event == "question" or .event == "asked")) | task_groups[]
       | {task: .[0].task, repeated: (length >= 2),
          events: map({ts, kind: .event, text} + if .event == "asked" then {id} else {role} end)}],
     reviews: [$in | map(select(.event == "review")) | task_groups[]
       | . as $reviews
       | {task: .[0].task, reopened: any(range(length - 1); $reviews[.].verdict == "findings"),
          verdicts: map({ts, verdict, head})}],
     waits: {spans: $spans,
       totals: ($spans | group_by(.on | tostring | ascii_downcase)
         | map({on: .[0].on, hours: (map(.hours) | add * 100 | round / 100), wall_hours: wall_hours, spans: length})
         | sort_by(-.hours))},
     rewrites: [$in[] | select(.event == "history-rewritten") | del(.i, .event)],
     injections: [$in[] | select(.event == "injection") | del(.i, .event)],
     tasks: [$in | task_groups[] | .[0].task as $id | $tasks[$id] as $all
       | ($all | map(select(.event == "opened")) | first) as $opened
       | {task: $id, title: $opened.title, project: $opened.project, path: $opened.path, phase: ($all | phase),
          record: "\($home)/tasks/\($id)/",
          sessions: [.[] | select(.event == "launch") | {session, role, launched: .ts}]}]};

# team-retro digest's text form, one line per string, from its JSON: a heading per section and a
# line per item, uncut, for the retro to read.
def retro_digest_text:
  def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";
  def section($title; $count; $lines):
    if $lines == [] then "\($title): none" else "\($title) (\($count)):", ($lines[] | "  " + .) end;
  def section($title; $lines): section($title; $lines | length; $lines);
  .window as $w
  | "Window: \($w.since // "the start") to \($w.until), \(plural($w.events; "event")), "
    + (if $w.task == null then "dry run" else "retro \($w.task)" end) + ", previous retro \($w.previous // "none")",
  "  kinds: " + ($w.kinds | to_entries | map("\(.key) \(.value)") | if . == [] then "none" else join(", ") end),
  section("Blocks"; [.blocks[] | "\(.ts) \(.task) \(.kind)\(if .denial then ", denial" else "" end): \(.reason)"]),
  section("Questions"; .questions | length | plural(.; "task");
    [.questions[] | "\(.task)\(if .repeated then ", repeated" else "" end):",
      (.events[] | "  \(.ts) " + if .kind == "asked" then "asked \(.id)" else "question from \(.role)" end + ": \(.text)")]),
  section("Reviews"; .reviews | length | plural(.; "task");
    [.reviews[] | "\(.task)\(if .reopened then ", reopened" else "" end): "
      + (.verdicts | map("\(.verdict) \(.head | tostring | .[:7]) \(.ts)") | join(", "))]),
  section("Waits"; [.waits.spans[] | "\(.task) \(.kind) on \(.on), \(.from) to \(.to), \(.hours)h"
    + (if .clipped then ", clipped to the window's start" else "" end)
    + (if .open then ", open at the window's end" else "" end) + ": \(.reason)"]),
  section("Wait totals"; [.waits.totals[] | "\(.on): \(.hours)h over \(plural(.spans; "span")), \(.wall_hours)h wall-clock"]),
  section("Rewrites"; [.rewrites[] | "\(.ts) \(.task)\(if .branch then " \(.branch)" else "" end): "
    + (if .old_head then "\(.old_head) -> " else "to " end) + "\(.head)" + (if .note then " (\(.note))" else "" end)]),
  section("Injections"; [.injections[] | "\(.ts) \(.task) \(.role) at \(.source): \(.text)"]),
  section("Tasks"; [.tasks[] | "\(.task) \([.project, .path, .phase] | map(select(. != null)) | join(" ")): \(.title // "untitled")"
    + "; record \(.record); sessions "
    + (.sessions | map("\(.role) \(.session)") | if . == [] then "none" else join(", ") end)]);
