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
def class_rank: {team: 0, gate: 1, legacy: 1, unowned: 2, anonymous: 3}[.] // 4;

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

# The time since the ISO 8601 UTC time <time>, at most one unit: "45s", "12m", "3h", "5d".
def age:
  (now - (utc_time | fromdate)) as $s
  | if $s < 60 then "\($s | floor)s"
    elif $s < 3600 then "\($s / 60 | floor)m"
    elif $s < 86400 then "\($s / 3600 | floor)h"
    else "\($s / 86400 | floor)d" end;

# Rows (arrays of strings) as lines of left-aligned columns two spaces apart; nothing for no
# rows.
def table:
  if length == 0 then empty else
    [range(map(length) | max) as $i | map(.[$i] // "" | length) | max] as $widths
    | .[] | [to_entries[] | .value + " " * ($widths[.key] - (.value | length) + 2)] | join("") | sub(" +$"; "")
  end;
