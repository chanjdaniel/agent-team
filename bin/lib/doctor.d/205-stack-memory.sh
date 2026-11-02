# stack memory  Warns while a registered project with a stack block has a stack whose mem_limits,
#               the seed team-capacity admits a stack it has no estimate of at, exceed full's
#               memory budget with nothing else running (min(full_share * T, T - reserve_gib), T
#               the newest reading's memory total, as team-level sizes it), so team-stack up would
#               never be admitted, naming each such project. The limits are the wrapper's config
#               --format json, run in the primary checkout with TH_PORTS=auto and
#               COMPOSE_PROJECT_NAME team-doctor-<project>, which starts nothing. Passes saying so
#               with no stack block, with no reading of the machine's load yet or a team-capacity
#               status that fails (the resources line says why), or for a project whose
#               wrapper is missing or fails; warns on a stack.json team-stack refuses, and on a
#               stack_cap or memory_floor_gib left in it, which nothing reads any more.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's; os, from the os check

# The stack memory line, for the registered projects <projects> (one per line): whether full's
# memory budget with nothing else running holds a stack of each, and what stack.json still sets
# that nothing reads.
stack_memory() {
  local project facts path compose config limits file=$HOME/.config/agent-team/stack.json given='[]'
  local problems status budget total fix line details stale=''
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
    stale=$(jq -r -L "$TEAM_LIB" 'include "stack"; [.[0] | keys_unsorted[] | select(IN(no_longer_read[]))] | join(" and ")' <<<"$given")
  fi
  if [[ -n $stale ]]; then
    report "stack memory" WARN "$(tilde "$file") sets $stale, which nothing reads since the level's budget admits a stack (team-capacity admit)" \
      "remove $stale from $(tilde "$file")"
    return
  fi
  if ! status=$(TEAM_HOME=$TEAM_HOME "$bin/team-capacity" status --json --stored 2>/dev/null </dev/null); then
    report "stack memory" PASS "unknown, since team-capacity status fails (the resources line says why)"
    return
  fi
  if [[ $(jq -r '.reading.memory.total // "none"' <<<"$status") == none ]]; then
    report "stack memory" PASS "unknown, since there is no reading of the machine's load yet (the resources line)"
    return
  fi
  budget=$(jq -L "$TEAM_LIB" 'include "capacity"; include "stack";
    capacity_budget(.settings; "full"; .reading | .memory.others = 0; null; 0).memory_bytes' <<<"$status")
  total=$(jq -r '.reading.memory.total' <<<"$status")
  fix="Daniel raises full_share or lowers reserve_gib in ~/.config/agent-team/capacity.json, or gives this machine more memory"

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
    weighed+=("$(jq -nc --arg project "$project" --argjson limits "$limits" --argjson budget "$budget" \
      '{project: $project, limits: $limits, short: ($limits > $budget)}')")
  done

  # A warning names only the stacks over the budget; a pass every stack it weighed, and those it
  # could not.
  mapfile -t short < <(printf '%s\n' "${weighed[@]}" | jq -r 'select(.short) | .project')
  details=$(printf '%s\n' "${weighed[@]}" | jq -nr -L "$TEAM_LIB" --argjson warn $((${#short[@]} > 0)) 'include "stack";
    [inputs | select($warn == 0 or .short)] | to_entries
    | map("\(.value.project)'"'"'s \(.value.limits / 1073741824 | one_decimal) GiB\(if .key == 0 then " of mem_limits" else "" end)")
    | join(", ")')
  if ((${#short[@]} == 0 && ${#unknown[@]})); then
    [[ -z $details ]] || details+="; "
    details+=$(printf '%s; ' "${unknown[@]}" | sed 's/; $//')
  fi
  line="with nothing else running, full's budget is $(jq -nr -L "$TEAM_LIB" --argjson b "$budget" --argjson t "$total" \
    'include "stack"; "\($b / 1073741824 | one_decimal) GiB of \($t / 1073741824 | one_decimal) GiB"')"
  if ((${#short[@]})); then
    report "stack memory" WARN "$line, less than a stack of $(printf '%s, ' "${short[@]}" | sed 's/, $//') needs, so team-capacity never admits it: $details" "$fix"
  elif ((${#weighed[@]})); then
    report "stack memory" PASS "$line, which holds a stack of each project: $details"
  else
    report "stack memory" PASS "$details"
  fi
}

# On a supported OS, once the registry is read (the projects line reports a registry it refuses).
if [[ -n $os ]] && projects=$(team_project --list 2>/dev/null); then
  stack_memory "$projects"
fi
