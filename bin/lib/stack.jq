# The definitions team-stack reads Docker's answers with: the labels contract's owner classes
# (sops/docker.md), Docker's sizes and memory, and the plain tables. jq 1.7.
# Included as: jq -L bin/lib 'include "stack"; ...'

# The labels contract's prefix.
def team_prefix: "io.github.chanjdaniel.team.";

# A team label of the labels object <labels>, null when unset or empty: team_label($labels; "task")
def team_label($labels; $key): ($labels // {})[team_prefix + $key] // "" | if . == "" then null else . end;

# Whether <labels> sets any team label to a value.
def has_team_labels($labels):
  any(($labels // {}) | to_entries[]; (.key | startswith(team_prefix)) and .value != "");

# The Compose project of the labels object <labels>, or null.
def compose_project($labels): ($labels // {})["com.docker.compose.project"] // null;

# The owner class of an object with the labels <labels> in the Compose project <project> (or
# null), given $stacks, the registry's stack blocks: gate (kind=gate, whatever its owner, since a
# gate run from a task's shell is labelled owner=agent-team too, or no team label set and a
# project name matching a legacy_gate), team (owner=agent-team), else unowned.
def owner_class($labels; $project; $stacks):
  if team_label($labels; "kind") == "gate" then "gate"
  elif team_label($labels; "owner") == "agent-team" then "team"
  elif (has_team_labels($labels) | not) and $project != null
    and any($stacks[] | .legacy_gate // empty; . as $gate | $project | test("^(?:" + $gate + ")$"))
  then "gate"
  else "unowned" end;

# An image repository's class: team when in a project's images, legacy when it matches a
# legacy_images pattern, else unowned.
def image_class($repository; $stacks):
  if any($stacks[] | .images[]?; . == $repository) then "team"
  elif any($stacks[] | .legacy_images[]?; . as $pattern | $repository | test("^(?:" + $pattern + ")$")) then "legacy"
  else "unowned" end;

# The order classes are listed in.
def class_rank: {team: 0, gate: 1, legacy: 1, unowned: 2, anonymous: 3, dangling: 3}[.] // 4;

# Docker's size or memory string ("210.9MB", "0B", "412.3MiB") as bytes, decimal units for kB,
# MB, GB and TB and binary ones for KiB, MiB, GiB and TiB; null for "N/A" or anything else.
def bytes:
  (capture("^(?<n>[0-9]+(\\.[0-9]+)?) *(?<unit>[kKMGT]?i?B)$") // null) as $size
  | ({B: 1, kB: 1e3, KB: 1e3, MB: 1e6, GB: 1e9, TB: 1e12,
      KiB: 1024, MiB: 1048576, GiB: 1073741824, TiB: 1099511627776}[$size.unit // ""] // null) as $unit
  | if $unit == null then null else $size.n | tonumber * $unit | floor end;

# <n> with one decimal.
def one_decimal: (. * 10 | round) / 10 | tostring | if test("\\.") then . else . + ".0" end;

# A number of bytes in the largest of <units> (each <base> times the one before) it reaches,
# with one decimal; "-" for null.
def scaled($base; $units):
  if . == null then "-"
  elif . < $base then "\(.) B"
  else . as $n | ([$units | to_entries[] | select($n >= pow($base; .key + 1))] | last) as $unit
    | "\($n / pow($base; $unit.key + 1) | one_decimal) \($unit.value)" end;

# A size in bytes as Docker writes it on disk, in decimal units: "312.4 MB".
def disk_size: scaled(1000; ["kB", "MB", "GB", "TB"]);

# Memory in bytes, in binary units: "599.8 MiB".
def memory_size: scaled(1024; ["KiB", "MiB", "GiB", "TiB"]);

# A Docker time ("2026-10-24T09:00:00.123456789Z") as UTC seconds-precision ISO 8601.
def utc_time: sub("\\.[0-9]+Z$"; "Z");

# A number of seconds, at most one unit: "45s", "12m", "3h", "5d".
def duration:
  if . < 60 then "\(floor)s"
  elif . < 3600 then "\(. / 60 | floor)m"
  elif . < 86400 then "\(. / 3600 | floor)h"
  else "\(. / 86400 | floor)d" end;

# The time since the ISO 8601 UTC time <time>, at most one unit: "45s", "12m", "3h", "5d".
def age: now - (utc_time | fromdate) | duration;

# A time in any of Docker's forms ("2026-10-24T09:00:00.123456789Z", "2026-10-19T00:54:02+08:00",
# "2026-10-24 19:31:13 +0800 CST") as seconds since the epoch; null for anything else.
def epoch:
  [if type == "string" then
     capture("^(?<day>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<time>[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)? ?(?<zone>Z|[+-][0-9]{2}:?[0-9]{2})?")
   else empty end
   | (.zone // "Z" | sub(":"; "")) as $zone
   | ("\(.day)T\(.time)Z" | fromdate)
     - if $zone == "Z" then 0
       else (if $zone[0:1] == "-" then -1 else 1 end) * (($zone[1:3] | tonumber) * 3600 + ($zone[3:5] | tonumber) * 60) end][0];

# The machine's stack settings (~/.config/agent-team/stack.json), every key optional, each with
# its default and its kind, which team-stack and the heartbeat (team-timers) both read; an unset
# memory_floor_gib is null, its default depending on what is measured (memory_floor).
def settings_defaults:
  {stack_cap: 6, memory_floor_gib: null, disk_floor_gb: 30, wait_minutes: 15, idle_minutes: 30,
   heartbeat_sweep: false, heartbeat_janitor: false};
def settings_kinds:
  {stack_cap: "count", memory_floor_gib: "amount", disk_floor_gb: "amount", wait_minutes: "amount",
   idle_minutes: "amount", heartbeat_sweep: "boolean", heartbeat_janitor: "boolean"};

# What is wrong with the settings file's JSON values (read with jq -s), to follow its name: ""
# when nothing, " is not one JSON object", or ": <problem>; <problem>..." naming each key of the
# wrong type and each unknown key.
def settings_problems:
  settings_kinds as $kinds
  | if length != 1 or (.[0] | type) != "object" then " is not one JSON object"
    else [.[0] | to_entries[] | $kinds[.key] as $kind | (.value | tojson) as $value
      | if $kind == null then "\(.key) is not a setting (they are: \($kinds | keys_unsorted | join(", ")))"
        elif $kind == "count" and ((.value | type) != "number" or .value < 1 or .value != (.value | floor)) then
          "\(.key) must be a whole number of 1 or more, not \($value)"
        elif $kind == "amount" and ((.value | type) != "number" or .value < 0) then
          "\(.key) must be a number of 0 or more, not \($value)"
        elif $kind == "boolean" and (.value | type) != "boolean" then "\(.key) must be true or false, not \($value)"
        else empty end]
      | if . == [] then "" else ": " + join("; ") end
    end;

# Every setting, the given ones (the settings file's one object, or none) over the defaults.
def settings: settings_defaults + (.[0] // {});

# The memory floor admission keeps, from the settings (settings' output) on macOS or not with
# the memory reading's <total> bytes (on macOS Docker's VM's MemTotal): {bytes, says}, says what it
# is and where it came from. memory_floor_gib when set; else on Linux 6 GiB of the host's
# MemAvailable, and on macOS half of the VM's MemTotal, since its use and limits are all Docker's
# (no host load to keep room for), and half leaves the running containers room to grow toward
# their limits while a Conventioner stack's 2.75 GiB still fits Daniel's laptop's 7.7 GiB VM.
def memory_floor($macos; $total):
  if .memory_floor_gib != null then
    {bytes: (.memory_floor_gib * 1073741824), says: "floor \(.memory_floor_gib) GiB, memory_floor_gib in stack.json"}
  elif $macos then
    {bytes: ($total / 2),
     says: "floor \($total / 2 / 1073741824 | one_decimal) GiB, the macOS default: half of Docker's VM's \($total / 1073741824 | one_decimal) GiB"}
  else {bytes: (6 * 1073741824), says: "floor 6 GiB, the Linux default"} end;

# Rows (arrays of strings) as lines of left-aligned columns two spaces apart; nothing for no
# rows.
def table:
  if length == 0 then empty else
    [range(map(length) | max) as $i | map(.[$i] // "" | length) | max] as $widths
    | .[] | [to_entries[] | .value + " " * ($widths[.key] - (.value | length) + 2)] | join("") | sub(" +$"; "")
  end;

# The reaper's plan (team-stack reap, sops/docker.md "Removing what is left behind"): {actions,
# kept} from $in: {containers, volumes, networks (docker inspect's arrays), images (docker system
# df -v's Images), sizes (each volume's bytes by name), stacks (the registry's stack blocks),
# closed (the tasks the ledger has closed), gone (the worktree labels whose directory is gone),
# now (seconds since the epoch), legacy (--legacy), scope (a Compose project pattern, or null)}.
# Each action is {rule, type, name, ref (what docker <type> rm or compose -p takes), class,
# size_bytes, why, tasks, worktrees}, in the rules' order; each kept object {type, name, class,
# size_bytes, created}, every object no rule matched that is not the team's but Docker's own
# networks, a stack's containers listed as their stack. With a scope, only the Compose projects
# it matches and their objects are looked at.
def reap_plan($in):
  $in.stacks as $stacks | $in.now as $now
  | def in_scope: $in.scope == null or (. != null and test("^(?:" + $in.scope + ")$"));
    # "its task T5 is closed", "its tasks T5, T6 are closed": its(<noun>; <names>; <state>)
    def its($noun; $names; $state):
      "its \($noun)\(if ($names | length) == 1 then " " else "s " end)\($names | join(", ")) \(if ($names | length) == 1 then "is" else "are" end) \($state)";
  ([$in.containers[] | compose_project(.Config.Labels) as $p
    | {type: "container", name: (.Name | ltrimstr("/")), project: $p, image: .Image, labels: (.Config.Labels // {}),
       class: owner_class(.Config.Labels; $p; $stacks), size_bytes: null, created: (.Created | epoch),
       mounts: [.Mounts[]? | select(.Type == "volume" and .Name) | .Name],
       # A stopped container is on no network's Containers, but its own settings still name them.
       networks: [(.NetworkSettings.Networks // {} | keys[]), (.HostConfig.NetworkMode // empty)]}]) as $all
  | [$all[] | select(.project | in_scope)] as $containers
  | ([$all[].networks[]] | unique) as $networked
  | [$in.volumes[] | (.Labels // {}) as $l | .Name as $n
    | (($l | has("com.docker.volume.anonymous")) or (($n | test("^[0-9a-f]{64}$")) and compose_project($l) == null)) as $anonymous
    | ([$all[] | select(any(.mounts[]; . == $n))] | first) as $by
    | (if $anonymous and $by != null then $by.project else compose_project($l) end) as $p
    | {type: "volume", name: $n, ref: $n, anonymous: $anonymous, attached: ($by != null), project: $p,
       labels: (if $anonymous and $by != null then $by.labels else $l end),
       class: (if $anonymous then (if $by != null then $by.class else "anonymous" end) else owner_class($l; $p; $stacks) end),
       size_bytes: $in.sizes[$n], created: (.CreatedAt | epoch)}
    | select(.project | in_scope)] as $volumes
  | [$in.networks[] | (.Labels // {}) as $l | compose_project($l) as $p | .Name as $n
    | {type: "network", name: $n, ref: .Id, project: $p, labels: $l, class: owner_class($l; $p; $stacks),
       used: (($networked | index([$n])) != null or (.Containers // {} | length) > 0),
       predefined: (($n | IN("bridge", "host", "none")) and $l == {}), size_bytes: null, created: (.Created | epoch)}
    | select(.project | in_scope)] as $networks

  # The Compose projects, of the objects Docker labels with one; a stack's size is its volumes'.
  | [$containers[], ($volumes[] | select(.anonymous | not)), $networks[] | select(.project != null)]
  | group_by(.project)
  | map(.[0].project as $p
    | {type: "stack", name: $p, ref: $p, classes: (map(.class) | unique),
       tasks: ([.[] | team_label(.labels; "task") // empty] | unique),
       worktrees: ([.[] | team_label(.labels; "worktree") // empty] | unique),
       expires: ([.[] | team_label(.labels; "expires") // empty | epoch // empty] | max),
       created: (map(.created // empty) | min),
       size_bytes: ([$volumes[] | select(.project == $p) | .size_bytes // 0] | add // 0)}) as $projects

  | [$projects[] | select(.classes == ["team"])
    | (.tasks != [] and all(.tasks[]; IN($in.closed[]))) as $closed
    | select($closed or (.worktrees != [] and all(.worktrees[]; IN($in.gone[]))))
    | . + {rule: "team stack", class: "team",
           why: (if $closed then its("task"; .tasks; "closed") else its("worktree"; .worktrees; "gone") end)}]
    as $team_stacks
  | [$projects[] | select(.classes == ["gate"])
    | select(if .expires != null then .expires < $now else .created != null and .created < $now - 7200 end)
    | . + {rule: "gate stack", class: "gate",
           why: (if .expires != null then "it expired at \(.expires | todate)"
                 else "it has no expires and was created at \(.created | todate), over 2 hours ago" end)}] as $gate_stacks
  | ([$team_stacks[], $gate_stacks[] | {key: .name, value: true}] | from_entries) as $removed

  | ([$all[].image] | unique) as $used
  | [if $in.scope == null then $in.images[] else empty end
    | {type: "image", id: .ID, repository: .Repository,
       name: (if .Repository == "<none>" then .ID else "\(.Repository):\(.Tag)" end),
       ref: (if .Repository == "<none>" or .Tag == "<none>" then .ID else "\(.Repository):\(.Tag)" end),
       class: (if .Repository == "<none>" then "dangling" else image_class(.Repository; $stacks) end),
       in_use: (.ID as $id | ($used | index([$id])) != null),
       size_bytes: ((.UniqueSize | bytes) // (.Size | bytes)), created: (.CreatedAt | epoch)}] as $images
  # The 2 newest images of each team repository, by id: every tag of either is kept.
  | ([$images[] | select(.class == "team")] | group_by(.repository)
     | map(([unique_by(.id) | sort_by(-(.created // 0), .id) | .[:2][].id]) as $ids
       | .[] | select(.id | IN($ids[])) | {key: .name, value: true}) | from_entries) as $newest
  | [$images[] | select(.class == "team" and (.in_use | not) and .created != null and .created < $now - 7 * 86400
      and ($newest[.name] | not))
    | . + {rule: "shared image",
           why: "no container uses it, it was created over 7 days ago and it is not among the 2 newest of \(.repository)"}]
    as $shared
  | [$images[] | select($in.legacy and .class == "legacy" and (.in_use | not))
    | . + {rule: "legacy image", why: "a legacy image no container uses (--legacy)"}] as $legacy
  | [$images[] | select(.class == "dangling" and (.in_use | not) and .created != null and .created < $now - 86400)
    | . + {rule: "dangling image", why: "dangling, no container uses it and it was created over 24 hours ago"}] as $dangling

  | [$volumes[] | select(.anonymous and (.attached | not) and .created != null and .created < $now - 86400)
    | . + {rule: "unattached anonymous volume", why: "no container mounts it and it was created over 24 hours ago"}]
    as $anonymous
  | [$volumes[] | select(.class == "team" and (.anonymous | not) and (.attached | not) and ($removed[.project // ""] | not))
    | . + {rule: "team volume", why: "no container uses it"}] as $team_volumes
  | [$networks[] | select(.class == "team" and (.used | not) and ($removed[.project // ""] | not))
    | . + {rule: "team network", why: "no container uses it"}] as $team_networks

  | ($team_stacks + $gate_stacks + $shared + $legacy + $dangling + $anonymous + $team_volumes + $team_networks) as $actions
  | ([$actions[] | {key: "\(.type) \(.ref)", value: true}] | from_entries) as $acted
  | def unacted: select((.class != "team") and ($acted["\(.type) \(.ref)"] | not) and ($removed[.project // ""] | not));
  {actions: [$actions[] | {rule, type, name, ref, class, size_bytes, why, tasks, worktrees}],
   kept: ([$projects[] | . + {class: (.classes | join("+"))} | unacted]
     + [$containers[] | select(.project == null) | unacted]
     + [$volumes[] | unacted] + [$images[] | unacted] + [$networks[] | select(.predefined | not) | unacted]
     | map({type, name, class, size_bytes, created})
     | sort_by(({stack: 0, container: 1, volume: 2, image: 3, network: 4}[.type]), (.class | class_rank), .name))};

# An object of the reaper's plan as its lines name it: "<type> <name> (<class>[, <size>])".
def reap_object:
  "\(.type) \(.name) (\(.class)\(if .size_bytes == null then "" else ", \(.size_bytes | disk_size)" end))";
