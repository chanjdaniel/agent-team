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

# The open worktrees among a stream of ledger events: one {task, project, branch, worktree} per
# opened or worktree-added event with no later worktree-returned of the same task, project and
# worktree, in the order they were added.
def open_worktrees(events):
  reduce events as $e ([];
    if $e.event == "opened" or $e.event == "worktree-added" then
      . + [$e | {task, project, branch, worktree}]
    elif $e.event == "worktree-returned" then
      map(select([.task, .project, .worktree] != [$e.task, $e.project, $e.worktree]))
    else . end)
  | .[];

# Whether two heads name the same commit: compared by the shorter one's prefix, which must be at
# least 7 characters, since the ledger holds both short and full SHAs.
def same_head($a; $b):
  if ($a | type) == "string" and ($b | type) == "string" then
    ([($a | length), ($b | length)] | min) as $n
    | $n >= 7 and ($a[:$n] | ascii_downcase) == ($b[:$n] | ascii_downcase)
  else false end;

# The following defs read a task's events, in ledger order, as an array.

# The latest PR head the ledger knows: the head of the latest pr or history-rewritten event.
def ledger_pr_head: map(select(.event == "pr" or .event == "history-rewritten") | .head) | last;

# Whether the latest event of $kind stands: no resumed after it.
def standing($kind):
  ([to_entries[] | select(.value.event == $kind) | .key] | last) as $i
  | $i != null and all(.[$i + 1:][]; .event != "resumed");

# The task's phase, first match wins. A review counts when it is the latest review of the
# ledger's PR head and a pass.
def phase:
  ledger_pr_head as $head
  | if any(.[]; .event == "closed") then "closed"
    elif any(.[]; .event == "merged") then "merged"
    elif standing("held") then "held"
    elif standing("blocked") then "blocked"
    elif (map(select(.event == "review" and same_head(.head; $head))) | last | .verdict) == "pass" then "awaiting-merge"
    elif any(.[]; .event == "pr") then "in-review"
    elif any(.[]; .event == "plan-approved") then "building"
    else "planning" end;

# Every worktree the task was given (opened or added), and whether it was returned since.
def worktree_list:
  . as $events
  | [to_entries[] | select(.value.event == "opened" or .value.event == "worktree-added")
    | .key as $i | .value as $w
    | $w | {project, branch, worktree}
      + {returned: any($events[$i + 1:][]; .event == "worktree-returned" and .project == $w.project and .worktree == $w.worktree)}];

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

# A task's state from its events and the session list; team-state adds the pr part.
def task_state($sessions):
  (map(select(.event == "opened")) | first) as $opened
  | {schema: "team-state/1", task: .[0].task, title: $opened.title, project: $opened.project,
     path: $opened.path, phase: phase, worktrees: worktree_list,
     thread: (map(select(.event == "thread") | .discord_thread) | last),
     workers: workers($sessions), last_event: last, pending_asks: pending_asks, pr: null};

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
     end);

# Whether the latest paused stands: no resumed and no launch after it.
def paused_standing:
  ([to_entries[] | select(.value.event == "paused") | .key] | last) as $i
  | $i != null and all(.[$i + 1:][]; .event != "resumed" and .event != "launch");

# Whether a task is parked, waiting on something other than a worker: held, blocked or awaiting
# merge, an ask with no answer, or a pause still standing.
def parked:
  IN(phase; "held", "blocked", "awaiting-merge") or pending_asks != [] or paused_standing;

# One of team-sweep's findings: {task, kind, session, name, next, text}, text being its one line.
def finding($task; $kind; $session; $name; $detail; $next):
  {task: $task, kind: $kind, session: $session, name: $name, next: $next,
   text: "\($task) \($kind): \($detail); next: \($next)"};

# The no-worker, waiting-input and silent findings of an open task that is not parked. A live
# session is judged by its latest launch, and one waiting for input is not also called silent.
def task_findings($sessions):
  .[0].task as $task
  | length as $count
  | [to_entries[] | select(.value.event == "launch") | {i: .key, launch: .value}] as $launches
  | ([$launches | reverse | .[] | . + {live: live_session(.launch.session; $sessions)} | select(.live != null)
      | . + {short: (.live.id // .launch.session), name: (.live.name // "\($task)-\(.launch.role)")}]
     | unique_by(.short) | sort_by(.i)) as $live
  | ($launches | last) as $latest
  | if $live == [] and any(.[]; .event == "opened" or .event == "launch") then
      if $latest == null then
        finding($task; "no-worker"; null; null; "opened with no worker launched";
          "launch one with team-worker, or log what is known with team-log")
      else
        "\($task)-\($latest.launch.role)" as $name | $latest.launch.session as $session
        | if phase == "merged" then
            finding($task; "no-worker"; $session; $name;
              "merged and not closed, with no live worker (latest \($name) \($session))"; "close it with team-close \($task)")
          else
            finding($task; "no-worker"; $session; $name;
              "no live session among its \($launches | length) launch\(if ($launches | length) == 1 then "" else "es" end) (latest \($name) \($session))";
              "read claude logs \($session) for how it ended, then launch the next worker with team-worker or log what is known with team-log")
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

# team-sweep's findings, over every ledger event as one array and the session list: each open
# task's (open means it has events and no closed) unless it is parked, then the stray sessions
# (named like a team worker, T<n>-<role>, whose task is closed or not in the ledger); in task
# number order.
def sweep($sessions):
  (group_by(.task) | map({key: .[0].task, value: .}) | from_entries) as $tasks
  | [($tasks[] | select(any(.[]; .event == "closed") | not) | select(parked | not) | task_findings($sessions)),
     ($sessions[] | (.name // "") as $name
       | ($name | capture("^(?<task>T(0|[1-9][0-9]*))-.").task) as $task
       | ($tasks[$task] // null) as $events
       | select($events == null or any($events[]; .event == "closed"))
       | (.id // ((.sessionId // "")[:8])) as $short
       | finding($task; "stray"; $short; $name;
           "\($name) \($short) is live but \($task) is \(if $events == null then "not in the ledger" else "closed" end)";
           "read claude logs \($short) for anything left to log, then stop it with claude stop \($short)"))]
  | sort_by(.task[1:] | tonumber);
