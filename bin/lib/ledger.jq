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

# The finding kinds a review's findings counts, and the guarded areas its guarded may name.
def finding_kinds: ["blocking", "correctness", "security", "real-data", "note-change", "note-before"];
def guarded_areas: ["ci", "dependencies", "migrations", "settings", "permissions", "secrets", "guardrails"];

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
  elif $want == "id" then "\(.) (id)"
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
  ["open", "close", "approve", "launch", "build", "done", "pr", "review", "rewrite", "merge", "ask",
   "settle", "park", "resume", "stowed"];

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

# The state before a task's first event. The state's fields, which later readers add to rather
# than fold again:
#   status  unknown (no event), legacy (events but no opened), open, closed.
#   path    the opened's path, null before it.
#   opened_at the opened's ts, null before it.
#   phase   the work phase, one of the table's phases: planning before an opened, then the table's
#           start for its path (planning for a path it lacks), moved by lifecycle_step's effects.
#   since   the ts of the event that set the phase.
#   prs     the task's PRs, one per repo, in the order of their latest pr events, as {url, repo,
#           head, number, merged, verdict}: a later pr in the repo replaces its PR (keeping merged
#           for the same url), a history-rewritten moves heads (from its old_head, or every PR's
#           when no PR has that head); merged by a merged event naming it (merged_names); verdict
#           the latest review's on its current head, or null, whenever that review was logged (a
#           fix's head is reviewed before a pr event logs it).
#   reviews each review's head and verdict, in the order logged, for a PR's verdict when its head
#           moves.
#   parks   the standing parks (held, blocked, waiting, paused) in the order logged, as {id, kind,
#           cause, typed, on, reason, role, session, since, ts, i, passed}: id <kind>-<n>, n the
#           park's ordinal among the task's events of its kind; cause park_cause's, typed whether
#           the line carries its own cause; role park_role's; on, reason and session its fields,
#           or null; since its since field or its ts; i its index among the task's events; passed
#           false. A launch ends every standing blocked, waiting and paused, never a held; a
#           resumed with none of id, all and brief ends every park, and any other ends none (one
#           with only brief is a merge-base round's holder brief); a merge-approved ends every old
#           wait on Daniel (lifecycle_old_wait_on_daniel).
#   asks    the asks no later event settles (settles), as {id, text, ts, i, passed}, passed false.
#   stow    null, or {state: "stowed", cause, roles, since, i} from the latest stowed with no
#           launch after it.
#   counts  each park kind's events so far, for the next park's id.
#   seen    the events folded so far, the next event's index.
def lifecycle_start:
  {status: "unknown", path: null, opened_at: null, phase: "planning", since: null, prs: [], reviews: [], parks: [],
   asks: [], stow: null, counts: {}, seen: 0};

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
# phase), close, approve (planning to building), launch (a builder's moves planning, merged-part
# or merged to building; every launch ends the parks a launch ends, and the stow), build (a
# ticket-done: the same moves), done (a builder's whose report starts review-ready or merged moves
# building to in-review), pr, review and rewrite (the PRs, then the review phase: a pr's from any
# phase, a review's or a rewrite's from building, in-review or awaiting-merge, a rewrite's only
# when the task has a PR, since no review is under way without one), merge (its PR
# merged; with none open, merged-part when it names a non-empty phases_left, else merged; else the
# review phase), ask, settle, park, resume and stowed (as the state's fields say).
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
      if .phase == "planning" then lifecycle_move("building"; $e.ts) else . end
    elif $effect == "launch" then
      (if $e.role == "builder" and IN(.phase; "planning", "merged-part", "merged") then lifecycle_move("building"; $e.ts) else . end)
      | .parks |= map(select(.kind == "held"))
      | .stow = null
    elif $effect == "build" then
      if IN(.phase; "planning", "merged-part", "merged") then lifecycle_move("building"; $e.ts) else . end
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
    elif $effect == "settle" then
      .asks |= map(. as $ask | select($e | settles($ask) | not))
      | if $e.event == "merge-approved" then .parks |= map(select(lifecycle_old_wait_on_daniel | not)) else . end
    elif $effect == "park" then
      .counts[$e.event] = ((.counts[$e.event] // 0) + 1)
      | .parks += [{id: "\($e.event)-\(.counts[$e.event])", kind: $e.event, cause: ($e | park_cause),
          typed: ($e.cause != null), on: ($e.on // null), reason: ($e.reason // null), role: ($e | park_role),
          session: ($e.session // null), since: ($e.since // $e.ts), ts: $e.ts, i: $i, passed: false}]
    elif $effect == "resume" then
      if $e.id == null and $e.all == null and $e.brief == null then .parks = [] else . end
    elif $effect == "stowed" then
      .stow = {state: "stowed", cause: ($e.cause // null), roles: ($e.roles // []), since: $e.ts, i: $i}
    else . end;

# The task's state: its events, in ledger order, folded from lifecycle_start.
def lifecycle: reduce .[] as $e (lifecycle_start; lifecycle_step($e));

# How the event $e breaks the table in the state (the input), one string each, nothing when the
# table takes it: a status its kind does not take (closed, with closed-own-retro for a closed
# task's own retro-change, its retro this task; not opened, unknown or legacy, naming the kinds
# that status takes in the table's order; opened already), else a phase it does not take. A kind
# the table does not list takes default.
def lifecycle_problems($e):
  lifecycle_table as $t
  | ($t.kinds[$e.event] // {}) as $row
  | ($row.status // $t.default.status) as $statuses
  | ($row.phases // $t.default.phases) as $phases
  | def kinds_taken($status): [$t.kinds | to_entries[] | select(.value.status // $t.default.status | index([$status])) | .key];
    def listed($word): if length < 2 then join("") else "\(.[:-1] | join(", ")) \($word) \(.[-1])" end;
  if (.status | IN($statuses[]))
     or (.status == "closed" and $e.retro == $e.task and ("closed-own-retro" | IN($statuses[]))) then
    if $phases == null or (.phase | IN($phases[])) then empty
    else "\($e.task) is \(.phase) since \(.since), and \($e.event) is taken only while it is \($phases | listed("or"))" end
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
# that says on, else null, as for a task with none or a closed one, whose walk ended with it. Read
# by team-ui --walk and task_state.
def qc_walk:
  if task_status == "closed" then null
  else map(select(.event == "walk")) | last | if .state == "on" then {since: .ts} else null end end;

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

# The index of the task's latest stowed, or -1 when it has none.
def latest_stowed: latest_index("stowed");

# Whether the task crashed on a machine switch: a launch after its latest stowed, or a launch and
# no stowed at all, so the machine it last ran on stopped without handing it off.
def crashed: latest_stowed as $stowed | any(.[$stowed + 1:][]; .event == "launch");

# Whether the task is stowed, waiting to resume: its latest stowed, for the level or a handoff (cause
# level or handoff, or none, as before team-stow), names roles to relaunch and no launch follows
# it, so it waits for the resume or for room at the team's level to be relaunched here.
def lifecycle_stowed_awaiting_resume: .stow != null and .stow.state == "stowed" and .stow.roles != [];
def stowed_awaiting_resume: lifecycle | lifecycle_stowed_awaiting_resume;

# What keeps a task's parked work, parked at its event of index <since>, from being launched, as
# text, or null, from the fold's standing parks: its latest held, wherever it falls ("held:
# <reason>"); else its latest waiting ("waiting on <on>: <reason>") or blocked ("blocked:
# <reason>") logged after <since>. A wait or block before it was the state the work was parked
# in, which its launch resumes, and a paused never holds it, since every park logs one; a resumed
# lifts each.
def lifecycle_hold_since($since):
  def after($kind): [.parks[] | select(.kind == $kind and .i > $since)] | last;
  if lifecycle_park("held") != null then "held: \(lifecycle_park("held").reason)"
  elif after("waiting") != null then after("waiting") | "waiting on \(.on): \(.reason)"
  elif after("blocked") != null then "blocked: \(after("blocked").reason)"
  else null end;
def hold_since($since): lifecycle | lifecycle_hold_since($since);

# What keeps the task, stowed and waiting to resume, from being relaunched (hold_since the fold's
# stow): a wait or block before the stow was the stowed worker's own state (a planner
# interviewing Daniel), which its relaunch resumes.
def lifecycle_stow_hold: lifecycle_hold_since(.stow.i // -1);
def stow_hold: lifecycle | lifecycle_stow_hold;

# The launches of the task refused for room and not launched or resumed since: the fold's standing
# parks whose cause (park_cause) is room and whose role (park_role) is known, as {at (the latest
# refusal's time), roles (each role once, in the order refused), hold (hold_since the latest
# refusal: a wait or block before it did not stop the launch tried then)}; null with none, or
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

# Whether the task's worktree in <project> resumes from the last checkpoint's snapshot: the task
# crashed, or its latest stowed recorded that worktree with uncommitted changes, which the
# handoff's checkpoint kept as wip/<project>/T<n> on the team home's origin.
def snapshot_due($project):
  crashed or (latest_stowed as $stowed | $stowed >= 0
    and any(.[$stowed].worktrees[]?; .project == $project and .uncommitted == true));

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
# task's events as an array (task_branch), one string, or none when it is: a word given on no head
# (the plan-time and standing ones) holds only for the task's own branch.
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
# when task_state_json added it, and the brief the launch logged (or null).
def workers($sessions):
  [.[] | select(.event == "launch") | live_session(.session; $sessions) as $live
    | {role, session, launched: .ts, worktree, live: ($live != null), status: $live.status, state: $live.state,
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

# Daniel's standing merge word on $project, over every ledger event as an array (never one task's),
# or null when no merge-standing or merge-standing-withdrawn names $project or all: the latest of
# those decides, so {stands: whether it is a merge-standing, word: the latest merge-standing that
# applies, withdrawn: the latest event when it is a withdrawal, else null}, each as {project (as
# logged), task, ts, discord_message, discord_channel}, word null when no merge-standing applies.
def standing_word($project):
  def said: {project, task, ts, discord_message, discord_channel};
  [.[] | select((.event == "merge-standing" or .event == "merge-standing-withdrawn")
    and (.project == $project or .project == "all"))] as $applying
  | ($applying | last) as $latest
  | if $latest == null then null
    else {stands: ($latest.event == "merge-standing"),
          word: ([$applying[] | select(.event == "merge-standing")] | last | if . == null then null else said end),
          withdrawn: (if $latest.event == "merge-standing-withdrawn" then $latest | said else null end)} end;

# The projects of the list $projects a standing word stands for, over every ledger event as an
# array, in the list's order, each as {project, word} (standing_word's word).
def standing_words($projects):
  . as $events
  | [$projects[] | . as $project | $events | standing_word($project)
     | select(. != null and .stands) | {project: $project, word}];

# Daniel's standing words from standing_words' list ({project, word}), one {projects, word} per
# word event, the projects in the list's order, the words in the order they were logged.
def standing_word_events:
  group_by(.word) | map({projects: map(.project), word: .[0].word}) | sort_by(.word.ts, .word.discord_message);

# A standing word's projects as text: "all", which only a word as logged names, is every project.
def projects_text: map(if . == "all" then "every project" else . end) | join(", ");

# Why Daniel's standing word on $project does not stand, over standing_word's answer ({stands,
# word, withdrawn}, or null for no event), one string, or none while it stands: no word names
# $project or all, or the latest event that applies withdrew it.
def standing_word_reasons($project):
  if .word == null then "no standing word of Daniel's names \($project) or every project"
  elif .stands | not then
    "Daniel's standing word on \(if .word.project == "all" then "every project" else .word.project end), Discord message \(.word.discord_message), was withdrawn at \(.withdrawn.ts) in Discord message \(.withdrawn.discord_message)"
  else empty end;

# The head whose review stands for $head: $head itself when a review of it is logged, or, when a
# caught-up event of the task names $head (by the shorter prefix) as the merge team-catch-up made,
# the head it was made from, followed back the same way, the latest such event first, until a head
# has a review of its own or no event names it.
def reviewed_head($head):
  [.[] | select(.event == "caught-up")] as $ups
  | [.[] | select(.event == "review") | .head] as $reviewed
  | def back($h; $n):
      (first($ups | reverse[] | select(same_head(.head; $h))) // null) as $up
      | if $up == null or $n <= 0 or any($reviewed[]; same_head(.; $h)) then $h
        else back($up.from; $n - 1) end;
    back($head; $ups | length);

# Why the task's reviews do not let a word given on no head (plan-time or standing) merge the PR's
# head $head unasked, one string per reason, none when they do, judged on the latest review of
# reviewed_head($head), so a head team-catch-up made with no review of its own stands on the
# review of the one it was made from (both named): no review of that head (by the shorter prefix)
# is logged; the latest one is not a pass; it logged no guarded list, or named areas in it; and
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
     waiting: ($state | lifecycle_waiting), walk: qc_walk,
     rehome_failures: rehome_failures, merge_preapproval: latest_merge_preapproval, pr: null,
     progress: progress($workers)};

# A task's state (team-state's JSON) as one line of text, each live worker's context in thousands
# and the brief it is on, then the tickets done, with the graph fresh or stale when there is one,
# and the latest review:
# T14 agent-team feature building | T14-builder idle 302k on build-04 | tickets 3/7, graph stale | review 4 findings, sent back 5, 6 | PR #5 a1b2c3d 16 behind dev checks 2/2 agent-review missing
def state_line:
  .task as $task
  | ([.task, .project, .path, .phase] | map(select(. != null)) | join(" "))
  + " | "
  + ([.workers[] | select(.live)
      | "\($task)-\(.role) \(.status)" + (if .state == null or .state == "working" then "" else " \(.state)" end)
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
  + (.pr.standing_word // null
     | if . == null or .covers == null then ""
       elif .withdrawn != null then " | standing word withdrawn"
       elif .covers then " | standing word covers it"
       else " | standing word does not cover it: \(.reasons[0])"
         + (.reasons | length | if . > 1 then " (and \(. - 1) more)" else "" end) end)
  + (if .walk == null then "" else " | walk on since \(.walk.since)" end)
  + (if .waiting == null then "" else " | waiting on \(.waiting.on): \(.waiting.reason)" end);

# Whether a task is parked, waiting on something other than a worker, by the fold: awaiting merge,
# a park standing (held, blocked, waiting or paused), or an ask nothing settled (settles).
def parked: lifecycle | lifecycle_phase == "awaiting-merge" or .parks != [] or .asks != [];

# One of team-sweep's findings: {task, kind, session, name, next, text}, text being its one line.
def finding($task; $kind; $session; $name; $detail; $next):
  {task: $task, kind: $kind, session: $session, name: $name, next: $next,
   text: "\($task) \($kind): \($detail); next: \($next)"};

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

# team-sweep's merge-due finding, over a task's events and the session list, or nothing: the task
# awaits merge, a plan-time approval of it stands or a standing word of Daniel's stands for one of
# its projects (its opened and worktree-added events'), nothing else parks it (no ask nothing
# settled, pause or wait), no merge-base round is in flight, and a PR not merged has no review-side
# reason against a word given on no head on the latest head the task logged for it (pr_heads, since
# no pr event logs a fix; unattended_review_reasons, as team-state and team-merge read them: the
# sweep reads no GitHub, so a guarded path a reviewer did not name is team-merge's to find, and of
# two open PRs the later review stands for both); only such PRs are named. $standing is the ledger's merge-standing and
# merge-standing-withdrawn events, every task's, as standing_words reads them. The ledger names no
# PR's project, so any word on one of the task's projects counts, and team-merge holds each PR to
# its own project's. Only the task's projects in $covered, the projects a standing word may cover
# (standing_projects in team.sh: every registered one but the team's own), count for a standing
# word.
def merge_due_finding($standing; $sessions; $covered):
  .[0].task as $task
  | . as $events
  | lifecycle as $state
  | if ($state | lifecycle_phase) == "awaiting-merge" and $state.asks == [] and $state.parks == [] then
      preapproved_projects as $plan
      | [($events | map(select(.event == "opened" or .event == "worktree-added") | .project)
          | reduce .[] as $p ([]; if IN(.[]; $p) then . else . + [$p] end)
          | map(select(IN($covered[]; .)))) as $projects
         | $standing | standing_words($projects)[] | .project] as $words
      | select($plan != [] or $words != [])
      | select($events | merge_base_round($sessions) | not)
      | task_prs as $prs
      | [$prs[] | select(pr_merged($events; $prs) | not) | . as $pr
         | select([$events | unattended_review_reasons(pr_heads($pr.url) | last | .head // $pr.head)] == []) | .url] as $due
      | select($due != [])
      | finding($task; "merge-due"; null; null;
          "awaiting the merge of \($due | join(", "))"
          + " on Daniel's "
          + ([if $plan != [] then "plan-time word on \($plan | join(", "))" else empty end,
              if $words != [] then "standing word on \($words | join(", "))" else empty end] | join(" and "))
          + ", with no ask open";
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
# takes it): each open task's merge-due (under a plan-time word or a standing word of any task's),
# else its findings unless it is parked, then the stray sessions (named like a team worker whose
# task is closed or not in the ledger, never the load check's T0, whose session the coordinator
# waits on for up to 30 minutes), in task number order; then the coordinator-twin, activity,
# level, retro-due and health findings. $covered is the projects a standing word may cover, as
# merge_due_finding takes it, $health the health view, as health_findings takes it, and $self the
# sweep's own session id, as coordinator_twin_findings takes it.
def sweep($sessions; $plan; $activity; $covered; $health; $self):
  . as $events
  | by_task as $tasks
  | [.[] | select(.event == "merge-standing" or .event == "merge-standing-withdrawn")] as $standing
  | ([($tasks[] | select(is_open) | [merge_due_finding($standing; $sessions; $covered)] as $due
        | if $due != [] then $due[] elif parked then empty
          else task_findings($sessions; $activity) end),
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
# with no new launch), stowed (while it is stowed_awaiting_resume, {at, roles} of its latest
# stowed and hold, stow_hold's, else null), stowed_since (its latest stowed's time when no launch
# follows it, else null), refused (refused_launches')} per open task, in task number order.
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
      stowed_since: ($state.stow | if . != null and .state == "stowed" then .since else null end),
      refused: ($state | lifecycle_refused_launches)}]
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
# resource level ($level, team-level status --json's object or {error}), the registered projects
# but the team's own a standing word of Daniel's stands for ($standing, standing_words' list), the
# session list, each registered project's open PRs ($prs), the current items ($items) and the
# production checks' last results ($production, team-uptime status --json's object or {error}). It
# carries $level as level, the open tasks stowed, waiting to resume, as awaiting_resume, the
# resources_line as resources (null when $level is {error}), and $production as production.
def snapshot($tasks; $states; $level; $standing; $sessions; $prs; $items; $production):
  team_sessions($tasks; $sessions) as $team
  | ($tasks | awaiting_resume) as $stowed
  | {schema: "team-snapshot/1",
     tasks: $states,
     level: $level,
     awaiting_resume: $stowed,
     resources: resources_line($level; $stowed),
     standing_words: $standing,
     production: $production,
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
# ten open tasks fit one screen, but an open task's state, the resources line, the Production line
# and a current item at 200, each being a whole thought (a task's progress and its PR part come
# last on its line). The Production line, after the standing merge words, is team-uptime's status
# line, or "Production unreadable: <error>", and there is none when no project has a check.
def snapshot_text:
  def section($title; $lines; $columns):
    if $lines == [] then "\($title): none" else "\($title) (\($lines | length)):", ($lines[] | "  " + . | clip($columns)) end;
  def section($title; $lines): section($title; $lines; 120);
  section("Open tasks"; [.tasks[] | if .error then "\(.task) state unreadable: \(.error)" else state_line end]; 200),
  (.resources // "Resources unreadable: \(.level.error // "team-level said nothing")" | clip(200)),
  ((.standing_words // []) | standing_word_events
   | if . == [] then "Standing merge word: none"
     else .[] | "Standing merge word: \(.projects | projects_text) (Discord message \(.word.discord_message), \(.word.ts), \(.word.task))" | clip(120) end),
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
# head, or at no head, as a legacy line, and whose repo (lowercased) is neither a key of
# $plan_repos naming a project with a merge-preapproved of the task not withdrawn (the projects
# that opt in to plan-time merges now and are not the team's own) nor a key of $standing_repos (the
# projects a standing word of Daniel's stands for), each of which team-inbox reads from the
# registry.
def merge_ready_prs($plan_repos; $standing_repos):
  . as $events
  | task_prs as $prs
  | if phase != "awaiting-merge" then []
    else [$prs[] | select(pr_merged($events; $prs) | not) | . as $pr
      | select(any($events[]; .event == "merge-approved" and (.url | strings | rtrimstr("/")) == ($pr.url | rtrimstr("/"))
          and (.head == null or same_head(.head; $pr.head))) | not)
      | (first($pr.url | strings | capture("^https://github\\.com/(?<r>[^/]+/[^/]+)/") | .r | ascii_downcase) // "") as $repo
      | $plan_repos[$repo] as $project
      | select(($project != null and ($events | merge_preapproval($project) | . != null and .withdrawn == null))
          or $standing_repos[$repo] != null | not)] end;

# What waits on Daniel, over every ledger event, each open task's in task number order: {items,
# standing}. items, each keyed as waiting_numbered reads it: the open asks ({key: "ask <task> <id>
# <the asked's ts>", kind: "ask", task, title, id, text (its first line), thread (the task's
# thread when it was asked), message (the question's discord_message)}), then the PRs ready to
# merge ({key: "pr <url, its trailing slash dropped>", kind: "pr", task, title, url}), as
# merge_ready_prs has them, its standing repos being those of $repos (each repo, lowercased, to its
# project) whose project a standing word stands for, then the interviews under way ({key:
# "interview <task> <thread>", kind: "interview", task, title, thread}); standing:
# standing_word_events of the projects $projects (standing_projects', in team-inbox) a standing
# word stands for.
def inbox_items($plan_repos; $repos; $projects):
  standing_words($projects) as $standing
  | ($repos | with_entries(select(.value as $project | any($standing[]; .project == $project)))) as $standing_repos
  | [by_task | to_entries[] | select(.value | is_open)
    | {task: .key, events: .value, title: (.value | map(select(.event == "opened")) | first | .title)}]
  | by_task_number
  | {items: ([.[] | . as $t | .events as $events | $events | unsettled_asks[]
        | {key: "ask \($t.task) \(.ask.id) \(.ask.ts)", kind: "ask", task: $t.task, title: $t.title, id: .ask.id,
           text: (.ask.text | tostring | split("\n")[0]),
           thread: ([$events[:.k][] | select(.event == "thread") | .discord_thread | strings] | last),
           message: (.ask.discord_message | if . == null then null else tostring end)}]
      + [.[] | . as $t | .events | merge_ready_prs($plan_repos; $standing_repos)[] | .url
        | {key: "pr \(rtrimstr("/"))", kind: "pr", task: $t.task, title: $t.title, url: .}]
      + [.[] | select(.events | interview_under_way)
        | (.events | map(select(.event == "interview-thread") | .discord_thread) | last | tostring) as $thread
        | {key: "interview \(.task) \($thread)", kind: "interview", task, title, thread: $thread}]),
     standing: ($standing | standing_word_events)};

# The items of inbox_items, in its order, each given its number n, from the previous waiting.json
# $previous (null when there is none or it cannot be read): an item whose key $previous's items
# hold keeps its number, and each other item, in order, takes the lowest positive number that no
# kept item holds, no earlier new item took and no item of the latest post ($previous.posted's
# items) showed.
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

# A numbered item's line in waiting.md, its number in bold rather than an ordered list's marker,
# which Discord and GitHub both renumber, and every URL in <>, which keeps Discord from showing a
# preview card for it: an ask linked to the question's message in guild $guild (null when unknown),
# to the task's thread when either is unknown, and to nothing with no thread; a PR with its URL; an
# interview with its thread.
def waiting_line($guild):
  def named: .task + if .title == null then "" else " \(.title | clip(80))" end;
  "- **\(.n)** "
  + if .kind == "ask" then "\(.task) \(.id): \(.text | clip(150))"
      + if .thread == null then ""
        elif .message != null and $guild != null then " <https://discord.com/channels/\($guild)/\(.thread)/\(.message)>"
        else " <#\(.thread)>" end
    elif .kind == "pr" then "\(named): <\(.url)>"
    else "\(named): <#\(.thread)>" end;

# waiting.json from inbox_items' answer: the items numbered (waiting_numbered, from $previous), in
# the order waiting.md shows them (the asks, the PRs, the interviews, each in number order), each
# with its line (waiting_line, in guild $guild), the standing words as inbox_items has them, and
# $previous's post, null until team-inbox --post records one.
def waiting_list($previous; $guild):
  {schema: "team-waiting/1",
   items: (.items | waiting_numbered($previous)
     | sort_by(.kind as $kind | [(["ask", "pr", "interview"] | index($kind)), .n])
     | map({n} + . + {line: waiting_line($guild)})),
   standing: .standing,
   posted: ($previous.posted // null)};

# waiting.md from waiting_list's answer, with a final newline: its title; "Nothing waits on you."
# or each section with items, its heading then its items' lines; and one line per standing word,
# linked to Daniel's message in its channel in guild $guild (named by its id and channel when the
# guild is unknown).
def waiting_text($guild):
  .items as $items
  | ["**Waiting on you**"]
  + if $items == [] then ["Nothing waits on you."]
    else [[["ask", "**Asks**"], ["pr", "**PRs ready to merge**"], ["interview", "**Interviews under way**"]][]
      as [$kind, $heading]
      | [$items[] | select(.kind == $kind) | .line] | select(. != []) | $heading, .[]]
    end
  + [.standing[] | "-# Standing merge word on \(.projects | projects_text) since "
      + if $guild != null then "<https://discord.com/channels/\($guild)/\(.word.discord_channel)/\(.word.discord_message)>"
        else "message \(.word.discord_message) in <#\(.word.discord_channel)>" end]
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
# the standing item numbered $n, the line naming it ("ask <task> <id>", "pr <task> <url>" or
# "interview <task> <thread>"), else {refusal}: the item the latest post showed as $n, which no
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
