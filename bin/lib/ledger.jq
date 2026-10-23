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
    elif standing("blocked") then "blocked"
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
# latest launch no later event ends (ends_worker), in the order of those launches.
def crash_roles:
  . as $events
  | latest_stowed as $stowed
  | [to_entries[] | select(.key > $stowed and .value.event == "launch") | {i: .key, role: .value.role}]
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
# of the task names it), task_state (open, closed, or unknown when not in the ledger)}.
def team_sessions($tasks; $sessions):
  [$sessions[] | . as $session
    | ((.name // "") | capture("^(?<task>T(0|[1-9][0-9]*))-(?<role>.+)$")) as $name
    | ($tasks[$name.task] // null) as $events
    | {task: $name.task, role: $name.role, name, session: (.id // ((.sessionId // "")[:8])), status, state,
       logged: ($events != null and any($events[]; .event == "launch" and live_session(.session; [$session]) != null)),
       task_state: (if $events == null then "unknown" elif $events | is_open then "open" else "closed" end)}];

# Sort by task number.
def by_task_number: sort_by(.task[1:] | tonumber);

# Why a team session is a stray, from team_sessions: "T4 is closed", "T9 is not in the ledger".
def stray_reason: "\(.task) is \(if .task_state == "unknown" then "not in the ledger" else "closed" end)";

# team-sweep's findings, over every ledger event as one array and the session list: each open
# task's unless it is parked, then the stray sessions (named like a team worker whose task is
# closed or not in the ledger); in task number order.
def sweep($sessions):
  by_task as $tasks
  | [($tasks[] | select(is_open) | select(parked | not) | task_findings($sessions)),
     (team_sessions($tasks; $sessions)[] | select(.task_state != "open")
       | finding(.task; "stray"; .session; .name;
           "\(.name) \(.session) is live but \(stray_reason)";
           "read claude logs \(.session) for anything left to log, then stop it with claude stop \(.session)"))]
  | by_task_number;

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
