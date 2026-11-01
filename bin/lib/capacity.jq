# The definitions team-capacity reads the machine with and team-level sizes the team with: the
# settings of capacity.json, the slots held, a reading of the machine's load with the team's use
# per task, the cost samples it learns from, the estimates, the level record (level.jsonl), the
# budget, the reservations, the slice's limits, and the texts. jq 1.7.
# Included as: jq -L bin/lib 'include "capacity"; include "stack"; ...', stack after it, as
# CLAUDE.md's script conventions say for jq 1.8.2. The program, not this module, reads the ledger
# (held_slots). team-slots shares the reading (machine_reading) and the slots held until its
# retirement.
include "stack";

# The machine's capacity settings (~/.config/agent-team/capacity.json), every key optional, each
# with its default and its kind (settings_problems in stack.jq).
def capacity_defaults:
  {full_share: 0.9, minor_share: 0.3, reserve_gib: 4, reserve_cores: 1, auto_full_free: 0.5, auto_none_below: 0.15,
   rise_minutes: 15, session_gib: 0.5, heavy_gib: 5, gate_gib: 2.2, min_cores: 1, min_gib: 2};
def capacity_kinds:
  {full_share: "share", minor_share: "share", reserve_gib: "amount", reserve_cores: "amount", auto_full_free: "fraction",
   auto_none_below: "fraction", rise_minutes: "amount", session_gib: "positive", heavy_gib: "positive",
   gate_gib: "positive", min_cores: "positive", min_gib: "positive"};

# What is wrong with capacity.json's JSON values (read with jq -s), to follow its name, as
# settings_problems says it.
def capacity_problems: settings_problems(capacity_kinds);

# Every setting, the given ones (capacity.json's one object, or none) over the defaults, with
# from: each key's source, "capacity.json" or "default".
def capacity_settings:
  (.[0] // {}) as $given
  | capacity_defaults + $given
    + {from: (capacity_defaults | with_entries(.key as $key | .value = (if $given | has($key) then "capacity.json" else "default" end)))};

# The task T<n> a task's branch, <type>/T<n>-<slug> with one of team-open's types, names; nothing
# for any other branch.
def task_branch_task:
  capture("^(feat|fix|docs|chore|build|ci|test|refactor|perf|research)/(?<task>T[1-9][0-9]*)-[a-z0-9]+(-[a-z0-9]+)*$")
  | .task;

# The slots held, from each task's ledger events <tasks> (by_task), the open worktrees <open> of
# the open tasks (open_worktrees over the events of the tasks is_open keeps, each path on this
# machine), and the registered worktrees <worktrees> of every registered project's primary
# checkout but the checkout itself, each {project, branch, worktree}: one {task, project,
# worktree, half_open} per open worktree, and per registered worktree on a task's branch whose
# task has no closed event and no open worktree of that project (half open), by task number, then
# project. The program reads the ledger as bin/lib/reading.sh does (READING_HELD):
#   include "ledger"; include "capacity"; include "stack"; ledger_events as $events | ($events | by_task) as $tasks
#   | held_slots($tasks; [open_worktrees($events[] | select($tasks[.task] | is_open); $home)]; $worktrees)
def held_slots($tasks; $open; $worktrees):
  [$open[] | {task, project, worktree, half_open: false}] as $open
  | $open
    + [$worktrees[] | (.branch | task_branch_task) as $task | .project as $project
      | select(($tasks[$task] // [] | any(.[]; .event == "closed")) | not)
      | select(any($open[]; .task == $task and .project == $project) | not)
      | {task: $task, project, worktree, half_open: true}]
  | sort_by((.task[1:] | tonumber), .project, .worktree);

# Whether a reading has the parts every reader reads: its time, its memory's total and others,
# and its CPU's count and others or null.
def well_formed_reading:
  try (type == "object" and (.at | type == "string" and (fromdateiso8601 | type == "number"))
       and (.memory.total | type == "number") and (.memory.others | type == "number")
       and (.cpu == null or ((.cpu.cpus | type == "number") and (.cpu.others | type == "number"))))
  catch false;

# A readings file's lines (an array of strings), as {readings: the well-formed ones, oldest first,
# broken: how many lines are not}; a blank line is neither.
def stored_readings:
  map(select(test("\\S")) | try fromjson catch null | if well_formed_reading then . else null end)
  | {readings: (map(select(. != null)) | sort_by(.at | fromdateiso8601)), broken: (map(select(. == null)) | length)};

# <n> rounded to two decimal places.
def hundredths: . * 100 | round / 100;

# The processes of a reading's input <in> (machine_reading's), each with team (whether its
# directory is one of the team paths <paths> or below one, or it descends from one that is) and
# busy (its CPU seconds since the snapshot, all of them for a process new since or whose count is
# lower, its pid used again; null with no snapshot).
def reading_procs($in; $paths):
  def under: . as $cwd | $cwd != "" and any($paths[]; . as $path | $cwd == $path or ($cwd | startswith($path + "/")));
  ($in.procs | map({key: (.pid | tostring), value: (.ppid | tostring)}) | from_entries) as $parent
  | ($in.procs | map(select(.cwd | under) | {key: (.pid | tostring), value: true}) | from_entries) as $direct
  | [$in.procs[] | ($in.previous.procs[.pid | tostring]) as $then
     | . + {team: any(limit(64; .pid | tostring | recurse($parent[.] // empty)); $direct[.] // false),
            busy: (if $in.previous == null then null
                   elif $then != null and .seconds >= $then then .seconds - $then else .seconds end)}];

# A reading of the machine's load, from $in: {at (UTC, YYYY-MM-DDTHH:MM:SSZ), os, total and
# available (memory, in bytes), cpus, procs ([{pid, ppid, rss (KiB), seconds (cumulative CPU),
# cwd ("" when unreadable), cgroup ("" when unread)}]), paths (the team paths), stacks
# (team-stack ls --json's object, or null when Docker did not answer), previous (null, or
# {seconds: the time since the previous snapshot, procs: {"<pid>": its CPU seconds then}})}. The
# team's processes are those whose directory is a team path or below one, and every descendant
# of one; the team's part adds the team and gate stacks' memory and CPU, which the others' part,
# holding the containers' processes, is less of.
def machine_reading($in):
  reading_procs($in; $in.paths) as $procs
  | [$in.stacks.projects // [] | .[] | select(.class == "team" or .class == "gate")] as $stacks
  | ([$stacks[].memory_bytes // 0] | add // 0) as $stacks_memory
  | (([$stacks[].cpu_percent // 0] | add // 0) / 100) as $stacks_cpu
  | (([$procs[] | select(.team) | .rss * 1024] | add // 0) + $stacks_memory) as $team
  | {at: $in.at, os: $in.os, docker: ($in.stacks != null),
     memory: {total: $in.total, available: $in.available, team: $team,
              others: ([$in.total - $in.available - $team, 0] | max)},
     cpu: (if $in.previous == null then null
           else {cpus: $in.cpus, seconds: $in.previous.seconds,
                 team: (([$procs[] | select(.team) | .busy] | add // 0) / $in.previous.seconds + $stacks_cpu | hundredths),
                 others: ([([$procs[] | select(.team | not) | .busy] | add // 0) / $in.previous.seconds - $stacks_cpu, 0] | max
                          | hundredths)}
           end)};

# The task whose slice a cgroup path is in (agent-team-T<n>.slice, which systemd nests under
# agent.slice/agent-team.slice), or null.
def slice_task:
  (capture("/agent\\.slice/agent-team\\.slice/agent-team-(?<task>T[0-9]+)\\.slice(/|$)") | .task) // null;

# The live team sessions of $in.sessions (claude agents --json's, as [{id, name, pid}], or null
# when it could not be read), each named T<n>-<role> with its process among $in.procs, as {id,
# task, role, pid}.
def team_sessions($in):
  ($in.procs | map({key: (.pid | tostring), value: true}) | from_entries) as $running
  | [$in.sessions // [] | .[] | select((.name // "") | test("^T[1-9][0-9]*-[a-z]+$")) | select($running[.pid | tostring] // false)
     | {id, task: (.name | split("-")[0]), role: (.name | sub("^T[0-9]+-"; "")), pid}];

# The tasks a reading's input <in> (capacity_reading's) shows work of: those holding a worktree,
# with a live team session, a running team stack, or a process in their slice, by task number.
def reading_tasks($in):
  [$in.held[].task, team_sessions($in)[].task,
   ($in.stacks.projects // [] | .[] | select(.class == "team" and .memory_bytes != null) | .task // empty),
   ($in.procs[] | .cgroup // "" | slice_task // empty)]
  | unique | sort_by(.[1:] | tonumber);

# The user manager's units a reading reads on Linux: each task's slice, each live team session's
# scope, and the gate's daemon units <gate_units>.
def capacity_units($in):
  [(reading_tasks($in)[] | "agent-team-\(.).slice"),
   (team_sessions($in)[] | "agent-team-\(.task)-\(.id).scope"),
   $in.gate_units[]];

# A reading of the machine's load with the team's use per task, from $in: machine_reading's input
# and held (the slots held, [{task, project, worktree}], each path resolved), sessions (as
# team_sessions reads them), units ({"<unit>": {MemoryCurrent, MemoryPeak, CPUUsageNSec}, each a
# number or null}, or null when the user manager did not answer or off Linux), gate_units (the
# gate's daemon units), gate_root (~/.no-mistakes), heavy (the pid of the team-heavy that holds the
# heavy-run lock, or null) and prior (the newest stored reading, or null).
# Each process is a task's when its directory is that task's held worktree or below it, or it
# descends from one that is, the nearest one deciding; on Linux one in a task's slice is counted
# by the slice's MemoryCurrent and CPUUsageNSec instead. A session's use is its scope's on Linux,
# else its process tree's (the session and its descendants, but a heavy run's team-heavy and what
# it runs, whose cost is heavy:<kind>'s). The gate runs a pipeline while a
# process works in one of its worktrees (gate_root/worktrees/...); its use is its daemon unit's on
# Linux, else the tree of the processes in gate_root.
def capacity_reading($in):
  def gib_bytes: . * 1024;
  def under($path): . as $cwd | $cwd != "" and ($cwd == $path or ($cwd | startswith($path + "/")));
  def unit($name): ($in.units // {})[$name] // {};
  machine_reading($in) as $base
  | ($in.held | sort_by(-(.worktree | length))) as $held
  | ($in.procs | map({key: (.pid | tostring), value: (.ppid | tostring)}) | from_entries) as $parent
  | ($in.procs | map({key: (.ppid | tostring), value: (.pid | tostring)}) | group_by(.key)
     | map({key: .[0].key, value: map(.value)}) | from_entries) as $kids
  | ($in.procs | map(.cwd as $cwd | {key: (.pid | tostring),
       value: (first($held[] | .worktree as $wt | select($cwd | under($wt)) | .task) // null)}) | from_entries) as $dir_task
  | ($in.procs | map(select(.cwd | under($in.gate_root)) | {key: (.pid | tostring), value: true}) | from_entries) as $gate_direct
  | (reading_procs($in; $in.paths)
     | map(. + {task: (first(limit(64; .pid | tostring | recurse($parent[.] // empty)) | $dir_task[.] // empty) // null),
                slice: (.cgroup // "" | slice_task),
                in_team: (.cgroup // "" | test("/agent\\.slice/agent-team\\.slice/")),
                gate: any(limit(64; .pid | tostring | recurse($parent[.] // empty)); $gate_direct[.] // false)})) as $procs
  | ($procs | map({key: (.pid | tostring), value: .}) | from_entries) as $by_pid
  | ($in.previous != null) as $timed
  | (if $timed then $in.previous.seconds else null end) as $seconds
  | ($in.prior.tasks // [] | map({key: .task, value: .cpu_nsec}) | from_entries) as $prior_nsec
  | ($in.prior.systemd == true) as $prior_read
  | [team_sessions($in)[]
     | [limit(4096; .pid | tostring | recurse($kids[.] // [] | .[] | select(. != ($in.heavy // "" | tostring))))] as $tree
     | ([$tree[] | $by_pid[.].rss // 0] | add | gib_bytes) as $rss
     | ([$tree[] | $by_pid[.].seconds // 0] | add) as $tree_seconds
     | unit("agent-team-\(.task)-\(.id).scope") as $scope
     | {id, task, role, memory: ($scope.MemoryCurrent // $rss), peak: ($scope.MemoryPeak // $rss),
        cpu_seconds: (if $scope.CPUUsageNSec != null then $scope.CPUUsageNSec / 1e9 else $tree_seconds end | hundredths)}]
    as $sessions
  | [$in.stacks.projects // [] | .[] | select((.class == "team" or .class == "gate") and .memory_bytes != null)
     | .worktree as $wt
     | {name, class, task, project: (if .class == "team" then first($in.held[] | select(.worktree == $wt) | .project) // null else null end),
        memory: .memory_bytes, cpu: ((.cpu_percent // 0) / 100), limits: .memory_limit_bytes}]
    as $stacks
  | [reading_tasks($in)[] as $task
     | unit("agent-team-\($task).slice") as $slice
     | [$procs[] | select(.task == $task and (.in_team | not))] as $outside
     | [$procs[] | select(.task == $task or .slice == $task)] as $all
     | [$procs[] | select(.slice == $task)] as $inside
     | [$stacks[] | select(.class == "team" and .task == $task)] as $mine
     | ([$mine[].memory] | add // 0) as $stacks_memory
     | ([$mine[].cpu] | add // 0) as $stacks_cpu
     | {task: $task,
        memory: ((if $slice.MemoryCurrent != null then $slice.MemoryCurrent + ([$outside[].rss] | add // 0 | gib_bytes)
                  else [$all[].rss] | add // 0 | gib_bytes end) + $stacks_memory),
        cpu: (if $timed | not then null
              else ((if $slice.CPUUsageNSec != null and $prior_read then
                       ($slice.CPUUsageNSec - ($prior_nsec[$task] // 0)) as $delta
                       | (if $delta < 0 then $slice.CPUUsageNSec else $delta end) / 1e9
                       + ([$outside[].busy] | add // 0)
                     else [$all[].busy] | add // 0 end) / $seconds + $stacks_cpu | hundredths)
              end),
        cpu_nsec: $slice.CPUUsageNSec,
        sessions: [$sessions[] | select(.task == $task) | del(.task)],
        stacks: [$mine[] | {name, memory, cpu: (.cpu | hundredths)}]}]
    as $tasks
  | (first($in.gate_units[] | unit(.) | select(.MemoryCurrent != null)) // {}) as $daemon
  | [$procs[] | select(.gate)] as $gate_procs
  | $base
    + {systemd: (if $in.os == "linux" then $in.units != null else null end),
       sessions: ($in.sessions != null),
       tasks: $tasks,
       stacks: [$stacks[] | .cpu |= hundredths],
       gate: {running: any($procs[]; .cwd | under($in.gate_root + "/worktrees")),
              memory: ($daemon.MemoryCurrent // ([$gate_procs[].rss] | add // 0 | gib_bytes)),
              cpu_seconds: (if $daemon.CPUUsageNSec != null then $daemon.CPUUsageNSec / 1e9
                            else [$gate_procs[].seconds] | add // 0 end | hundredths)}};

# What the readings keep of what they saw running (capacity/live.json) and the cost lines of what
# ended, from the kept state <live> (null with none) and the new reading <r> (capacity_reading's),
# as {live, costs}. Kept: each live session by id ({kind: "session:<role>", task, first, last,
# peak, cpu_seconds}), each running stack of a registered project by name ({kind:
# "stack:<project>", first, last, peak, cpu_seconds, its CPU summed over the readings that saw it
# 15 minutes apart at most}), the gate while it runs a pipeline ({first, last, peak, cpu_first,
# cpu_seconds}) and each project's stack limits as last seen running (limits). A session the
# session list no longer has, a stack Docker no longer runs and a gate no longer running a
# pipeline end, each one cost line {at, kind, peak_bytes, cpu_seconds, seconds}, seconds from the
# first reading that saw it to the last; what a reading could not read (the session list, Docker)
# ends nothing.
def capacity_track($live; $r):
  ($live // {}) as $live
  | $r.at as $at | ($at | fromdateiso8601) as $now
  | def span: (.last | fromdateiso8601) - (.first | fromdateiso8601);
    def cost($kind): {at: $at, kind: $kind, peak_bytes: .peak, cpu_seconds: (.cpu_seconds | hundredths), seconds: span};
  ($live.sessions // {}) as $was_sessions
  | ([$r.tasks[] | .task as $task | .sessions[] | ($was_sessions[.id] // null) as $was
      | {key: .id, value: {kind: "session:\(.role)", task: $task, first: ($was.first // $at), last: $at,
                           peak: ([$was.peak // 0, .peak] | max), cpu_seconds: ([$was.cpu_seconds // 0, .cpu_seconds] | max)}}]
     | from_entries) as $sessions
  | ($was_sessions | with_entries(.key as $k | select($sessions | has($k) | not))) as $gone_sessions
  | ($live.stacks // {}) as $was_stacks
  | ([$r.stacks[] | select(.project != null) | ($was_stacks[.name] // null) as $was
      | {key: .name, value: {kind: "stack:\(.project)", first: ($was.first // $at), last: $at,
                             peak: ([$was.peak // 0, .memory] | max),
                             cpu_seconds: (($was.cpu_seconds // 0)
                               + (if $was == null then 0
                                  else ($now - ($was.last | fromdateiso8601)) as $gap
                                  | if $gap > 0 and $gap <= 900 then .cpu * $gap else 0 end end))}}]
     | from_entries) as $stacks
  | ($was_stacks | with_entries(.key as $k | select($stacks | has($k) | not))) as $gone_stacks
  | ($live.gate // null) as $was_gate
  | (if $r.gate.running then
       {first: ($was_gate.first // $at), last: $at, peak: ([$was_gate.peak // 0, $r.gate.memory] | max),
        cpu_first: ($was_gate.cpu_first // $r.gate.cpu_seconds), cpu_seconds: $r.gate.cpu_seconds}
     else null end) as $gate
  | {live: {sessions: (if $r.sessions then $sessions else $was_sessions + $sessions end),
            stacks: (if $r.docker then $stacks else $was_stacks + $stacks end),
            gate: $gate,
            limits: (($live.limits // {}) + ([$r.stacks[] | select(.project != null and .limits != null)
                                              | {key: .project, value: .limits}] | from_entries))},
     costs: ((if $r.sessions then [$gone_sessions[] | cost(.kind)] else [] end)
             + (if $r.docker then [$gone_stacks[] | cost(.kind)] else [] end)
             + (if $was_gate != null and ($r.gate.running | not) then
                  [$was_gate | .cpu_seconds = ([.cpu_seconds - .cpu_first, 0] | max) | cost("gate")]
                else [] end))};

# Whether a cost line has the parts the estimates read.
def well_formed_cost:
  try (type == "object" and (.kind | type == "string") and (.peak_bytes | type == "number")) catch false;

# <bytes> as GiB with one decimal place.
def gib: "\(. / 1073741824 | one_decimal) GiB";

# The estimate of each kind of work, from $in: {settings (capacity_settings), costs (the cost
# lines, oldest first), roles (the worker roles), stack_projects (the registered projects with a
# stack block), limits (live.json's limits)}: [{kind, estimate_bytes (null with no seed), source
# ("learned", "seed" or "none"), samples (how many it has), range ({min, max} of the last 20
# peaks, or null), says}], the sessions by role, the stacks by project, the gate, then every
# other kind the costs have. From 5 samples it is the 90th percentile (nearest rank) of the last
# 20 peaks plus 10%; else the seed: session_gib, heavy_gib or gate_gib, and for a stack the sum
# of its services' mem_limits as last seen running.
def capacity_costs($in):
  $in.settings as $s
  | (["session:" + $in.roles[]] + ["stack:" + $in.stack_projects[]] + ["gate"]) as $known
  | ($known + ([$in.costs[].kind] | unique | map(select(. as $k | $known | index($k) | not)))) as $kinds
  | def seed($kind):
      def setting($key): {bytes: ($s[$key] * 1073741824 | round),
                          says: "the seed: \($key) \($s[$key]) GiB\(if $s.from[$key] == "default" then ", its default" else " in capacity.json" end)"};
      if $kind | startswith("session:") then setting("session_gib")
      elif $kind | startswith("heavy:") then setting("heavy_gib")
      elif $kind == "gate" then setting("gate_gib")
      elif $kind | startswith("stack:") then
        ($in.limits[$kind[6:]] // null) as $limits
        | if $limits == null then {bytes: null, says: "no seed: no stack of it seen running yet"}
          else {bytes: $limits, says: "the seed: its services' mem_limits, \($limits | gib) as last seen running"} end
      else {bytes: null, says: "no seed"} end;
  [$kinds[] as $kind
   | [$in.costs[] | select(.kind == $kind) | .peak_bytes] as $all
   | $all[-20:] as $last
   | ($all | length) as $n
   | (if $last == [] then null else {min: ($last | min), max: ($last | max)} end) as $range
   | if $n >= 5 then
       {kind: $kind, estimate_bytes: (($last | sort | .[(length * 0.9 | ceil) - 1]) * 1.1 | round), source: "learned",
        samples: $n, range: $range,
        says: "learned from \(if $n > 20 then "the last 20 of \($n)" else "\($n)" end) samples, \($range.min | gib) to \($range.max | gib)"}
     else seed($kind) as $seed
       | {kind: $kind, estimate_bytes: $seed.bytes, source: (if $seed.bytes == null then "none" else "seed" end),
          samples: $n, range: $range,
          says: ($seed.says + (if $n == 0 then "" else " (\($n) sample\(if $n == 1 then "" else "s" end) of 5)" end))}
     end];

# team-capacity costs's lines from capacity_costs's array.
def costs_text:
  .[] | "\(.kind): \(if .estimate_bytes == null then "no estimate" else .estimate_bytes | gib end), \(.says)";

# A reading's time, as HH:MM in the local time zone.
def capacity_time: .at | fromdateiso8601 | strflocaltime("%H:%M");

# <cores> with two decimal places at most, and its noun.
def cores_text: "\(.) core\(if . == 1 then "" else "s" end)";

# team-capacity status's lines from its team-capacity/1 object: what the other programs and the
# team use at the newest reading, then each task's use, its sessions and its stacks, and the gate
# while it runs a pipeline.
def capacity_status_text:
  .reading as $r
  | (.machine // "this machine") as $machine
  | if $r == null then "\($machine): no reading of the machine's load yet"
    else
      "\($machine) at \($r | capacity_time): other programs use \($r.memory.others | gib) of \($r.memory.total | gib)"
        + (if $r.cpu == null then "" else " and \($r.cpu.others) of \($r.cpu.cpus | cores_text)" end)
        + "; the team \($r.memory.team | gib)" + (if $r.cpu == null then "" else " and \($r.cpu.team | cores_text)" end)
        + (if .stale then " (the newest reading, over 15 minutes old)" else "" end),
      ($r.tasks // [] | .[]
       | "  \(.task): \(.memory | gib)" + (if .cpu == null then "" else ", \(.cpu | cores_text)" end)
         + ([(.sessions[] | "\(.role) \(.id) \(.memory | gib)"), (.stacks[] | "stack \(.name) \(.memory | gib)")]
            | if . == [] then "" else "; " + join(", ") end)),
      (select($r.gate.running // false) | "  gate: running a pipeline, \($r.gate.memory | gib)")
    end;

# The levels, lowest first, and each one's share of the machine under the settings <s>
# (capacity_settings): full_share, minor_share, or 0 for none.
def capacity_levels: ["none", "minor", "full"];
def level_share($s): if . == "full" then $s.full_share elif . == "minor" then $s.minor_share else 0 end;

# Whether a line of level.jsonl is a level record: {ts (UTC, YYYY-MM-DDTHH:MM:SSZ), mode (manual
# or auto), level, by and machine (each a non-empty string)}, with discord_message and reason
# strings when present.
def well_formed_level:
  try (type == "object" and (.ts | type == "string" and (fromdateiso8601 | type == "number"))
       and (.mode == "manual" or .mode == "auto") and (.level as $l | capacity_levels | index($l) != null)
       and (.by | type == "string" and . != "") and (.machine | type == "string" and . != "")
       and ((.discord_message // "") | type == "string") and ((.reason // "") | type == "string"))
  catch false;

# level.jsonl's lines (an array of strings) as {records: the level records in their order,
# broken: the numbers of the lines that are not one}; a blank line is neither.
def level_records:
  [to_entries[] | select(.value | test("\\S")) | {line: (.key + 1), record: (.value | try fromjson catch null)}]
  | {records: map(select(.record | well_formed_level) | .record),
     broken: map(select(.record | well_formed_level | not) | .line)};

# The current mode and level from level_records' object: the last record's, else manual full
# (the team before any record), as {mode, level, last_change (the last record, or null)}.
def level_current: {mode: (.records[-1].mode // "manual"), level: (.records[-1].level // "full"), last_change: .records[-1]};

# The team's budget at <level>, from the settings <s>, the newest reading <r> (null with none), the
# newest reading with CPU <c> (null with none) and the machine's cores <cpus>, with T the memory
# total, C the cores, s the level's share, O_m and O_c the other programs' memory and cores:
#   memory_bytes  max(0, min(s * T, T - O_m - reserve_gib)), null with no reading
#   cores         max(0, min(s * C, C - O_c - reserve_cores)), s * <cpus> with no reading with CPU
# and bound_by {memory, cores}: "share" when the share is the smaller bound, else "others" (the
# other programs leave less), null with no reading.
def capacity_budget($s; $level; $r; $c; $cpus):
  ($level | level_share($s)) as $share
  | (if $r == null then {bytes: null, bound: null}
     else ($share * $r.memory.total) as $by_share
       | ($r.memory.total - $r.memory.others - $s.reserve_gib * 1073741824) as $left
       | {bytes: ([0, ([$by_share, $left] | min)] | max | floor), bound: (if $by_share <= $left then "share" else "others" end)}
     end) as $memory
  | (if $c == null then {cores: ($share * $cpus | hundredths), bound: "share"}
     else ($share * $c.cpu.cpus) as $by_share
       | ($c.cpu.cpus - $c.cpu.others - $s.reserve_cores) as $left
       | {cores: ([0, ([$by_share, $left] | min)] | max | hundredths), bound: (if $by_share <= $left then "share" else "others" end)}
     end) as $cpu
  | {share: $share, memory_bytes: $memory.bytes, cores: $cpu.cores, bound_by: {memory: $memory.bound, cores: $cpu.bound}};

# What the live work of the reading <r> reserves, from the estimates <costs> (capacity_costs'
# array): each live team session, each running team or gate stack and the gate while it runs a
# pipeline, at the larger of its kind's estimate (a stack with none: its mem_limits) and its use,
# as [{kind, task, name, estimate_bytes, use_bytes, bytes}].
def capacity_reservations($r; $costs):
  ($costs | map({key: .kind, value: .estimate_bytes}) | from_entries) as $estimate
  | def item($kind; $task; $name; $use; $fallback):
      ($estimate[$kind] // $fallback // 0) as $e
      | {kind: $kind, task: $task, name: $name, estimate_bytes: $e, use_bytes: $use, bytes: ([$e, $use // 0] | max)};
  [($r.tasks // [] | .[] | .task as $task | .sessions[] | item("session:\(.role)"; $task; .id; .memory; null)),
   ($r.stacks // [] | .[] | item("stack:\(.project // .class)"; .task; .name; .memory; .limits)),
   (if $r.gate.running // false then item("gate"; null; "gate"; $r.gate.memory; null) else empty end)];

# The team slice's limits and the containers' CPU for the budget <budget> (capacity_budget's),
# from the reservations <reserved> (capacity_reservations'), the slice's current use <current> and
# MemoryHigh <previous> (bytes, null when unknown or infinity) and the settings <s>:
#   cpu_quota_percent  max(cores, min_cores) * 100, rounded
#   cpus               max(cores, min_cores), for docker update --cpus
#   memory_high        max(min_gib, the budget less the stacks' reservations (they run outside the
#                      slice), min(current, previous)): while the slice uses more than its part,
#                      never below that use, so a drop reclaims through stops and stows, never by
#                      throttling live sessions, and lowered as the use falls
#   memory_max         max(memory_high, current) + 1 GiB, so a drop never kills a worker
def level_limits($budget; $reserved; $current; $previous; $s):
  ([$reserved[] | select(.kind | startswith("stack:")) | .bytes] | add // 0) as $stacks
  | ([$budget.memory_bytes - $stacks, 0] | max) as $part
  | ([$current // 0, $previous // ($current // 0)] | min) as $held
  | ([$s.min_gib * 1073741824, $part, $held] | max | floor) as $high
  | ([$budget.cores, $s.min_cores] | max) as $cores
  | {cpu_quota_percent: ($cores * 100 | round), cpus: ($cores | hundredths), memory_high: $high,
     memory_max: (([$high, $current // 0] | max) + 1073741824 | floor)};

# <share> as a percentage: 0.3 is "30%".
def percent: "\(. * 100 | round)%";

# <cores> with one decimal place, and its noun.
def cores_short: "\(one_decimal) core\(if . == 1 then "" else "s" end)";

# The level's one line from team-level's team-level/1 object, which the coordinator posts:
# "manual, minor (30%): 9.2 GiB and 3.6 cores for the team; 6.1 GiB reserved".
def level_says:
  "\(.mode), \(.level) (\(.share | percent)): "
  + if .budget.memory_bytes == null then "no reading of the machine's load yet, so no budget"
    else "\(.budget.memory_bytes | gib) and \(.budget.cores | cores_short) for the team; \(.reserved_bytes | gib) reserved" end;

# team-level status's lines from its team-level/1 object.
def level_status_text:
  def bound: if . == "share" then "bound by the share" else "bound by what other programs leave" end;
  "Resources: \(level_says)",
  (select(.reading != null) | .reading as $r
   | "  memory: \(.budget.memory_bytes | gib), \(.budget.bound_by.memory | bound): \(.share | percent) of \($r.total | gib), other programs use \($r.others_memory | gib) and \(.settings.reserve_gib) GiB stays free for them",
     "  cores: \(.budget.cores | one_decimal), \(.budget.bound_by.cores | bound)"
       + (if $r.cpus == null then " (no reading of the CPU yet: \(.share | percent) of \(.cpus))"
          else ": \(.share | percent) of \($r.cpus), other programs use \($r.others_cores) and \(.settings.reserve_cores) stays free for them" end),
     "  the team uses \(.use.memory_bytes | gib)" + (if .use.cores == null then "" else " and \(.use.cores | cores_short)" end)
       + " (the reading at \($r.at | fromdateiso8601 | strflocaltime("%H:%M")))"),
  (if .last_change == null then "  last change: none recorded, so manual full"
   else .last_change | "  last change: \(.mode) \(.level) by \(.by) at \(.ts | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")) on \(.machine)" end);
