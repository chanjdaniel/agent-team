# The queue of approved work, the team home's tasks/queued/: what each item's state is, when an
# after: condition is met, how the items rank, the problems team-queue index --check names, the text
# of the index, the judging of team-queue set's table, of team-queue take and of team-queue tidy's
# links and moves, whether the level has room for one more task and team-queue list's object and
# findings. Used by team-queue over the ledger's lines (jq -nR), with the items' cards (team-queue's
# one awk pass: {file, title, keys, problems}), the registry's project names, the items that left
# the queue, the queued files the tasks' plans cite, today's UTC date, the time now, and for list
# team-capacity's plan and costs; team-queue's header documents the keys, the states and the words.
include "ledger";

# The front matter keys, in the order team-queue writes them.
def queue_keys: ["summary", "project", "priority", "size", "after", "waits", "from", "opened", "takes", "alone", "guarded"];

# The sizes, smallest first, which is their rank.
def queue_sizes: ["S", "M", "L"];

# Seconds a finished item may stay queued before --check names it: three heartbeat runs.
def queue_grace: 900;

def queue_task_re: "^T[1-9][0-9]*$";
def queue_file_re: "^[A-Za-z0-9][A-Za-z0-9._-]*\\.md$";

# A string less its leading and trailing spaces.
def queue_trim: sub("^ +"; "") | sub(" +$"; "");

# A comma-joined value as its parts, each trimmed.
def queue_parts: split(",") | map(queue_trim);

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

# What the ledger says of one task's events: whole, whether it is merged whole, which is the
# ledger's own lifecycle (bin/lib/ledger.jq) left in its merged phase, so a merge logged with no
# phases_left (before team-merge logged them) that a builder launch, a later PR or a merged part
# follows is none, or, once the task closed, any merged that names no phase left (phases_left []
# or absent, as team-merge logs a task with no tickets), whatever followed it; each merged's phases_left where it names them; and the events that
# end it, its last merged when it is merged whole and its closed, the earliest first; and unmerged,
# its last closed's {ts} when a feature, bug or small task (its latest opened's path) closed not
# merged whole, which leaves its work unbuilt, else null (a research or retro task finishes by
# closing, and a task with no path is read as one).
def queue_task_facts:
  (lifecycle.phase == "merged"
   or (any(.[]; .event == "closed") and any(.[]; .event == "merged" and (.phases_left // []) == []))) as $whole
  | (last(.[] | select(.event == "opened") | .path) // null) as $path
  | {whole: $whole,
     merges: [.[] | select(.event == "merged") | .phases_left | arrays],
     ends: ([(select($whole) | last(.[] | select(.event == "merged")) | {event, ts}),
             (.[] | select(.event == "closed") | {event, ts})] | sort_by(.ts)),
     unmerged: (if $whole or (IN($path; "feature", "bug", "small") | not) then null
                else last(.[] | select(.event == "closed") | {ts}) // null end)};

# Whether a parsed condition is met, given the tasks' facts, today's date, the queued files and
# the files that left the queue: a phase is merged once a merged names phases left without it, or
# the task is merged whole.
def queue_met($facts; $today; $queued; $left):
  if .kind == "merged" then $facts[.task].whole // false
  elif .kind == "phase" then . as $c | $facts[.task] // {} | .whole or any(.merges[]?; IN(.[]; $c.phase) | not)
  elif .kind == "closed" then any($facts[.task].ends[]?; .event == "closed")
  elif .kind == "date" then $today >= .date
  elif .kind == "file" then (IN($queued[]; .file) | not) and IN($left[]; .file)
  else false end;

# A problem as a fault, {key, problem}: the front matter key it is about, or null for one no key's
# value causes (the form's, a finished item still queued, two plans citing it), which tells
# team-queue set's refusals from what it leaves to the files.
def queue_fault($key): {key: $key, problem: .};

# The problem "<key> names T<n>, which the ledger does not hold", for a task the ledger lacks.
def queue_unknown($key; $facts): select($facts[.] == null) | "\($key) names \(.), which the ledger does not hold";

# One queued item from its card: its keys read, its own problems as faults (queue_fault), and its
# after: conditions judged; the problems and state that need the other items come in queue_items.
def queue_item($facts; $projects; $today; $queued; $left; $now):
  .keys as $k
  | ($k.after // null | if . == null then [] else queue_parts | map(queue_condition) end) as $after
  | ($k.from // null | if . == null then [] else queue_parts end) as $from
  | ($k.takes // null | if . == null then [] else queue_parts end) as $takes
  | ($k.opened // null) as $opened
  | (if $opened != null and ($opened | test(queue_task_re)) then $facts[$opened] // {} else {} end) as $of
  | (if $of.unmerged != null then null else $of.ends[0]? // null end) as $end
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
     faults: ([.problems[] | queue_fault(null)] + [
       ($k | keys_unsorted[] | select(IN(queue_keys[]; .) | not) | select(. != "task") | . as $u
        | "front matter key \(tojson) is none team-queue reads (team-queue --help)" | queue_fault($u)),
       (select($k | has("task")) | "task: is from: since T305 (the tasks it came from)" | queue_fault("task")),
       ((if $k | has("summary") then (select($k.summary == "") | "its summary is empty")
         elif .title == "" then "it has no summary and no title"
         else "it has no summary" end) | queue_fault("summary")),
       ((if $k | has("project") | not then "it has no project"
         elif $projects != null and (IN($projects[]; $k.project) | not) then "project \($k.project | tojson) is not in projects.toml"
         else empty end) | queue_fault("project")),
       ((if $k | has("priority") | not then "it has no priority (1, 2, 3 or 4)"
         elif $k.priority | test("^[1-4]$") | not then "priority \($k.priority | tojson) is not 1, 2, 3 or 4"
         else empty end) | queue_fault("priority")),
       ((if $k | has("size") | not then "it has no size (S, M or L)"
         elif IN(queue_sizes[]; $k.size) | not then "size \($k.size | tojson) is not S, M or L"
         else empty end) | queue_fault("size")),
       ($after[] | if .kind == "bad" then
          "after \(.text | tojson) is not T<n> merged, T<n> phase <k> merged, T<n> closed, a YYYY-MM-DD date or a queued file"
        elif .task != null then .task | queue_unknown("after"; $facts)
        elif .kind == "file" and (IN($queued[]; .file) or IN($left[]; .file) | not) then
          "after names \(.file), which is neither queued nor in a task's queued/"
        else empty end | queue_fault("after")),
       (select($k.waits == "") | "its waits is empty" | queue_fault("waits")),
       ($from[] | if test(queue_task_re) then queue_unknown("from"; $facts) else "from \(tojson) is not T<n>" end | queue_fault("from")),
       ($opened // empty | if test(queue_task_re) then queue_unknown("opened"; $facts) else "opened \(tojson) is not T<n>" end
        | queue_fault("opened")),
       ($of.unmerged // empty
        | "opened names \($opened), which closed at \(.ts) with no whole merge: remove opened: to queue it again, or delete the file"
        | queue_fault("opened")),
       ($takes[] | . as $t | if test(queue_file_re) | not then "takes \(tojson) is not a queued file"
        elif IN($queued[]; $t) | not then "takes \($t), which is not queued"
        else empty end | queue_fault("takes")),
       (select($k | has("alone")) | select($k.alone != "yes") | "alone \($k.alone | tojson) is not yes" | queue_fault("alone")),
       (select($end != null and ($now - ($end.ts | queue_seconds)) > queue_grace)
        | "\($opened) \($end.event) at \($end.ts) but it is still queued; the heartbeat's queue step moves it (team-queue tidy)"
        | queue_fault(null))
     ])};

# Every queued item, its state derived: from the cards ($cards, in name order), the ledger's
# events, the registry's project names (null when it could not be read), the files that left the
# queue ($left, [{file, task}]), the queued files each task's plan cites ($cites, [{task, file}]),
# today (YYYY-MM-DD) and now (seconds). Each item is queue_item's, with its faults completed,
# problems (their texts, in order), citing (the open tasks whose plans cite it and that may take it: its project one of theirs, its
# from not naming them), unblocks (how many queued items' after: name it), rank (null here, set
# by queue_view), state (unranked, finished, opened, taken, waiting or ready) and reasons (why it
# waits).
def queue_items($cards; $events; $projects; $left; $cites; $today; $now):
  ($events | by_task) as $tasks
  # The lifecycle is folded only for the tasks an item's after: or opened: names; every other task
  # the ledger holds gets {}, which says only that it holds it.
  | ([$cards[].keys | ((.after // "" | queue_parts[] | queue_condition | .task // empty), (.opened // empty))] | unique) as $named
  | (reduce $named[] as $t ($tasks | map_values({});
      if $tasks[$t] == null then . else .[$t] = ($tasks[$t] | queue_task_facts) end)) as $facts
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
    | .faults += [
        (.takes[] | . as $t | $by_file[$t] // empty
         | if $t == $i.file then "takes itself"
           elif .takes != [] then "takes \($t), which takes others"
           elif .opened != null then "takes \($t), which \(.opened) opened"
           else empty end
         | queue_fault("takes")),
        (select($i.opened == null and $takers == [] and $i.waits == null and all($i.after[]; .met) and ($citing | length) > 1)
         | "cited by \($citing | map("\(.)'s") | if length == 2 then join(" and ") else (.[:-1] | join(", ")) + " and " + .[-1] end) plans: link it to one with team-queue take and give the other --part"
         | queue_fault(null))]
    | .problems = [.faults[].problem]
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
# opened or finished item, by task number), unranked (by name, a taken one too, which the index
# also lists under its takers), and every item by file, taken ones included: {ready, waiting,
# opened, unranked, items}.
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

# The index's sections as lines, each section opening with a blank line, from queue_view's object:
# Ready, ranked; Waiting; Opened; Unranked; a section with no item left out.
def queue_section_lines:
  . as $v
  | (select($v.ready != []) | "", "## Ready, ranked", "",
     ($v.ready[] | "\(.rank). \(.file) \(queue_label): \(queue_what)", queue_taken_lines($v.items))),
    (select($v.waiting != []) | "", "## Waiting", "",
     ($v.waiting[] | "- \(.file) \(queue_label): \(queue_what); waits for \(.reasons | join(", "))", queue_taken_lines($v.items))),
    (select($v.opened != []) | "", "## Opened", "",
     ($v.opened[] | "- \(.file) (\(.project), \(.opened)): \(queue_what)", queue_taken_lines($v.items))),
    (select($v.unranked != []) | "", "## Unranked", "",
     ($v.unranked[] | "- \(.file): \(.problems | join("; "))", queue_taken_lines($v.items)));

# The index, tasks/queued/index.md, as one string ending in a newline, from queue_view's object.
def queue_index_text:
  [ "# Queued work",
    "",
    "Written by `team-queue index` from each file's front matter and the ledger; edit the files, never this index.",
    queue_section_lines
  ] | join("\n") + "\n";

# The problems team-queue index --check names but the stale index's, from the items, as
# {file, problem}: the registry's first when it could not be read ($registry_error, else ""), its
# file null, then each item's in name order.
def queue_problems($registry_error):
  [(select($registry_error != "") | {file: null, problem: "projects not checked: \($registry_error)"}),
   (.[] | .file as $f | .problems[] | {file: $f, problem: .})];

# A problem as --check prints it, "tasks/queued/<file>: <reason>", or "tasks/queued/: <reason>"
# for one of no file.
def queue_problem_line: "tasks/queued/\(.file // ""): \(.problem)";

# The lines team-queue index --check prints, from the items: queue_problems', each as a line.
def queue_problem_lines($registry_error): queue_problems($registry_error)[] | queue_problem_line;

# "<n> <word>s", or "1 <word>": queue_count($word)
def queue_count($word): "\(.) \($word)\(if . == 1 then "" else "s" end)";

# A front matter's keys in the order team-queue writes them: queue_keys' order, then the others
# in theirs.
def queue_ordered:
  . as $k
  | [(queue_keys[] | select(. as $q | $k | has($q)) | {key: ., value: $k[.]}),
     ($k | to_entries[] | select(IN(queue_keys[]; .key) | not))]
  | from_entries;

# A front matter as written, from its keys in their order: "---", a "<key>: <value>" line each,
# "---", a newline after each line.
def queue_front: "---\n" + ([to_entries[] | "\(.key): \(.value)\n"] | add // "") + "---\n";

# team-queue set's judging of a table, $table its text and $name its path as given, against the
# queued files' cards ($cards), items being queue_items over the cards given as its input:
# {refusals, writes}. The table is tab-separated, a carriage return ending a line dropped and each
# cell trimmed; its header's first column is file and its others are front matter keys, each once;
# each line after it but a blank one is a row, as many cells as the header, naming a queued file
# once, whose front matter set can rewrite (a form problem would lose a line). A row's file gets its
# keys with task: dropped, each column's key set to the row's cell or, for an empty cell, removed,
# the keys in queue_keys' order and then the file's others; a fault of the result whose key is one
# of the table's columns refuses the row. refusals are "<name>:<line>: <reason>" in line order,
# the header's alone when it is refused; writes, only when there is no refusal, are each row's
# {file, front}, its front matter from "---" to "---" with a newline after each line.
def queue_set($table; $name; $cards; items):
  ($table | split("\n") | map(rtrimstr("\r"))) as $lines
  | if $lines == [] then {refusals: ["\($name):1: the table has no header line"], writes: []} else
    ($lines[0] | split("\t") | map(queue_trim)) as $header
    | [(select($header[0] != "file") | "the header's first column is \($header[0] | tojson), not file"),
       ($header | to_entries | .[1:][] | .key as $i | .value as $c
        | if IN($header[:$i][]; $c) then "column \($c | tojson) is given twice"
          elif IN(queue_keys[]; $c) | not then "column \($c | tojson) is no front matter key (team-queue --help)"
          else empty end)
      | "\($name):1: \(.)"] as $bad_header
    | if $bad_header != [] then {refusals: $bad_header, writes: []} else
      ($cards | map({key: .file, value: .}) | from_entries) as $by_file
      | [$lines | to_entries | .[1:][] | select(.value != "")
         | {line: (.key + 1), cells: (.value | split("\t") | map(queue_trim))}] as $rows
      | [$rows[] | . as $r | .cells[0] as $f
         | {line, cells, file: $f, refusals: [
             if (.cells | length) != ($header | length) then
               "it has \(.cells | length | queue_count("cell")) and the header \($header | length)"
             elif $by_file[$f] == null then "\($f) is not queued"
             else (first($rows[] | select(.line < $r.line and .cells[0] == $f) | .line) // null) as $twice
               | if $twice != null then "\($f) is on line \($twice) too"
                 else $by_file[$f].problems[] | "tasks/queued/\($f): \(.), which set cannot rewrite: fix the file by hand first" end
             end]}] as $judged
      | [$judged[] | select(.refusals == []) | . as $r | $by_file[.file] as $card
         | ($card.keys | del(.task)
            | reduce ($header | to_entries | .[1:][]) as $c (.;
                if $r.cells[$c.key] == "" then del(.[$c.value]) else .[$c.value] = $r.cells[$c.key] end)
            | queue_ordered) as $keys
         | {file, card: ($card + {keys: $keys})}] as $sets
      | ($sets | map({key: .file, value: .card}) | from_entries) as $new
      | ([$cards[] | $new[.file] // .] | items | map({key: .file, value: .}) | from_entries) as $result
      | $header[1:] as $columns
      | [$judged[] | .file as $f | .line as $n
         | (.refusals[] | "\($name):\($n): \(.)"),
           (select(.refusals == []) | $result[$f].faults[] | select(.key != null and IN($columns[]; .key))
            | "\($name):\($n): tasks/queued/\($f): \(.problem)")] as $refusals
      | {refusals: $refusals,
         writes: (if $refusals != [] then [] else
           [$sets[] | {file, front: (.card.keys | queue_front)}] end)}
    end
  end;

# <bytes> as GiB with one decimal place: "11.7 GiB".
def queue_gib: "\((. / 1073741824 * 10 | round) / 10 | tostring | if test("\\.") then . else . + ".0" end) GiB";

# The level as the room says it, from a team-capacity-plan/1 object: "full (90%)".
def queue_at: "\(.level) (\(.share * 100 | round)%)";

# A team-capacity --json object read from its raw text, $name saying where it came from: the
# object when its schema is $schema, {error} as given (the caller's {error} for a run that
# failed), else {error} naming it as no $schema object.
def queue_capacity($name; $schema):
  (try fromjson catch null)
  | if type == "object" and (.error | type) == "string" then {error}
    elif type == "object" and .schema == $schema then .
    else {error: "\($name) is no \($schema) object"} end;

# The open tasks whose latest opened no launch follows, [{task, ts}] by task number, from the
# events by task (by_task's object).
def queue_unstaffed($tasks):
  [$tasks | to_entries[] | .key as $t | .value
   | (last(to_entries[] | select(.value.event == "opened")) // null) as $o
   | select($o != null and (any(.[$o.key + 1:][]; .event == "launch") | not))
   | select(is_open)
   | {task: $t, ts: $o.value.ts}]
  | sort_by(.task[1:] | tonumber);

# Whether the level has room for one more task, {fits, says}, from team-capacity plan --json's
# object ($plan, {error} when it could not be read), costs --json's ($costs, alike), the events by
# task ($tasks) and today (YYYY-MM-DD): it fits when the level is not none, the plan has a budget
# and is not over it, no task waits to resume or to launch (stowed and refused work comes first,
# but for work something holds, a hold the plan gives, which it will not relaunch),
# the budget less what is reserved is at least a builder's estimate (every task soon launches
# one, the largest worker a task starts), and no open task has an opened with no launch since (a
# task just opened gets its first worker before the next is named), the first that fails saying
# why.
def queue_room($plan; $costs; $tasks; $today):
  def no($why): {fits: false, says: "no room: \($why)"};
  if $plan.error != null then no("the plan cannot be read: \($plan.error)")
  elif $plan.level == "none" then no("the level is none")
  elif $plan.budget == null then no("no reading of the machine's load, so no budget")
  elif $plan.over then no("over budget")
  elif any($plan.resume[]?; .hold == null) then no("\(first($plan.resume[] | select(.hold == null)).task) waits to resume")
  elif any($plan.launch[]?; .hold == null) then no("\(first($plan.launch[] | select(.hold == null)).task) waits to launch")
  elif $costs.error != null then no("the costs cannot be read: \($costs.error)")
  else
    (first($costs.costs[]? | select(.kind == "session:builder") | .estimate_bytes | numbers) // null) as $need
    | ($plan.budget - $plan.reserved) as $free
    | if $need == null then no("the costs give no builder's estimate")
      elif $free < $need then no("\($free | queue_gib) free at \($plan | queue_at), a builder needs \($need | queue_gib)")
      else
        (queue_unstaffed($tasks) | first(.[]) // null) as $u
        | if $u != null then
            no("\($u.task), opened at \($u.ts | if .[:10] == $today then .[11:16] else "\(.[:10]) \(.[11:16])" end), has no worker yet")
          else
            {fits: true,
             says: "room for one more task at \($plan | queue_at): \($free | queue_gib) of \($plan.budget | queue_gib) free, a builder needs \($need | queue_gib)"}
          end
      end
  end;

# An item as team-queue list --json gives it, its internal fields left out.
def queue_list_item: {file, title, summary, project, priority, size, after, waits, from, opened, takes, alone, guarded, unblocks, rank};

# team-sweep's queue findings, each with task, session and name null, from the room
# (queue_room's), queue_view's object, the problems (queue_problems') and the events by task:
# queue-ready while the room fits and an item is ready, naming the top one and the command that
# opens it, and for an item that runs alone the project's other open tasks to hold first; queue
# while there are problems, their count and the first two.
def queue_findings($room; $view; $problems; $tasks):
  (select($room.fits and $view.ready != []) | $view.ready[0]
   | . as $top
   | (queue_what | if length > 80 then .[:77] + "..." else . end) as $what
   | ([select($top.alone) | $tasks | to_entries[] | .key as $t | .value
       | select(IN((task_projects | .[$t] // [])[]; $top.project)) | select(is_open) | $t]
      | sort_by(.[1:] | tonumber)) as $others
   | "team-open --queued \(.file)" as $next
   | {task: null, kind: "queue-ready", session: null, name: null, next: $next,
      text: "queue: \($room.says): open \(.file) (\(.project), priority \(.priority), \(.size)): \($what)\(
        if $others != [] then "; it runs alone: hold \(.project)'s other open tasks (\($others | join(", "))) first" else "" end); next: \($next)"}),
  (select($problems != []) | "fix each file team-queue index --check names" as $next
   | {task: null, kind: "queue", session: null, name: null, next: $next,
      text: "queue: \($problems | length | queue_count("problem")) in tasks/queued/: \($problems[:2] | map(queue_problem_line) | join("; ")); next: \($next)"});

# team-queue list's object, team-queue/1, from the items and the inputs queue_room and
# queue_findings take: {schema, room, ready, waiting, opened, unranked, problems, findings}.
def queue_list($plan; $costs; $events; $registry_error; $today):
  ($events | by_task) as $tasks
  | queue_view as $view
  | queue_room($plan; $costs; $tasks; $today) as $room
  | queue_problems($registry_error) as $problems
  | {schema: "team-queue/1", room: $room,
     ready: [$view.ready[] | queue_list_item],
     waiting: [$view.waiting[] | queue_list_item],
     opened: [$view.opened[] | queue_list_item],
     unranked: [$view.unranked[] | {file, problems}],
     problems: $problems,
     findings: [queue_findings($room; $view; $problems; $tasks)]};

# team-queue list's text from its object and queue_view's: the room's line, then the index's
# sections, ending in a newline.
def queue_list_text($view): [.room.says, ($view | queue_section_lines)] | join("\n") + "\n";

# team-queue take's judging of T<n> ($task) taking the queued files $files (names, as given),
# or with $part building part of each, against the cards ($cards), the ledger's events and the
# items (queue_items'): {refusals, writes}. It refuses a task with no opened or with a closed, and
# each file not queued, whose front matter it cannot rewrite without losing a line (a form
# problem), whose project is none of the task's (its opened's and worktree-added's; not judged
# for a task with no opened), and, but with
# $part, one another task opened or another item takes. refusals are lines in that order, the
# task's first; writes, only when there is none, are each file's {file, front}: its keys with
# opened set to the task, or with $part the task added to from once, written in queue_keys' order.
def queue_take($task; $files; $part; $cards; $events; $items):
  ($events | by_task | .[$task] // []) as $te
  | ($events | task_projects | .[$task] // []) as $projects
  | ($cards | map({key: .file, value: .}) | from_entries) as $by_file
  | ($items | map({key: .file, value: .}) | from_entries) as $item
  | ($files | reduce .[] as $f ([]; if IN(.[]; $f) then . else . + [$f] end)) as $files
  | any($te[]; .event == "opened") as $opened
  | [(if $opened | not then "\($task) has no opened in the ledger"
      else (last($te[] | select(.event == "closed")) // null | select(. != null) | "\($task) closed at \(.ts)") end),
     ($files[] | . as $f | $item[$f] as $i
      | if $by_file[$f] == null then "\($f) is not queued"
        else
          ($by_file[$f].problems[] | "tasks/queued/\($f): \(.), which take cannot rewrite: fix the file by hand first"),
          (if $opened | not then empty
           elif $i.project == null then "tasks/queued/\($f): it has no project, so it is none of \($task)'s"
           elif IN($projects[]; $i.project) | not then
             "tasks/queued/\($f): its project \($i.project) is none of \($task)'s (\($projects | if . == [] then "none" else join(", ") end))"
           else empty end),
          (select($part | not)
           | (select($i.opened != null and $i.opened != $task)
              | "tasks/queued/\($f): \($i.opened) opened it; give --part when \($task) builds part of it"),
             ([$items[] | select(.file != $f and IN(.takes[]; $f)) | .file] as $takers
              | select($takers != [])
              | "tasks/queued/\($f): \($takers | join(", ")) \(if ($takers | length) == 1 then "takes" else "take" end) it; give --part when \($task) builds part of it"))
        end)] as $refusals
  | {refusals: $refusals,
     writes: (if $refusals != [] then [] else
       [$files[] | . as $f | $by_file[$f].keys
        | if $part then .from = ((.from // "" | if . == "" then [] else queue_parts end) | if IN(.[]; $task) then . else . + [$task] end | join(", "))
          else .opened = $task end
        | {file: $f, front: (queue_ordered | queue_front)}] end)};

# team-queue tidy's judging, over the queued files' cards ($cards, in name order), their items
# ($items, queue_items') and the files that left the queue ($left, [{task, file}]), items_over being
# queue_items over its input [<cards>, <left>]: {links, moves, index, same}. links are each item
# that is not opened, that no other item takes, that waits on nothing (no waits:, every after:
# met, since a plan cites a waiting item for what lands before it or after it), whose front matter
# take can rewrite and that exactly one open task may take by its plan's citing (queue_items'
# citing), linked to that task, {file, task, front} in name order; moves, judged once the links are written, are each finished item,
# {file, task, why: "T<n> merged" or "T<n> closed"}, followed by each file it takes that is queued,
# not finished itself, opened by no task and taken by no item that stays nor by an earlier one
# leaving, {file, task, why: "<taker> takes it"}; index is the index's text once the links and moves
# are made, and same whether it is the index as it is ($current).
def queue_tidy($cards; $items; $left; $current; items_over):
  ($cards | map({key: .file, value: .}) | from_entries) as $by_card
  | [$items[] | . as $i
     | select(.opened == null and (.citing | length) == 1 and $by_card[.file].problems == [])
     | select(.waits == null and all(.after[]; .met))
     | select(any($items[]; .file != $i.file and IN(.takes[]; $i.file)) | not)
     | {file, task: .citing[0],
        front: ($by_card[.file].keys | .opened = $i.citing[0] | queue_ordered | queue_front)}] as $links
  | ($links | map({key: .file, value: .task}) | from_entries) as $linked
  | (if $links == [] then $cards else [$cards[] | if $linked[.file] then .keys.opened = $linked[.file] else . end] end) as $cards
  | (if $links == [] then $items else [$cards, $left] | items_over end) as $items
  | [$items[] | select(.finished != null)] as $leaving
  | [$items[] | select(.finished == null)] as $staying
  | ($items | map({key: .file, value: .}) | from_entries) as $by_file
  | (reduce $leaving[] as $f ([];
      . as $moves
      | . + [{file: $f.file, task: $f.finished.task, why: "\($f.finished.task) \($f.finished.event)"}]
          + [$f.takes[] | . as $t | $by_file[$t] // empty
             | select(.finished == null and .opened == null)
             | select(any($staying[]; IN(.takes[]; $t)) | not)
             | select(any($moves[]; .file == $t) | not)
             | {file: $t, task: $f.finished.task, why: "\($f.file) takes it"}])) as $moves
  | (if $moves == [] then $items
     else [[$cards[] | select(.file as $c | any($moves[]; .file == $c) | not)], $left + [$moves[] | {task, file}]] | items_over end) as $items
  | ($items | queue_view | queue_index_text) as $index
  | {links: [$links[] | {file, task, front}], moves: $moves, index: $index, same: ($index == $current)};
