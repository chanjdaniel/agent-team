# The definitions team-slots reads the machine's task slots with: the settings of slots.json,
# the slots held, the room each side has, and the texts. jq 1.7.
# Included as: jq -L bin/lib 'include "slots"; include "capacity"; include "stack"; ...', the
# modules it includes after it, as CLAUDE.md's script conventions say for jq 1.8.2. The slots held
# and the readings of the machine's load are capacity.jq's (held_slots, stored_readings).
include "capacity";
include "stack";

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
# <project>, and the readings <readings> (stored_readings), as {cap, lowered_by, reason, readings
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

# <path> with ~ for the home directory <home>.
def tilde($home):
  if . == $home then "~" elif startswith($home + "/") then "~" + .[($home | length):] else . end;

# The summary line of the team-slots/1 object, given the home directory <home> and the code
# checkout <code>: the slots held of the cap, those kept for the reserved project, and the
# effective cap.
def summary_text($home; $code):
  .settings as $s | .reserved_project as $project
  | "\(.machine // "this machine"): \(.counts.held) of \($s.cap) task slots held, "
    + (if $project == null then
         "none kept, since no registered project's primary checkout is the code checkout \($code | tilde($home)) (reserved \($s.reserved) ignored)"
       elif $s.reserved == 0 then "none kept for \($project) (reserved 0)"
       else "\($s.reserved) kept for \($project) (\($project) holds \(.counts.reserved_held))" end)
    + "; effective \(.effective.cap)";

# The team-slots/1 object, from $in: {given (slots.json's values read with jq -s, [] with none),
# machine (null without a name), reserved_project (null with none), held (held_slots), readings
# (stored_readings's readings), home (the home directory) and code (the code checkout)}.
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
     stale: ($in.readings == [] or ($in.readings[-1].at | fromdateiso8601) < now - 15 * 60)}
  | {schema, machine, summary: summary_text($in.home; $in.code)} + .;

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

# team-slots status's lines from the team-slots/1 object, given the home directory <home>: the
# summary, the cap and the effective cap's reason, then one per held slot.
def status_text($home):
  .summary,
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

# team-doctor's slots line from the team-slots/1 object, as {verdict, reason, fix}, given <pools>
# ({"<project>": its pool's slot count}, in the registry's order), <file> (slots.json's state:
# "missing", "empty" with no key, or "set"), <holding> ("yes" when this machine holds the lease,
# "no", or "" when the lease line cannot say) and <heartbeat> ("enabled" or "disabled").
# It passes with the cap and where it came from, the effective cap, the slots held and kept, the
# latest reading, and each pool smaller than the cap lets its project take (cap - reserved for
# another project than the reserved one); it warns, the facts after the problems, on a cap
# slots.json does not set, more held than the effective cap, and stale readings on the lease
# holder, whose heartbeat takes them.
def doctor_line($pools; $file; $holding; $heartbeat):
  .settings as $s | .reserved_project as $project
  | (if $project == null then 0 else $s.reserved end) as $kept
  | ([$pools | to_entries[]
      | (if .key == $project then $s.cap else $s.cap - $kept end) as $share
      | select(.value < $share) | "\(.key) \(.value) of \($share)"]) as $small
  | ("cap \($s.cap) (\(if $s.from.cap == "slots.json" then "slots.json" else "the default" end)), effective \(.effective.cap)"
     + (if .effective.lowered_by == "memory" then " (lowered by memory)"
        elif .effective.lowered_by == "cpu" then " (lowered by CPU)"
        elif $s.dynamic == false then " (dynamic sizing is off)"
        else "" end)
     + ", \(.counts.held) held, "
     + (if $project == null then "none kept, since no registered project's primary checkout is the code checkout"
        elif $s.reserved == 0 then "none kept for \($project)"
        else "\($s.reserved) kept for \($project)" end)
     + "; "
     + (if .effective.readings != [] then .effective.readings[-1] | "\(others_text) (\(reading_time))"
        elif .effective.reason | startswith("no reading") then .effective.reason
        else "no reading of the machine's load in the last \(counted($s.window_minutes; "minute"; "minutes"))" end)
     + (if $small == [] then "" else "; pools smaller than the cap lets them take: \($small | join(", "))" end)) as $facts
  | [(select($s.from.cap != "slots.json")
      | if $file == "missing" then
          {reason: "~/.config/agent-team/slots.json is missing, so the cap is the default \($s.cap)",
           fix: "echo '{\"cap\": <n>}' > ~/.config/agent-team/slots.json"}
        elif $file == "empty" then
          {reason: "~/.config/agent-team/slots.json sets no cap, so the cap is the default \($s.cap)",
           fix: "echo '{\"cap\": <n>}' > ~/.config/agent-team/slots.json"}
        else
          {reason: "~/.config/agent-team/slots.json sets no cap, so the cap is the default \($s.cap)",
           fix: "add \"cap\": <n> to ~/.config/agent-team/slots.json"}
        end),
     (select(.counts.held > .effective.cap)
      | {reason: "\(.counts.held) held, over the effective cap of \(.effective.cap)", fix: "none needed; no task opens until some close"}),
     (select(.stale and $holding == "yes")
      | {reason: "no reading of the machine's load in the last 15 minutes, though this machine holds the lease, whose heartbeat takes one every 5",
         fix: (if $heartbeat == "enabled" then "the slots step's lines in ~/.local/state/agent-team/heartbeat.log say why it takes none"
               else "team-timers enable" end)})] as $problems
  | if $problems == [] then {verdict: "PASS", reason: $facts, fix: ""}
    else {verdict: "WARN", reason: ($problems | map(.reason) + [$facts] | join("; ")), fix: ($problems | map(.fix) | join("; "))} end;
