#!/usr/bin/env bats
# The coordinator's manual (roles/coordinator.md), its skills plugin and the root CLAUDE.md,
# checked against bin/ so the manual and the tools cannot drift.
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

@test "the manual triggers exactly the plugin's skills, recover-worker, retro, stow and status-report" {
  local skill
  assert_equal "$(triggered_skills | paste -sd ' ')" "recover-worker retro status-report stow"
  assert_equal "$(cd "$plugin/skills" && find . -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort | paste -sd ' ')" \
    "recover-worker retro status-report stow"
  for skill in $(triggered_skills); do
    # One line per trigger, so each stays a one-line pointer.
    assert_equal "$(grep -c "\`$skill\` skill" "$manual")" 1
    assert_equal "$(sed -n '2s/^name: //p' "$plugin/skills/$skill/SKILL.md")" "$skill"
    [[ $(sed -n '1p' "$plugin/skills/$skill/SKILL.md") == --- ]]
    grep -q '^description: .' "$plugin/skills/$skill/SKILL.md"
  done
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
