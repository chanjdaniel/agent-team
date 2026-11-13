# The queue of approved work, the team home's tasks/queued/: what each item's state is, when an
# after: condition is met, how the items rank, the problems team-queue index --check names and the
# text of the index. Used by team-queue as
# jq -nR -L bin/lib 'include "queue"; include "ledger"; ...' over the ledger's lines, with the
# items' cards (team-queue's one awk pass: {file, title, keys, problems}), the registry's project
# names, the items that left the queue, the queued files the tasks' plans cite, today's UTC date
# and the time now; team-queue's header documents the keys, the states and the words.
include "ledger";

# The front matter keys, in the order team-queue writes them.
def queue_keys: ["summary", "project", "priority", "size", "after", "waits", "from", "opened", "takes", "alone", "guarded"];

# The sizes, smallest first, which is their rank.
def queue_sizes: ["S", "M", "L"];

# Seconds a finished item may stay queued before --check names it: three heartbeat runs.
def queue_grace: 900;

def queue_task_re: "^T[1-9][0-9]*$";
def queue_file_re: "^[A-Za-z0-9][A-Za-z0-9._-]*\\.md$";

# A comma-joined value as its parts, each trimmed.
def queue_parts: split(",") | map(sub("^ +"; "") | sub(" +$"; ""));

# Whether a string is a real YYYY-MM-DD date.
def queue_date: test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") and ((try (strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch null) == .);

# An after: condition as written, parsed: {kind: merged, task}, {kind: phase, task, phase},
# {kind: closed, task}, {kind: date, date}, {kind: file, file} or {kind: bad}; with its text.
def queue_condition:
  . as $text
  | ((capture("^(?<task>T[1-9][0-9]*) merged$") | {kind: "merged", task})
     // (capture("^(?<task>T[1-9][0-9]*) phase (?<phase>[1-9][0-9]*) merged$") | {kind: "phase", task, phase: (.phase | tonumber)})
     // (capture("^(?<task>T[1-9][0-9]*) closed$") | {kind: "closed", task})
     // (select(queue_date) | {kind: "date", date: .})
     // (select(test(queue_file_re)) | {kind: "file", file: .})
     // {kind: "bad"})
  | . + {text: $text};

# A ledger timestamp as seconds since the epoch, fractions dropped.
def queue_seconds: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;

# What the ledger says of one task's events: each merged's phases left, and the events that end
# it, a whole merge (a merged with no phases_left or an empty one) or a closed, the earliest first.
def queue_task_facts:
  {merges: [.[] | select(.event == "merged") | (.phases_left // [])],
   ends: ([.[] | select((.event == "merged" and ((.phases_left // []) == [])) or .event == "closed")
           | {event, ts}] | sort_by(.ts))};

# Whether a parsed condition is met, given the tasks' facts, today's date, the queued files and
# the files that left the queue.
def queue_met($facts; $today; $queued; $left):
  if .kind == "merged" then any($facts[.task].ends[]?; .event == "merged")
  elif .kind == "phase" then . as $c | any($facts[.task].merges[]?; IN(.[]; $c.phase) | not)
  elif .kind == "closed" then any($facts[.task].ends[]?; .event == "closed")
  elif .kind == "date" then $today >= .date
  elif .kind == "file" then (IN($queued[]; .file) | not) and IN($left[]; .file)
  else false end;

# The problem "<key> names T<n>, which the ledger does not hold", for a task the ledger lacks.
def queue_unknown($key; $facts): select($facts[.] == null) | "\($key) names \(.), which the ledger does not hold";

# One queued item from its card: its keys read, its own problems, and its after: conditions
# judged; the problems and state that need the other items come in queue_items.
def queue_item($facts; $projects; $today; $queued; $left; $now):
  .keys as $k
  | ($k.after // null | if . == null then [] else queue_parts | map(queue_condition) end) as $after
  | ($k.from // null | if . == null then [] else queue_parts end) as $from
  | ($k.takes // null | if . == null then [] else queue_parts end) as $takes
  | ($k.opened // null) as $opened
  | (if $opened != null and ($opened | test(queue_task_re)) then $facts[$opened].ends[0]? // null else null end) as $end
  | {file, title,
     summary: ($k.summary // null),
     project: ($k.project // null),
     priority: ($k.priority // null | if . != null and test("^[1-4]$") then tonumber else . end),
     size: ($k.size // null),
     after: [$after[] | {condition: .text, met: queue_met($facts; $today; $queued; $left)}],
     waits: ($k.waits // null),
     from: $from,
     opened: $opened,
     takes: $takes,
     alone: ($k.alone == "yes"),
     guarded: ($k.guarded // null),
     finished: (if $end == null then null else {task: $opened} + $end end),
     problems: (.problems + [
       ($k | keys_unsorted[] | select(IN(queue_keys[]; .) | not) | select(. != "task")
        | "front matter key \(tojson) is none team-queue reads (team-queue --help)"),
       (select($k | has("task")) | "task: is from: since T305 (the tasks it came from)"),
       (if $k | has("summary") then (select($k.summary == "") | "its summary is empty")
        elif .title == "" then "it has no summary and no title"
        else "it has no summary" end),
       (if $k | has("project") | not then "it has no project"
        elif $projects != null and (IN($projects[]; $k.project) | not) then "project \($k.project | tojson) is not in projects.toml"
        else empty end),
       (if $k | has("priority") | not then "it has no priority (1, 2, 3 or 4)"
        elif $k.priority | test("^[1-4]$") | not then "priority \($k.priority | tojson) is not 1, 2, 3 or 4"
        else empty end),
       (if $k | has("size") | not then "it has no size (S, M or L)"
        elif IN(queue_sizes[]; $k.size) | not then "size \($k.size | tojson) is not S, M or L"
        else empty end),
       ($after[] | if .kind == "bad" then
          "after \(.text | tojson) is not T<n> merged, T<n> phase <k> merged, T<n> closed, a YYYY-MM-DD date or a queued file"
        elif .task != null then .task | queue_unknown("after"; $facts)
        elif .kind == "file" and (IN($queued[]; .file) or IN($left[]; .file) | not) then
          "after names \(.file), which is neither queued nor in a task's queued/"
        else empty end),
       (select($k.waits == "") | "its waits is empty"),
       ($from[] | if test(queue_task_re) then queue_unknown("from"; $facts) else "from \(tojson) is not T<n>" end),
       ($opened // empty | if test(queue_task_re) then queue_unknown("opened"; $facts) else "opened \(tojson) is not T<n>" end),
       ($takes[] | . as $t | if test(queue_file_re) | not then "takes \(tojson) is not a queued file"
        elif IN($queued[]; $t) | not then "takes \($t), which is not queued"
        else empty end),
       (select($k | has("alone")) | select($k.alone != "yes") | "alone \($k.alone | tojson) is not yes"),
       (select($end != null and ($now - ($end.ts | queue_seconds)) > queue_grace)
        | "\($opened) \($end.event) at \($end.ts) but it is still queued; the heartbeat's queue step moves it (team-queue tidy)")
     ])};

# Every queued item, its state derived: from the cards ($cards, in name order), the ledger's
# events, the registry's project names (null when it could not be read), the files that left the
# queue ($left, [{file, task}]), the queued files each task's plan cites ($cites, [{task, file}]),
# today (YYYY-MM-DD) and now (seconds). Each item is queue_item's, with its problems completed,
# citing (the open tasks whose plans cite it and that may take it: its project one of theirs, its
# from not naming them), unblocks (how many queued items' after: name it), rank (null here, set
# by queue_view), state (unranked, finished, opened, taken, waiting or ready) and reasons (why it
# waits).
def queue_items($cards; $events; $projects; $left; $cites; $today; $now):
  ($events | by_task) as $tasks
  | ($tasks | map_values(queue_task_facts)) as $facts
  | ($events | task_projects) as $task_projects
  | ([$cites[].task] | unique | map(select($tasks[.] | is_open))) as $open
  | [$cards[].file] as $queued
  | [$left[].file] as $gone
  | [$cards[] | queue_item($facts; $projects; $today; $queued; $gone; $now)] as $items
  | ($items | map({key: .file, value: .}) | from_entries) as $by_file
  | [$items[] | . as $i
    | ([$items[] | select(.file != $i.file and IN(.takes[]; $i.file)) | .file]) as $takers
    | ([$cites[] | select(.file == $i.file) | .task] | unique
       | map(select(. as $t | IN($open[]; $t) and (IN($i.from[]; $t) | not)
                    and IN($task_projects[$t][]?; $i.project)))
       | sort_by(.[1:] | tonumber)) as $citing
    | .problems += [
        (.takes[] | . as $t | $by_file[$t] // empty
         | if $t == $i.file then "takes itself"
           elif .takes != [] then "takes \($t), which takes others"
           elif .opened != null then "takes \($t), which \(.opened) opened"
           else empty end),
        (select($i.opened == null and $takers == [] and ($citing | length) > 1)
         | "cited by \($citing | map("\(.)'s") | if length == 2 then join(" and ") else (.[:-1] | join(", ")) + " and " + .[-1] end) plans: link it to one with team-queue take and give the other --part")]
    | .citing = $citing
    | .unblocks = ([$items[] | select(any(.after[]; .condition == $i.file))] | length)
    | .rank = null
    | .reasons = ([.waits // empty] + [.after[] | select(.met | not) | .condition])
    | .state = (if .problems != [] then "unranked"
                elif .finished != null then "finished"
                elif .opened != null then "opened"
                elif $takers != [] then "taken"
                elif .reasons != [] then "waiting"
                else "ready" end)];

# The order ready and waiting items rank in: priority, then more items waiting on it first, then
# size, then file name.
def queue_order: sort_by([.priority, -.unblocks, (.size as $s | queue_sizes | index($s)), .file]);

# The items by section: ready (ranked, rank 1 first), waiting (in the same order), opened (an
# opened or finished item, by task number), unranked (by name), and every item by file, taken
# ones included: {ready, waiting, opened, unranked, items}.
def queue_view:
  {ready: ([.[] | select(.state == "ready")] | queue_order | to_entries | map(.value + {rank: (.key + 1)})),
   waiting: ([.[] | select(.state == "waiting")] | queue_order),
   opened: ([.[] | select(IN(.state; "opened", "finished"))] | sort_by([(.opened[1:] | tonumber), .file])),
   unranked: [.[] | select(.state == "unranked")],
   items: (map({key: .file, value: .}) | from_entries)};

# What an item says of itself in the index: its summary, else its title.
def queue_what: if (.summary // "") != "" then .summary else .title end;

# An item's ranking facts in parentheses: "(proj, priority 1, M, guarded: ci, alone)".
def queue_label: "(\(.project), priority \(.priority), \(.size)\(if .guarded != null then ", guarded: \(.guarded)" else "" end)\(if .alone then ", alone" else "" end))";

# The lines under an item for each queued item it takes.
def queue_taken_lines($items): .takes[] | $items[.] // empty | "   - takes \(.file): \(queue_what)";

# The index, tasks/queued/index.md, as one string ending in a newline, from queue_view's object.
def queue_index_text:
  . as $v
  | [ "# Queued work",
      "",
      "Written by `team-queue index` from each file's front matter and the ledger; edit the files, never this index.",
      (select($v.ready != []) | "", "## Ready, ranked", "",
       ($v.ready[] | "\(.rank). \(.file) \(queue_label): \(queue_what)", queue_taken_lines($v.items))),
      (select($v.waiting != []) | "", "## Waiting", "",
       ($v.waiting[] | "- \(.file) \(queue_label): \(queue_what); waits for \(.reasons | join(", "))", queue_taken_lines($v.items))),
      (select($v.opened != []) | "", "## Opened", "",
       ($v.opened[] | "- \(.file) (\(.project), \(.opened)): \(queue_what)", queue_taken_lines($v.items))),
      (select($v.unranked != []) | "", "## Unranked", "",
       ($v.unranked[] | "- \(.file): \(.problems | join("; "))", queue_taken_lines($v.items)))
    ] | join("\n") + "\n";

# The lines team-queue index --check prints, from the items: the registry's when it could not be
# read ($registry_error, else ""), then each item's problems in name order.
def queue_problem_lines($registry_error):
  (select($registry_error != "") | "tasks/queued/: projects not checked: \($registry_error)"),
  (.[] | .file as $f | .problems[] | "tasks/queued/\($f): \(.)");
