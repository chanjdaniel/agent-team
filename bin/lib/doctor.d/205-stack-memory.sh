# stack memory  Warns while, with nothing else running, the most memory team-stack up's
#               admission can read (macOS: docker info's MemTotal, Docker's VM; Linux: the
#               host's MemTotal) less a stack's mem_limits is under the floor admission keeps
#               (memory_floor_gib in ~/.config/agent-team/stack.json, else 6 GiB on Linux and
#               half the VM on macOS), naming each registered project with a stack block whose
#               stack would never be admitted. The limits are the wrapper's config --format json,
#               run in the primary checkout with TH_PORTS=auto and COMPOSE_PROJECT_NAME
#               team-doctor-<project>, which starts nothing. Passes saying so with no stack block,
#               with docker info not answering on macOS, or for a project whose wrapper is
#               missing or fails; warns on a stack.json team-stack refuses.
# shellcheck shell=bash
# shellcheck disable=SC2154 # err, the doctor's; os, from the os check

# The stack memory line, for the registered projects <projects> (one per line): with nothing
# else running, whether the memory team-stack's admission reads at most, less a stack's
# mem_limits, leaves the floor it keeps (memory_floor in bin/lib/stack.jq).
stack_memory() {
  local project facts path compose config limits file=$HOME/.config/agent-team/stack.json given='[]'
  local problems total reading floor macos=false fix line says details
  local -a stacks=() weighed=() short=() unknown=()
  while IFS= read -r project; do
    [[ -n $project ]] || continue
    facts=$(team_project "$project" 2>/dev/null) || continue
    if jq -e '.stack != null' <<<"$facts" >/dev/null; then stacks+=("$project"); fi
  done <<<"$1"
  if ((${#stacks[@]} == 0)); then
    report "stack memory" PASS "no registered project has a stack block"
    return
  fi
  fix="correct it as team-stack --help describes, since team-stack up refuses it too"
  if [[ -e $file ]]; then
    if ! given=$(jq -s . "$file" 2>/dev/null); then
      report "stack memory" WARN "$(tilde "$file") is not JSON" "$fix"
      return
    fi
    problems=$(jq -r -L "$TEAM_LIB" 'include "stack"; settings_problems(settings_kinds)' <<<"$given")
    if [[ -n $problems ]]; then
      report "stack memory" WARN "$(tilde "$file")$problems" "$fix"
      return
    fi
  fi
  if [[ $os == macos ]]; then
    macos=true
    if ! total=$(bounded 30 docker info --format '{{.MemTotal}}' 2>/dev/null </dev/null) || [[ ! $total =~ ^[0-9]+$ ]]; then
      report "stack memory" PASS "unknown, since docker info does not answer (the docker line)"
      return
    fi
    reading="Docker's VM's $(jq -nr -L "$TEAM_LIB" --argjson b "$total" 'include "stack"; $b / 1073741824 | one_decimal') GiB"
    fix="Daniel gives Docker Desktop more memory (Settings, Resources) or sets a lower memory_floor_gib in ~/.config/agent-team/stack.json"
  else
    if ! total=$(awk '$1 == "MemTotal:" { print $2 * 1024; found = 1 } END { exit !found }' "${TEAM_MEMINFO:-/proc/meminfo}" 2>/dev/null); then
      report "stack memory" PASS "unknown, since ${TEAM_MEMINFO:-/proc/meminfo} gives no MemTotal"
      return
    fi
    reading="this machine's $(jq -nr -L "$TEAM_LIB" --argjson b "$total" 'include "stack"; $b / 1073741824 | one_decimal') GiB (MemTotal)"
    fix="Daniel sets a lower memory_floor_gib in ~/.config/agent-team/stack.json, or gives this machine more memory"
  fi
  floor=$(jq -c -L "$TEAM_LIB" --argjson macos "$macos" --argjson total "$total" \
    'include "stack"; settings | memory_floor($macos; $total)' <<<"$given")

  # Each stack's mem_limits, from its wrapper's config in the primary checkout, called as a
  # project of its own whose ports Docker assigns, so it names no stack that runs.
  for project in "${stacks[@]}"; do
    facts=$(team_project "$project")
    path=$(jq -r .path <<<"$facts") compose=$(jq -r .stack.compose <<<"$facts")
    if [[ ! -x $path/$compose ]]; then
      unknown+=("unknown for $project, since its checkout has no $compose")
      continue
    fi
    if ! config=$(
      while IFS= read -r line; do unset "$line"; done < <(compgen -e | grep -E '^(TH_|COMPOSE_|TEAM_(OWNER|TASK|KIND|WORKTREE|EXPIRES)$)')
      cd "$path" && TH_DIR=$path COMPOSE_PROJECT_NAME=team-doctor-$project TH_PORTS=auto \
        bounded 60 "$path/$compose" config --format json 2>"$err" </dev/null
    ) || ! limits=$(jq -e '[.services[]?.mem_limit // 0 | tonumber] | add // 0' <<<"$config" 2>/dev/null); then
      unknown+=("unknown for $project, since $compose config --format json failed: $(grep . "$err" | tail -n 1 || echo "no reason given")")
      continue
    fi
    weighed+=("$(jq -nc --arg project "$project" --argjson limits "$limits" --argjson total "$total" --argjson floor "$floor" \
      '{project: $project, limits: $limits, left: ($total - $limits), short: ($total - $limits < $floor.bytes)}')")
  done

  # A warning names only the stacks short of the floor; a pass every stack it weighed, and those
  # it could not.
  says=$(jq -r .says <<<"$floor")
  mapfile -t short < <(printf '%s\n' "${weighed[@]}" | jq -r 'select(.short) | .project')
  details=$(printf '%s\n' "${weighed[@]}" | jq -nr -L "$TEAM_LIB" --argjson warn $((${#short[@]} > 0)) 'include "stack";
    [inputs | select($warn == 0 or .short)] | to_entries
    | map("\(.value.project)'"'"'s \(.value.limits / 1073741824 | one_decimal) GiB\(if .key == 0 then " of mem_limits" else "" end) leaves \(.value.left / 1073741824 | one_decimal) GiB")
    | join(", ")')
  if ((${#short[@]} == 0 && ${#unknown[@]})); then
    [[ -z $details ]] || details+="; "
    details+=$(printf '%s; ' "${unknown[@]}" | sed 's/; $//')
  fi
  if ((${#short[@]})); then
    report "stack memory" WARN "with nothing else running, $reading leaves less than the floor after a stack of $(printf '%s, ' "${short[@]}" | sed 's/, $//') ($says), so team-stack up refuses it: $details" "$fix"
  elif ((${#weighed[@]})); then
    report "stack memory" PASS "with nothing else running, $reading leaves at least the floor after a stack of each project ($says): $details"
  else
    report "stack memory" PASS "$details"
  fi
}

# On a supported OS, once the registry is read (the projects line reports a registry it refuses).
if [[ -n $os ]] && projects=$(team_project --list 2>/dev/null); then
  stack_memory "$projects"
fi
