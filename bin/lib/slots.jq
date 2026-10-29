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

# The effective cap from the settings <s>: the cap, with no reading of the machine's load yet.
def effective_cap($s):
  {cap: $s.cap, lowered_by: null, reason: "no reading of the machine's load yet", readings: []};

# The team-slots/1 object, from $in: {given (slots.json's values read with jq -s, [] with none),
# machine (null without a name), reserved_project (null with none), held (held_slots)}.
def slots_status($in):
  ($in.given | slots_settings) as $s
  | effective_cap($s) as $effective
  | $in.reserved_project as $project
  | (if $project == null then 0 else $s.reserved end) as $reserved
  | ($in.held | length) as $held
  | ([$in.held[] | select(.project == $project)] | length) as $reserved_held
  | ($held - $reserved_held) as $others_held
  | ([$effective.cap - $held, 0] | max) as $free
  | {schema: "team-slots/1", machine: $in.machine, settings: $s, reserved_project: $project, effective: $effective,
     held: $in.held, counts: {held: $held, reserved_held: $reserved_held, others_held: $others_held},
     room: {reserved: (if $project == null then null else $free end),
            others: ([[$free, $effective.cap - $reserved - $others_held] | min, 0] | max)},
     stale: ($effective.readings == [])};

# <path> with ~ for the home directory <home>.
def tilde($home):
  if . == $home then "~" elif startswith($home + "/") then "~" + .[($home | length):] else . end;

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
    "the cap is \($s.cap) "
    + (if $s.from.cap == "slots.json" then "(cap in ~/.config/agent-team/slots.json)"
       else "(the default: ~/.config/agent-team/slots.json sets no cap)" end)
    + ", effective \(.effective.cap): \(.effective.reason)",
    (.held[] | "  \(.task) \(.project) in \(.worktree | tilde($home))\(if .half_open then " (half open)" else "" end)");
