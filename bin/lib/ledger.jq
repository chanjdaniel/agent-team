# Checking ledger lines against the ledger contract (ledger-contract.json, passed as $contract).
# Used through ledger_jq in team.sh. Each *_problems def yields one string per problem found.

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
