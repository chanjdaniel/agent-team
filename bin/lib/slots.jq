# The definitions team-slots reads the machine's task slots with: the settings of slots.json,
# the slots held, the room each side has, and the texts. jq 1.7.
# Included as: jq -L bin/lib 'include "slots"; ...'
include "stack";
include "ledger";

# The machine's slot settings (~/.config/agent-team/slots.json), every key optional, each with its
# default and its kind (settings_problems in stack.jq).
def slots_defaults:
  {cap: 6, reserved: 1, dynamic: true, task_gib: 1.25, reserve_gib: 6, task_cores: 0.5, reserve_cores: 2,
   window_minutes: 15, wait_minutes: 15};
def slots_kinds:
  {cap: "count", reserved: "count0", dynamic: "boolean", task_gib: "positive", reserve_gib: "amount",
   task_cores: "positive", reserve_cores: "amount", window_minutes: "count", wait_minutes: "amount"};

# What is wrong with slots.json's JSON values (read with jq -s), to follow its name, as
# settings_problems says it, then reserved not below cap (either one's default included).
def slots_problems:
  settings_problems(slots_kinds) as $problems
  | if $problems != "" then $problems
    else (slots_defaults + .[0]) as $s
      | if $s.reserved < $s.cap then "" else ": reserved must be less than cap (\($s.cap)), not \($s.reserved)" end
    end;

# Every setting, the given ones (slots.json's one object, or none) over the defaults, with from:
# each key's source, "slots.json" or "default".
def slots_settings:
  (.[0] // {}) as $given
  | slots_defaults + $given
    + {from: (slots_defaults | with_entries(.key as $key | .value = (if $given | has($key) then "slots.json" else "default" end)))};

# The task T<n> a task's branch, <type>/T<n>-<slug> with one of team-open's types, names; nothing
# for any other branch.
def task_branch_task:
  capture("^(feat|fix|docs|chore|build|ci|test|refactor|perf|research)/(?<task>T[1-9][0-9]*)-[a-z0-9]+(-[a-z0-9]+)*$")
  | .task;

# The slots held, from the ledger's events <events> (an array, ledger order) and the registered
# worktrees <worktrees> of every registered project's primary checkout but the checkout itself,
# each {project, branch, worktree}: one {task, project, worktree, half_open} per open worktree of
# an open task (open_worktrees, its path on this machine, whose home is <home>), and per registered
# worktree on a task's branch whose task has no closed event and no open worktree of that project
# (half open), by task number, then project.
def held_slots($events; $worktrees; $home):
  ($events | by_task) as $tasks
  | [open_worktrees($events[] | select($tasks[.task] | is_open); $home) | {task, project, worktree, half_open: false}]
    as $open
  | $open
    + [$worktrees[] | (.branch | task_branch_task) as $task | .project as $project
      | select(($tasks[$task] // [] | any(.[]; .event == "closed")) | not)
      | select(any($open[]; .task == $task and .project == $project) | not)
      | {task: $task, project, worktree, half_open: true}]
  | sort_by((.task[1:] | tonumber), .project, .worktree);

# Whether a reading has the parts the effective cap reads: its time, its memory's total and
# others, and its CPU's count and others or null.
def well_formed_reading:
  try (type == "object" and (.at | type == "string" and (fromdateiso8601 | type == "number"))
       and (.memory.total | type == "number") and (.memory.others | type == "number")
       and (.cpu == null or ((.cpu.cpus | type == "number") and (.cpu.others | type == "number"))))
  catch false;

# The readings file's lines (an array of strings), as {readings: the well-formed ones, oldest
# first, broken: how many lines are not}; a blank line is neither.
def slots_readings:
  map(select(test("\\S")) | try fromjson catch null | if well_formed_reading then . else null end)
  | {readings: (map(select(. != null)) | sort_by(.at | fromdateiso8601)), broken: (map(select(. == null)) | length)};

# <n> written with one decimal place, 18.0 for 18.
def one_decimal:
  (. * 10 | round) as $tenths | "\($tenths / 10 | floor).\($tenths % 10)";

# "<n> <one>" or "<n> <many>", by <n>.
def counted($n; $one; $many):
  "\($n) \(if $n == 1 then $one else $many end)";

# A reading's time, as HH:MM in the local time zone.
def reading_time:
  .at | fromdateiso8601 | strflocaltime("%H:%M");

# How many tasks the machine carries beside the other programs at a reading, by the settings <s>:
# {fit, by}, the lower of memory's and the CPU's (memory's alone when the CPU was not read), never
# below 0, and by the resource that sets it, "memory" or "cpu".
def reading_fit($s):
  ((.memory.total - .memory.others - $s.reserve_gib * 1073741824) / ($s.task_gib * 1073741824) | floor) as $memory
  | (if .cpu == null then null else (.cpu.cpus - .cpu.others - $s.reserve_cores) / $s.task_cores | floor end) as $cpu
  | if $cpu != null and $cpu < $memory then {fit: ([$cpu, 0] | max), by: "cpu"}
    else {fit: ([$memory, 0] | max), by: "memory"} end;

# The memory the other programs use at a reading, and the CPU.
def memory_use:
  "\(.memory.others / 1073741824 | one_decimal) GiB of \(.memory.total / 1073741824 | one_decimal) GiB";
def cpu_use:
  "\(.cpu.others | one_decimal) of \(counted(.cpu.cpus; "core"; "cores"))";

# What the other programs use at a reading.
def others_text:
  "other programs use \(memory_use)" + (if .cpu == null then "" else " and \(cpu_use)" end);

# The effective cap from the settings <s>, the slots kept <kept> for the reserved project
# <project>, and the readings <readings> (slots_readings), as {cap, lowered_by, reason, readings
# (the window's)}. A reading's confirmed fit is the higher of its fit and the previous reading's
# (the one before the window for the window's first), so a lower number holds only once two
# readings in a row show it; the cap is the lowest confirmed fit in the window, at most the cap and
# never below <kept>. With dynamic false, or no reading in the window, it is the cap.
def effective_cap($s; $kept; $project; $readings):
  (now - $s.window_minutes * 60) as $since
  | [$readings[] | select(.at | fromdateiso8601 >= $since)] as $window
  | if $s.dynamic == false then
      {cap: $s.cap, lowered_by: null, reason: "dynamic sizing is off (dynamic in slots.json)", readings: $window}
    elif $window == [] then
      {cap: $s.cap, lowered_by: null,
       reason: (if $readings == [] then "no reading of the machine's load yet"
                else "no reading of the machine's load in the last \(counted($s.window_minutes; "minute"; "minutes"))" end),
       readings: []}
    else
      ([$readings[] | select(.at | fromdateiso8601 < $since)] | last) as $before
      | [range($window | length) as $i
         | (if $i == 0 then $before else $window[$i - 1] end) as $previous
         | select($previous != null)
         | ($previous | reading_fit($s) + {reading: .}) as $earlier
         | ($window[$i] | reading_fit($s) + {reading: .}) as $later
         | (if $earlier.fit > $later.fit then $earlier else $later end) + {times: [$previous, $window[$i]] | map(reading_time)}]
      | (map(.fit) | min) as $low
      | if $low == null or $low >= $s.cap then
          {cap: $s.cap, lowered_by: null, reason: ($window[-1] | "\(others_text) (the reading of \(reading_time))"), readings: $window}
        else
          (map(select(.fit == $low)) | last) as $pair
          | $pair.reading as $r
          | {cap: ([$low, $kept] | max), lowered_by: $pair.by,
             reason: ((if $pair.by == "memory" then
                         "lowered by memory: other programs use \($r | memory_use), leaving room for \(counted($low; "task"; "tasks")) of \($s.task_gib) GiB after \($s.reserve_gib) GiB kept"
                       else
                         "lowered by CPU: other programs use \($r | cpu_use), leaving room for \(counted($low; "task"; "tasks")) of \(counted($s.task_cores; "core"; "cores")) after \(counted($s.reserve_cores; "core"; "cores")) kept"
                       end)
                      + " (the readings of \($pair.times[0]) and \($pair.times[1]))"
                      + (if $low < $kept then ", and never below the \($kept) kept for \($project)" else "" end)),
             readings: $window}
        end
    end;

# The team-slots/1 object, from $in: {given (slots.json's values read with jq -s, [] with none),
# machine (null without a name), reserved_project (null with none), held (held_slots), readings
# (slots_readings's readings)}.
def slots_status($in):
  ($in.given | slots_settings) as $s
  | $in.reserved_project as $project
  | (if $project == null then 0 else $s.reserved end) as $reserved
  | effective_cap($s; $reserved; $project; $in.readings) as $effective
  | ($in.held | length) as $held
  | ([$in.held[] | select(.project == $project)] | length) as $reserved_held
  | ($held - $reserved_held) as $others_held
  | ([$effective.cap - $held, 0] | max) as $free
  | {schema: "team-slots/1", machine: $in.machine, settings: $s, reserved_project: $project, effective: $effective,
     held: $in.held, counts: {held: $held, reserved_held: $reserved_held, others_held: $others_held},
     room: {reserved: (if $project == null then null else $free end),
            others: ([[$free, $effective.cap - $reserved - $others_held] | min, 0] | max)},
     stale: ($in.readings == [] or ($in.readings[-1].at | fromdateiso8601) < now - 15 * 60)};

# <path> with ~ for the home directory <home>.
def tilde($home):
  if . == $home then "~" elif startswith($home + "/") then "~" + .[($home | length):] else . end;

# The cap line of the team-slots/1 object: the cap, where it came from, and the effective cap's
# reason.
def cap_text:
  .settings as $s
  | "the cap is \($s.cap) "
    + (if $s.from.cap == "slots.json" then "(cap in ~/.config/agent-team/slots.json)"
       else "(the default: ~/.config/agent-team/slots.json sets no cap)" end)
    + ", effective \(.effective.cap): \(.effective.reason)";

# One line per held slot of the team-slots/1 object, given the home directory <home>.
def held_text($home):
  .held[] | "  \(.task) \(.project) in \(.worktree | tilde($home))\(if .half_open then " (half open)" else "" end)";

# team-slots status's lines from the team-slots/1 object, given the home directory <home> and the
# code checkout <code>: the summary, the cap and the effective cap's reason, then one per held slot.
def status_text($home; $code):
  .settings as $s | .reserved_project as $project
  | "\(.machine // "this machine"): \(.counts.held) of \($s.cap) task slots held, "
    + (if $project == null then
         "none kept, since no registered project's primary checkout is the code checkout \($code | tilde($home)) (reserved \($s.reserved) ignored)"
       elif $s.reserved == 0 then "none kept for \($project) (reserved 0)"
       else "\($s.reserved) kept for \($project) (\($project) holds \(.counts.reserved_held))" end)
    + "; effective \(.effective.cap)",
    cap_text,
    held_text($home);

# The room the project <project> has for a new slot, from the team-slots/1 object: the reserved
# project's, or the others'.
def room_for($project):
  if .reserved_project != null and $project == .reserved_project then .room.reserved else .room.others end;

# The lines refusing the project <project> a new slot, from the team-slots/1 object, given the home
# directory <home>: why (every slot up to the effective cap held, or the free ones kept for the
# reserved project), the cap line, then the slots and who holds them.
def refusal_text($project; $home):
  .effective.cap as $cap | .counts.held as $held | .reserved_project as $reserved
  | ($cap - $held) as $free
  | "no task slot for \($project) on \(.machine // "this machine"): "
    + (if $held > $cap then "\($held) held, over the effective cap of \($cap)"
       elif $free == 0 then "\($held) of \($cap) held"
       else "\($held) of \($cap) held, and "
         + (if $free == 1 then "the last one is" else "the last \($free) are" end)
         + " kept for \($reserved) (reserved \(.settings.reserved)"
         + (if .counts.reserved_held > 0 then ", \($reserved) holds \(.counts.reserved_held)" else "" end) + ")"
       end),
    cap_text,
    (if $held == 0 then "the slots: none held" else "the slots:", held_text($home) end);

# The line saying the machine holds more slots than its effective cap, from the team-slots/1
# object; nothing when it does not.
def over_cap_text:
  select(.counts.held > .effective.cap)
  | "\(.machine // "this machine") holds \(.counts.held) task slots, over its effective cap of \(.effective.cap)"
    + " (cap \(.settings.cap), \(.effective.reason)); no new task opens until tasks close";

# A reading of the machine's load, from $in: {at (UTC, YYYY-MM-DDTHH:MM:SSZ), os, total and
# available (memory, in bytes), cpus, procs ([{pid, ppid, rss (KiB), seconds (cumulative CPU),
# cwd ("" when unreadable)}]), paths (the team paths), stacks (team-stack ls --json's object, or
# null when Docker did not answer), previous (null, or {seconds: the time since the previous
# snapshot, procs: {"<pid>": its CPU seconds then}})}. The team's processes are those whose
# directory is a team path or below one, and every descendant of one; the team's part adds the
# team and gate stacks' memory and CPU, which the others' part, holding the containers'
# processes, is less of. A process whose count is new or lower than the snapshot's (a pid used
# again) counts whole.
def slots_reading($in):
  def team_path: . as $cwd | $cwd != "" and any($in.paths[]; . as $path | $cwd == $path or ($cwd | startswith($path + "/")));
  def hundredths: . * 100 | round / 100;
  ($in.procs | map({key: (.pid | tostring), value: (.ppid | tostring)}) | from_entries) as $parent
  | ($in.procs | map(select(.cwd | team_path) | {key: (.pid | tostring), value: true}) | from_entries) as $direct
  | [$in.procs[] | . + {team: any(limit(64; .pid | tostring | recurse($parent[.] // empty)); $direct[.] // false)}]
    as $procs
  | [$in.stacks.projects // [] | .[] | select(.class == "team" or .class == "gate")] as $stacks
  | ([$stacks[].memory_bytes // 0] | add // 0) as $stacks_memory
  | (([$stacks[].cpu_percent // 0] | add // 0) / 100) as $stacks_cpu
  | ([$procs[] | select(.team) | .rss * 1024] | add // 0) + $stacks_memory as $team
  | {at: $in.at, os: $in.os, docker: ($in.stacks != null),
     memory: {total: $in.total, available: $in.available, team: $team,
              others: ([$in.total - $in.available - $team, 0] | max)},
     cpu: (if $in.previous == null then null
           else $in.previous as $previous
             | [$procs[] | ($previous.procs[.pid | tostring]) as $then
                 | {team, busy: (if $then != null and .seconds >= $then then .seconds - $then else .seconds end)}]
               as $busy
             | {cpus: $in.cpus, seconds: $previous.seconds,
                team: (([$busy[] | select(.team) | .busy] | add // 0) / $previous.seconds + $stacks_cpu | hundredths),
                others: ([([$busy[] | select(.team | not) | .busy] | add // 0) / $previous.seconds - $stacks_cpu, 0] | max
                         | hundredths)}
           end)};
