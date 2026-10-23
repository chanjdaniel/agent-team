#!/usr/bin/env bats
# The coordinator's manual (roles/coordinator.md), its skills plugin, the worker roles' message
# forms and the root CLAUDE.md, checked against bin/ and each other so they cannot drift.
load helpers/common

setup() {
  sandbox
  manual=$REPO_ROOT/roles/coordinator.md
  plugin=$REPO_ROOT/plugins/coordinator-skills
}

# The team-* commands a file names, one per line, sorted and unique.
named_commands() {
  grep -oE '(^|[^[:alnum:]_/-])team-[a-z]+(-[a-z]+)*' "$1" | sed -E 's/^[^t]*//' | sort -u
}

# The skills the manual triggers: each "`<name>` skill" it names.
triggered_skills() {
  grep -oE '`[a-z]+(-[a-z]+)*` skill' "$manual" | sed -E 's/^`([^`]*)`.*/\1/' | sort -u
}

# A role file's lines under its "## <heading>", up to the next heading, blank lines dropped.
section() {
  awk -v h="## $2" '$0 == h { on = 1; next } /^## / { on = 0 } on && NF' "$REPO_ROOT/roles/$1.md"
}

@test "the manual is at most 120 lines" {
  local n
  n=$(wc -l <"$manual")
  echo "roles/coordinator.md has $n lines" >&2
  ((n > 0 && n <= 120))
}

@test "every bin/ path the manual names exists" {
  local path found=0 missing=()
  while IFS= read -r path; do
    found=$((found + 1))
    [[ -e $REPO_ROOT/$path ]] || missing+=("$path")
  done < <(grep -oE '\bbin/[A-Za-z0-9_./-]*[A-Za-z0-9_]' "$manual" | sort -u)
  assert_equal "${missing[*]}" ""
  ((found >= 1))
}

@test "every team-* command the manual names is a script in bin/" {
  local cmd missing=()
  [[ -f $manual ]]
  while IFS= read -r cmd; do
    [[ -x $REPO_ROOT/bin/$cmd ]] || missing+=("$cmd")
  done < <(named_commands "$manual")
  assert_equal "${missing[*]}" ""
}

@test "every bin/team-* script is named in the manual" {
  local script unnamed=() named
  named=$(named_commands "$manual")
  while IFS= read -r script; do
    grep -qx -- "$script" <<<"$named" || unnamed+=("$script")
  done < <(cd "$REPO_ROOT/bin" && find . -maxdepth 1 -type f -name 'team-*' -printf '%P\n' | sort)
  assert_equal "${unnamed[*]}" ""
}

@test "the manual triggers exactly the plugin's skills, handoff, recover-worker, resume, stow and status-report" {
  local skill
  assert_equal "$(triggered_skills | paste -sd ' ')" "handoff recover-worker resume status-report stow"
  assert_equal "$(cd "$plugin/skills" && find . -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort | paste -sd ' ')" \
    "handoff recover-worker resume status-report stow"
  for skill in $(triggered_skills); do
    # One line per trigger, so each stays a one-line pointer.
    assert_equal "$(grep -c "\`$skill\` skill" "$manual")" 1
    assert_equal "$(sed -n '2s/^name: //p' "$plugin/skills/$skill/SKILL.md")" "$skill"
    [[ $(sed -n '1p' "$plugin/skills/$skill/SKILL.md") == --- ]]
    grep -q '^description: .' "$plugin/skills/$skill/SKILL.md"
  done
}

@test "each worker role says what to do on STOW and on a resume, within its line budget" {
  local role body budget
  for role in builder planner reviewer; do
    body=$(section "$role" 'On STOW and on resume')
    budget=4
    [[ $role != builder ]] || budget=6
    echo "$role: $(wc -l <<<"$body") lines" >&2
    (($(wc -l <<<"$body") <= budget))
    grep -qF 'On `T<n> STOW`' <<<"$body"
    grep -qF 'write `.scratch/task/handoff.md` (done, next, anything odd) and reply `T<n> PAUSED stowed`' <<<"$body"
    grep -qF 'On a resume, read `.scratch/task/handoff.md` first when it exists, and delete it once the work it describes is done.' <<<"$body"
  done
  body=$(section builder 'On STOW and on resume')
  grep -qF 'with a no-mistakes run active, wait for it first and say so in `handoff.md`' <<<"$body"
  grep -qF 'commit what is unfinished as `wip: <what is unfinished>` on the task branch and push it' <<<"$body"
  grep -qF 'Never rewrite a `wip:` commit' <<<"$body"
  # A planner and a reviewer have nothing to commit: their stow is the handoff note alone.
  for role in planner reviewer; do
    if section "$role" 'On STOW and on resume' | grep -Eiw 'commit|push|wip'; then
      echo "$role's stow commits or pushes" >&2
      return 1
    fi
  done
}

@test "the manual logs a worker's PAUSED stowed as paused, the answer to its STOW" {
  grep -E '^\| `PAUSED stowed` \| `paused reason=stowed` \| .*`T<n> STOW`' "$manual"
}

@test "the stow skill leaves a machine handoff to the handoff skill" {
  local skill=$plugin/skills/stow/SKILL.md
  grep -qF 'the `handoff` skill' "$skill"
  if grep -nE '^#.*handoff' "$skill"; then
    echo "the stow skill still has a handoff section" >&2
    return 1
  fi
}

@test "the plugin is named in its manifest and team-load-check forbids it to workers" {
  local name
  name=$(jq -r .name "$plugin/.claude-plugin/plugin.json")
  assert_equal "$name" coordinator-skills
  # The forbidden pattern is the one grep -Ei line that fails a production or coordinator-only plugin.
  grep -E "grep -Eiq '[^']*\b$name\b[^']*'" "$REPO_ROOT/bin/team-load-check"
}

@test "the root CLAUDE.md gives layout, tests and conventions, and addresses nobody as the coordinator" {
  local doc=$REPO_ROOT/CLAUDE.md
  [[ -f $doc ]]
  grep -q 'tests/run' "$doc"
  grep -q 'bin/lib/team.sh' "$doc"
  grep -q 'TEAM_HOME' "$doc"
  grep -q -- '--help' "$doc"
  grep -q 'ledger_append' "$doc"
  if grep -Eni 'you are (the|a) coordinator|as the coordinator,|coordinator-skills:' "$doc"; then
    echo "CLAUDE.md speaks to the coordinator" >&2
    return 1
  fi
}

@test "the registry lists CLAUDE.md as the team home's docs" {
  cp "$REPO_ROOT/projects.toml" "$TEAM_HOME/projects.toml"
  run_bin -0 team-project agent-team docs
  assert_equal "$(jq -c . <<<"$output")" '["CLAUDE.md"]'
}

@test "the manual, CLAUDE.md and the skills put one sentence on each line and call Daniel they" {
  local files=("$manual" "$REPO_ROOT/CLAUDE.md" "$plugin"/skills/*/SKILL.md) file
  for file in "${files[@]}"; do [[ -f $file ]] || { echo "missing $file" >&2; return 1; }; done
  # A sentence ends in ". " after a word and before a capital, outside code spans; a skill's
  # description is one YAML value, so it may hold two.
  local joined
  joined=$(sed -E 's/`[^`]*`//g' "${files[@]}" | grep -vE '^description: ' | grep -nE '[a-z)][.!?] +[A-Z]' || true)
  assert_equal "$joined" ""
  joined=$(grep -nEiw 'he|him|his|she|her|hers' "${files[@]}" || true)
  assert_equal "$joined" ""
}

@test "the handoff skill holds the procedure in order: check, post, STOW and wait, run, post, retire" {
  local skill=$plugin/skills/handoff/SKILL.md steps
  steps=$(grep -oE '^[0-9]+\. \*\*[A-Za-z ]+\.\*\*' "$skill" | sed -E 's/^[0-9]+\. \*\*(.*)\.\*\*$/\1/' | paste -sd ,)
  assert_equal "$steps" "Check,Stow yourself,Post,STOW the workers,Run,Post the final message,Retire"
  grep -qF '`team-handoff --check`' "$skill"
  grep -qF 'Send `T<n> STOW` to each live worker' "$skill"
  grep -qF 'up to 10 minutes' "$skill"
  grep -qF '`team-handoff --retire`' "$skill"
  grep -qF '`team-handoff` moves the team off this machine' "$manual"
}

@test "the resume skill holds the procedure in order: read, catch up on Discord, relaunch, log, post, clean up" {
  local skill=$plugin/skills/resume/SKILL.md steps
  steps=$(grep -oE '^[0-9]+\. \*\*[A-Za-z ]+\.\*\*' "$skill" | sed -E 's/^[0-9]+\. \*\*(.*)\.\*\*$/\1/' | paste -sd ,)
  assert_equal "$steps" "Read,Catch up on Discord,Relaunch,Log,Post,Clean up"
  grep -qF 'Read the report and run `team-snapshot`.' "$skill"
  grep -qF 'Messages sent while no coordinator listened are never delivered to you, only readable.' "$skill"
  grep -qF '`fetch_messages` back to your own last message there' "$skill"
  grep -qF 'answer anything Daniel asked that has no answer, before anything else' "$skill"
  grep -qF '`team-brief T<n> resume --name resume-<role> --force --set role=<role> --set brief=<that brief> --set from=' "$skill"
  grep -qF '`team-worker T<n> <role> <worktree>' "$skill"
  grep -qF '`team-log T<n> resumed`' "$skill"
  grep -qF 'Delete the report once everything in it runs again.' "$skill"
  # The manual names the command, the skill and the missed Discord history.
  grep -qF '`team-resume` takes the team over' "$manual"
  grep -qF 'Your first prompt names a resume report: the `resume` skill.' "$manual"
  grep -qF 'Messages sent while no coordinator listened are never delivered to you, only readable: on a resume, read `#coordinator` and each open task'"'"'s thread back to your own last message' "$manual"
}
