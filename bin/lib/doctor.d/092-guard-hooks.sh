# guard hooks   Runs each guard hook of bin/hooks/ that the sessions' settings run on a Bash
#               call (scratch-only-edits, command-guard, lease-fence and lease-fence
#               --coordinator) on one harmless call (ls), within its settings' timeout, and
#               fails on any exit but 0, naming the hook, its exit code (a timeout's, 124, as
#               "did not answer") and its first stderr line: since each settings entry blocks on
#               its hook's failure (onFailure block), a guard that fails blocks every call it
#               sees, the coordinator's Discord posts included.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, scratch and the doctor's report

# Each guard's command line and its timeout in seconds, as the settings give it (tests/repo.bats
# holds the settings to these).
guard_hooks=("scratch-only-edits:30" "command-guard:10" "lease-fence:60" "lease-fence --coordinator:60")
guard_input=$(jq -cn --arg cwd "$scratch" '{session_id: "team-doctor", hook_event_name: "PreToolUse",
  tool_name: "Bash", tool_input: {command: "ls", description: "List files"}, cwd: $cwd}')
guard_failed=()
for guard in "${guard_hooks[@]}"; do
  guard_seconds=${guard##*:} guard=${guard%:*}
  read -ra guard_words <<<"$guard"
  guard_rc=0
  (cd "$scratch" && TEAM_HOME=$TEAM_HOME bounded "$guard_seconds" "$bin/hooks/${guard_words[0]}" "${guard_words[@]:1}" \
    >/dev/null 2>"$err" <<<"$guard_input") || guard_rc=$?
  if ((guard_rc == 0)); then
    continue
  elif ((guard_rc == 124)); then
    guard_failed+=("$guard did not answer within its $guard_seconds s")
  else
    guard_line=$(grep -m1 . "$err" || true)
    guard_failed+=("$guard exited $guard_rc${guard_line:+ (\"$guard_line\")}")
  fi
done
if ((${#guard_failed[@]} == 0)); then
  report "guard hooks" PASS "scratch-only-edits, command-guard, lease-fence and lease-fence --coordinator each pass a harmless Bash call (ls)"
else
  guard_reason=$(printf '%s; ' "${guard_failed[@]}" | sed 's/; $//')
  report "guard hooks" FAIL "on a harmless Bash call (ls), $guard_reason, so each blocks every call it guards" \
    "fix each hook named in $(tilde "$bin/hooks"), then run team-doctor again"
fi
