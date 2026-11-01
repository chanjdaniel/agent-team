# Checking ledger lines against the ledger contract (ledger-contract.json, passed as $contract),
# and reading state from them. Used through ledger_jq in team.sh. Each *_problems def yields one
# string per problem found.

# A jq type, or a field type of the contract, as a noun: "a list", "a number", "null".
def noun:
  {array: "a list", numbers: "a list of whole numbers", object: "an object", boolean: "a boolean", number: "a number",
    string: "a string", null: "null"}[.];

# Whether a value is a whole number: a number, 0 or more, with no fraction.
def whole_number: type == "number" and . >= 0 and . == floor;

# Whether a value is a whole number written as a string, as a comma list or an old team-log left one.
def whole_number_string: type == "string" and test("^[0-9]{1,15}$");

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
# An id is a Discord id, a string of digits; with $legacy (--check), a whole number too, as
# team-log wrote one before the contract typed every Discord id (its digits are the id, since jq
# keeps a number's literal through tostring). A list of whole numbers whose other items are whole
# numbers written as strings, as team-log stored sent_back before the contract typed it, passes
# with $legacy too, and check_notes names it.
# (A parameter named $type would shadow the builtin type inside the def.)
def type_problems($name; $want; $legacy):
  if ($want | type) == "array" then
    select(IN($want[]) | not) | "\($name) must be one of \($want | join(", "))"
  elif $want == "numbers" then
    if type != "array" then "\($name) must be a list of whole numbers, got \(type | noun)"
    else [.[] | select(whole_number | not)] | select(. != [])
      | select($legacy and all(.[]; whole_number_string) | not)
      | "\($name) must be a list of whole numbers, got \(map(tojson) | join(", "))"
    end
  elif $want == "id" then
    if type == "string" then select(test("^[0-9]+$") | not) | "\($name) must be a Discord id, a string of digits, got a string that is not one"
    elif type == "number" and $legacy then select(. < 0 or . != floor) | "\($name) must be a Discord id, a string of digits, got a number that is not one"
    else "\($name) must be a Discord id, a string of digits, got \(type | noun)" end
  elif type != $want then
    "\($name) must be \($want | noun), got \(type | noun)"
  else empty end;

# The field types a kind's line may carry: its required and optional fields, and note.
def field_types($kind): $kind.required + ($kind.optional // {}) + {note: "string"};

# What a line of a known kind must meet: its required fields present and not empty, and every
# field the contract types holding that type ($legacy: as --check reads an existing line).
def kind_problems($contract; $legacy):
  . as $line
  | .event as $event
  | $contract.kinds[$event] as $kind
  | if $kind == null then "unknown event kind '\($event)'"
    else
      ($kind.required | keys_unsorted[] | select($line[.] == null or $line[.] == "") | "\($event) needs \(.)"),
      (field_types($kind) | to_entries[] | .key as $name | .value as $type
        | $line[$name] | select(. != null and . != "") | type_problems($name; $type; $legacy))
    end;

# A value team-log was given for field $name, whose contract type is $want (null for a field the
# contract does not type), as {value} or {problems}. A list (array, numbers) or an object that
# starts with [ or { is JSON; any other list is a comma list, each item trimmed, none the empty
# list, and any other object key:value pairs separated by commas, each trimmed, a value a number
# when it reads as one. A list of whole numbers holds each item that is a whole number written as
# a string as the number. A choice, a string or an id, any discord_* field, and a whole number of
# 16 digits or more (which a JSON number cannot hold exactly) are kept as written; anything else is
# JSON when it parses as JSON, else a string.
def typed_value($name; $want):
  def trimmed: sub("^\\s+"; "") | sub("\\s+$"; "");
  def items:
    . as $raw | split(",") | map(trimmed)
    | if any(.[]; . == "") then {problems: ["\($name) has an empty item in '\($raw)'"]} else {value: .} end;
  . as $raw
  | if ($want | IN("array", "numbers", "object")) and test("^\\s*[\\[{]") then
      try {value: fromjson} catch {problems: ["\($name) starts as JSON, but is not JSON: \($raw)"]}
    elif ($want | IN("array", "numbers")) then
      if trimmed == "none" then {value: []} else items end
    elif $want == "object" then
      items
      | if .problems then .
        else .value as $pairs
          | [$pairs[] | [capture("^(?<key>[^:]*[^:\\s])\\s*:\\s*(?<value>.+)$")] | first // null] as $parsed
          | [range($parsed | length) | select($parsed[.] == null) | "\($name): \($pairs[.]) is not a key:value pair"]
            + [$parsed | map(.key? // empty) | group_by(.)[] | select(length > 1) | "\($name): \(first) is given twice"]
          | if . != [] then {problems: .}
            else {value: ($parsed | map({key, value: (.value | if test("^-?[0-9]+(\\.[0-9]+)?$") then tonumber else . end)}) | from_entries)}
            end
        end
    elif ($want | type) == "array" or ($want | IN("string", "id")) or ($name | startswith("discord_"))
      or test("^-?[0-9]{16,}$") then {value: .}
    else {value: ((try fromjson catch null) | if . == null or (type == "number" and isnan) then $raw else . end)}
    end
  | if $want == "numbers" and (.value | type) == "array" then
      .value |= map(if whole_number_string then tonumber else . end)
      | [.value[] | select(whole_number | not) | "\($name): \(strings // tojson) is not a whole number"] as $bad
      | if $bad == [] then . else {problems: $bad} end
    else . end;

# The fields of a ledger line, read raw, that the contract types as whole numbers and that hold
# strings, as {field: [those strings]}: {} for a line that has none, is not a JSON object or is of
# no kind the contract knows. team-log --fix-sent-back converts them, every line's, legacy too.
def number_strings($contract):
  (try fromjson catch null) as $line
  | if ($line | type) != "object" or ($line.event | type) != "string" or $contract.kinds[$line.event] == null then {}
    else [field_types($contract.kinds[$line.event]) | to_entries[] | select(.value == "numbers") | .key as $field
        | $line[$field] | arrays | [.[] | strings] | select(. != []) | {key: $field, value: .}]
      | from_entries end;

# A ledger line, read raw, with the whole numbers number_strings finds stored as numbers, or
# unchanged, byte for byte, when it finds none.
def numbers_fixed($contract):
  number_strings($contract) as $fields
  | if $fields == {} then .
    else fromjson | reduce ($fields | keys_unsorted[]) as $field (.; .[$field] |= map(if whole_number_string then tonumber else . end))
      | tojson end;

# The shapes team-log holds beyond the contract's types, each *_problems def yielding
# "<value>: <problem>" lines.

# The finding kinds a review's findings counts, and the guarded areas its guarded may name.
def finding_kinds: ["blocking", "correctness", "security", "real-data", "note-change", "note-before"];
def guarded_areas: ["ci", "dependencies", "migrations", "settings", "permissions", "secrets"];

# How a review's findings, an object, is not the count of each finding kind, exactly.
def findings_problems:
  . as $findings
  | (finding_kinds[] | select(in($findings)) | . as $kind | $findings[$kind]
      | select(type != "number" or . < 0 or . != floor) | "\($kind): \(tojson) is not a whole number"),
    (finding_kinds[] | select(in($findings) | not) | "\(.): missing"),
    (keys_unsorted[] | select(IN(finding_kinds[]) | not) | "\(.): not a finding kind");

# How a review's before, a list, is not the numbers of its plain before notes, each once.
def before_problems:
  (.[] | select(type != "number" or . < 1 or . != floor) | "\(tojson): not a finding number"),
  (map(numbers) | group_by(.) | .[] | select(length > 1) | "\(first): listed twice");

# How a review's guarded, a list, holds something other than guarded areas.
def guarded_problems: .[] | select(IN(guarded_areas[]) | not) | "\(tojson): not a guarded area";

# How a scope entry is not a clean repository path, a file or a directory ending in /; nothing for
# one that is.
def path_problem:
  if type != "string" then "not a string"
  elif startswith("/") then "a leading /"
  elif test("[*?\\[]") then "a glob character"
  elif test("\\s") then "whitespace"
  elif any(rtrimstr("/") | split("/")[]; . == "." or . == "..") then "a . or .. segment"
  elif . == "" or any(rtrimstr("/") | split("/")[]; . == "") then "an empty segment"
  else empty end;

# How a merge-preapproved's scope, a list, holds entries that are not clean repository paths.
def scope_problems: .[] | path_problem as $problem | "\(tojson): \($problem)";

# What a line in an existing ledger must meet: legacy lines (before strict_from) only the basics.
def check_problems($contract):
  [line_problems] as $basic
  | if $basic != [] then $basic[]
    elif .ts >= $contract.strict_from then kind_problems($contract; true)
    else empty end;

# What a line in an existing ledger holds in a legacy form its contract still takes, one string
# each: a list of whole numbers from strict_from on that holds some as strings, whose conversion
# team-log --fix-sent-back is.
def check_notes($contract):
  if type == "object" and ([line_problems] == []) and .ts >= $contract.strict_from
    and $contract.kinds[.event] != null then
    . as $line
    | field_types($contract.kinds[.event]) | to_entries[] | select(.value == "numbers") | .key as $name
    | $line[$name] | arrays | [.[] | select(whole_number | not)]
    | select(. != [] and all(.[]; whole_number_string))
    | "\($name) holds whole numbers as strings (\(map(tojson) | join(", "))): team-log --fix-sent-back stores them as numbers"
  else empty end;

# The scripts that write a kind ($kind.writer, one name or a list), as a list.
def writers($kind): [$kind.writer // empty] | flatten;

# What an event must meet to be appended by script $writer: the basics, then that $writer is
# one of the kind's writers, then the kind's fields, whatever its ts. Only the first failing step
# is told.
def append_problems($contract; $writer):
  (if type == "object" then .event else null end) as $event
  | ([line_problems] | select(. != []))
    // ([writers($contract.kinds[$event]) | select(. != [] and (index($writer) | not))
        | "\($event) events are written by \(join(" or ")), not \($writer)"]
      | select(. != []))
    // [kind_problems($contract; false)]
  | .[];

# The report of checking a ledger read as raw lines (jq -nR):
# {total, bad: [{line, problems}], noted: [{line, notes}]}, noted holding the check_notes of
# lines with no problem.
def check_ledger($contract):
  [inputs
    | (if test("^\\s*$") then null else (try {value: fromjson} catch null) end) as $parsed
    | if $parsed == null then {problems: ["not JSON"], notes: []}
      else {problems: [$parsed.value | check_problems($contract)], notes: [$parsed.value | check_notes($contract)]} end]
  | {total: length,
     bad: [to_entries[] | select(.value.problems != []) | {line: (.key + 1), problems: .value.problems}],
     noted: [to_entries[] | select(.value.problems == [] and .value.notes != []) | {line: (.key + 1), notes: .value.notes}]};

# Pad a string with spaces to $width.
def pad($width): . + ([range($width - length)] | map(" ") | add // "");

# How a field type reads in the contract table: "commits (list)", "verdict (pass|findings)".
def field_text($want):
  if ($want | type) == "array" then "\(.) (\($want | join("|")))"
  elif $want == "string" then .
  elif $want == "id" then "\(.) (id)"
  else "\(.) (\($want | noun | sub("^an? "; "")))" end;

# The contract as a table, one row per kind: event, writer, fields, and what the kind is about.
def contract_table:
  .kinds | to_entries
  | (map(.key | length) | max) as $event_width
  | (map(writers(.value) | join(", ") | length) | max) as $writer_width
  | "  \("event" | pad($event_width))  \("written by" | pad($writer_width))  fields",
    (.[] | .value as $kind
      | ([$kind.required | to_entries[] | .value as $type | .key | field_text($type)] as $fields
         | [($kind.optional // {}) | to_entries[] | .value as $type | .key | field_text($type)] as $optional
         | if $fields == [] then "-" else $fields | join(", ") end
           + if $optional == [] then "" else "; optional \($optional | join(", "))" end) as $text
      | "  \(.key | pad($event_width))  \(writers($kind) | join(", ") | pad($writer_width))  \($text)"
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
# project its new path, and a branch-renamed its new branch. Worktrees are paths on this machine
# (local_worktree).
def open_worktrees(events; $home):
  reduce (events | local_worktree($home)) as $e ([];
    if $e.event == "opened" or $e.event == "worktree-added" then
      . + [$e | {task, project, branch, worktree}]
    elif $e.event == "worktree-moved" then
      map(if [.task, .project] == [$e.task, $e.project] then .worktree = $e.worktree else . end)
    elif $e.event == "branch-renamed" then
      map(if [.task, .project] == [$e.task, $e.project] then .branch = $e.branch else . end)
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

# The events that logged a head of the PR at $url, each a head Daniel may be asked on: its pr
# events, and the task's review events after its first pr event (a fix after findings is
# reviewed at a head no pr event logs). A trailing slash aside.
def pr_heads($url):
  ($url | rtrimstr("/")) as $url
  | ([to_entries[] | select(.value.event == "pr" and (.value.url | strings | rtrimstr("/")) == $url) | .key] | first) as $first
  | if $first == null then []
    else [.[$first:][] | select((.event == "pr" and (.url | strings | rtrimstr("/")) == $url) or .event == "review")
      | select(.head | type == "string")] end;

# The first event of pr_heads($url) that logged $head, or null: the earliest Daniel's word on
# $head may be sent.
def head_logged($url; $head): first(pr_heads($url)[] | select(same_head(.head; $head))) // null;

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

# The worktrees team-resume could not re-home that still are not made: each project's latest
# rehome-failed with no later opened, worktree-added, worktree-moved, rehomed or worktree-returned
# in that project, as {project, branch, machine, reason, since}, in the order they failed.
def rehome_failures:
  . as $events
  | [to_entries[] | select(.value.event == "rehome-failed") | .key as $i | .value as $failed
     | select(all($events[$i + 1:][]; .project != $failed.project
         or (.event | IN("rehome-failed", "opened", "worktree-added", "worktree-moved", "rehomed", "worktree-returned") | not)))
     | $failed | {project, branch, machine, reason, since: .ts}];

# The index of the task's latest event of $kind, or -1 when it has none.
def latest_index($kind): [to_entries[] | select(.value.event == $kind) | .key] | last // -1;

# The task's phase, first match wins. Merged needs every PR of task_prs merged, and no held or
# blocked standing that was logged after the latest merged (a later part of the task still to
# come); awaiting-merge needs each PR not merged yet to have, as the latest review of its head, a
# pass.
def phase:
  . as $events
  | task_prs as $prs
  | [$prs[] | select(pr_merged($events; $prs) | not)] as $open
  | latest_index("merged") as $merged
  | ((standing("held") and latest_index("held") > $merged)
     or (standing_until_launch("blocked") and latest_index("blocked") > $merged)) as $parked_since_merge
  | if any(.[]; .event == "closed") then "closed"
    elif $merged >= 0 and $open == [] and ($parked_since_merge | not) then "merged"
    elif standing("held") then "held"
    elif standing_until_launch("blocked") then "blocked"
    elif $open != [] and all($open[]; . as $pr
      | ($events | map(select(.event == "review" and same_head(.head; $pr.head))) | last | .verdict) == "pass") then "awaiting-merge"
    elif any(.[]; .event == "pr") then "in-review"
    elif any(.[]; .event == "plan-approved") then "building"
    else "planning" end;

# The index of the task's latest stowed, or -1 when it has none.
def latest_stowed: latest_index("stowed");

# Whether the task crashed on a machine switch: a launch after its latest stowed, or a launch and
# no stowed at all, so the machine it last ran on stopped without handing it off.
def crashed: latest_stowed as $stowed | any(.[$stowed + 1:][]; .event == "launch");

# Whether the task's worktree in <project> resumes from the last checkpoint's snapshot: the task
# crashed, or its latest stowed recorded that worktree with uncommitted changes, which the
# handoff's checkpoint kept as wip/<project>/T<n> on the team home's origin.
def snapshot_due($project):
  crashed or (latest_stowed as $stowed | $stowed >= 0
    and any(.[$stowed].worktrees[]?; .project == $project and .uncommitted == true));

# Whether the event ends the worker of <role>: its DONE, which the coordinator logs as a done of
# that role, a review (a reviewer's), or a ticket-done or a pr (a builder's: a delivering
# builder's PR <url> is logged as a pr, not a done).
def ends_worker($role):
  (.event == "done" and .role == $role) or (.event == "review" and $role == "reviewer")
  or ((.event == "ticket-done" or .event == "pr") and $role == "builder");

# The task's unfinished work: each role launched since its latest stowed whose latest launch no
# later event ends (ends_worker), in the order of those launches. The roles a handoff's stowed
# records and a crash relaunches. Never ops: an ops session runs only on Daniel's request, so on
# the other machine Daniel asks again.
def unfinished_roles:
  . as $events
  | latest_stowed as $stowed
  | [to_entries[] | select(.key > $stowed and .value.event == "launch" and .value.role != "ops")
    | {i: .key, role: .value.role}]
  | group_by(.role) | map(max_by(.i)) | sort_by(.i)
  | map(.i as $i | .role as $role | select(all($events[$i + 1:][]; ends_worker($role) | not)) | .role);

# Every worktree the task was given (opened or added), at its latest path (worktree-moved) and on
# its latest branch (branch-renamed), and whether it was returned since.
def worktree_list:
  . as $events
  | [to_entries[] | select(.value.event == "opened" or .value.event == "worktree-added")
    | .key as $i | .value as $w
    | reduce ($events[$i + 1:][] | select(.project == $w.project)) as $e
        ($w | {project, branch, worktree, returned: false};
         if .returned then .
         elif $e.event == "worktree-moved" then .worktree = $e.worktree
         elif $e.event == "branch-renamed" then .branch = $e.branch
         elif $e.event == "worktree-returned" and $e.worktree == .worktree then .returned = true
         else . end)];

# The task's branch in <project>, over the task's events as an array: the latest opened,
# worktree-added or branch-renamed of the project names it; null when none does.
def task_branch($project):
  [.[] | select((.event | IN("opened", "worktree-added", "branch-renamed")) and .project == $project)]
  | last | .branch // null;

# A launch's session in the session list ($sessions, from claude agents --json), or null: by the
# short id, or by the start of the full session id (interactive sessions have no short id).
def live_session($session; $sessions):
  if ($session | type) == "string" and $session != "" then
    $sessions | map(select(.id == $session or ((.sessionId // "") | startswith($session)))) | first
  else null end;

# Every launch of the task, live when the session list has its session, with that session's context
# when task_state_json added it.
def workers($sessions):
  [.[] | select(.event == "launch") | live_session(.session; $sessions) as $live
    | {role, session, launched: .ts, worktree, live: ($live != null), status: $live.status, state: $live.state,
       context: $live.context}];

# The full session ids of the task's launches the session list has.
def live_session_ids($sessions):
  [.[] | select(.event == "launch") | live_session(.session; $sessions) | .sessionId // empty | strings] | unique;

# Whether this event, logged after the ask $ask (an asked event), settles it: the answered or the
# merge-preapproved with its id, or a merge-approved whose url (a trailing slash aside) the ask's
# text names, not followed by a digit, since the coordinator logs a merge answer as merge-approved
# alone as often as not.
def settles($ask):
  (.event == "answered" and .id == $ask.id)
  or (.event == "merge-preapproved" and .ask == $ask.id)
  or (.event == "merge-approved" and (.url | type) == "string" and (.url | test("^https?://"))
    and ((.url | rtrimstr("/")) as $url | ($ask.text // "" | tostring) as $text
      | any($text | indices($url)[]; $text[. + ($url | length):] | test("^[0-9]") | not)));

# The latest asked of id $id among the task's events, or null: the ask a merge-preapproved of
# that id answers.
def latest_asked($id): [.[] | select(.event == "asked" and .id == $id)] | last;

# The task's latest merge-preapproved of $project, or null, with withdrawn: the first
# merge-preapproval-withdrawn of $project logged after it, or null while it stands.
def merge_preapproval($project):
  ([to_entries[] | select(.value.event == "merge-preapproved" and .value.project == $project)] | last) as $latest
  | if $latest == null then null
    else $latest.value + {withdrawn: (first(.[$latest.key + 1:][]
      | select(.event == "merge-preapproval-withdrawn" and .project == $project)) // null)} end;

# The task's latest merge-preapproved, of any project, as team-state shows it, or null: its
# project, ask, discord_message, scope and ts, withdrawn ({ts, discord_message} of the first
# merge-preapproval-withdrawn of its project after it, or null while it stands), and opted_in and
# own, null here, which task_state_json reads from the registry.
def latest_merge_preapproval:
  (map(select(.event == "merge-preapproved")) | last | .project) as $project
  | if $project == null then null
    else merge_preapproval($project)
      | {project, ask, discord_message, scope, ts,
         withdrawn: (.withdrawn | if . == null then null else {ts, discord_message} end),
         opted_in: null, own: null} end;

# The projects whose plan-time merge approval of the task stands: its latest merge-preapproved of
# each has no withdrawal after it, in the order of their first merge-preapproved.
def preapproved_projects:
  . as $events
  | reduce (.[] | select(.event == "merge-preapproved") | .project) as $project ([];
      if IN(.[]; $project) then . else . + [$project] end)
  | map(select(. as $project | $events | merge_preapproval($project) | .withdrawn == null));

# Why the task's reviews do not let a word given on no head (the plan-time one) merge the PR's
# head $head unasked, one string per reason, none when they do: no review of the head (by the
# shorter prefix) is logged; the latest one is not a pass; it logged no guarded list, or named
# areas in it; and each review of the task, of any head, that left out its finding counts or
# counted a security or real-data finding, fixed or not, named by its head and time.
def unattended_review_reasons($head):
  ([.[] | select(.event == "review" and same_head(.head; $head))] | last) as $reviewed
  | "the latest review of the head \($head[:7]), at \($reviewed.ts), " as $latest
  | (if $reviewed == null then "no review of the head \($head[:7]) is logged, so no reviewer has passed it"
     elif $reviewed.verdict != "pass" then "\($latest)is \($reviewed.verdict), not pass"
     else empty end),
    ($reviewed | select(. != null)
     | if has("guarded") | not then "\($latest)logged no guarded areas, so no reviewer has said the change touches none"
       elif .guarded != [] then "\($latest)found the change touching guarded areas: \(.guarded | join(", "))"
       else empty end),
    (.[] | select(.event == "review") | "the review of the head \(.head[:7]), at \(.ts), " as $review
     | if has("findings") | not then
         "\($review)logged no finding counts, so whether it found a security or real-data issue is not known"
       else
         [.findings | ("security", "real-data") as $kind | .[$kind] | select(. > 0)
           | "\(.) \($kind) finding\(if . == 1 then "" else "s" end)"]
         | select(length > 0)
         | "\($review)counted \(join(" and ")): such a finding on the task, even fixed, comes back to Daniel"
       end);

# Whether the task's events hold an answered of ask $id read from Discord message $message.
def answered_from($id; $message):
  any(.[]; .event == "answered" and .id == $id and (.discord_message | tostring) == $message);

# The asked events no later event settles yet, each as {k, ask}: its index among the events and
# the event.
def unsettled_asks:
  . as $events
  | [range(length) as $k | $events[$k] | select(.event == "asked") | . as $ask
     | select(any($events[$k + 1:][]; settles($ask)) | not) | {k: $k, ask: .}];

# The asks put to Daniel that no later event settles yet.
def pending_asks: [unsettled_asks[] | .ask | {id, text, ts}];

# A task's state from its events and the session list, its worktrees as paths on this machine,
# whose home directory is $home (local_worktree); team-state adds the pr part.
def task_state($sessions; $home):
  map(local_worktree($home))
  | (map(select(.event == "opened")) | first) as $opened
  | {schema: "team-state/1", task: .[0].task, title: $opened.title, project: $opened.project,
     path: $opened.path, phase: phase, worktrees: worktree_list,
     thread: (map(select(.event == "thread") | .discord_thread) | last),
     workers: workers($sessions), last_event: last, pending_asks: pending_asks, waiting: waiting,
     rehome_failures: rehome_failures, merge_preapproval: latest_merge_preapproval, pr: null};

# A task's state (team-state's JSON) as one line of text, each live worker's context in thousands:
# T14 agent-team feature building | T14-builder idle 302k | PR #5 a1b2c3d checks 2/2 agent-review missing
def state_line:
  .task as $task
  | ([.task, .project, .path, .phase] | map(select(. != null)) | join(" "))
  + " | "
  + ([.workers[] | select(.live)
      | "\($task)-\(.role) \(.status)" + (if .state == null or .state == "working" then "" else " \(.state)" end)
        + if (.context | type) == "number" then " \(.context / 1000 | round)k" else "" end]
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
  + (if (.rehome_failures // []) == [] then ""
     else " | not re-homed: " + (.rehome_failures | map("\(.project) on \(.machine): \(.reason)") | join("; ")) end)
  + (.merge_preapproval // null
     | if . == null then ""
       elif .withdrawn != null then " | merge pre-approval withdrawn"
       elif .own == true then " | merge pre-approved, but \(.project) is the team's own project"
       elif .opted_in == false then " | merge pre-approved, but \(.project) does not opt in"
       else " | merge pre-approved" end)
  + (if .waiting == null then "" else " | waiting on \(.waiting.on): \(.waiting.reason)" end);

# Whether a task is parked, waiting on something other than a worker: held, blocked or awaiting
# merge, an ask nothing settled (settles), or a pause or a wait still standing.
def parked:
  IN(phase; "held", "blocked", "awaiting-merge") or pending_asks != [] or standing_until_launch("paused")
  or waiting != null;

# One of team-sweep's findings: {task, kind, session, name, next, text}, text being its one line.
def finding($task; $kind; $session; $name; $detail; $next):
  {task: $task, kind: $kind, session: $session, name: $name, next: $next,
   text: "\($task) \($kind): \($detail); next: \($next)"};

# team-sweep's merge-due finding, over a task's events, or nothing: the task awaits merge, a
# plan-time approval of it stands, and nothing else parks it (no ask nothing settled, pause or
# wait). The ledger names no PR's project, so any standing approval of the task's counts, and
# team-merge holds each PR to its own project's.
def merge_due_finding:
  .[0].task as $task
  | . as $events
  | preapproved_projects as $projects
  | if phase == "awaiting-merge" and $projects != [] and pending_asks == []
      and (standing_until_launch("paused") | not) and waiting == null then
      task_prs as $prs
      | finding($task; "merge-due"; null; null;
          "awaiting the merge of \([$prs[] | select(pr_merged($events; $prs) | not) | .url] | join(", "))"
          + " on Daniel's plan-time word on \($projects | join(", ")), with no ask open";
          "run team-merge \($task); on a refusal, ask Daniel for the per-head word with team-ask")
    else empty end;

# A duration in seconds as <h>h<mm>m, or <m>m under an hour.
def duration:
  (. / 60 | floor) as $m
  | if $m < 60 then "\($m)m" else "\($m / 60 | floor)h\($m % 60 | tostring | if length < 2 then "0" + . else . end)m" end;

# The stall limits, in seconds: how long a busy session's transcripts may go unwritten before
# team-sweep calls it stalled. default, 50 minutes, so with the sweep watch's three-minute stand
# the coordinator is woken within the hour (a full Playwright run or tests/run, up to about 33
# minutes seen, passes); gate, 180 minutes, while a running call runs the gate, whose runs went
# up to about 115; ci_wait, 100 minutes, while a running call runs team-ci-wait, which ends by
# its 90-minute deadline; interview, none (null), while a running call waits on Daniel with
# team-thread wait. session-activity names each call's limit from its whole command. team-sweep
# reads the session-activity floor from default too, since no session quieter than it is stalled.
def stall_limits: {default: 3000, gate: 10800, ci_wait: 6000, interview: null};

# A running call's stall limit: the one session-activity names for it (its limit), else default.
def call_limit:
  (.limit // "default") as $name
  | if stall_limits | has($name) then stall_limits[$name] else stall_limits.default end;

# A session's stall limit from its running calls (session-activity's running, or null when not
# read): the largest of theirs, none when any has none, the default when none runs.
def stall_limit:
  if . == null or . == [] then stall_limits.default
  else map(call_limit) | if any(. == null) then null else max end end;

# What a quiet session waits on, from its running calls, to follow "has written nothing for
# <time>": the newest foreground call when there is one (it holds the turn, and is the innermost
# when an Agent call waits on its subagent's), else the oldest, then how many more run; or that
# none runs.
def waiting_on:
  if . == null then ""
  elif . == [] then " with no tool call running"
  else ((map(select(.background | not)) | last) // first) as $call
    | ([if $call.command != null then $call.tool + (if $call.subagent then " in a subagent" else "" end)
        elif $call.subagent then "in a subagent" else empty end,
        if $call.background then "in the background" else empty end,
        "running \($call.seconds | duration)"] | join(", ")) as $how
    | ", waiting on \(if $call.command == null then $call.tool else "\"\($call.command)\"" end) (\($how))"
      + (if length > 1 then ", and \(length - 1) more running" else "" end)
  end;

# The no-worker, waiting-input, silent and stalled findings of an open task that is not parked,
# the stalled one from session-activity's object as team-sweep passes it ($activity: {sessions},
# its object keyed by full session id, or {error} when it failed, where none is stalled). A live
# session is judged by its latest launch, and one waiting for input is not also called silent;
# stalled is a busy session, not waiting for input, whose transcripts have gone unwritten past
# its limit (stall_limits).
# A live session is at work while it is busy, waiting for input, or idle with no ledger event
# since its launch (silent); idle with an event since, it has handed the next step back to the
# coordinator, so a task with no session at work is no-worker however many are live. A denied is
# no report (the worker went past the denial), so these findings read the events without it.
def task_findings($sessions; $activity):
  .[0].task as $task
  | map(select(.event != "denied"))
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
        elif .live.status != "idle"
          and ($activity.sessions[.live.sessionId // ""] // null
            | . != null and ((.running | stall_limit) as $limit | $limit != null and .quiet > $limit)) then
          $activity.sessions[.live.sessionId] as $quiet
          | finding($task; "stalled"; .short; .name;
            "\(.name) \(.short) has written nothing for \($quiet.quiet | duration)\($quiet.running | waiting_on)";
            "read claude logs \(.short), then follow the recover-worker skill's stalled rung")
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

# team-sweep's slots finding, from team-slots --json's object (or {error} when it failed): one
# while the effective cap is below the cap or more slots are held than it, saying the summary
# line and why, else none; one naming the error when team-slots failed.
def slots_finding:
  if .error then
    {task: null, kind: "slots", session: null, name: null, next: "fix what team-slots names",
     text: "slots: \(.error): fix what team-slots names"}
  else
    .summary as $summary
    | [if .effective.cap < .settings.cap then .effective.reason else empty end,
       if .counts.held > .effective.cap then "\(.counts.held) held, over the effective cap of \(.effective.cap)" else empty end]
    | select(. != [])
    | {task: null, kind: "slots", session: null, name: null, next: "tell Daniel which wait",
       text: "slots: \($summary); \(join("; ")): new tasks wait; tell Daniel which wait"}
  end;

# team-sweep's activity finding, from session-activity's object as task_findings takes it: one
# naming the error when it failed, since then no busy worker can be found stalled, else none.
def activity_finding:
  select(.error)
  | {task: null, kind: "activity", session: null, name: null, next: "fix what session-activity names",
     text: "activity: \(.error), so no busy worker is found stalled: fix what session-activity names"};

# team-sweep's findings, over every ledger event as one array, the session list, the machine's
# task slots ($slots, as slots_finding takes them) and session-activity's object ($activity, as
# task_findings takes it): each open task's merge-due, else its findings unless it is parked,
# then the stray sessions (named like a team worker whose task is closed or not in the ledger,
# never the load check's T0, whose session the coordinator waits on for up to 30 minutes), in task
# number order; then the activity, slots and retro-due findings.
def sweep($sessions; $slots; $activity):
  . as $events
  | by_task as $tasks
  | ([($tasks[] | select(is_open) | [merge_due_finding] as $due
        | if $due != [] then $due[] elif parked then empty
          else task_findings($sessions; $activity) end),
      (team_sessions($tasks; $sessions)[] | select(.task_state | IN("closed", "unknown"))
        | finding(.task; "stray"; .session; .name;
            "\(.name) \(.session) is live but \(stray_reason)";
            "read claude logs \(.session) for anything left to log, then stop it with claude stop \(.session)"))]
     | by_task_number)
    + [$activity | activity_finding]
    + [$slots | slots_finding]
    + [$events | retro_status | retro_due_finding];

# The ids of the open tasks among every task's events by id, in task number order.
def open_tasks: [to_entries[] | select(.value | is_open) | .key] | sort_by(.[1:] | tonumber);

# team-snapshot's JSON from every task's events by id ($tasks), the open tasks' team-state JSON
# in task number order ($states; {task, error} for a task whose state could not be told), the
# machine's task slots ($slots, team-slots --json's object or {error}), the session list, and each
# registered project's open PRs ($prs).
def snapshot($tasks; $states; $slots; $sessions; $prs; $items):
  team_sessions($tasks; $sessions) as $team
  | {schema: "team-snapshot/1",
     tasks: $states,
     slots: $slots,
     sessions: [$team[] | select(.task_state == "open") | del(.task_state)],
     strays: [$team[] | select(.task_state != "open") | del(.logged)],
     prs: $prs,
     pending_asks: [$states[] | .task as $task | (.pending_asks // [])[] | {task: $task} + .],
     items: $items};

# The current items of tasks/current.md, over its lines (-R): each line starting "- ", without it.
def current_items: [inputs | rtrimstr("\r") | select(startswith("- ")) | .[2:]];

# Cut a line to $n characters, showing the cut.
def clip($n): if length > $n then .[:$n - 3] + "..." else . end;

# A live session as text: its name, short id, status, and state unless working.
def session_text:
  "\(.name) \(.session) \(.status)" + if .state == null or .state == "working" then "" else " \(.state)" end;

# team-snapshot's text form, one line per string, from its JSON. Lines are cut at 120 columns, so
# ten open tasks fit one screen, but current items at 200, each being a whole thought.
def snapshot_text:
  def section($title; $lines):
    if $lines == [] then "\($title): none" else "\($title) (\($lines | length)):", ($lines[] | "  " + . | clip(120)) end;
  section("Open tasks"; [.tasks[] | if .error then "\(.task) state unreadable: \(.error)" else state_line end]),
  (if .slots.error then "Task slots unreadable: \(.slots.error)" else .slots.summary end | clip(120)),
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
  section("Pending asks"; [.pending_asks[] | "\(.task) \(.id): \(.text)"]),
  ((.items // []) as $items
   | if $items == [] then "Current items: none"
     else "Current items (\($items | length)):", ($items[:40][] | "  - " + . | clip(200)),
       if $items | length > 40 then "  and \($items | length - 40) more in tasks/current.md" else empty end
     end);

# The following defs serve team-inbox, a task's events as an array, then every ledger event as one.

# Whether the task's latest interview thread still holds an interview: no planner's done and no
# plan-approved logged after its interview-thread.
def interview_under_way:
  latest_index("interview-thread") as $i
  | $i >= 0 and all(.[$i + 1:][]; ((.event == "done" and .role == "planner") or .event == "plan-approved") | not);

# The task's PRs that wait on Daniel's word to merge, from task_prs: none unless its phase is
# awaiting-merge, then each not merged that no merge-approved names (a trailing slash aside) at its
# head, or at no head, as a legacy line, and whose repo (lowercased) is not a key of $plan_repos
# naming a project with a standing merge-preapproved of the task: the projects that opt in to
# plan-time merges now and are not the team's own, which team-inbox reads from the registry.
def merge_ready_prs($plan_repos):
  . as $events
  | task_prs as $prs
  | if phase != "awaiting-merge" then []
    else [$prs[] | select(pr_merged($events; $prs) | not) | . as $pr
      | select(any($events[]; .event == "merge-approved" and (.url | strings | rtrimstr("/")) == ($pr.url | rtrimstr("/"))
          and (.head == null or same_head(.head; $pr.head))) | not)
      | $plan_repos[first($pr.url | strings | capture("^https://github\\.com/(?<r>[^/]+/[^/]+)/") | .r | ascii_downcase) // ""] as $project
      | select($project != null and ($events | merge_preapproval($project) | . != null and .withdrawn == null) | not)] end;

# What waits on Daniel, over every ledger event, each open task's in task number order:
# {asks: [{task, id, text (its first line), thread (the task's thread when it was asked), message
# (the question's discord_message)}], prs: [{task, title, url}], interviews: [{task, title, thread}]},
# the PRs as merge_ready_prs($plan_repos) has them.
def inbox_items($plan_repos):
  [by_task | to_entries[] | select(.value | is_open)
    | {task: .key, events: .value, title: (.value | map(select(.event == "opened")) | first | .title)}]
  | by_task_number
  | {asks: [.[] | .task as $task | .events as $events | $events | unsettled_asks[]
        | {task: $task, id: .ask.id, text: (.ask.text | tostring | split("\n")[0]),
           thread: ([$events[:.k][] | select(.event == "thread") | .discord_thread | strings] | last),
           message: (.ask.discord_message | if . == null then null else tostring end)}],
     prs: [.[] | {task, title} + (.events | merge_ready_prs($plan_repos)[] | {url})],
     interviews: [.[] | select(.events | interview_under_way)
        | {task, title, thread: (.events | map(select(.event == "interview-thread") | .discord_thread) | last | tostring)}]};

# The Waiting on you message from inbox_items, at most $limit characters, its asks linked to the
# question's message in guild $guild (to the thread when either is unknown), and its last line the
# time $now (seconds since the epoch) as Discord shows it to each reader. Items past the limit are
# left out from the end, counted in one line.
def inbox_text($guild; $limit; $now):
  def link:
    if .thread == null then ""
    elif .message != null and $guild != null then " https://discord.com/channels/\($guild)/\(.thread)/\(.message)"
    else " <#\(.thread)>" end;
  def named: .task + if .title == null then "" else " \(.title | clip(80))" end;
  [["**Asks**", [.asks[] | "- \(.task) \(.id): \(.text | clip(150))" + link]],
   ["**PRs ready to merge**", [.prs[] | "- \(named): \(.url)"]],
   ["**Interviews under way**", [.interviews[] | "- \(named): <#\(.thread)>"]]] as $sections
  | ([$sections[][1][]] | length) as $total
  | "-# team-inbox keeps this current; updated <t:\($now):R>" as $foot
  | def render($n):
      (reduce $sections[] as $s ({left: $n, lines: []};
        $s[1][:.left] as $take
        | if $take == [] then . else .lines += [$s[0]] + $take | .left -= ($take | length) end)
       | .lines)
      + (if $n < $total then ["- and \($total - $n) more, which team-snapshot lists"] else [] end)
      | ["**Waiting on you**"] + . + [$foot] | join("\n");
    if $total == 0 then ["**Waiting on you**", "Nothing waits on you.", $foot] | join("\n")
    else first(range($total; -1; -1) as $n | render($n) | select(length <= $limit)) end;

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
# {task, kind, on, reason, start, from, end}, end being the event that clears it, or null, and from
# when it began: a park's since when it was logged after the fact, else its ts. waiting, paused and
# blocked clear at the next resumed or launch, held at the next resumed, asked at the event that
# settles it (settles), and every one at the task's closed.
def wait_spans:
  . as $events
  | range(length) as $k | $events[$k] as $s
  | {waiting: ["resumed", "launch"], paused: ["resumed", "launch"], blocked: ["resumed", "launch"], held: ["resumed"], asked: []}[$s.event | tostring] as $clears
  | select($clears != null)
  | {task: $s.task, kind: $s.event,
     on: (if $s.event == "waiting" then $s.on // "unknown" elif $s.event == "asked" then "Daniel" else $s.event end),
     reason: (if $s.event == "asked" then $s.text else $s.reason end),
     start: $s, from: (if $s.event != "asked" then $s.since // $s.ts else $s.ts end),
     end: (first($events[$k + 1:][] | select(.event == "closed" or (.event | IN($clears[]))
       or ($s.event == "asked" and settles($s)))) // null)};

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

# team-retro digest's JSON for the retro task $task (null for a dry run), the team home $team_home
# naming each task's record directory. Every section is in ledger order.
def retro_digest($task; $team_home):
  . as $events
  | retro_window($task) as $w
  | [to_entries[] | .value + {i: .key}] as $placed
  | $placed[$w.start:$w.end] as $in
  | ([$placed | task_groups[] | wait_spans | .end as $end
      | select(.start.i < $w.end and ($end == null or $end.i >= $w.start))
      | (.start.i < $w.start or .from < $w.since) as $clipped
      | ($end == null or $end.i >= $w.end) as $open
      | (if $clipped then $w.since else .from end) as $from
      | (if $open then $w.until else $end.ts end) as $to
      | {task, kind, on, reason, from: $from, to: $to, hours: hours($from; $to), open: $open, clipped: $clipped, i: .start.i}]
     | sort_by(.i) | map(del(.i))) as $spans
  | ($events | by_task) as $tasks
  | {schema: "team-retro-digest/1",
     window: ($w | {task, previous, since, until}
       + {events: ($in | length), kinds: ($in | group_by(.event) | map({key: (.[0].event | tostring), value: length}) | from_entries)}),
     blocks: [$in[] | select(.event == "blocked" or .event == "failed" or .event == "denied")
       | if .event == "denied" then {ts, task, kind: .event, reason: "\(.role) \(.what): \(.why)", denial: true}
         else {ts, task, kind: .event, reason, denial: (.reason | denial)} end],
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
          record: "\($team_home)/tasks/\($id)/",
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
