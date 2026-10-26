# tool <name>   Each tool bin/lib/tools.lock lists for this OS, by its version_cmd: missing, a
#               version it cannot read (no line of the output matches its version_pattern, as
#               when it prints only another tool's version), or below its min fails; a version
#               off its pin fails, or
#               warns where the lock says pin_mismatch WARN (Claude Code, which updates itself).
#               Each runs with the library's PATH, the tool directories of the lock first, and a
#               tool the lock marks show_path (Python) names the command it found ("3.12.4 at
#               /opt/homebrew/opt/python@3.12/libexec/bin/python3").
#               The fix is the lock's install command for this OS and machine type (uname -m),
#               from bin/lib/tools.jq: for a GitHub release, its archive checked against the
#               SHA-256 the lock records; for a fork (no-mistakes), a build of its pinned
#               commit, with Go and make from their own tool lines.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2004 # installed, an associative array of the doctor's, for the later checks

lock=$TEAM_LIB/tools.lock

# Whether version <a> is below version <b>, number by number: version_below <a> <b>
version_below() {
  local -a a b
  local i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    if ((10#${a[i]:-0} < 10#${b[i]:-0})); then return 0; fi
    if ((10#${a[i]:-0} > 10#${b[i]:-0})); then return 1; fi
  done
  return 1
}

# One tool of the lock: check_tool <name> <version_cmd> <pattern> <pin> <min> <pin_mismatch>
# <show_path> <source>
check_tool() {
  local name=$1 cmd=$2 pattern=$3 pin=$4 min=$5 mismatch=$6 show=$7 source=$8 words out rc=0 version='' shown line
  read -ra words <<<"$cmd"
  out=$(bounded 30 "${words[@]}" 2>&1 </dev/null) || rc=$?
  # The first line that matches gives the version, so ^ and $ anchor to a line.
  while IFS= read -r line; do
    if [[ $line =~ $pattern ]]; then version=${BASH_REMATCH[1]} && break; fi
  done <<<"$out"
  ((rc == 127)) || installed[$name]=1
  if ((rc == 127)); then
    report "tool $name" FAIL "not installed" "$source"
  elif ((rc == 124)); then
    report "tool $name" FAIL "\`$cmd\` did not answer within 30 s" "$source"
  elif [[ -z $version ]]; then
    report "tool $name" FAIL "\`$cmd\` printed no version" "$source"
  else
    shown=$version
    [[ $show != true ]] || shown+=" at $(command -v "${words[0]}")"
    if [[ -n $pin && $version == "$pin" ]]; then
      report "tool $name" PASS "$shown"
    elif [[ -n $pin ]]; then
      report "tool $name" "$mismatch" "$shown, not the pinned $pin" "$source"
    elif version_below "$version" "$min"; then
      report "tool $name" FAIL "$shown, below the minimum $min" "$source"
    else
      report "tool $name" PASS "$shown (minimum $min)"
    fi
  fi
}

# Each tool of the lock, on fd 3, since a tool's version command may read stdin.
if [[ -n $os ]]; then
  while IFS= read -r -u 3 name && IFS= read -r -u 3 cmd && IFS= read -r -u 3 pattern &&
    IFS= read -r -u 3 pin && IFS= read -r -u 3 min && IFS= read -r -u 3 mismatch &&
    IFS= read -r -u 3 show && IFS= read -r -u 3 source; do
    check_tool "$name" "$cmd" "$pattern" "$pin" "$min" "$mismatch" "$show" "$source"
  done 3< <(jq -L "$TEAM_LIB" -r --arg os "$os" --arg machine "$(uname -m)" 'include "tools"; tools_for($os; $machine)
    | .name, .version_cmd, .version_pattern, .pin, .min, .pin_mismatch, .show_path, .source' "$lock")
fi
