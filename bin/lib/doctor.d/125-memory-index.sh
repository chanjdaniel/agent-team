# memory index  Each memory/*/MEMORY.md of the team home against Claude Code's load cap: a session
#               loads the first 200 lines or 25KB of a MEMORY.md, whichever comes first
#               (https://code.claude.com/docs/en/memory), and Claude Code 2.1.323 counts the 25KB
#               as 25,000 characters of the trimmed text (UTF-16 code units, as JavaScript counts a
#               string), cutting at the last whole line within them. Warns, never fails, so the
#               load check and team-resume go on, naming each index past the cap with its lines,
#               its characters and the line the cut falls at; the fix is to condense the index's
#               lines to their hooks. Passes, naming the fullest, when each fits; passes when
#               there is no index; warns naming an index it cannot read, and with no team home.
#               Never prints a memory's text.
# shellcheck shell=bash

# One jq per index: its lines, its characters, the lines a session loads and how full it is.
memory_lines=200 memory_chars=25000
memory_reasons=() memory_fixes=() memory_unread=() memory_count=0 memory_fullest=''
if [[ -z $TEAM_HOME || ! -d $TEAM_HOME ]]; then
  report "memory index" WARN "no team home to read the memory indexes from (the team home line)" \
    "the team home line's fix, then run team-doctor again"
else
  for memory_index in "$TEAM_HOME"/memory/*/MEMORY.md; do
    [[ -f $memory_index ]] || continue
    memory_path=${memory_index#"$TEAM_HOME"/}
    memory_project=${memory_path#memory/} memory_project=${memory_project%/MEMORY.md}
    if [[ ! -r $memory_index ]] || ! memory_view=$(jq -Rsr --argjson lines "$memory_lines" --argjson chars "$memory_chars" '
      def units: [explode[] | if . > 65535 then 2 else 1 end] | add // 0;
      def commas: tostring | until(test("^[0-9]{4}") | not; sub("(?<a>[0-9])(?<b>[0-9]{3})(?<c>(,|$))"; "\(.a),\(.b)\(.c)"));
      trim | split("\n") as $all
      | ($all | length) as $n
      # Where each of the first $lines lines ends, its newline there: a line loads when it ends
      # within $chars.
      | ([foreach ($all[:$lines][] | units) as $u (-1; . + 1 + $u)] | map(select(. <= $chars)) | length) as $kept
      | (if $n == 0 then 0 else ($all | map(units) | add) + $n - 1 end) as $size
      | (if $n > $lines or $size > $chars then "over" else "fits" end), $kept,
        ([$n / $lines, $size / $chars] | max),
        "\($n) \(if $n == 1 then "line" else "lines" end) and \($size | commas) characters"' "$memory_index" 2>/dev/null); then
      memory_unread+=("$memory_path")
      continue
    fi
    { read -r memory_verdict && read -r memory_kept && read -r memory_fill && read -r memory_counts; } <<<"$memory_view"
    memory_count=$((memory_count + 1))
    if [[ $memory_verdict == over ]]; then
      memory_cap="past it too"
      ((${#memory_reasons[@]})) || memory_cap="past Claude Code's load cap of 200 lines or 25,000 characters"
      if ((memory_kept == 0)); then
        memory_load="part of line 1 and the cut falls inside it"
      elif ((memory_kept == 1)); then
        memory_load="line 1 and the cut falls at line 2"
      else
        memory_load="lines 1 to $memory_kept and the cut falls at line $((memory_kept + 1))"
      fi
      memory_reasons+=("$memory_project's MEMORY.md is $memory_counts, $memory_cap, so its sessions load $memory_load")
      memory_fixes+=("$memory_path")
    elif [[ -z $memory_fullest ]] || jq -ne --argjson a "$memory_fill" --argjson b "$memory_fullest_fill" '$a > $b' >/dev/null; then
      memory_fullest="$memory_project's, is $memory_counts" memory_fullest_fill=$memory_fill
    fi
  done
  if ((${#memory_reasons[@]} + ${#memory_unread[@]})); then
    memory_fix=()
    if ((${#memory_fixes[@]})); then
      memory_list=$(printf '%s and ' "${memory_fixes[@]}")
      memory_fix+=("condense each line of ${memory_list% and } to its hook, one line per memory, so every memory loads")
    fi
    if ((${#memory_unread[@]})); then
      memory_list=$(printf '%s and ' "${memory_unread[@]}")
      memory_reasons+=("${memory_list% and } cannot be read")
      memory_fix+=("make ${memory_list% and } readable, then run team-doctor again")
    fi
    memory_reason=$(printf '%s; ' "${memory_reasons[@]}")
    memory_list=$(printf '%s; ' "${memory_fix[@]}")
    report "memory index" WARN "${memory_reason%; }" "${memory_list%; }"
  elif ((memory_count == 0)); then
    report "memory index" PASS "the team home has no memory/*/MEMORY.md, so no index to load"
  else
    memory_indexes="$memory_count memory indexes, each"
    ((memory_count > 1)) || memory_indexes="1 memory index,"
    report "memory index" PASS \
      "$memory_indexes within Claude Code's load cap of 200 lines and 25,000 characters; the fullest, $memory_fullest"
  fi
fi
