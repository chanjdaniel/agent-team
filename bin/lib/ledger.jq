# Checking ledger lines against the ledger contract (ledger-contract.json, passed as $contract),
# and reading state from them. Used through ledger_jq in team.sh. Each *_problems def yields one
# string per problem found.

import "lifecycle" as $lifecycle;

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
# An id is a Discord id, a string of digits, and digits any other whole number kept as one (a
# GitHub run or job id). With $legacy (--check), an id may be a whole number too, as
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
  elif $want == "digits" then
    if type == "string" then select(test("^[0-9]+$") | not) | "\($name) must be a whole number written in digits, got a string that is not one"
    else "\($name) must be a whole number written in digits, got \(type | noun)" end
  elif type != $want then
    "\($name) must be \($want | noun), got \(type | noun)"
  else empty end;

# The field types a kind's line may carry: its required and optional fields, and note.
def field_types($kind): $kind.required + ($kind.optional // {}) + {note: "string"};

# What a line of a known kind must meet: its required fields present and not empty, exactly one
# field of each of its one_of sets present and not empty, every field the contract types holding
# that type ($legacy: as --check reads an existing line), and every field of its field_when only
# beside the values it names.
def kind_problems($contract; $legacy):
  . as $line
  | .event as $event
  | $contract.kinds[$event] as $kind
  | if $kind == null then "unknown event kind '\($event)'"
    else
      ($kind.required | keys_unsorted[] | select($line[.] == null or $line[.] == "") | "\($event) needs \(.)"),
      (($kind.one_of // [])[] | . as $set | [.[] | select($line[.] != null and $line[.] != "")] | length
        | (if $event | test("^[aeiou]") then "an" else "a" end) as $a
        | if . == 0 then "\($a) \($event) needs \($set | join(" or "))"
          elif . > 1 then "\($a) \($event) takes \($set | join(" or ")), \(if ($set | length) == 2 then "not both" else "only one" end)"
          else empty end),
      (field_types($kind) | to_entries[] | .key as $name | .value as $type
        | $line[$name] | select(. != null and . != "") | type_problems($name; $type; $legacy)),
      (($kind.field_when // {}) | to_entries[] | .key as $name | select($line[$name] != null)
        | .value | to_entries[] | .key as $on | .value as $values
        | select(any($values[]; . == $line[$on]) | not)
        | "\(if $event | test("^[aeiou]") then "an" else "a" end) \($event)'s \($name) is only for \($on) \($values | join(" or ")), not \($line[$on] | tojson)")
    end;

# A value team-log was given for field $name, whose contract type is $want (null for a field the
# contract does not type), as {value} or {problems}. A list (array, numbers) or an object that
# starts with [ or { is JSON; any other list is a comma list, each item trimmed, none the empty
# list, and any other object key:value pairs separated by commas, each trimmed, a value a number
# when it reads as one. A list of whole numbers holds each item that is a whole number written as
# a string as the number. A choice, a string, an id or digits, any discord_* field, and a whole number of
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
    elif ($want | type) == "array" or ($want | IN("string", "id", "digits")) or ($name | startswith("discord_"))
      or test("^-?[0-9]{16,}$") then {value: .}
    else {value: ((try fromjson catch null) | if . == null or (type == "number" and isnan) then $raw else . end)}
    end
  | if $want == "numbers" and (.value | type) == "array" then
      .value |= map(if whole_number_string then tonumber else . end)
      | [.value[] | select(whole_number | not) | "\($name): \(strings // tojson) is not a whole number"] as $bad
      | if $bad == [] then . else {problems: $bad} end
    else . end;

# A typed review line whose sent_back names any finding as verdict findings, whatever the
# reviewer's word: a pass whose notes go back before the merge is not ready to merge, so every
# reader of a review's verdict (phase, team-sweep, team-inbox, team-merge) holds it back. team-log
# applies it to every review it logs, by hand or from a worker's message; any other line is left.
def review_sent_back:
  if .event == "review" and .verdict == "pass" and (.sent_back | type) == "array" and .sent_back != []
  then .verdict = "findings" else . end;

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

# The finding kinds a review's findings counts, and the guarded areas its guarded may name, the
# areas of bin/lib/guarded in its order; dependencies and settings are retired (T276), so a review
# logged before naming them holds nothing back.
def finding_kinds: ["blocking", "correctness", "security", "real-data", "note-change", "note-before"];
def guarded_areas: ["ci", "migrations", "deploy", "permissions", "secrets", "guardrails"];

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

# How a plan's scope, a list (scope.txt's lines, on a plan-approved), holds entries that are not
# clean repository paths.
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
# one of the kind's writers and of each field_writers field it holds, then the kind's fields,
# whatever its ts. Only the first failing step is told.
def append_problems($contract; $writer):
  (if type == "object" then .event else null end) as $event
  | . as $line
  | ([line_problems] | select(. != []))
    // ([writers($contract.kinds[$event]) | select(. != [] and (index($writer) | not))
        | "\($event) events are written by \(join(" or ")), not \($writer)"]
      | select(. != []))
    // ([$contract.kinds[$event].field_writers // {} | to_entries[]
        | select((.key | in($line)) and .value != $writer)
        | "\(if $event | test("^[aeiou]") then "an" else "a" end) \($event)'s \(.key) is written by \(.value), not \($writer)"]
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
  elif $want == "id" or $want == "digits" then "\(.) (\($want))"
  else "\(.) (\($want | noun | sub("^an? "; "")))" end;

# The contract as a table, one row per kind: event, writer, fields, "pushed at once" for a push
# kind, and what the kind is about.
def contract_table:
  .kinds | to_entries
  | (map(.key | length) | max) as $event_width
  | (map(writers(.value) | join(", ") | length) | max) as $writer_width
  | "  \("event" | pad($event_width))  \("written by" | pad($writer_width))  fields",
    (.[] | .value as $kind
      | ([$kind.required | to_entries[] | .value as $type | .key | field_text($type)] as $fields
         | [($kind.optional // {}) | to_entries[] | .value as $type | .key | field_text($type)] as $optional
         | [($kind.one_of // [])[] | "one of \(join(" or "))"] as $one_of
         | if $fields == [] then "-" else $fields | join(", ") end
           + if $optional == [] then "" else "; optional \($optional | join(", "))" end
           + if $one_of == [] then "" else "; \($one_of | join("; "))" end
           + if $kind.push == true then "; pushed at once" else "" end) as $text
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

# The open worktrees among a stream of ledger events: one {task, project, branch, worktree, ticket}
# per opened or worktree-added event with no later worktree-returned of the same task, project,
# ticket and worktree, in the order they were added, ticket the two-digit number of a ticket
# worktree (team-open --ticket) and null for the task's own worktree in its project; a
# worktree-moved gives the open worktree of its task, project and ticket its new path, and a
# branch-renamed, which names no ticket, the task's own worktree in its project its new branch.
# Worktrees are paths on this machine (local_worktree). A caller that means the task's worktree in
# a project takes the one whose ticket is null; one that walks every worktree takes all.
def open_worktrees(events; $home):
  reduce (events | local_worktree($home)) as $e ([];
    if $e.event == "opened" or $e.event == "worktree-added" then
      . + [$e | {task, project, branch, worktree, ticket}]
    elif $e.event == "worktree-moved" then
      map(if [.task, .project, .ticket] == [$e.task, $e.project, $e.ticket] then .worktree = $e.worktree else . end)
    elif $e.event == "branch-renamed" then
      map(if [.task, .project, .ticket] == [$e.task, $e.project, null] then .branch = $e.branch else . end)
    elif $e.event == "worktree-returned" then
      map(select([.task, .project, .ticket, .worktree] != [$e.task, $e.project, $e.ticket, $e.worktree]))
    else . end)
  | .[];

# A task's open worktrees (open_worktrees, over its events as an array), each with the folder
# under tasks/T<n>/ its task directory is archived to: scratch for the project the task was
# opened in, scratch-<project> for one added later, and for a ticket worktree its task
# worktree's folder with --NN after it (scratch--03, scratch-<project>--03).
def archived_worktrees($home):
  (map(select(.event == "opened")) | first | .project) as $opened
  | open_worktrees(.[]; $home)
  | . + {archive: ((if .project == $opened then "scratch" else "scratch-\(.project)" end)
      + if .ticket == null then "" else "--\(.ticket)" end)};

# Whether $a is a full 40-hex SHA and $b the same one, the case aside: the match where a prefix
# must not stand for a commit, as the reviewer App's check on a head.
def exact_head($a; $b):
  ($a | type) == "string" and ($b | type) == "string" and ($a | test("^[0-9a-fA-F]{40}$"))
  and ($a | ascii_downcase) == ($b | ascii_downcase);

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

# Whether this event, logged after the ask $ask (an asked event), settles it: the answered with its
# id, or for history a merge-preapproved with it (a kind retired by T276), or a merge-approved
# whose url (a trailing slash aside) the ask's text names, not followed by a digit, since the
# coordinator logs a merge answer as merge-approved alone as often as not.
def settles($ask):
  (.event == "answered" and .id == $ask.id)
  or (.event == "merge-preapproved" and .ask == $ask.id)
  or (.event == "merge-approved" and (.url | type) == "string" and (.url | test("^https?://"))
    and ((.url | rtrimstr("/")) as $url | ($ask.text // "" | tostring) as $text
      | any($text | indices($url)[]; $text[. + ($url | length):] | test("^[0-9]") | not)));

# The lifecycle: one fold of a task's events into its state, read by every def that asks where
# the task stands. The table is bin/lib/lifecycle.json, imported as data: which kinds a task takes
# in each status and phase, and the effect each kind has here.

# The lifecycle table, lifecycle.json.
def lifecycle_table: $lifecycle::lifecycle[0];

# The statuses the table names: a task's status, and closed-own-retro, a closed retro taking its own
# retro-change.
def lifecycle_statuses: ["unknown", "legacy", "open", "closed", "closed-own-retro"];

# The effects lifecycle_step implements, each named by a kind of the table.
def lifecycle_effects:
  ["open", "close", "approve", "withdraw", "launch", "build", "done", "pr", "review", "rewrite", "merge", "ask",
   "settle", "park", "resume", "stowing", "stowed", "stow-failed", "worktree"];

# The cause of a park event (held, blocked, waiting, paused) that carries none, as an old line
# does, first match wins: a paused whose reason starts with the word stowed (any case) stow, a
# worker's answer to a STOW; a reason holding no room room, a launch refused for room; a reason or
# on naming a usage, token, weekly or session limit limit; a reason holding stowed, shutdown, OS
# update or handoff shutdown; a held daniel-hold; a waiting whose reason is ask <id> ask; a
# waiting on Daniel (any case) or on no one daniel, any other waiting outside; a blocked on a task
# (T<m>) task, one whose reason names a denial (denied, refused, deny rule, denial, permission
# prompt, auto mode) denial, any other worker; a paused naming load, memory, Docker, a daemon, a
# restart or an outage machine; any other worker. It may name a cause the table does not list for
# the kind (an old held for an OS update reads shutdown): the table's kinds bind new lines only.
def legacy_cause:
  (.reason // "" | tostring) as $reason
  | (.on // "" | tostring) as $on
  | ($on | ascii_downcase) as $who
  | .event as $kind
  | if $kind == "paused" and ($reason | test("^stowed\\b"; "i")) then "stow"
    elif $reason | test("no room"; "i") then "room"
    elif "\($reason) \($on)" | test("(usage|token|weekly|session) limit"; "i") then "limit"
    elif $reason | test("stowed|shutdown|OS update|handoff"; "i") then "shutdown"
    elif $kind == "held" then "daniel-hold"
    elif $kind == "waiting" and ($reason | test("^ask \\S+$")) then "ask"
    elif $kind == "waiting" and ($who == "daniel" or $who == "") then "daniel"
    elif $kind == "waiting" then "outside"
    elif $kind == "blocked" and ($who | test("^t[0-9]+$")) then "task"
    elif $kind == "blocked" and ($reason | test("denied|refused|deny rule|denial|permission prompt|auto mode"; "i")) then "denial"
    elif $kind == "blocked" then "worker"
    elif $kind == "paused" and ("\($reason) \($on)" | test("load|memory|docker|daemon|restart|outage"; "i")) then "machine"
    else "worker" end;

# A park event's cause: its own, else legacy_cause's. Every reader that asks whether a park is a
# stow or a room refusal reads this, never the park's words.
def park_cause: .cause // legacy_cause;

# A park event's role: its own, else for a room refusal the role its reason names after session:
# ("no room for session:builder at ..."), else null.
def park_role:
  .role // (if park_cause == "room" then first(.reason | strings | capture("session:(?<r>[a-z]+)") | .r) // null else null end);

# A park event's ticket in the state $state (lifecycle_start's fields tickets and
# ticket_worktrees): the ticket of the launch its session names, a builder's in a ticket worktree,
# else for team-worker's room refusal of a brief brief-build-NN, or of team-next --fill's relaunch
# brief brief-resume-build-NN (-<k> after it for a later one), while ticket NN's worktree is open
# (the refused launch was that ticket's, into its worktree) NN, else null.
def park_ticket($state):
  (if (.session | type) == "string" then $state.tickets[.session] else null end)
  // (if park_cause == "room" then first(.brief | strings | capture("^brief-(resume-)?build-(?<n>[0-9]{2})(-[0-9]+)?$") | .n
        | select(IN($state.ticket_worktrees[]; .))) // null
      else null end);

# The state before a task's first event. The state's fields, which later readers add to rather
# than fold again:
#   status  unknown (no event), legacy (events but no opened), open, closed.
#   path    the opened's path, null before it.
#   opened_at the opened's ts, null before it.
#   phase   the work phase, one of the table's phases: planning before an opened, then the table's
#           start for its path (planning for a path it lacks), moved by lifecycle_step's effects.
#   since   the ts of the event that set the phase.
#   approval null before a plan-approved, then approved, or withdrawn after a
#           plan-approval-withdrawn until the next plan-approved: while it is withdrawn nothing
#           moves the phase to building.
#   withdrawal the plan-approval-withdrawn's {ts, discord_message} while approval is
#           withdrawn, else null.
#   prs     the task's PRs, one per repo, in the order of their latest pr events, as {url, repo,
#           head, number, merged, verdict}: a later pr in the repo replaces its PR (keeping merged
#           for the same url), a history-rewritten moves heads (from its old_head, or every PR's
#           when no PR has that head); merged by a merged event naming it (merged_names); verdict
#           the latest review's on its current head, or null, whenever that review was logged (a
#           fix's head is reviewed before a pr event logs it).
#   reviews each review's head and verdict, in the order logged, for a PR's verdict when its head
#           moves.
#   parks   the standing parks (held, blocked, waiting, paused) in the order logged, as {id, kind,
#           cause, typed, on, reason, role, session, ticket, ask, since, ts, i, passed}: id
#           <kind>-<n>, n the park's ordinal among the task's events of its kind; cause
#           park_cause's, typed whether the line carries its own cause; role park_role's; ticket
#           park_ticket's, the ticket whose builder it parks, or null; on, reason, session and ask
#           (a wait's ask id) its fields, or null; since its since field or its ts; i its index
#           among the task's events; passed whether a launch since named its ask (a wait's ask
#           id) in past_ask, so it parks nothing. A typed park ends by its cause's rules in the
#           table's causes: a launch by lifecycle_launch_ends (a ticket's park only by a launch of
#           that ticket), a resumed by lifecycle_resume_ends,
#           and an ask's wait (lifecycle_ask_wait) only once no ask of the state is its ask. An
#           asked from the table's asked_parks_from on parks by itself (one before it parks
#           nothing, as history read it): it adds its ask's wait, {id: asked-<n> (n its ordinal among the
#           task's asked events), kind waiting, cause ask, typed, on Daniel, reason "ask <id>", ask
#           <id>, asked true}, which an old line's typed wait on the same ask (team-ask logged one
#           until T303) takes the place of, keeping that line's id and since. An old
#           park (no cause on its line) ends as before: at a launch unless it is a held, and at a
#           resumed with none of id, all and brief; a resumed's id naming it ends it too, and all
#           true when its legacy_cause takes all. A brief alone (a merge-base round's holder brief)
#           ends none; a merge-approved ends every old wait on Daniel (lifecycle_old_wait_on_daniel).
#   asks    the asks no later event settles (settles), as {id, text, ts, i, passed}, passed whether
#           a launch since named it in past_ask (team-worker --past-ask), so it parks nothing.
#   stow    null, or the task's stow since its latest launch, as {state, cause, roles, since, i}:
#           state stowing from a stowing (a stow under way, its cause and roles the stowing's),
#           stowed from a stowed (its cause and roles), or failed from a stow-failed, which keeps
#           the stowing's cause and roles and adds reason, read as stowed for the resume; since
#           and i the event's ts and index.
#   tickets each ticket launch's session (a builder's in a ticket worktree), as {<session>: NN}.
#   ticket_worktrees the tickets whose ticket worktree is open (a worktree-added with ticket and
#           no worktree-returned of that ticket since), in the order added.
#   counts  each park kind's events so far, and the asked events that parked (asked), for the
#           next park's id.
#   seen    the events folded so far, the next event's index.
def lifecycle_start:
  {status: "unknown", path: null, opened_at: null, phase: "planning", since: null, approval: null, withdrawal: null, prs: [], reviews: [], parks: [],
   asks: [], stow: null, tickets: {}, ticket_worktrees: [], counts: {}, seen: 0};

# Whether the merged event $e names the PR (the input, one of the state's or task_prs' PRs) among
# $prs: by its URL when the event names one; a legacy event names only the number, and then, when
# another of $prs has the same number in another repo, its head must be the PR's.
def merged_names($e; $prs):
  . as $pr
  | $e.event == "merged"
    and if $e.url != null then $e.url == $pr.url
      else $pr.number != null and ($e.pr | tostring) == ($pr.number | tostring)
        and (([$prs[] | select(.number == $pr.number)] | length) == 1 or same_head($e.head; $pr.head)) end;

# The state with its work phase moved to $phase at $ts; since stays when the phase does not move.
def lifecycle_move($phase; $ts): if .phase == $phase then . else .phase = $phase | .since = $ts end;

# The verdict of the state's latest review of $head, or null.
def lifecycle_verdict($head): first(.reviews | reverse[] | select(same_head(.head; $head)) | .verdict) // null;

# The state's PRs not merged.
def lifecycle_open_prs: [.prs[] | select(.merged | not)];

# Whether a park of the state is an old (untyped) wait on Daniel, which a merge-approved ends, as
# Daniel's word on a merge answers what the wait was for.
def lifecycle_old_wait_on_daniel: .kind == "waiting" and (.typed | not) and IN(.cause; "daniel", "ask");

# The table's rules for a park of the state (its cause's row of causes), or null for a cause the
# table lacks.
def lifecycle_rules: lifecycle_table.causes[.cause // ""] // null;

# Whether a park of the state is a typed wait on an ask (cause ask on its own line), which only
# its ask's settling ends.
def lifecycle_ask_wait: .typed and .cause == "ask";

# Whether the launch $e ends a park of the state: a typed park by its cause's launch rule (any;
# role, a launch of the park's role, or any launch when the park names none; never), an old one
# by phase 1's (every blocked, waiting and paused, never a held); and a ticket's park (its ticket
# not null, park_ticket's) only when $e is a launch of that ticket, so one ticket builder's launch
# never ends another ticket's park.
def lifecycle_launch_ends($e):
  lifecycle_rules as $rules
  | (.ticket == null or ($e.ticket // null) == .ticket)
    and if .typed and $rules != null then
      $rules.launch == "any" or ($rules.launch == "role" and (.role == null or .role == $e.role))
    else .kind != "held" end;

# Whether the resumed $e ends a park of the state: an id naming it ends a typed park whose cause's
# resume is id, or daniel with $e's discord_message, Daniel's word, and an old one whatever its
# cause, as team-answer ends an old ask's wait; all true ends one whose cause (legacy_cause's on an
# old line) takes all; an old line with none of id, all and brief ends every old park, and a
# brief alone ends none.
def lifecycle_resume_ends($e):
  lifecycle_rules as $rules
  | ($e.id != null and .id == $e.id
     and ((.typed | not) or $rules.resume == "id" or ($rules.resume == "daniel" and $e.discord_message != null)))
    or ($e.all == true and $rules.all == true)
    or ($e.id == null and $e.all == null and $e.brief == null and (.typed | not));

# The review phase at $ts: awaiting-merge when the task has an open PR and every open PR's verdict
# is pass, else in-review; applied only while the phase is one of $from.
def lifecycle_review_phase($ts; $from):
  if IN(.phase; $from[]) then
    lifecycle_open_prs as $open
    | lifecycle_move(if $open != [] and all($open[]; .verdict == "pass") then "awaiting-merge" else "in-review" end; $ts)
  else . end;
def lifecycle_review_phase($ts): lifecycle_review_phase($ts; ["building", "in-review", "awaiting-merge"]);

# The state after the event $e: its status (legacy once it has an event), then the effect the
# table gives its kind: open (an opened of an unknown or legacy task: open, its path, the start
# phase), close, approve (approval approved, planning to building), withdraw (approval withdrawn,
# building to planning), launch (a builder's moves planning, merged-part or merged to building
# unless the approval is withdrawn; every launch ends the parks a launch ends, and the stow, and
# marks passed each ask its past_ask names and each standing wait on one), build (a
# ticket-done: the same moves), done (a builder's whose report starts review-ready or merged moves
# building to in-review), pr, review and rewrite (the PRs, then the review phase: a pr's from any
# phase, a review's or a rewrite's from building, in-review or awaiting-merge, a rewrite's only
# when the task has a PR, since no review is under way without one), merge (its PR
# merged; with none open, merged-part when it names a non-empty phases_left, else merged; else the
# review phase), ask, settle, park, resume, stowing, stowed, stow-failed and worktree (a
# worktree-added or worktree-returned of a ticket worktree, ticket_worktrees) (as the state's
# fields say); a launch with a ticket also records its session's ticket (tickets).
def lifecycle_step($e):
  (lifecycle_table.kinds[$e.event // ""].effect // null) as $effect
  | .seen as $i
  | .seen += 1
  | if .status == "unknown" then .status = "legacy" else . end
  | if $effect == "open" then
      if IN(.status; "unknown", "legacy") then
        .status = "open" | .path = $e.path | .opened_at = $e.ts
        | lifecycle_move(lifecycle_table.start[$e.path // ""] // "planning"; $e.ts) | .since = $e.ts
      else . end
    elif $effect == "close" then .status = "closed"
    elif $effect == "approve" then
      .approval = "approved" | .withdrawal = null
      | if .phase == "planning" then lifecycle_move("building"; $e.ts) else . end
    elif $effect == "withdraw" then
      .approval = "withdrawn" | .withdrawal = {ts: $e.ts, discord_message: $e.discord_message}
      | if .phase == "building" then lifecycle_move("planning"; $e.ts) else . end
    elif $effect == "launch" then
      ($e.past_ask // []) as $past
      | (if $e.role == "builder" and IN(.phase; "planning", "merged-part", "merged") and .approval != "withdrawn"
         then lifecycle_move("building"; $e.ts) else . end)
      | .asks |= map(if IN(.id; $past[]) then .passed = true else . end)
      | .parks |= map(select(lifecycle_launch_ends($e) | not) | if .ask != null and IN(.ask; $past[]) then .passed = true else . end)
      | .stow = null
      | if ($e.ticket | type) == "string" and ($e.session | type) == "string" then .tickets[$e.session] = $e.ticket else . end
    elif $effect == "build" then
      if IN(.phase; "planning", "merged-part", "merged") and .approval != "withdrawn" then lifecycle_move("building"; $e.ts) else . end
    elif $effect == "done" then
      if $e.role == "builder" and .phase == "building" and ($e.report // "" | tostring | test("^(review-ready|merged) "))
      then lifecycle_move("in-review"; $e.ts) else . end
    elif $effect == "pr" then
      (first($e.url | strings | capture("^https://github\\.com/(?<r>[^/]+/[^/]+)/") | .r | ascii_downcase) // $e.url) as $repo
      | (.prs | map(select(.repo == $repo)) | first) as $old
      | .prs = (.prs | map(select(.repo != $repo)))
        + [{url: $e.url, repo: $repo, head: $e.head,
            number: (first($e.url | strings | capture("/pull/(?<n>[0-9]+)/?$") | .n | tonumber) // null),
            merged: ($old != null and $old.url == $e.url and $old.merged), verdict: lifecycle_verdict($e.head)}]
      | lifecycle_review_phase($e.ts; lifecycle_table.phases)
    elif $effect == "review" then
      .reviews += [{head: $e.head, verdict: $e.verdict}]
      | .prs |= map(if same_head(.head; $e.head) then .verdict = $e.verdict else . end)
      | lifecycle_review_phase($e.ts)
    elif $effect == "rewrite" then
      any(.prs[]; same_head($e.old_head; .head)) as $named
      | . as $state
      | .prs |= map(if ($named | not) or same_head($e.old_head; .head) then .head = $e.head | .verdict = ($state | lifecycle_verdict($e.head)) else . end)
      | if .prs == [] then . else lifecycle_review_phase($e.ts) end
    elif $effect == "merge" then
      .prs as $prs
      | .prs |= map(if merged_names($e; $prs) then .merged = true else . end)
      | if lifecycle_open_prs == [] then
          lifecycle_move(if ($e.phases_left | type) == "array" and $e.phases_left != [] then "merged-part" else "merged" end; $e.ts)
        else lifecycle_review_phase($e.ts) end
    elif $effect == "ask" then
      .asks += [{id: $e.id, text: $e.text, ts: $e.ts, i: $i, passed: false}]
      | if ($e.ts | tostring) < lifecycle_table.asked_parks_from then .
        else
          .counts.asked = ((.counts.asked // 0) + 1)
          | .parks += [{id: "asked-\(.counts.asked)", kind: "waiting", cause: "ask", typed: true, on: "Daniel",
              reason: "ask \($e.id)", role: null, session: null, ticket: null, ask: $e.id, since: $e.ts, ts: $e.ts,
              i: $i, passed: false, asked: true}]
        end
    elif $effect == "settle" then
      .asks |= map(. as $ask | select($e | settles($ask) | not))
      | if $e.event == "merge-approved" then .parks |= map(select(lifecycle_old_wait_on_daniel | not)) else . end
      | .asks as $asks
      | .parks |= map(select(lifecycle_ask_wait and (.ask as $ask | all($asks[]; .id != $ask)) | not))
    elif $effect == "park" then
      .counts[$e.event] = ((.counts[$e.event] // 0) + 1)
      | if $e.event == "waiting" and $e.cause == "ask" and $e.ask != null
        then .parks |= map(select(.asked == true and .ask == $e.ask | not)) else . end
      | . as $state
      | .parks += [{id: "\($e.event)-\(.counts[$e.event])", kind: $e.event, cause: ($e | park_cause),
          typed: ($e.cause != null), on: ($e.on // null), reason: ($e.reason // null), role: ($e | park_role),
          session: ($e.session // null), ticket: ($e | park_ticket($state)), ask: ($e.ask // null),
          since: ($e.since // $e.ts), ts: $e.ts, i: $i, passed: false}]
    elif $effect == "resume" then
      .parks |= map(select(lifecycle_resume_ends($e) | not))
    elif $effect == "stowing" then
      .stow = {state: "stowing", cause: ($e.cause // null), roles: ($e.roles // []), since: $e.ts, i: $i}
    elif $effect == "stowed" then
      .stow = {state: "stowed", cause: ($e.cause // null), roles: ($e.roles // []), since: $e.ts, i: $i}
    elif $effect == "stow-failed" then
      (if .stow.state == "stowing" then .stow else {cause: null, roles: []} end) as $stowing
      | .stow = {state: "failed", cause: $stowing.cause, roles: $stowing.roles, since: $e.ts, i: $i, reason: ($e.reason // null)}
    elif $effect == "worktree" and ($e.ticket | type) == "string" then
      if $e.event == "worktree-added" then .ticket_worktrees |= (if index([$e.ticket]) then . else . + [$e.ticket] end)
      else .ticket_worktrees |= map(select(. != $e.ticket)) end
    else . end;

# The task's state: its events, in ledger order, folded from lifecycle_start.
def lifecycle: reduce .[] as $e (lifecycle_start; lifecycle_step($e));

# Why a launch of $role in the task $task (the state is the input) is refused, one string each,
# none when it may go; $past the ask ids the launch names (team-worker --past-ask), $hint whether
# a refused ask's text says how to launch past it, and $role "" a message that launches nothing:
#   1. not open: closed, or not opened (no opened event);
#   2. for every role but ops, Daniel's hold (a standing park of cause daniel-hold, typed or by
#      legacy_cause), naming the resumed that lifts it;
#   3. for every role but ops, an open ask neither $past nor an earlier launch's past_ask names,
#      and each $past id that is no open ask;
#   4. a builder or reviewer of a task, on any path and in any phase, whose plan approval is
#      withdrawn, naming the withdrawal; else of a feature task still planning (its work phase
#      planning: no plan-approved, builder launch or ticket-done yet).
def lifecycle_launch_refusal($task; $role; $past; $hint):
  if .status == "closed" then "\($task) is closed"
  elif .status != "open" then "\($task) is not open: the ledger has no opened event for it"
  else
    (if $role == "ops" then empty
     else
       ([.parks[] | select(.cause == "daniel-hold")] | last // empty
        | "\($task) is on Daniel's hold since \(.since) (\(.id)): \(.reason); only Daniel's word lifts it: team-log \($task) resumed id=\(.id) discord_message=<their message id>"),
       (.asks[] | select((.passed | not) and (IN(.id; $past[]) | not))
        | "\($task) has an unanswered ask, \(.id), since \(.ts)" + (if $hint then "; launch past it with --past-ask \(.id)" else "" end)),
       (.asks as $asks | $past[] | select(IN($asks[].id) | not) | "--past-ask \(.) names no unanswered ask of \($task)")
     end),
    (if IN($role; "builder", "reviewer") and .approval == "withdrawn" then
       "\($task)'s plan approval was withdrawn at \(.withdrawal.ts) in Discord message \(.withdrawal.discord_message), so it takes no \($role) until Daniel approves the plan again (plan-approved by=Daniel)"
     elif IN($role; "builder", "reviewer") and .path == "feature" and .phase == "planning" then
       "\($task) is a feature task with no approved plan (no plan-approved), so it takes no \($role) yet"
     else empty end)
  end;
def lifecycle_launch_refusal($task; $role; $past): lifecycle_launch_refusal($task; $role; $past; false);

# The launch refusal (lifecycle_launch_refusal) over a task's events, as team-worker and team-next
# check it before they act.
def launch_refusal($task; $role; $past; $hint): lifecycle | lifecycle_launch_refusal($task; $role; $past; $hint);
def launch_refusal($task; $role; $past): launch_refusal($task; $role; $past; false);

# How the event $e breaks the table in the state (the input), one string each, nothing when the
# table takes it: a status its kind does not take (closed, with closed-own-retro for a closed
# task's own retro-change, its retro this task; not opened, unknown or legacy, naming the kinds
# that status takes in the table's order; opened already), else a phase it does not take, a park
# (a kind of effect park) with no cause, naming the causes the table gives its kind, a held while
# Daniel's hold (a park of cause daniel-hold) stands, and a resumed whose id names no standing
# park, an ask's wait, or Daniel's hold with no discord_message: every resumed id= the fold would
# not end; a launch lifecycle_launch_refusal refuses, by its role and past_ask, so the guard and
# the table cannot disagree; and a stowing while one stands, or a stowed or stow-failed with no
# stowing standing. A kind the table does not list takes default.
def lifecycle_problems($e):
  lifecycle_table as $t
  | ($t.kinds[$e.event] // {}) as $row
  | ($row.status // $t.default.status) as $statuses
  | ($row.phases // $t.default.phases) as $phases
  | def kinds_taken($status): [$t.kinds | to_entries[] | select(.value.status // $t.default.status | index([$status])) | .key];
    def listed($word): if length < 2 then join("") else "\(.[:-1] | join(", ")) \($word) \(.[-1])" end;
  if (.status | IN($statuses[]))
     or (.status == "closed" and $e.retro == $e.task and ("closed-own-retro" | IN($statuses[]))) then
    (if $phases == null or (.phase | IN($phases[])) then empty
     else "\($e.task) is \(.phase) since \(.since), and \($e.event) is taken only while it is \($phases | listed("or"))" end),
    (if $row.effect == "park" and $e.cause == null then
       "a \($e.event) needs a cause, one of \([$t.causes | to_entries[] | select(.value.kinds | index([$e.event])) | .key] | sort | join(", "))"
     else empty end),
    (if $e.event == "held" then
       first(.parks[] | select(.cause == "daniel-hold")) | "\($e.task) is on Daniel's hold already: \(.id) since \(.since)"
     else empty end),
    (if $e.event == "resumed" and $e.id != null then
       (first(.parks[] | select(.id == $e.id)) // null) as $park
       | if $park == null then
           "\($e.task) has no standing park \($e.id); its standing parks: \(.parks | map(.id) | if . == [] then "none" else join(", ") end)"
         elif $park | lifecycle_ask_wait then
           "\($e.id) is the wait on ask \($park.ask), which ends when the ask is answered (team-answer), not with a resumed"
         elif ($park | lifecycle_rules.resume == "daniel" and (lifecycle_resume_ends($e) | not)) then
           "\($e.id) is Daniel's hold, which only a resumed with discord_message, Daniel's word, lifts"
         else empty end
     else empty end),
    (if $e.event == "launch" then lifecycle_launch_refusal($e.task; $e.role // ""; $e.past_ask // []) else empty end),
    (if $e.event == "stowing" and .stow.state == "stowing" then "\($e.task) is stowing already, since \(.stow.since)"
     elif IN($e.event; "stowed", "stow-failed") and .stow.state != "stowing" then "\($e.event) with no stowing of \($e.task) standing"
     else empty end)
  elif .status == "closed" then "\($e.task) is closed, and a closed task takes no \($e.event)"
  elif IN(.status; "unknown", "legacy") then
    "\($e.task) is not opened (no opened event), and it takes only \(kinds_taken(.status) | listed("and")) before its opened, not \($e.event)"
  elif $e.event == "opened" then "\($e.task) is opened already, at \(.opened_at)"
  else "\($e.task) is \(.status), and an \(.status) task takes no \($e.event)" end;

# How the event $e breaks the table in the state the task's events (the input) reach
# (lifecycle_problems), one string each.
def transition_problems($e): lifecycle | lifecycle_problems($e);

# The replay of a ledger read as raw lines (jq -nR) against the table, in one pass: each line that
# is a JSON object with a task and an event checked against its task's state before it
# (lifecycle_problems), then folded into it; any other line is check_ledger's to name. As
# {total (the lines), from (the table's lifecycle_from), bad: [{line, task, event, ts, problems}]}.
def check_lifecycle:
  reduce inputs as $raw ({total: 0, tasks: {}, bad: []};
    .total += 1
    | (if $raw | test("^\\s*$") then null else (try ($raw | fromjson) catch null) end) as $e
    | if ($e | type) == "object" and ($e.task | type) == "string" and ($e.event | type) == "string" then
        (.tasks[$e.task] // lifecycle_start) as $state
        | [$state | lifecycle_problems($e)] as $problems
        | (if $problems == [] then . else .bad += [{line: .total, task: $e.task, event: $e.event, ts: $e.ts, problems: $problems}] end)
        | .tasks[$e.task] = ($state | lifecycle_step($e))
      else . end)
  | {total, from: lifecycle_table.lifecycle_from, bad};

# The task's status: open (opened by team-open, not closed), closed, legacy (from before
# team-open: events but no opened, not closed) or unknown (no events).
def task_status: lifecycle.status;

# The task's PRs, one per repo, as {url, head, number}, in the order of their latest pr events
# (the fold's prs).
def task_prs: lifecycle.prs | map({url, head, number});

# The head the ledger knows for the PR at $url, from task_prs.
def pr_head($url): task_prs | map(select(.url == $url)) | last | .head;

# Whether a PR of task_prs (the input) has a merged event among $events naming it (merged_names
# among $prs, the task's PRs).
def pr_merged($events; $prs): . as $pr | any($events[]; . as $e | $pr | merged_names($e; $prs));

# The task's phase: closed when it is closed, else held while a held stands, else blocked while
# a blocked stands, wherever either was logged, else the fold's work phase (planning, building,
# in-review, awaiting-merge, merged-part or merged).
def lifecycle_phase:
  if .status == "closed" then "closed"
  elif any(.parks[]; .kind == "held") then "held"
  elif any(.parks[]; .kind == "blocked") then "blocked"
  else .phase end;
def phase: lifecycle | lifecycle_phase;

# The state's latest standing park of $kind, or null.
def lifecycle_park($kind): [.parks[] | select(.kind == $kind)] | last;

# The state's stow under way, {since, cause} of its stowing while one stands, or null.
def lifecycle_stowing: .stow | if . != null and .state == "stowing" then {since, cause} else null end;

# The state's standing parks as team-state shows them, in the order logged, each {id, kind, cause
# (its own, else legacy_cause's), on, reason, since, passed}.
def lifecycle_parks: [.parks[] | {id, kind, cause, on, reason, since, passed}];

# What the task is waiting on, from the fold's latest standing waiting, as {on, reason, since (its
# ts)}, or null.
def lifecycle_waiting: lifecycle_park("waiting") | if . == null then null else {on, reason, since: .ts} end;
def waiting: lifecycle | lifecycle_waiting;

# The asks put to Daniel that no later event settles yet, from the fold, as {id, text, ts}.
def lifecycle_pending_asks: [.asks[] | {id, text, ts}];
def pending_asks: lifecycle | lifecycle_pending_asks;

# The asked events no later event settles yet (the fold's asks), each as {k, ask}: its index among
# the events and the event.
def unsettled_asks: . as $events | [lifecycle.asks[] | {k: .i, ask: $events[.i]}];

# The task's manual QC walk: {since} while it is on, since the ts of its latest walk event when
# that says on, with its thread when that names one (interview) and the message of Daniel's it
# reseeded on and the one port that clears when it has one, else null, as for a task with none or a
# closed one, whose walk ended
# with it. Read by team-ui --walk, capture_refusal, team-post, task_state and walk_last_note.
def qc_walk:
  if task_status == "closed" then null
  else map(select(.event == "walk")) | last
    | if .state == "on" then {since: .ts} + (if .thread then {thread} else {} end) + (if .reseeded then {reseeded, reseeded_port} else {} end) else null end end;

# How long a walk counts with no message from Daniel, in seconds: a person clicking in Chrome makes
# no session busy, so this is all that tells a walk under way from one left on.
def walk_hold_seconds: 14400;

# Over a task's events: when Daniel last spoke on the walk that is on, the latest of its start and
# its walk-note events, or null with no walk on. A message that reached neither team-thread wait nor
# team-ui --note-file is not among them.
def walk_last_note:
  qc_walk as $walk
  | if $walk == null then null
    else [$walk.since, (.[] | select(.event == "walk-note") | .ts)] | max end;

# Over a task's events: whether a walk is on and still counts at the time <now> (seconds), keeping
# its stack up and its task last to stow. Read by team-stack sweep and plan_tasks.
def walk_holds($now):
  walk_last_note | . != null and ($now - fromdateiso8601) <= walk_hold_seconds;

# The worktrees team-resume could not re-home that still are not made: the latest rehome-failed of
# each project and ticket (none for the task's own worktree in the project) with no later opened,
# worktree-added, worktree-moved, rehomed or worktree-returned of that project and ticket, as
# {project, branch, machine, reason, since}, with ticket for a ticket worktree's, in the order
# they failed.
def rehome_failures:
  . as $events
  | [to_entries[] | select(.value.event == "rehome-failed") | .key as $i | .value as $failed
     | select(all($events[$i + 1:][]; .project != $failed.project or .ticket != $failed.ticket
         or (.event | IN("rehome-failed", "opened", "worktree-added", "worktree-moved", "rehomed", "worktree-returned") | not)))
     | $failed | {project, branch, machine, reason, since: .ts} + if .ticket then {ticket} else {} end];

# The index of the task's latest event of $kind, or -1 when it has none.
def latest_index($kind): [to_entries[] | select(.value.event == $kind) | .key] | last // -1;

# The index of the task's latest stowed, or -1 when it has none.
def latest_stowed: latest_index("stowed");

# Whether the task crashed, read on <machine> (this machine's team name): its latest machine event
# (a stowed, stow-failed, launch or worktree-moved) is a launch on another machine, or one that
# names none (an old launch), so the machine it last ran on stopped without handing it off. A
# launch here with no stow after it is no crash here: this machine restarted, and its worktree is
# live where it was.
def crashed($machine):
  [.[] | select(.event | IN("stowed", "stow-failed", "launch", "worktree-moved"))] | last
  | . != null and .event == "launch" and .machine != $machine;

# Whether the task is stowed, waiting to resume: its latest stowed, for the level or a handoff (cause
# level or handoff, or none, as before team-stow), or a stow-failed, which keeps its stowing's
# roles, names roles to relaunch and no launch follows it, so it waits for the resume or for room
# at the team's level to be relaunched here. A stowing (a stow under way) is not.
def lifecycle_stowed_awaiting_resume: .stow != null and IN(.stow.state; "stowed", "failed") and .stow.roles != [];
def stowed_awaiting_resume: lifecycle | lifecycle_stowed_awaiting_resume;

# What keeps a task's parked work, parked at its event of index <since>, from being launched, as
# text, or null, from the fold: wherever it was logged, its latest Daniel's hold (a park of cause
# daniel-hold, "held: <reason>") or its latest ask no launch passed ("unanswered ask <id>:
# <text>"); else its latest held of another cause, waiting ("waiting on <on>: <reason>") or
# blocked ("blocked: <reason>") logged after <since>, a passed ask's wait aside. A wait or block
# before it was the state the work was parked in, which its launch resumes, and a paused never
# holds it, since every park logs one; a resumed, or the ask's answer, lifts each.
def lifecycle_hold_since($since):
  def after($kind): [.parks[] | select(.kind == $kind and .i > $since and (.passed | not))] | last;
  ([.parks[] | select(.cause == "daniel-hold")] | last) as $hold
  | ([.asks[] | select(.passed | not)] | last) as $ask
  | if $hold != null then "held: \($hold.reason)"
    elif $ask != null then "unanswered ask \($ask.id): \($ask.text)"
    elif after("held") != null then "held: \(after("held").reason)"
    elif after("waiting") != null then after("waiting") | "waiting on \(.on): \(.reason)"
    elif after("blocked") != null then "blocked: \(after("blocked").reason)"
    else null end;
def hold_since($since): lifecycle | lifecycle_hold_since($since);

# What keeps the task, stowed and waiting to resume, from being relaunched (hold_since the fold's
# stow): Daniel's hold or an ask no launch passed holds it wherever it was logged, while a wait or
# block before the stow was the stowed worker's own state (a planner interviewing Daniel), which
# its relaunch resumes.
def lifecycle_stow_hold: lifecycle_hold_since(.stow.i // -1);
def stow_hold: lifecycle | lifecycle_stow_hold;

# The launches of the task refused for room and not launched or resumed since: the fold's standing
# parks whose cause (park_cause) is room and whose role (park_role) is known, as {at (the latest
# refusal's time), roles (each role once, in the order refused), hold (hold_since the latest
# refusal: Daniel's hold or an ask no launch passed wherever it was logged, while a wait or block
# before it did not stop the launch tried then)}; null with none, or
# while the task is stowed_awaiting_resume, whose resume relaunches its roles.
def lifecycle_refused_launches:
  if lifecycle_stowed_awaiting_resume then null
  else [.parks[] | select(.cause == "room" and .role != null)] as $refused
    | if $refused == [] then null
      else {at: $refused[-1].ts, roles: (reduce $refused[].role as $r ([]; if index([$r]) then . else . + [$r] end)),
            hold: lifecycle_hold_since($refused[-1].i)}
      end
  end;
def refused_launches: lifecycle | lifecycle_refused_launches;

# Whether the task's worktree in <project> of <ticket> (null for the task's own worktree there)
# resumes on <machine> from the last checkpoint's snapshot: the task crashed, read on <machine>,
# or its latest stowed recorded that worktree with uncommitted changes, which the handoff's
# checkpoint kept as wip/<project>/T<n> (a ticket worktree's as wip/<project>/T<n>--NN) on the
# team home's origin. With two arguments, the task's own worktree in <project>.
def snapshot_due($project; $ticket; $machine):
  crashed($machine) or (latest_stowed as $stowed | $stowed >= 0
    and any(.[$stowed].worktrees[]?; .project == $project and .ticket == $ticket and .uncommitted == true));
def snapshot_due($project; $machine): snapshot_due($project; null; $machine);

# Whether the event ends the worker of the launch <launch> (a launch event, its role, session and
# ticket): a launch with a ticket (a builder in that ticket's worktree) only by a done of its
# session or a ticket-done of its ticket; any other by its DONE, which the coordinator logs as a
# done of that role, a review (a reviewer's), or a ticket-done or a pr (a builder's: a delivering
# builder's PR <url> is logged as a pr, not a done).
def ends_launch($launch):
  if $launch.ticket != null then
    (.event == "done" and .session == $launch.session) or (.event == "ticket-done" and .ticket == $launch.ticket)
  else
    (.event == "done" and .role == $launch.role) or (.event == "review" and $launch.role == "reviewer")
    or ((.event == "ticket-done" or .event == "pr") and $launch.role == "builder")
  end;

# The task's unfinished work: each role launched since its latest stowed whose latest launch of a
# ticket (or of none) no later event ends (ends_launch), named once, in the order of those
# launches. The roles a handoff's stowed records and a crash relaunches. Never ops: an ops session
# runs only on Daniel's request, so on the other machine Daniel asks again.
def unfinished_roles:
  . as $events
  | latest_stowed as $stowed
  | [to_entries[] | select(.key > $stowed and .value.event == "launch" and .value.role != "ops")
    | .value + {i: .key}]
  | group_by([.role, .ticket]) | map(max_by(.i)) | sort_by(.i)
  | map(. as $l | select(all($events[$l.i + 1:][]; ends_launch($l) | not)) | .role)
  | reduce .[] as $role ([]; if index([$role]) then . else . + [$role] end);

# Every worktree the task was given (opened or added), at its latest path (worktree-moved) and on
# its latest branch (branch-renamed), and whether it was returned since, each event matched by
# project and ticket (null for the task's own worktree in its project, so a branch-renamed, which
# names no ticket, renames only that one), ticket the number of a ticket worktree.
def worktree_list:
  . as $events
  | [to_entries[] | select(.value.event == "opened" or .value.event == "worktree-added")
    | .key as $i | .value as $w
    | reduce ($events[$i + 1:][] | select(.project == $w.project and .ticket == $w.ticket)) as $e
        ($w | {project, branch, worktree, ticket, returned: false};
         if .returned then .
         elif $e.event == "worktree-moved" then .worktree = $e.worktree
         elif $e.event == "branch-renamed" then .branch = $e.branch
         elif $e.event == "worktree-returned" and $e.worktree == .worktree then .returned = true
         else . end)];

# The task's branch in <project>, over the task's events as an array: the latest opened,
# worktree-added or branch-renamed of the project with no ticket names it (a ticket worktree's
# branch is never the task's); null when none does.
def task_branch($project):
  [.[] | select((.event | IN("opened", "worktree-added", "branch-renamed")) and .project == $project and .ticket == null)]
  | last | .branch // null;

# Why PR #$number, from the branch $branch, is not task $task's own PR for $project, over the
# task's events as an array (task_branch), one string, or none when it is: the default word, given
# on no head, holds only for the task's own branch.
def task_branch_reasons($task; $project; $branch; $number):
  task_branch($project) as $own
  | if $own == null then "\($task) logged no branch for \($project): no opened, worktree-added or branch-renamed event of it"
    elif $branch != $own then "PR #\($number) comes from \($branch), not \($own), \($task)'s branch for \($project)"
    else empty end;

# A launch's session in the session list ($sessions, from claude agents --json), or null: by the
# short id, or by the start of the full session id (interactive sessions have no short id).
def live_session($session; $sessions):
  if ($session | type) == "string" and $session != "" then
    $sessions | map(select(.id == $session or ((.sessionId // "") | startswith($session)))) | first
  else null end;

# The task's launches whose sessions a new launch of <role> may stop, over its events as an array,
# each {session, role, worktree (local_path's), stowed, handed_on}; <role> "" stands for no new
# launch (the heartbeat's stow plan, over every open task). They are every planner and reviewer,
# and every builder when the new worker is a builder (team-worker keeps those of its own worktree,
# one builder holding a worktree's work at a time), or with no new launch every builder that a
# later logged builder launch of its worktree follows, and every ticket builder (a launch with a
# ticket) that its ticket's ticket-done follows. Handed on is a launch the ledger follows with a
# done of its session, or for a builder what else ends it (ends_launch: its ticket's ticket-done
# for a ticket builder, else a pr or any ticket-done), or with a paused whose cause
# is stow (park_cause: "stowed", "stowed, handoff written") and then a logged launch of its role
# and worktree (a stow carries no session, so it
# hands on only to the fresh worker that resumes the work, and a resumed does not undo it);
# stowed is whether such a paused follows it, so team-worker can count itself as that fresh
# worker. Any other paused is a wait the worker comes back from, and a review carries no session,
# so a reviewer is handed on by the done logged beside its review.
def handed_on_launches($role; $home):
  . as $events
  | [to_entries[] | .key as $i | .value
     | select(.event == "launch" and (.session | type) == "string" and .session != "")
     | . as $l | ($l.worktree | local_path($home)) as $wt
     | select(.role == "planner" or .role == "reviewer"
         or (.role == "builder"
             and if $role == "" then any($events[$i + 1:][]; (.event == "launch" and .role == "builder"
                   and (.worktree | local_path($home)) == $wt)
                   or ($l.ticket != null and .event == "ticket-done" and .ticket == $l.ticket))
                 else $role == "builder" end))
     | [range($i + 1; $events | length) | select($events[.] | .event == "paused" and park_cause == "stow")] as $stows
     | {session, role, worktree: $wt, stowed: ($stows != []),
        handed_on: (any($events[$i + 1:][]; (.event == "done" and .session == $l.session)
            or ($l.role == "builder" and .event != "done" and ends_launch($l)))
          or any($stows[] as $k | $events[$k + 1:][]; .event == "launch" and .role == $l.role
            and (.worktree | local_path($home)) == $wt))}];

# The live sessions of handed_on_launches' launches, given the session list <sessions>, each
# {session, role, worktree, state, handed_on}: state "busy", "waiting for input", "no status",
# "status <its status>" for one that is not idle, "handed-on" for an idle one whose work is handed
# on (the one to stop), "stowed" for an idle one a stow followed, else "idle with no event of its
# own since its launch"; handed_on is the launch's, whatever its state, so team-worker can wait
# for a busy one whose work is handed on.
def launch_states($sessions):
  [.[] | live_session(.session; $sessions) as $live | select($live != null)
   | {session, role, worktree, handed_on,
      state: (if $live.status == "busy" then "busy"
              elif $live.state == "blocked" then "waiting for input"
              elif $live.status == null then "no status"
              elif $live.status != "idle" then "status \($live.status)"
              elif .handed_on then "handed-on"
              elif .stowed then "stowed"
              else "idle with no event of its own since its launch" end)}];

# Every launch of the task, live when the session list has its session, with that session's context
# when task_state_json added it, the brief the launch logged (or null), its ticket (a builder's in
# ticket NN's worktree, else null) and its session's name, T<n>-<role>, or T<n>-builder-NN for a
# ticket's launch, as team-worker names it.
def workers($sessions):
  [.[] | select(.event == "launch") | live_session(.session; $sessions) as $live
    | (.ticket // null) as $ticket
    | {role, session, name: ("\(.task)-\(.role)" + if $ticket == null then "" else "-\($ticket)" end), ticket: $ticket,
       launched: .ts, worktree, live: ($live != null), status: $live.status, state: $live.state,
       context: $live.context, brief: (.brief // null)}];

# Where the task is, over its events and its workers: tickets (done, the tickets with a
# ticket-done, each once, and total and graph, null here, which task_state_json reads from
# team-tickets and the graph's page and PNG),
# on (each live worker's role, session and brief) and reviews (the count of the task's reviews,
# and the latest one's verdict, head and sent_back, each null when there is none).
def progress($workers):
  {tickets: {done: [.[] | select(.event == "ticket-done") | .ticket] | unique, total: null, graph: null},
   on: [$workers[] | select(.live) | {role, session, brief}],
   reviews: (map(select(.event == "review"))
     | {count: length} + (last // {} | {verdict, head, sent_back}))};

# The full session ids of the task's launches the session list has.
def live_session_ids($sessions):
  [.[] | select(.event == "launch") | live_session(.session; $sessions) | .sessionId // empty | strings] | unique;

# The latest asked of id $id among the task's events, or null: the ask a plan-approved of that id
# answers.
def latest_asked($id): [.[] | select(.event == "asked" and .id == $id)] | last;

# The task's plan approval, from its latest plan-approved or plan-approval-withdrawn, or null when
# it has neither, as {state, by, ask, discord_message, plan, scope, parallel, ts, legacy}: state
# approved or withdrawn; by, ask, plan, scope and parallel (the phases' caps) the approval's (null
# on a withdrawal, and parallel null when it names none), discord_message and ts the latest event's; legacy true for an approval logged before T276, with no plan, which is
# read as the coordinator's whatever its by says, so no old line is Daniel's read-back word.
def plan_approval:
  [.[] | select(.event == "plan-approved" or .event == "plan-approval-withdrawn")] | last
  | if . == null then null
    elif .event == "plan-approval-withdrawn" then
      {state: "withdrawn", by: null, ask: null, discord_message, plan: null, scope: null, parallel: null, ts, legacy: false}
    else
      (.plan == null) as $legacy
      | {state: "approved", by: (if $legacy then "coordinator" else .by end), ask: (.ask // null),
         discord_message: (.discord_message // null), plan: (.plan // null), scope: (.scope // null),
         parallel: (.parallel // null), ts, legacy: $legacy} end;

# Whether a merge-default-withdrawn or merge-default-restored covers the PRs of task $task in
# project $project: its scope is task and it is logged under $task, its scope is $project, or all.
# An empty $task or $project names none, so a scope of that kind never covers it.
def default_covers($task; $project):
  (.scope == "task" and .task == $task and $task != "") or (.scope == $project and $project != "") or .scope == "all";

# The latest merge-default-withdrawn or merge-default-restored of the events (any array, every
# task's) that covers the PRs of task $task in $project (default_covers), or null: the one that
# decides whether the default word stands for them, which it does unless that is a withdrawal.
def default_cover($task; $project):
  [.[] | select((.event == "merge-default-withdrawn" or .event == "merge-default-restored") and default_covers($task; $project))]
  | last;

# Who a merge-default-withdrawn or merge-default-restored is for, as text: its task, "project
# <name>" or "every project".
def default_scope_text: if .scope == "task" then .task elif .scope == "all" then "every project" else "project \(.scope)" end;

# Each task's projects, over every ledger event as an array: an object mapping each task an opened
# or worktree-added names to the projects of those events, each once.
def task_projects:
  [.[] | select((.event == "opened" or .event == "worktree-added") and (.task | type) == "string")]
  | group_by(.task) | map({key: .[0].task, value: (map(.project | strings) | unique)}) | from_entries;

# The PRs, as {task, project} ("" for none), whose default word the merge-default-withdrawn and
# merge-default-restored events (the input, every task's) and the events $extra may decide: each
# task a scope task names with each of its projects in $projects (task_projects; none known: no
# project), and no task with each project a scope or a task names, and with none.
def default_prs($extra; $projects):
  ([.[], $extra[] | select(.scope == "task") | .task] | unique) as $tasks
  | ([(.[], $extra[] | .scope | select(. != "task" and . != "all")), ($tasks[] | $projects[.] // [] | .[])] | unique + [""]) as $names
  | [($tasks[] | . as $t | ($projects[$t] // [] | if . == [] then [""] else . end) | .[] | {task: $t, project: .}),
     ($names[] | {task: "", project: .})];

# Whether a merge-default-restored of $restore ({task, scope}) would give the default word back
# anywhere, over the ledger's merge-default-withdrawn and merge-default-restored events (an array,
# every task's): whether some PR it covers (default_prs) has a withdrawal as the latest event
# covering it (default_cover). $projects is task_projects'.
def default_restore_withdrawn($restore; $projects):
  . as $events
  | any(default_prs([$restore]; $projects)[];
      . as $pr | ($restore | default_covers($pr.task; $pr.project))
      and ($events | default_cover($pr.task; $pr.project) | .event == "merge-default-withdrawn"));

# The withdrawals of the default word that stand, over the ledger's merge-default-withdrawn and
# merge-default-restored events (an array, every task's), in ledger order: each that is still the
# latest event covering some PR (default_prs, default_cover), so a giving back of all ends every
# withdrawal before it, a project's ends that project's and its tasks', and a task's that task's,
# and a withdrawal of all leaves no earlier one standing. $projects is task_projects'.
def default_withdrawals($projects):
  [to_entries[] | .value + {i: .key}] as $events
  | [default_prs([]; $projects)[] | . as $pr | $events | default_cover($pr.task; $pr.project)
     | select(.event == "merge-default-withdrawn")]
  | unique_by(.i) | map(del(.i));

# The ledger's merge-default-withdrawn and merge-default-restored events, over every ledger event
# as an array, in ledger order, each giving back with thread, the latest thread of the task it was
# logged under (a string, or null), where its message may be read back: merge_authority's
# $withdrawals.
def default_events:
  . as $all
  | [$all[] | select(.event == "merge-default-withdrawn" or .event == "merge-default-restored")
     | if .event == "merge-default-restored" then
         .task as $t | .thread = ([$all[] | select(.task == $t and .event == "thread") | .discord_thread | tostring] | last)
       else . end];

# The bar merge_authority holds $project to, its $own, given $own, own_projects' {projects, app}
# in team.sh: {app} when $project is the team's own (one of projects; agent-team by name always
# is), else false.
def own_in($own; $project):
  if $project == "agent-team" or ($project | IN($own.projects[])) then {app: $own.app} else false end;

# The project of the task's PR $url (a trailing slash aside), over the task's events: its latest
# pr event's project, else the task's opened one's, else null.
def pr_project($url):
  ($url | rtrimstr("/")) as $url
  | ([.[] | select(.event == "pr" and (.url | strings | rtrimstr("/")) == $url) | .project | strings] | last)
    // (map(select(.event == "opened")) | first | .project);

# Why the changed paths (the input, pr_file_reasons' PR_CHANGED: {path} and, for a rename's old
# path, {path, renamed}) are not within the approved plan's scope $scope, one string per path
# outside, none when $scope is null: an entry ending in / covers every path under it, any other
# that path only.
def scope_reasons($scope):
  def name: if .renamed then "\(.path), renamed to \(.renamed)," else .path end;
  select($scope != null) | .[] | .path as $p
  | select(any($scope[]; . as $entry | if endswith("/") then $p | startswith($entry) else $p == $entry end) | not)
  | "\(name) is outside the approved plan's scope: \($scope | join(", "))";

# The head whose review stands for $head: $head itself when a review of it is logged, or, when a
# caught-up event of the task names $head (by the shorter prefix) as the merge team-catch-up made,
# the head it was made from, followed back the same way, the latest such event first, until a head
# has a review of its own or no event names it. reviewed_head_by($head; match) matches two heads
# by match over [<a>, <b>] instead; exact_reviewed_head by exact_head, so no prefix leads back.
def reviewed_head_by($head; match):
  [.[] | select(.event == "caught-up")] as $ups
  | [.[] | select(.event == "review") | .head] as $reviewed
  | def back($h; $n):
      (first($ups | reverse[] | select([.head, $h] | match)) // null) as $up
      | if $up == null or $n <= 0 or any($reviewed[]; [., $h] | match) then $h
        else back($up.from; $n - 1) end;
    back($head; $ups | length);
def reviewed_head($head): reviewed_head_by($head; same_head(.[0]; .[1]));
def exact_reviewed_head($head): reviewed_head_by($head; exact_head(.[0]; .[1]));

# How a base branch's protection, as GitHub's branches API answers it (the branch's JSON as
# input), fails to hold the reviewer App $app's check, each one object, none when it holds:
# {kind: "pin"} when no required check agent-review is pinned to the App's id (a context in
# contexts alone is a commit status's, met by any token), and {kind: "admins", level} when its
# required checks are enforced for less than everyone, so an administrator could merge past them.
# team-merge's default word and team-doctor's review app line both read the pin through it.
def review_app_pin_problems($app):
  .protection.required_status_checks
  | (select(any((. // {}).checks[]?; .context == "agent-review" and .app_id == $app) | not) | {kind: "pin"}),
    (select(. != null and .enforcement_level != "everyone") | {kind: "admins", level: (.enforcement_level // "no one")});

# What waits on the checks of a pass, over the task's events, or null: null unless the task's
# latest review is a pass on one of its PRs not merged, the PR whose head the pass names (by the
# shorter prefix), else the latest PR whose first pr event came before the pass (a fix's head, which
# no pr event logs). Else {url, reviewed, head, since, state, reruns}: url the PR's; reviewed the
# passed head; head the latest caught-up made from it since the pass, followed on through each
# caught-up made from that one (reviewed_head's rule, forward), else reviewed; state the outcome of
# the latest ci of head on the PR logged after the pass and that catch-up (passed, failed,
# infrastructure or pending), waiting when none; since the ts of the latest of the pass, that
# catch-up, and each ci and ci-rerun of head on the PR logged after them (a rerun starts the wait
# again); reruns the names of the checks with a ci-rerun of head on the PR, whenever logged, each
# once, in the order first rerun. URLs compare with a trailing slash aside.
def checks_wait:
  . as $events
  | def url_of: .url // "" | tostring | rtrimstr("/");
    ([range(length) | select($events[.].event == "review")] | last) as $r
  | if $r == null or $events[$r].verdict != "pass" then null
    else $events[$r] as $pass
    | [$events[:$r][] | select(.event == "pr") | url_of] as $before
    | [lifecycle.prs[] | select(url_of as $u | any($before[]; . == $u))] as $prs
    | (first($prs[] | select(same_head(.head; $pass.head))) // ($prs | last)) as $pr
    | if $pr == null or $pr.merged then null
      else ($pr | url_of) as $url
      | (reduce range($r + 1; length) as $i ({head: $pass.head, at: $r};
          $events[$i] as $e
          | if $e.event == "caught-up" and ($e | url_of) == $url and same_head($e.from; .head) then {head: $e.head, at: $i}
            else . end)) as $up
      | [range($up.at + 1; length) | $events[.]
          | select((.event == "ci" or .event == "ci-rerun") and url_of == $url and same_head(.head; $up.head))] as $ends
      | ([$ends[] | select(.event == "ci")] | last) as $ci
      | {url: $pr.url, reviewed: $pass.head, head: $up.head, since: ($ends | last | .ts // $events[$up.at].ts),
         state: ($ci.outcome // "waiting"),
         reruns: (reduce ($events[] | select(.event == "ci-rerun" and url_of == $url and same_head(.head; $up.head)) | .check) as $c
           ([]; if any(.[]; . == $c) then . else . + [$c] end))}
      end
    end;

# Why the task's reviews do not let the default word, given on no head, merge the PR's
# head $head unasked, one string per reason, none when they do, judged on the latest review of
# reviewed_head($head), so a head team-catch-up made with no review of its own stands on the
# review of the one it was made from (both named): no review of that head (by the shorter prefix)
# is logged; the latest one is not a pass; it logged no guarded list, or named guarded areas in it
# (an area retired since, which a review logged before may name, is not one); and
# each review of the task, of any head, that left out its finding counts or counted a security or
# real-data finding, fixed or not, named by its head and time.
def unattended_review_reasons($head):
  reviewed_head($head) as $reviewed_head
  | "\($reviewed_head[:7])\(if same_head($reviewed_head; $head) then "" else " (caught up to \($head[:7]))" end)" as $named
  | ([.[] | select(.event == "review" and same_head(.head; $reviewed_head))] | last) as $reviewed
  | "the latest review of the head \($named), at \($reviewed.ts), " as $latest
  | (if $reviewed == null then "no review of the head \($named) is logged, so no reviewer has passed it"
     elif $reviewed.verdict != "pass" then "\($latest)is \($reviewed.verdict), not pass"
     else empty end),
    ($reviewed | select(. != null) | [(.guarded // [])[] | select(IN(guarded_areas[]))] as $areas
     | if has("guarded") | not then "\($latest)logged no guarded areas, so no reviewer has said the change touches none"
       elif $areas != [] then "\($latest)found the change touching guarded areas: \($areas | join(", "))"
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

# The words PR $url of $project at the head $head may merge on, from the task's events (as an
# array) alone, every reader's one derivation of them: {words, word}, words the per-head word and
# then the default word, in the order team-merge tries them, each {word: "head" or "default",
# applies, holds, reasons, facts}, and word the first that holds on the ledger, or null. $own is
# the bar $project is held to (own_bar in bin/lib/team.sh): false for a project not the team's
# own, else {app}, the reviewer App's id, or null while it is off; $withdrawals is the ledger's
# merge-default-withdrawn and merge-default-restored events, every task's, in ledger order, each
# giving back with thread, the latest thread of the task it was logged under, when team-merge adds
# it.
# The per-head word applies when a merge-approved names $url (the latest counts, a trailing slash
# aside); its one reason is that none does, or that no pr event of $url, nor a review since,
# logged the head it names; facts: approval (the event, with i its index), head (the head it
# names, or null for a legacy one) and logged ({ts, event} of the event its message is timed
# against: head_logged's, or a legacy one's latest pr event of $url, or null).
# The default word, the approved plan, applies while plan_approval is approved; its reasons: no
# approval, or one withdrawn; on the team's own project with the App off, the one reason that it
# merges unattended only behind the reviewer App's check, which is not set up; else, on the team's
# own project, that the approval is not Daniel's (the coordinator's, or a legacy one), and on
# every project that the default is withdrawn for the task, $project or every project (the latest
# of $withdrawals covering the PR, default_cover, is a withdrawal), that the task logged no branch
# for $project, and
# unattended_review_reasons($head). Its facts, null unless it applies: the approval's by, ts,
# legacy, plan and scope, branch (task_branch), restored (that latest event when it is a giving
# back, whose message team-merge reads back, else null), withdrawn (that latest event when it is a
# withdrawal, else null), and for Daniel's approval its ask,
# discord_message and asked (the latest asked of that id before the approval, or null).
# A word holds on the ledger when it applies with no reason; team-merge checks what the ledger
# cannot show (Discord, git, the plan's files and GitHub's) before it merges on one.
def merge_authority($url; $head; $project; $own; $withdrawals):
  . as $events
  | (first(.[] | .task | strings) // "the task") as $task
  | ([to_entries[] | .value + {i: .key}
      | select(.event == "merge-approved" and (.url | strings | rtrimstr("/")) == $url)] | last) as $approval
  | ($approval.head // null) as $approved
  | (if $approval == null then null
     elif $approved == null then [.[] | select(.event == "pr" and (.url | strings | rtrimstr("/")) == $url)] | last
     else head_logged($url; $approved) end) as $logged
  | {word: "head", applies: ($approval != null),
     reasons: (if $approval == null then ["no merge-approved event for \($url): Daniel's word is not recorded"]
               elif $logged == null then ["merge-approved names the head \(($approved // "")[:7]), which no pr event of \($url), nor a review since, logged: ask again on the PR's head"]
               else [] end),
     facts: {approval: $approval, head: $approved, logged: (if $logged == null then null else $logged | {ts, event} end)}} as $per_head
  | plan_approval as $plan
  | ([to_entries[] | select(.value.event == "plan-approved")] | last | .key) as $at
  | ($withdrawals | default_cover(first($events[] | .task | strings) // ""; $project)) as $cover
  | {word: "default", applies: ($plan.state == "approved"),
     reasons: (if $plan == null then ["\($task) has no approved plan: no plan-approved is logged"]
               elif $plan.state == "withdrawn" then
                 ["\($task)'s plan approval was withdrawn at \($plan.ts) in Discord message \($plan.discord_message): approve the plan again"]
               elif $own and $own.app == null then
                 ["the team's own project merges unattended only behind the reviewer App's check, which is not set up"]
               else [(select($own) | "the team's own project merges unattended only on a plan Daniel approved, and "
                       + if $plan.legacy then "\($task)'s approval at \($plan.ts) is a legacy one, logged with no plan: ask Daniel to approve it"
                         elif $plan.by != "Daniel" then "the coordinator approved \($task)'s at \($plan.ts): ask Daniel to approve it"
                         else empty end),
                     ($cover | select(.event == "merge-default-withdrawn")
                       | "the default word was withdrawn for \(default_scope_text) at \(.ts) in Discord message \(.discord_message), and not given back since"),
                     (task_branch($project) | select(. == null)
                       | "\($task) logged no branch for \($project): no opened, worktree-added or branch-renamed event of it"),
                     unattended_review_reasons($head)] end),
     facts: (if $plan.state != "approved" then null
             else {by: $plan.by, ts: $plan.ts, legacy: $plan.legacy, plan: $plan.plan, scope: $plan.scope,
                   branch: task_branch($project),
                   restored: (if $cover.event == "merge-default-restored" then $cover else null end),
                   withdrawn: (if $cover.event == "merge-default-withdrawn" then $cover else null end)}
               + if $plan.by == "Daniel" then
                   {ask: $plan.ask, discord_message: $plan.discord_message, asked: ($events[:$at] | latest_asked($plan.ask))}
                 else {} end end)} as $default
  | [$per_head, $default] | map(.holds = (.applies and .reasons == []))
  | {words: ., word: (first(.[] | select(.holds) | .word) // null)};

# Whether the task's events hold an answered of ask $id read from Discord message $message.
def answered_from($id; $message):
  any(.[]; .event == "answered" and .id == $id and (.discord_message | tostring) == $message);

# A list of strings as text, its last two joined by "and" and the rest by commas: "1, 2 and 4".
def and_text: if length < 2 then join("") else (.[:-1] | join(", ")) + " and " + .[-1] end;

# The numbered parts of a reply's text, as Daniel answers several items of the waiting list in one
# message ("3 yes, 5 no"), an array of {n, text} in the order they come. Each line (a trailing \r
# dropped) loses a leading bullet (- or * and spaces), and is split before each separator (a
# comma, semicolon or &, or the word and, with any spaces) that a number follows: an optional #,
# 1 to 3 digits, then a space, one of . ) : - , ; & or the line's end. A piece is a part when it is
# an optional #, a number from 1 to 999, optional spaces, an optional marker (. ) : or -), then
# spaces and its text, or the piece's end; a piece that is not one stays with the piece before it.
# A part with no text takes the text of the next part on its line that has some, so "3 and 5 yes"
# answers both, and keeps an empty text when none has. "1-2 yes" and "2026 was busy" name nothing.
def numbered_parts:
  def trimmed: sub("^\\s+"; "") | sub("\\s+$"; "");
  def part: trimmed | capture("^#?(?<n>[0-9]{1,3})\\s*[.):-]?(?:\\s+(?<text>.*)|$)")
    | {n: (.n | tonumber), text: (.text // "" | trimmed)} | select(.n >= 1 and .n <= 999);
  "\\s*(?:[,;&]|\\band\\b)\\s*(?=#?[0-9]{1,3}(?:[ .):,;&-]|$))" as $separator
  | [split("\n")[] | rtrimstr("\r") | sub("^\\s*[-*]\\s+"; "") | . as $line
    | [$line | splits($separator; "gi")] as $pieces
    | [$line | match($separator; "gi") | .string] as $separators
    | reduce range(1; $pieces | length) as $i ([$pieces[0]];
        if [$pieces[$i] | part] != [] then . + [$pieces[$i]] else .[-1] += $separators[$i - 1] + $pieces[$i] end)
    | [.[] | part] as $parts
    | range($parts | length) as $i
    | $parts[$i] | if .text == "" then .text = (first($parts[$i + 1:][] | .text | select(. != "")) // "") else . end];

# A task's state from its events and the session list, its worktrees as paths on this machine,
# whose home directory is $home (local_worktree); team-state adds the pr part.
def task_state($sessions; $home):
  map(local_worktree($home))
  | (map(select(.event == "opened")) | first) as $opened
  | workers($sessions) as $workers
  | lifecycle as $state
  | {schema: "team-state/1", task: .[0].task, title: $opened.title, project: $opened.project,
     path: $opened.path, phase: ($state | lifecycle_phase), worktrees: worktree_list,
     thread: (map(select(.event == "thread") | .discord_thread) | last),
     workers: $workers, last_event: last, pending_asks: ($state | lifecycle_pending_asks),
     waiting: ($state | lifecycle_waiting), parks: ($state | lifecycle_parks), stowing: ($state | lifecycle_stowing), walk: qc_walk,
     rehome_failures: rehome_failures, checks_wait: checks_wait, pr: null,
     progress: progress($workers)};

# A task's state (team-state's JSON) as one line of text, each live worker's context in thousands
# and the brief it is on, then the tickets done, with the graph fresh or stale when there is one,
# the latest review, the PR, the state of the checks wait of its latest pass while one stands
# ("checks <state>", checks_wait's), the words on the PR, the walk, a stow under way, and last the
# standing parks:
# T14 agent-team feature building | T14-builder idle 302k on build-04 | tickets 3/7, graph stale | review 4 findings, sent back 5, 6 | PR #5 a1b2c3d 16 behind dev checks 2/2 agent-review missing
def state_line:
  .task as $task
  | ([.task, .project, .path, .phase] | map(select(. != null)) | join(" "))
  + " | "
  + ([.workers[] | select(.live)
      | "\(.name // "\($task)-\(.role)") \(.status)" + (if .state == null or .state == "working" then "" else " \(.state)" end)
        + (if (.context | type) == "number" then " \(.context / 1000 | round)k" else "" end)
        + if (.brief | type) == "string" then " on \(.brief | ltrimstr("brief-"))" else "" end]
     | if . == [] then "no live worker" else join(", ") end)
  + (.progress.tickets // {} | (.done // [] | length) as $done
     | if (.total | type) == "number" and .total > 0 then " | tickets \($done)/\(.total)"
       elif $done > 0 then " | tickets \($done) done"
       else "" end
     + if .graph == null then "" elif .graph.fresh then ", graph fresh" else ", graph stale" end)
  + (.progress.reviews // {} | if (.count // 0) == 0 then ""
     else " | review \(.count) \(.verdict)"
       + (if (.sent_back | type) == "array" and .sent_back != [] then ", sent back \(.sent_back | map(tostring) | join(", "))" else "" end)
     end)
  + (if .pr == null then "" else
     .pr | if .number == null then " | PR \(.url) unreadable"
       else " | PR #\(.number)" end
       + if .number == null then ""
         elif .error then " GitHub unavailable"
         else
           (if .state == "open" then "" else " \(.state)" end)
           + " \(.head[:7])"
           + (if .caught_up then " (caught up cleanly with \(.base))" elif .head_moved then " (head moved)" else "" end)
           + (if (.behind_by | type) == "number" and .behind_by > 0 then " \(.behind_by) behind \(.base)" else "" end)
           + " checks \(.checks.passed | length)/\(.checks | map(length) | add)"
           + if .review_check == null then " agent-review \(.agent_review)"
             elif .review_check == "foreign" then " agent-review foreign (\(.review_check_by), not the reviewer App's check)"
             else " agent-review \(.review_check) (the reviewer App's check)" end
         end
     end)
  + (if .checks_wait == null then "" else " | checks \(.checks_wait.state)" end)
  + (if (.rehome_failures // []) == [] then ""
     else " | not re-homed: " + (.rehome_failures
       | map("\(.project)\(if .ticket then "--\(.ticket)" else "" end) on \(.machine): \(.reason)") | join("; ")) end)
  + (if .phase != "awaiting-merge" then ""
     else first((.pr.merge_authority // {} | .words // [])[] | select(.word == "default" and .applies)
       | if .holds then " | default word covers it"
         elif .facts.withdrawn != null then " | default word withdrawn"
         else " | default word does not cover it: \(.reasons[0])"
           + (.reasons | length | if . > 1 then " (and \(. - 1) more)" else "" end) end) // "" end)
  + (if .walk == null then "" else " | walk on since \(.walk.since)\(if .walk.thread then " in its \(.walk.thread) thread" else "" end)" end)
  + (if .stowing == null then "" else " | stowing since \(.stowing.since)" end)
  + (.parks // [] | if . == [] then ""
     else " | parks: " + (map("\(.id) \(.cause) since \(.since): \(.reason)" + if .passed then " (passed by a launch)" else "" end) | join("; ")) end);

# The task's running ticket launches, over its events: the latest launch of each ticket (a builder
# in its ticket worktree) that no later event ends (ends_launch: a done of its session or its
# ticket's ticket-done), live or not, each with i its index among the events, in launch order.
def running_ticket_launches:
  . as $events
  | [to_entries[] | select(.value.event == "launch" and (.value.ticket | type) == "string") | .value + {i: .key}]
  | group_by(.ticket) | map(last)
  | map(. as $l | select(any($events[$l.i + 1:][]; ends_launch($l)) | not))
  | sort_by(.i);

# Whether a task is parked, waiting on something other than a worker, by the fold: awaiting merge,
# a park standing (held, blocked, waiting or paused), or an ask nothing settled (settles); an ask a
# launch passed (past_ask), and its wait, park nothing, so the sweep watches that launch's worker.
# A ticket's park (park_ticket's) parks the task only while every running ticket launch's ticket
# has one standing, or a stowed after that launch (a builder the stow stopped without its answer),
# so the sweep still watches the tickets that build beside it.
def parked:
  . as $events
  | lifecycle as $state
  | ([$state.parks[] | select(.passed | not) | .ticket | strings] | unique) as $tickets
  | ($state | lifecycle_phase) == "awaiting-merge"
    or any($state.parks[]; (.passed | not) and .ticket == null)
    or any($state.asks[]; .passed | not)
    or ($tickets != [] and all($events | running_ticket_launches[];
          IN(.ticket; $tickets[]) or (.i as $i | any($events[$i + 1:][]; .event == "stowed"))));

# One of team-sweep's findings: {task, kind, session, name, next, text}, text being its one line.
def finding($task; $kind; $session; $name; $detail; $next):
  {task: $task, kind: $kind, session: $session, name: $name, next: $next,
   text: "\($task) \($kind): \($detail); next: \($next)"};

# team-sweep's walk-stale finding, over a task's events, or nothing: a walk on that no longer counts.
def walk_stale_finding:
  .[0].task as $task | walk_last_note as $last | qc_walk as $walk
  | select($last != null and (walk_holds(now) | not))
  | finding($task; "walk-stale"; null; null;
      "its walk has had no message from Daniel since \($last), over \(walk_hold_seconds / 3600) hours, so it no longer keeps its stack up or stows last";
      "ask Daniel whether it goes on: if not, team-ui \($task) --walk stop; if so, team-ui \($task) --walk stop, then team-ui \($task) --walk start\(if $walk.thread then " --in \($walk.thread)" else "" end)\(if $walk.reseeded then " --reseeded <a new message of Daniel's>" else "" end)");

# Whether a task's merge-base round is in flight, over its events and the session list: its latest
# builder launch or resumed that names a merge-base brief has no later review, caught-up or merged,
# and a worker on it is live with no done since: the builder then, or a launch since, such as the
# rereview's. A round whose workers are gone is over, so the task is not left unwatched.
def merge_base_round($sessions):
  . as $events
  | ([range(length) | select($events[.]
      | (.event == "resumed" or (.event == "launch" and .role == "builder")) and ((.brief // "") | contains("merge-base")))]
     | last) as $i
  | if $i == null then false
    else $events[$i + 1:] as $rest
    | if any($rest[]; .event | IN("review", "caught-up", "merged")) then false
      else any(([$events[:$i + 1][] | select(.event == "launch" and .role == "builder")] | last | select(. != null)),
            ($rest[] | select(.event == "launch"));
          . as $l | (any($rest[]; .event == "done" and .session == $l.session) | not)
            and live_session($l.session; $sessions) != null)
      end
    end;

# Whether the default word, the approved plan, holds on the ledger for the task's PR $pr (one of
# task_prs) at the latest head the task logged for it (pr_heads, since no pr event logs a fix), as
# merge_authority says it over the task's events (the input), $withdrawals (default_events') and
# $own (own_projects' {projects, app}, read through own_in), the PR's project its latest pr
# event's, else the task's opened one's.
def default_holds($pr; $withdrawals; $own):
  pr_project($pr.url) as $project
  | $project != null
    and (merge_authority($pr.url | rtrimstr("/"); pr_heads($pr.url) | last | .head // $pr.head; $project;
          own_in($own; $project); $withdrawals)
         | any(.words[]; .word == "default" and .holds));

# team-sweep's merge-due finding, over a task's events and the session list, or nothing: the task
# awaits merge, nothing else parks it (no ask nothing settled, pause or wait), the checks of its
# latest pass have passed (checks_wait's state is passed: team-next T<n> --ci logged a ci passed of
# the head it waits on), no merge-base round is in flight, and a PR not merged has the default
# word holding on the ledger (default_holds, merge_authority's word: the plan approved, the team's
# own project's by Daniel with the reviewer App on and never with it off, not withdrawn for the
# task, its project or all, the task's branch logged, and no review-side reason, as team-state and
# team-merge read them: the sweep reads no GitHub, so a guarded path a reviewer did not name, a
# plan changed since its approval, Daniel's message not reading back or the App's check is
# team-merge's to find, and of two open PRs the later review stands for both); only such PRs are
# named. $withdrawals is default_events' and $own own_projects' {projects, app} (own_in), or null
# when the registry cannot be read, which raises none.
def merge_due_finding($withdrawals; $sessions; $own):
  .[0].task as $task
  | . as $events
  | lifecycle as $state
  | if $own != null and ($state | lifecycle_phase) == "awaiting-merge" and $state.asks == [] and $state.parks == []
      and ($events | checks_wait | .state) == "passed" then
      select($events | merge_base_round($sessions) | not)
      | task_prs as $prs
      | [$prs[] | select(pr_merged($events; $prs) | not) | . as $pr
         | select($events | default_holds($pr; $withdrawals; $own)) | .url] as $due
      | select($due != [])
      | finding($task; "merge-due"; null; null;
          "awaiting the merge of \($due | join(", ")) on the default word, the approved plan, with no ask open";
          "run team-merge \($task); on a refusal, ask Daniel for the per-head word with team-ask")
    else empty end;

# team-sweep's stowing finding, over a task's events, or nothing: its stowing (a stow under way)
# has stood 30 minutes with no stowed or stow-failed, whatever parks the task, since the worker
# that answered its STOW parked it.
def stowing_finding:
  .[0].task as $task
  | lifecycle.stow
  | select(. != null and .state == "stowing" and now - (.since | fromdate) >= 1800)
  | finding($task; "stowing"; null; null; "stowing since \(.since) (\(.cause)), with no stowed";
      "run team-stow \($task), which finishes the stow or logs stow-failed");

# A duration in seconds as <h>h<mm>m, or <m>m under an hour.
def duration:
  (. / 60 | floor) as $m
  | if $m < 60 then "\($m)m" else "\($m / 60 | floor)h\($m % 60 | tostring | if length < 2 then "0" + . else . end)m" end;

# How long, in seconds, a pass's checks may go with no wait of them ending before team-sweep calls
# it ci-due: 100 minutes, team-ci-wait's 90-minute deadline, then its 2-minute settle, then room.
def ci_due_seconds: 6000;

# team-sweep's ci-due finding, over a task's events, or nothing: the task awaits merge with no ask
# nothing settled and no standing park, and its checks_wait is waiting or pending since
# ci_due_seconds or more, so no team-next T<n> --ci has ended on the checks of the head its pass
# waits on, or rerun one of them (whose wait then starts again), for that long; with session null. It reads no GitHub and no process: a wait still
# running is the coordinator's to see in its background commands.
def ci_due_finding:
  .[0].task as $task
  | lifecycle as $state
  | select(($state | lifecycle_phase) == "awaiting-merge" and $state.asks == [] and $state.parks == [])
  | checks_wait
  | select(. != null and (.state | IN("waiting", "pending")))
  | (now - (.since | fromdate)) as $age
  | select($age >= ci_due_seconds)
  | finding($task; "ci-due"; null; null; "the checks of \(.url) at \(.head[:8]) have had no wait end for \($age | duration)";
      "arm team-next \($task) --ci with Bash run_in_background unless it is running");

# The stall limits, in seconds: how long a busy session's transcripts may go unwritten before
# team-sweep calls it stalled. default, 50 minutes, so with the sweep watch's three-minute stand
# the coordinator is woken within the hour (a full Playwright run or tests/run, up to about 33
# minutes seen, passes); gate, 180 minutes, while a running call runs the gate, whose runs went
# up to about 115; ci_wait, 110 minutes, while a running call runs team-ci-wait, whose deadline of
# 180 looks ends it by about 100, each look's reads taking a few seconds on top of its 30; interview, none (null), while a running call waits on Daniel with
# team-thread wait. session-activity names each call's limit from its whole command. team-sweep
# reads the session-activity floor from default too, since no session quieter than it is stalled.
def stall_limits: {default: 3000, gate: 10800, ci_wait: 6600, interview: null};

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

# The no-worker, waiting-input, silent, stalled, ticket-gone and ticket-worktree-left findings of
# an open task that is not parked, the stalled one from session-activity's object as team-sweep
# passes it ($activity: {sessions}, its object keyed by full session id, or {error} when it
# failed, where none is stalled). A live session is judged by its latest launch, and one waiting
# for input is not also called silent; stalled is a busy session, not waiting for input, whose
# transcripts have gone unwritten past its limit (stall_limits).
# A live session is at work while it is busy, waiting for input, or idle with no ledger event
# since its launch (silent); idle with an event since, it has handed the next step back to the
# coordinator, so a task with no session at work is no-worker however many are live. A ticket
# launch (a builder in a ticket worktree, T<n>-builder-NN) is judged by its own events: live, it
# is at work until an event ends it (ends_launch: a done of its session or its ticket's
# ticket-done), and silent while idle with no event since its launch naming its session or its
# ticket. ticket-gone is a running ticket launch (running_ticket_launches) whose session is not
# live, with no stowed after it and no park of its ticket standing (park_ticket's: one naming its
# session, or a room refusal of its brief), in place of no-worker; ticket-worktree-left an open
# ticket worktree whose ticket has a ticket-done since the worktree's latest worktree-added,
# worktree-moved or rehomed of that ticket, with no stowed after that ticket-done and no park of
# its ticket standing. A denied is no report (the worker went past the denial), nor is a walk-note
# (Daniel spoke, the worker did not), so these findings read the events without them.
def task_findings($sessions; $activity):
  .[0].task as $task
  | map(select(.event | IN("denied", "walk-note") | not))
  | . as $events
  | length as $count
  | ([lifecycle.parks[] | select(.passed | not) | .ticket | strings] | unique) as $parked_tickets
  | (def stowed_after($i): any($events[$i + 1:][]; .event == "stowed");
     def launch_name: "\($task)-\(.role)" + if (.ticket | type) == "string" then "-\(.ticket)" else "" end;
     [to_entries[] | select(.value.event == "launch") | {i: .key, launch: .value}] as $launches
  | ([$launches | reverse | .[] | . + {live: live_session(.launch.session; $sessions)} | select(.live != null)
      | . + {short: (.live.id // .launch.session), name: (.live.name // (.launch | launch_name))}
      | .launch as $l | $events[.i + 1:] as $since
      | . + if ($l.ticket | type) == "string" then
          {ended: any($since[]; ends_launch($l)), quiet: (any($since[]; .session == $l.session or .ticket == $l.ticket) | not)}
        else {ended: false, quiet: (.i == $count - 1)} end]
     | unique_by(.short) | sort_by(.i)) as $live
  | ($live | map(select(.live.state == "blocked" or .live.status != "idle" or .quiet
      or ((.launch.ticket | type) == "string" and (.ended | not))))) as $at_work
  | [$events | running_ticket_launches[]
     | select(live_session(.session; $sessions) == null and (stowed_after(.i) | not) and (IN(.ticket; $parked_tickets[]) | not))
     | launch_name as $name
     | finding($task; "ticket-gone"; .session; $name;
         "ticket \(.ticket): its builder \($name) \(.session) is gone with the ticket not done";
         "recover it (the recover-worker skill)")] as $gone
  | ($launches | last) as $latest
  | if $at_work == [] and $gone == [] and any(.[]; .event == "opened" or .event == "launch") then
      if $latest == null then
        finding($task; "no-worker"; null; null; "opened with no worker launched";
          "launch one with team-worker, or log what is known with team-log")
      else
        ($latest.launch | launch_name) as $name | $latest.launch.session as $session
        | (if $live == [] then "with no live worker" else "with every live worker idle" end) as $how
        | phase as $phase
        | if $phase == "merged" then
            finding($task; "no-worker"; $session; $name;
              "merged and not closed, \($how) (latest \($name) \($session))"; "close it with team-close \($task)")
          elif $phase == "merged-part" then
            (map(select(.event == "merged" and .phases_left != null)) | last | .phases_left | map(tostring) | join(", ")) as $left
            | finding($task; "no-worker"; $session; $name;
                "a part merged, with phase \($left) still to build, \($how) (latest \($name) \($session))";
                "launch the next phase's first ticket's builder (team-tickets \($task) names it)")
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
        elif .live.status == "idle" and .quiet and (IN(.launch.ticket; $parked_tickets[]) | not) then
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
        else empty end),
    $gone[],
    (open_worktrees($events[]; $home) | select(.ticket != null) | .ticket as $n | .worktree as $path
      | ([$events | to_entries[] | select((.value.event | IN("worktree-added", "worktree-moved", "rehomed")) and .value.ticket == $n) | .key]
         | last) as $from
      | ([$events | to_entries[] | select(.key > $from and .value.event == "ticket-done" and .value.ticket == $n) | .key] | first) as $done
      | select($done != null and (stowed_after($done) | not) and (IN($n; $parked_tickets[]) | not))
      | finding($task; "ticket-worktree-left"; null; null;
          "ticket \($n) is done, but its worktree \($path) is still open";
          "team-close \($task) --ticket \($n)")));

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

# The live sessions named like team workers (T<n>-<role>, or T<n>-<role>-NN for ticket NN's, a
# builder in a ticket worktree), from the session list and every task's events by id: {task, role,
# name, session (the short id), status, state, logged (a launch of the task names it), task_state
# (open, closed, unknown when not in the ledger, or load-check for T0, team-load-check's task,
# which is never in the ledger)}, with ticket after role for a ticket's session.
def team_sessions($tasks; $sessions):
  [$sessions[] | . as $session
    | ((.name // "") | capture("^(?<task>T(0|[1-9][0-9]*))-(?<role>.+?)(-(?<ticket>[0-9]{2}))?$")) as $name
    | ($tasks[$name.task] // null) as $events
    | {task: $name.task, role: $name.role} + (if $name.ticket == null then {} else {ticket: $name.ticket} end)
      + {name, session: (.id // ((.sessionId // "")[:8])), status, state,
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

# Whether the retro task of one of retros' opened events ran, over every ledger event $events: it
# has a launch, or no closed yet (one still open may be running). A retro closed with no launch was
# opened by mistake, so it is no window's previous retro and no due time's last retro.
def retro_ran($events):
  .task as $task
  | [$events[] | select(.task == $task) | .event] | IN(.[]; "launch") or (IN(.[]; "closed") | not);

# The retros (retros') that ran (retro_ran), in ledger order.
def retros_ran: . as $events | [retros[] | select(retro_ran($events))];

# team-retro status's JSON. The schedule is the latest retro-schedule, on while every_hours is
# above 0; the next retro is due every_hours after the later of its time and the opening of the
# latest retro task that ran (retro_ran), unless a retro task is still open.
def retro_status:
  . as $events
  | retros as $retros
  | ($events | map(select(.event == "retro-schedule")) | last
     | if . != null and (.every_hours | type) == "number" and .every_hours > 0 then {every_hours, since: .ts, discord_message, task}
       else null end) as $schedule
  | (retros_ran | last) as $last
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

# team-sweep's level findings, from team-capacity plan --json's object (or {error} when it failed),
# each with task and session null: level-stow while its stow list is not empty, naming the tasks
# newest first ("level: over budget at minor (30%): stow T174, then T171"); level-resume for the
# first task stowed, waiting to resume, whose roles fit again and that nothing holds (its hold
# null) ("level: T171 fits again: relaunch its builder"); level-launch for the first task whose
# launches refused for room fit again and that nothing holds ("level: T5 has room again: launch
# its reviewer, refused for room at <time>"); one level finding naming the error when
# team-capacity failed.
def level_findings:
  def roles: if length < 2 then join("") else "\(.[:-1] | join(", ")) and \(.[-1])" end;
  if .error then
    {task: null, kind: "level", session: null, name: null, next: "fix what team-capacity names",
     text: "level: \(.error): fix what team-capacity names"}
  else
    (select(.stow != []) | "stow \([.stow[].task] | join(", then "))" as $next
     | {task: null, kind: "level-stow", session: null, name: null, next: $next,
        text: "level: over budget at \(.level) (\(.share * 100 | round)%): \($next)"}),
    (first(.resume[] | select(.fits and .hold == null)) | "relaunch its \(.roles | roles)" as $next
     | {task: null, kind: "level-resume", session: null, name: null, next: $next,
        text: "level: \(.task) fits again: \($next)"}),
    (first(.launch // [] | .[] | select(.fits and .hold == null)) | "launch its \(.roles | roles)" as $next
     | {task: null, kind: "level-launch", session: null, name: null, next: $next,
        text: "level: \(.task) has room again: \($next), refused for room at \(.refused)"})
  end;

# team-sweep's health findings, from team-timers health --json's view (or {error} when it could
# not be read), each with task and session null: checkpoint-stale for the alerting problems whose
# sweep kind it is (checkpoint, heartbeat), health for those whose kind is health (login-refused,
# ledger, a step failing 12 runs in a row), each kind's joined in one finding, and one health
# finding naming the error when the view could not be read. A view off the lease, or {} (a
# machine with no team name), has no problems, so none.
def health_findings:
  if .error then
    {task: null, kind: "health", session: null, name: null, next: "fix what team-timers names",
     text: "health: \(.error): fix what team-timers names"}
  else
    [.problems // [] | .[] | select(.alerting == true)] as $alerting
    | ([$alerting[] | select(.sweep == "checkpoint-stale") | .text]
       | select(. != [])
       | "fix what it names (heartbeat-failures.log has every line), then run team-checkpoint --force" as $next
       | {task: null, kind: "checkpoint-stale", session: null, name: null, next: $next,
          text: "checkpoint: \(join("; ")); next: \($next)"}),
      ([$alerting[] | select(.sweep == "health") | .text]
       | select(. != [])
       | "fix what each names; team-timers health lists them" as $next
       | {task: null, kind: "health", session: null, name: null, next: $next,
          text: "health: \(join("; ")); next: \($next)"})
  end;

# team-sweep's activity finding, from session-activity's object as task_findings takes it: one
# naming the error when it failed, since then no busy worker can be found stalled, else none.
def activity_finding:
  select(.error)
  | {task: null, kind: "activity", session: null, name: null, next: "fix what session-activity names",
     text: "activity: \(.error), so no busy worker is found stalled: fix what session-activity names"};

# team-sweep's coordinator-twin findings, from the session list (this machine's, as claude agents
# --json lists it) and the full session id of the session the sweep runs in ($self, "" when it is
# not known): when more than one session is named coordinator, one finding for each of them but
# $self's, session being its short id (an interactive one's, the first 8 characters of its session
# id), and when $self names none of them, "one of <n> sessions" in place of "a second session" and
# "if it is not you" before the next step; a session whose startedAt is not a number "started at
# an unknown time". A background twin is stopped with claude stop; an interactive one is Daniel's
# to end. A Remote Control row is not in the list: the coordinator's own ListAgents finds that one
# (bin/hooks/session-digest).
def coordinator_twin_findings($self):
  [.[] | select(.name == "coordinator")] as $coordinators
  | select(($coordinators | length) > 1)
  | any($coordinators[]; $self != "" and .sessionId == $self) as $known
  | $coordinators[] | select(($known | not) or .sessionId != $self)
  | (.id // ((.sessionId // "")[:8])) as $short
  | (if .kind == "interactive" then "ask Daniel to end it, an interactive session, pid \(.pid)"
     else "read claude logs \($short) for anything left to log, then stop it with claude stop \($short)" end
     | if $known then . else "if it is not you, " + . end) as $next
  | {task: null, kind: "coordinator-twin", session: $short, name: "coordinator", next: $next,
     text: "coordinator-twin: coordinator \($short) (\(.kind), \(.state // .status // "no state"), \(
       if (.startedAt | type) == "number" then "started \(.startedAt / 1000 | floor | todate)"
       else "started at an unknown time" end)) is \(
       if $known then "a second session" else "one of \($coordinators | length) sessions" end
       ) named coordinator on this machine; next: \($next)"};

# team-sweep's findings, over every ledger event as one array, the session list, the stow plan
# ($plan, as level_findings takes it) and session-activity's object ($activity, as task_findings
# takes it): each open task's stowing finding, then its merge-due (on the default word, judged with
# every task's withdrawals), else its findings unless it is parked, then its walk-stale, parked or
# not, since a parked task's walk still needs asking about, then its ci-due, then the stray sessions (named
# like a team worker whose task is closed or not in the ledger, never the load check's T0, whose
# session the coordinator waits on for up to 30 minutes), in task number order; then the
# coordinator-twin, activity, level, retro-due and health findings. $own is the registered projects
# that are the team's own, or null, as merge_due_finding takes it, $health the health view, as
# health_findings takes it, and $self the sweep's own session id, as coordinator_twin_findings takes
# it.
def sweep($sessions; $plan; $activity; $own; $health; $self):
  . as $events
  | by_task as $tasks
  | default_events as $withdrawals
  | ([($tasks[] | select(is_open) | stowing_finding,
        ([merge_due_finding($withdrawals; $sessions; $own)] as $due
         | if $due != [] then $due[] elif parked then empty
           else task_findings($sessions; $activity) end),
        walk_stale_finding,
        ci_due_finding),
      (team_sessions($tasks; $sessions)[] | select(.task_state | IN("closed", "unknown"))
        | finding(.task; "stray"; .session; .name;
            "\(.name) \(.session) is live but \(stray_reason)";
            "read claude logs \(.session) for anything left to log, then stop it with claude stop \(.session)"))]
     | by_task_number)
    + [$sessions | coordinator_twin_findings($self)]
    + [$activity | activity_finding]
    + [$plan | level_findings]
    + [$events | retro_status | retro_due_finding]
    + [$health | health_findings];

# What team-capacity plan reads of the ledger, over every ledger event as one array, with the
# session list <sessions>: one {task, opened (its opened's time, else its first event's),
# finished ([{session, role}]: the idle live sessions whose work is handed on, handed_on_launches
# with no new launch), stowing ({since, cause} of its stowing while that stands, a stow under way,
# else null), stowed (while it is stowed_awaiting_resume, {at, roles} of its latest stowed or
# stow-failed and hold, stow_hold's, else null), stowed_since (that stowed's or stow-failed's time
# when no launch follows it, else null), refused (refused_launches'), walk (whether its walk counts
# now, walk_holds)} per open task, in task number order.
def plan_tasks($sessions):
  [by_task | to_entries[] | select(.value | is_open) | .key as $task | .value as $events
   | ($events | lifecycle) as $state
   | {task: $task,
      opened: (first($events[] | select(.event == "opened") | .ts) // $events[0].ts),
      finished: [$events | handed_on_launches(""; $home) | launch_states($sessions)[]
        | select(.state == "handed-on") | {session, role}],
      stowed: (if $state | lifecycle_stowed_awaiting_resume
               then $state.stow | {at: .since, roles, hold: ($state | lifecycle_stow_hold)}
               else null end),
      stowing: ($state | lifecycle_stowing),
      stowed_since: ($state.stow | if . != null and IN(.state; "stowed", "failed") then .since else null end),
      refused: ($state | lifecycle_refused_launches),
      walk: ($events | walk_holds(now))}]
  | by_task_number;

# The ids of the open tasks stowed, waiting to resume (stowed_awaiting_resume), among every task's
# events by id, in task number order.
def awaiting_resume: [to_entries[] | select((.value | is_open) and (.value | stowed_awaiting_resume)) | .key] | sort_by(.[1:] | tonumber);

# The resources line team-inbox --post and the snapshot end their items with, from
# team-level status --json's object $level (its says) and the tasks stowed, waiting to resume
# ($stowed, awaiting_resume's): "Resources: manual, minor (30%): 9.2 GiB and 3.6 cores for the
# team; 6.1 GiB reserved; T171 and T174 stowed, waiting to resume"; null when $level is {error}.
def resources_line($level; $stowed):
  if $level.error != null or $level.says == null then null
  else "Resources: \($level.says)"
    + if $stowed == [] then ""
      else "; \(if ($stowed | length) < 2 then $stowed[0] else "\($stowed[:-1] | join(", ")) and \($stowed[-1])" end) stowed, waiting to resume"
      end
  end;

# The ids of the open tasks among every task's events by id, in task number order.
def open_tasks: [to_entries[] | select(.value | is_open) | .key] | sort_by(.[1:] | tonumber);

# team-snapshot's JSON from every task's events by id ($tasks), the open tasks' team-state JSON in
# task number order ($states; {task, error} for a task whose state could not be told), the team's
# resource level ($level, team-level status --json's object or {error}), the withdrawals of the
# default merge word that stand ($withdrawn, default_withdrawals' list), the session list, each
# registered project's open PRs ($prs), the current items ($items) and the production checks' last
# results ($production, team-uptime status --json's object or {error}). It carries $level as level,
# the open tasks stowed, waiting to resume, as awaiting_resume, the resources_line as resources
# (null when $level is {error}), and $production as production.
def snapshot($tasks; $states; $level; $withdrawn; $sessions; $prs; $items; $production; $waiting; $queued):
  team_sessions($tasks; $sessions) as $team
  | ($tasks | awaiting_resume) as $stowed
  | {schema: "team-snapshot/1",
     tasks: $states,
     level: $level,
     awaiting_resume: $stowed,
     resources: resources_line($level; $stowed),
     default_withdrawn: $withdrawn,
     production: $production,
     sessions: [$team[] | select(.task_state == "open") | del(.task_state)],
     strays: [$team[] | select(.task_state != "open") | del(.logged)],
     prs: $prs,
     pending_asks: [$states[] | .task as $task | (.pending_asks // [])[] | {task: $task} + .],
     waiting: $waiting,
     items: $items,
     queued: $queued};

# The current items of tasks/current.md, over its lines (-R): each line starting "- ", without it.
def current_items: [inputs | rtrimstr("\r") | select(startswith("- ")) | .[2:]];

# Cut a line to $n characters, showing the cut.
def clip($n): if length > $n then .[:$n - 3] + "..." else . end;

# A live session as text: its name, short id, status, and state unless working.
def session_text:
  "\(.name) \(.session) \(.status)" + if .state == null or .state == "working" then "" else " \(.state)" end;

# The checks waits to arm, over team-snapshot's JSON: each open task whose checks_wait (in its
# team-state JSON) is waiting or pending, as {task, url, head, since}, in task number order, so a
# restart or a compaction rearms each team-next T<n> --ci not running.
def checks_waits_to_arm:
  [.tasks[] | select(.error == null and (.checks_wait.state // null | IN("waiting", "pending")))
   | {task} + (.checks_wait | {url, head, since})];

# team-snapshot's text form, one line per string, from its JSON. Lines are cut at 120 columns, so
# ten open tasks fit one screen, but an open task's state, the resources line, the Production line
# and a current item at 200, each being a whole thought (a task's progress and its PR part come
# last on its line). After the open tasks, one line per checks wait to arm (checks_waits_to_arm):
# "Checks waits to arm unless running: team-next T<n> --ci (<url> at <short>, since <ts>)", none
# when there is none. After the resources line, one line per withdrawal of the default merge word
# that stands. The Production line, after them, is team-uptime's status line, or "Production
# unreadable: <error>", and there is none when no project has a check.
def snapshot_text:
  def section($title; $lines; $columns):
    if $lines == [] then "\($title): none" else "\($title) (\($lines | length)):", ($lines[] | "  " + . | clip($columns)) end;
  def section($title; $lines): section($title; $lines; 120);
  section("Open tasks"; [.tasks[] | if .error then "\(.task) state unreadable: \(.error)" else state_line end]; 200),
  (checks_waits_to_arm[]
   | "Checks waits to arm unless running: team-next \(.task) --ci (\(.url) at \(.head[:8]), since \(.since))" | clip(200)),
  (.resources // "Resources unreadable: \(.level.error // "team-level said nothing")" | clip(200)),
  ((.default_withdrawn // [])[]
   | "Default merge word withdrawn for \(default_scope_text) since \(.ts) (Discord message \(.discord_message), \(.task))" | clip(120)),
  (.production // {}
   | if .line | type == "string" then .line | clip(200)
     elif .error != null then "Production unreadable: \(.error)" | clip(200)
     else empty end),
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
  (.waiting as $w
   | if $w != null and $w.error == null then
       (if $w.total == 0 then "Waiting on Daniel: nothing"
        else "Waiting on Daniel (\($w.total)), ranked by what each answer unblocks:", ($w.lines[] | "  " + . | clip(200)),
          (if $w.total > ($w.lines | length) then "  and \($w.total - ($w.lines | length)) more in waiting.md" else empty end)
        end),
       ($w.owed[] | "  Owed you: " + . | clip(200))
     else
       (if $w.error != null then "Waiting on Daniel unreadable: \($w.error)" | clip(120) else empty end),
       section("Pending asks"; [.pending_asks[] | "\(.task) \(.id): \(.text)"])
     end),
  ((if .waiting != null and .waiting.error == null then ["queued", "ask", "owe"] else ["queued"] end) as $left_out
   | [(.items // [])[] | select(split(" ")[0] | IN($left_out[]) | not)] as $items
   | if $items == [] then "Current items: none"
     else "Current items (\($items | length)):", ($items[:40][] | "  - " + . | clip(200)),
       if $items | length > 40 then "  and \($items | length - 40) more in tasks/current.md" else empty end
     end),
  (.queued // 0 | if . > 0 then "Queued work: \(.) file\(if . == 1 then "" else "s" end), listed in tasks/queued/index.md" else empty end);

# Whether the default word may hold for some PR, over every ledger event as an array: an open task
# awaits merge with its plan approved. team-sweep and team-inbox read the registry for own_in only
# then.
def default_may_hold: by_task | any(.[]; is_open and phase == "awaiting-merge" and plan_approval.state == "approved");

# The following defs serve team-inbox, a task's events as an array, then every ledger event as one.

# Whether the task's latest interview thread still holds an interview: no planner's done and no
# plan-approved logged after its interview-thread.
def interview_under_way:
  latest_index("interview-thread") as $i
  | $i >= 0 and all(.[$i + 1:][]; ((.event == "done" and .role == "planner") or .event == "plan-approved") | not);

# Whether the event is a merge-approved naming the PR $pr (one of task_prs) at its head: its url is
# the PR's, a trailing slash aside, and its head the PR's, or none, as a legacy line.
def approves_pr($pr):
  .event == "merge-approved" and (.url | strings | rtrimstr("/")) == ($pr.url | rtrimstr("/"))
  and (.head == null or same_head(.head; $pr.head));

# The task's PRs that wait on Daniel's word to merge, from task_prs: none unless its phase is
# awaiting-merge, then each not merged that no merge-approved names at its head (approves_pr), and
# whose default word does not hold on the ledger
# (default_holds over $withdrawals, default_events', and $own, own_projects' {projects, app}, the
# team's own and the reviewer App; with $own null, as when the registry cannot be read, none holds).
def merge_ready_prs($withdrawals; $own):
  . as $events
  | task_prs as $prs
  | if phase != "awaiting-merge" then []
    else [$prs[] | select(pr_merged($events; $prs) | not) | . as $pr
      | select(any($events[]; approves_pr($pr)) | not)
      | select($own != null and ($events | default_holds($pr; $withdrawals; $own)) | not)] end;

# Each open task's count of the other open tasks blocked on it, over by_task's answer: {"T<n>": n},
# counting each task whose standing blocked park of cause task (no launch went past it) is on it.
def blocked_on_counts:
  [to_entries[] | select(.value | is_open) | .key as $t
   | [.value | lifecycle | lifecycle_parks[] | select(.kind == "blocked" and .cause == "task" and (.passed | not))
      | .on | tostring | ascii_upcase | select(. != $t)] | unique[] | {on: ., task: $t}]
  | group_by(.on) | map({key: .[0].on, value: length}) | from_entries;

# What waits on Daniel, over every ledger event, each open task's in task number order: {items,
# withdrawn}. items, each keyed as waiting_numbered reads it: the open asks ({key: "ask <task> <id>
# <the asked's ts>", kind: "ask", task, title, id, text (its first line), thread (the task's
# thread when it was asked), message (the question's discord_message)}), then the PRs ready to
# merge ({key: "pr <url, its trailing slash dropped>", kind: "pr", task, title, url}), as
# merge_ready_prs has them over $own (own_projects' {projects, app}, or null),
# then the interviews under way ({key: "interview <task> <thread>", kind: "interview", task, title,
# thread}), none whose walk is on in that thread, which the walks list, then the walks under way
# ({key: "walk <task> <its start's ts>", kind: "walk", task, title, thread (the thread it runs in,
# or null)}), then the asks of tasks/current.md, $notes' of kind ask ({key: "note <id>", kind:
# "note", task (T<n> or -), title: null, id (team-current's), text, where}), in its order; each also
# with since, when it began (the asked's ts, the PR's first pr event's, the latest
# interview-thread's, the walk's start's; null for a note, which the ledger does not date), and
# unblocks, what its answer unblocks, {tasks, tickets, prs}: while the item holds its task (an ask
# no launch went past, a PR ready to merge, an interview or a walk under way), tasks is 1 for it
# and 1 for each other open task blocked on it (blocked_on_counts) and tickets its ready tickets,
# $tickets' count for it ({"T<n>": n}, 0 when it has none), else both are 0, as for a note, which
# holds no task; prs is 1 for a PR ready to merge and for an ask whose text names one of its task's
# PRs not merged, else 0. withdrawn: the withdrawals of the default merge word that stand
# (default_withdrawals), in ledger order; owed: the replies owed to Daniel, $notes' of kind owe, as
# {task, text, where}. $notes is current.md's ask and owe lines as team-inbox reads them, [{kind,
# task, text, where, id}].
def inbox_items($own; $notes; $tickets):
  default_events as $withdrawals
  | ($withdrawals | default_withdrawals(task_projects)) as $withdrawn
  | by_task as $tasks
  | ($tasks | blocked_on_counts) as $blocked
  | [$tasks | to_entries[] | select(.value | is_open)
    | {task: .key, events: .value, title: (.value | map(select(.event == "opened")) | first | .title)}]
  | by_task_number
  | def unblocks($t; $holds; $prs):
      if $holds then {tasks: (1 + ($blocked[$t] // 0)), tickets: ($tickets[$t] // 0)} else {tasks: 0, tickets: 0} end
      + {prs: $prs};
    {items: ([.[] | . as $t | .events as $events
        | ($events | task_prs | map(select(pr_merged($events; $events | task_prs) | not) | .url | rtrimstr("/"))) as $open_prs
        | ($events | lifecycle.asks | map({key: (.i | tostring), value: .passed}) | from_entries) as $passed
        | $events | unsettled_asks[]
        | (.ask.text | tostring) as $text
        | {key: "ask \($t.task) \(.ask.id) \(.ask.ts)", kind: "ask", task: $t.task, title: $t.title, id: .ask.id,
           text: ($text | split("\n")[0]),
           thread: ([$events[:.k][] | select(.event == "thread") | .discord_thread | strings] | last),
           message: (.ask.discord_message | if . == null then null else tostring end),
           since: .ask.ts,
           unblocks: unblocks($t.task; $passed[.k | tostring] != true;
             if any($open_prs[]; . as $url | $text | contains($url)) then 1 else 0 end)}]
      + [.[] | . as $t | .events as $events | $events | merge_ready_prs($withdrawals; $own)[] | .url
        | rtrimstr("/") as $url
        | {key: "pr \($url)", kind: "pr", task: $t.task, title: $t.title, url: .,
           since: ([$events[] | select(.event == "pr" and (.url | strings | rtrimstr("/")) == $url) | .ts] | first),
           unblocks: unblocks($t.task; true; 1)}]
      + [.[] | select(.events | interview_under_way and (qc_walk.thread != "interview"))
        | (.events | map(select(.event == "interview-thread")) | last) as $interview
        | ($interview.discord_thread | tostring) as $thread
        | {key: "interview \(.task) \($thread)", kind: "interview", task, title, thread: $thread, since: $interview.ts,
           unblocks: unblocks(.task; true; 0)}]
      + [.[] | (.events | qc_walk) as $walk | select($walk != null)
        | (if $walk.thread == "interview" then "interview-thread" else "thread" end) as $kind
        | {key: "walk \(.task) \($walk.since)", kind: "walk", task, title,
           thread: (.events | map(select(.event == $kind) | .discord_thread | strings) | last), since: $walk.since,
           unblocks: unblocks(.task; true; 0)}]
      + [$notes[] | select(.kind == "ask")
        | {key: "note \(.id)", kind: "note", task, title: null, id, text, where, since: null,
           unblocks: {tasks: 0, tickets: 0, prs: 0}}]),
     withdrawn: [$withdrawn[] | {task, scope, ts, discord_message, discord_channel}],
     owed: [$notes[] | select(.kind == "owe") | {task, text, where}]};

# The items of inbox_items, in the order given, each given its number n, from the previous
# waiting.json $previous (null when there is none or it cannot be read): an item whose key
# $previous's items hold keeps its number, and each other item, in order, takes the lowest
# positive number that no kept item holds, no earlier new item took and no item of the latest post
# ($previous.posted's items) showed.
def waiting_numbered($previous):
  ([$previous.items[]? | objects | select((.key | type) == "string" and (.n | type) == "number")]
   | map({key, value: .n}) | from_entries) as $kept
  | [$previous.posted.items[]? | objects | .n | numbers] as $shown
  | reduce .[] as $item ({items: [], seen: {}};
      .items += [{n: (if .seen[$item.key] then null else $kept[$item.key] end)} + $item]
      | .seen[$item.key] = true)
  | .items
  | reduce range(length) as $i ({items: ., taken: ([.[].n | numbers] + $shown)};
      if .items[$i].n != null then .
      else . as $s | first(range(1; infinite) | select(IN($s.taken[]) | not)) as $n
        | .items[$i].n = $n | .taken += [$n] end)
  | .items;

# What an item's answer unblocks, as one count: the sum of its unblocks.
def waiting_rank: [.unblocks // {} | .[] | numbers] | add // 0;

# A numbered item's line in waiting.md, its number in bold rather than an ordered list's marker,
# which Discord and GitHub both renumber, and every URL in <>, which keeps Discord from showing a
# preview card for it: an ask linked to the question's message in guild $guild (null when unknown),
# to the task's thread when either is unknown, and to nothing with no thread; a PR, "ready to
# merge", with its URL; an interview, "interview under way", with its thread; a walk, "walk under
# way", with the thread it runs in, or nothing with none; an ask of current.md with its task unless
# -, and its where when that is a URL (note_text); then what its answer unblocks, " - unblocks
# <n>", n being its unblocks' sum, and when it is more than 0 each part that is, as "(1 task, 2
# tickets, 1 PR)".
def note_text:
  (if .task == "-" then "" else "\(.task) " end) + (.text | clip(150))
  + if (.where // "") | test("^https?://\\S+$") then " <\(.where)>" else "" end;
def waiting_line($guild):
  def named: .task + if .title == null then "" else " \(.title | clip(80))" end;
  def count($n; $what): if $n == 0 then empty else "\($n) \($what)\(if $n == 1 then "" else "s" end)" end;
  (.unblocks // {}) as $u
  | ([count($u.tasks // 0; "task"), count($u.tickets // 0; "ticket"), count($u.prs // 0; "PR")] | join(", ")) as $parts
  | "- **\(.n)** "
  + if .kind == "ask" then "\(.task) \(.id): \(.text | clip(150))"
      + if .thread == null then ""
        elif .message != null and $guild != null then " <https://discord.com/channels/\($guild)/\(.thread)/\(.message)>"
        else " <#\(.thread)>" end
    elif .kind == "pr" then "\(named): ready to merge <\(.url)>"
    elif .kind == "note" then note_text
    elif .kind == "walk" then "\(named): walk under way" + if .thread == null then "" else " <#\(.thread)>" end
    else "\(named): interview under way <#\(.thread)>" end
  + " - unblocks \(waiting_rank)" + if $parts == "" then "" else " (\($parts))" end;

# waiting.json from inbox_items' answer: the items ranked by what each answer unblocks
# (waiting_rank), the most first, ties oldest first (by since, a note's null after every date),
# then in inbox_items' order, then numbered in that order (waiting_numbered, from $previous), so a
# new item's number follows its rank, each with its line (waiting_line, in guild $guild); the
# withdrawals and the owed replies as inbox_items has them, and $previous's post, null until
# team-inbox --post records one.
def waiting_list($previous; $guild):
  {schema: "team-waiting/1",
   items: (.items | sort_by([- waiting_rank, .since // "~"]) | waiting_numbered($previous)
     | map({n} + . + {line: waiting_line($guild)})),
   withdrawn: .withdrawn,
   owed: .owed,
   posted: ($previous.posted // null)};

# How waiting_rank counts, the line after the items.
def waiting_rank_text:
  "-# Ranked by what each answer unblocks: its task while that waits on it, the open tasks blocked on that task, the task's ready tickets and a PR to merge; ties oldest first.";

# waiting.md from waiting_list's answer, with a final newline: its title; "Nothing waits on you."
# or the items' lines in their order and how they are ranked (waiting_rank_text); one line per
# reply owed to Daniel, "-# Owed you: <note_text>"; and one line per withdrawal of the default
# merge word that stands, linked to Daniel's message in its channel in guild $guild (named by its
# id and channel when the guild is unknown).
def waiting_text($guild):
  .items as $items
  | ["**Waiting on you**"]
  + if $items == [] then ["Nothing waits on you."] else [$items[].line, waiting_rank_text] end
  + [.owed[]? | "-# Owed you: \(note_text)"]
  + [.withdrawn[] | "-# Default merge word withdrawn for \(default_scope_text) since "
      + if $guild != null then "<https://discord.com/channels/\($guild)/\(.discord_channel)/\(.discord_message)>"
        else "message \(.discord_message) in <#\(.discord_channel)>" end]
  | join("\n") + "\n";

# The messages of team-inbox --post from its lines, an array: packed greedily in order, each line
# whole, into messages of at most $max characters joined by newlines.
def post_messages($max):
  reduce .[] as $line ([];
    if length > 0 and (.[-1] | length) + 1 + ($line | length) <= $max then .[-1] += "\n" + $line
    else . + [$line] end);

# waiting.json with its post recorded: at $at, as the messages $ids, whose contents were $sent;
# the items it showed are those whose lines are in them.
def waiting_posted($at; $ids; $sent):
  ([$sent[] | split("\n")[]]) as $lines
  | .posted = {at: $at, messages: $ids, items: [.items[] | select(.line | IN($lines[]))]};

# team-inbox --item's answer for the number $n, over waiting.json read whole (jq -s): {item} for
# the standing item numbered $n, the line naming it ("ask <task> <id>", "pr <task> <url>",
# "interview <task> <thread>", "walk <task>" with the thread it runs in when it has one, or "note
# <task or -> <id>"), else {refusal}: the item the latest post showed as $n, which no
# longer waits, or the numbers that do; or a waiting.json of another schema.
def waiting_item($n):
  if length != 1 or (.[0] | type != "object" or .schema != "team-waiting/1") then
    {refusal: "waiting.json cannot be read: its schema is not team-waiting/1; team-inbox writes it afresh"}
  else .[0]
    | ([.items[]? | objects | select(.n == $n)] | first) as $item
    | ([.posted.items[]? | objects | select(.n == $n)] | first) as $shown
    | if $item != null then
        {item: (if $item.kind == "ask" then "ask \($item.task) \($item.id)"
          elif $item.kind == "pr" then "pr \($item.task) \($item.url)"
          elif $item.kind == "walk" then "walk \($item.task)" + if $item.thread == null then "" else " \($item.thread)" end
          elif $item.kind == "note" then "note \($item.task) \($item.id)"
          else "\($item.kind) \($item.task) \($item.thread)" end)}
      elif $shown != null then {refusal: "item \($n) no longer waits: the list posted \(.posted.at) showed it as \($shown.line)"}
      else {refusal: ("no item \($n) waits; "
        + ([.items[]?.n | numbers] | sort | map(tostring) | if . == [] then "nothing waits" else "the list holds \(and_text)" end))}
      end
  end;

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
# the ledger (end exclusive). For the retro task $task: after the opening of the last retro opened
# before it that ran (retro_ran), or from the first event, up to and including its own opening.
# For a dry run ($task null): after the opening of the latest retro that ran, up to now.
def retro_window($task):
  . as $events
  | retros as $retros
  | (if $task == null then {this: null, previous: (retros_ran | last)}
     else ($retros | map(.task == $task) | index(true)) as $k
       | $retros[$k] as $this
       | {this: $this, previous: ([retros_ran[] | select(.i < $this.i)] | last)} end) as $w
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

# The changes earlier retros led to, for the window $w (retro_window's), over every event with its
# place i ($placed), each task's events by id ($tasks) naming its title: each retro-change placed
# before the window's end whose retro is not the window's own, as {retro, proposals, task, title,
# logged, state, landed, prs}. It ends at its own time when logged on its retro (records changed
# in place, landed, no PRs), else at its task's last closed placed before the window's end; prs are
# the task's merged events placed before the window's end, oldest first. state is landed (ended,
# landed at its own time or at the last of those merges), closed (its task closed with no merge)
# or open (not ended, with its PRs merged so far). Kept while open, and when it ended at or after
# the window's start, so a change that ended is listed, and judged, in the one window it ended in.
def retro_changes($w; $placed; $tasks):
  ($placed[:$w.end] | map(select(.event == "merged" or .event == "closed")) | group_by(.task)
    | map({key: .[0].task, value: .}) | from_entries) as $ends
  | [$placed[:$w.end][] | select(.event == "retro-change" and .retro != $w.task) | . as $c
    | ($ends[$c.task] // []) as $mine
    | (if $c.task == $c.retro then {end: $c, at: $c, prs: []}
       else [$mine[] | select(.event == "merged")] as $merges
         | ([$mine[] | select(.event == "closed")] | last) as $closed
         | {end: $closed, at: (if $closed == null then null else $merges | last end),
            prs: [$merges[] | {pr, url, ts}]} end) as $life
    | select($life.end == null or $life.end.i >= $w.start)
    | {retro: $c.retro, proposals: $c.proposals, task: $c.task,
       title: ($tasks[$c.task] | map(select(.event == "opened")) | first | .title),
       logged: $c.ts,
       state: (if $life.at != null then "landed" elif $life.end != null then "closed" else "open" end),
       landed: $life.at.ts, prs: $life.prs}];

# A question's or an asked's text, or for an ops session's question, which logs its length and
# never its text, a line saying so.
def question_text:
  .text // (.chars | if . != null then "(an ops question of \(.) characters, kept out of the ledger)" else null end);

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
          events: map({ts, kind: .event, text: question_text} + if .event == "asked" then {id} else {role} end)}],
     reviews: [$in | map(select(.event == "review")) | task_groups[]
       | . as $reviews
       | {task: .[0].task, reopened: any(range(length - 1); $reviews[.].verdict == "findings"),
          verdicts: map({ts, verdict, head})}],
     waits: {spans: $spans,
       totals: ($spans | group_by(.on | tostring | ascii_downcase)
         | map({on: .[0].on, hours: (map(.hours) | add * 100 | round / 100), wall_hours: wall_hours, spans: length})
         | sort_by(-.hours))},
     rewrites: [$in[] | select(.event == "history-rewritten" or .event == "gate-lane-cleared")
       | del(.i) | if .event == "history-rewritten" then del(.event) else . end],
     injections: [$in[] | select(.event == "injection") | del(.i, .event)],
     tasks: [$in | task_groups[] | .[0].task as $id | $tasks[$id] as $all
       | ($all | map(select(.event == "opened")) | first) as $opened
       | {task: $id, title: $opened.title, project: $opened.project, path: $opened.path, phase: ($all | phase),
          record: "\($team_home)/tasks/\($id)/",
          sessions: [.[] | select(.event == "launch") | {session, role, launched: .ts}]}],
     changes: retro_changes($w; $placed; $tasks)};

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
    + (if .event == "gate-lane-cleared" then "gate lane cleared, its head " elif .old_head then "\(.old_head) -> " else "to " end)
    + "\(.head)" + (if .note then " (\(.note))" else "" end)]),
  section("Injections"; [.injections[] | "\(.ts) \(.task) \(.role) at \(.source): \(.text)"]),
  section("Tasks"; [.tasks[] | "\(.task) \([.project, .path, .phase] | map(select(. != null)) | join(" ")): \(.title // "untitled")"
    + "; record \(.record); sessions "
    + (.sessions | map("\(.role) \(.session)") | if . == [] then "none" else join(", ") end)]),
  section("Changes"; [.changes[] | "\(.task) (\(.title // "untitled")) for retro \(.retro)'s proposals \(.proposals | tojson): "
    + if .state == "open" then "open at the window's end"
        + if .prs == [] then "" else ", merged so far " + (.prs | map("PR \(.pr)" + if .url == null then "" else " \(.url)" end) | join(", ")) end
      elif .state == "closed" then "closed unmerged"
      elif .prs == [] then "landed \(.landed) in the records, no PR"
      else "landed \(.landed) by " + (.prs | map("PR \(.pr)" + if .url == null then "" else " \(.url)" end) | join(", ")) end]);
