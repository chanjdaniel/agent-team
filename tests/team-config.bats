#!/usr/bin/env bats
# team-config: machine/claude/ in the team home against this machine's ~/.claude, by copies.
# The team home holds a small shared config; HOME starts with the same config installed, and each
# test changes one side. The claude stub answers `plugin list --json` and
# `plugin marketplace list --json` from $STUB_FIXTURES/plugins.json and marketplaces.json.

load helpers/common

setup() {
  sandbox
  make_team_home >/dev/null
  shared=$TEAM_HOME/machine/claude
  mkdir -p "$shared/skills/tdd" "$shared/skills/wizard/references"
  echo "Never use the em dash." >"$shared/CLAUDE.md"
  echo "Agents' instructions." >"$shared/AGENTS.md"
  jq -n '{model: "opus", enabledPlugins: {"discord@claude-plugins-official": false}}' >"$shared/settings.json"
  printf '%s\n' '---' 'name: tdd' '---' 'Red, green, refactor.' >"$shared/skills/tdd/SKILL.md"
  printf '%s\n' '---' 'name: wizard' '---' >"$shared/skills/wizard/SKILL.md"
  echo "Steps only a human can take." >"$shared/skills/wizard/references/steps.md"
  echo '{"version": 3, "skills": {}}' >"$shared/skill-lock.json"
  printf '%s\n' '# User-scope plugins every machine installs, and their marketplaces (team-config).' \
    'marketplace anthropics/claude-plugins-official' \
    'plugin discord@claude-plugins-official' 'plugin mongodb-atlas@claude-plugins-official' >"$shared/plugins.txt"
  git -C "$TEAM_HOME" add -A
  git -C "$TEAM_HOME" commit -q -m "chore: the shared config"

  # This machine has it all installed, the lock and the plugins included.
  mkdir -p "$HOME/.claude/skills" "$HOME/.agents"
  cp "$shared"/{CLAUDE.md,AGENTS.md,settings.json} "$HOME/.claude/"
  cp -R "$shared/skills/tdd" "$shared/skills/wizard" "$HOME/.claude/skills/"
  cp "$shared/skill-lock.json" "$HOME/.agents/.skill-lock.json"
  plugins_installed discord@claude-plugins-official mongodb-atlas@claude-plugins-official
  echo '[{"name": "claude-plugins-official", "source": "github", "repo": "anthropics/claude-plugins-official"}]' \
    >"$STUB_FIXTURES/marketplaces.json"
  stub_script claude <<'EOF'
case $* in
  'plugin list --json') cat "$STUB_FIXTURES/plugins.json" ;;
  'plugin marketplace list --json') cat "$STUB_FIXTURES/marketplaces.json" ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 127 ;;
esac
EOF
}

# `claude plugin list --json` lists these plugins at user scope, enabled.
plugins_installed() {
  printf '%s\n' "$@" | jq -R '{id: ., version: "1.0.0", scope: "user", enabled: true}' | jq -s . \
    >"$STUB_FIXTURES/plugins.json"
}

# The backup folders apply made, one per line.
backups() {
  find "$HOME/.claude/backups" -mindepth 1 -maxdepth 1 -name 'team-config-*' 2>/dev/null | sort
}

@test "a machine with the team home's config installed has no difference" {
  run_bin -0 team-config diff
  assert_equal "$output" ""
  run_bin -0 team-config diff --json
  assert_equal "$output" "[]"
}

@test "diff prints one line per difference and exits 1; a local-only skill is listed" {
  echo '{"model": "sonnet"}' >"$HOME/.claude/settings.json"
  rm "$HOME/.claude/AGENTS.md"
  rm -r "$HOME/.claude/skills/tdd"
  echo "Changed here." >>"$HOME/.claude/skills/wizard/references/steps.md"
  mkdir -p "$HOME/.claude/skills/retro" "$HOME/.claude/skills/synced/claude-ai"
  echo "Look back." >"$HOME/.claude/skills/retro/SKILL.md"
  echo '{"version": 3, "skills": {"lavish": {}}}' >"$HOME/.agents/.skill-lock.json"
  plugins_installed discord@claude-plugins-official ponder@claude-plugins-official
  run_bin -1 team-config diff
  assert_equal "$output" "AGENTS.md missing
settings.json differs
skill retro local only
skill tdd missing
skill wizard differs
skill-lock.json differs
plugin mongodb-atlas@claude-plugins-official not installed
plugin ponder@claude-plugins-official not in plugins.txt"
  run_bin -1 team-config diff --json
  jq -e 'length == 8 and .[1] == {item: "settings.json", state: "differs"} and .[2] == {item: "skill retro", state: "local only"}' <<<"$output"
}

@test "diff --full adds a unified diff, the team home's side first, under each text that differs; settings as sorted JSON" {
  echo '{"model": "sonnet"}' >"$HOME/.claude/settings.json"
  echo "Changed here." >>"$HOME/.claude/skills/wizard/references/steps.md"
  run_bin -1 team-config diff --full
  assert_equal "$(sed -n 1p <<<"$output")" "settings.json differs"
  assert_contains "$output" "--- $shared/settings.json"
  assert_contains "$output" "+++ $HOME/.claude/settings.json"
  assert_contains "$output" '-  "model": "opus"'
  assert_contains "$output" '+  "model": "sonnet"'
  assert_contains "$output" "skill wizard differs"
  assert_contains "$output" "+Changed here."
}

@test "a marketplace or plugin missing here is listed, and one only here too; claude not answering is one line" {
  echo '[]' >"$STUB_FIXTURES/marketplaces.json"
  run_bin -1 team-config diff
  assert_equal "$output" "marketplace anthropics/claude-plugins-official not added"
  echo '[{"name": "x", "source": "github", "repo": "someone/x"}, {"name": "claude-plugins-official", "repo": "anthropics/claude-plugins-official"}]' \
    >"$STUB_FIXTURES/marketplaces.json"
  run_bin -1 team-config diff
  assert_equal "$output" "marketplace someone/x not in plugins.txt"
  # A plugin installed in a project's scope is that project's, not the user's.
  jq '. + [{id: "local@x", scope: "project", enabled: true}]' "$STUB_FIXTURES/plugins.json" >"$BATS_TEST_TMPDIR/p"
  mv "$BATS_TEST_TMPDIR/p" "$STUB_FIXTURES/plugins.json"
  run_bin -1 team-config diff
  assert_equal "$output" "marketplace someone/x not in plugins.txt"
  echo 'not json' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-config diff
  assert_equal "$output" "plugins unreadable"
}

@test "apply installs copies, backs up what it replaces, leaves a local-only skill; a second apply changes nothing" {
  echo '{"model": "sonnet"}' >"$HOME/.claude/settings.json"
  rm "$HOME/.claude/AGENTS.md"
  rm -r "$HOME/.claude/skills/tdd"
  echo "Changed here." >>"$HOME/.claude/skills/wizard/references/steps.md"
  mkdir -p "$HOME/.claude/skills/retro"
  echo "Look back." >"$HOME/.claude/skills/retro/SKILL.md"
  run_bin -0 team-config apply
  local backup
  backup=$(backups)
  [[ ${backup##*/} =~ ^team-config-[0-9]{8}T[0-9]{6}Z$ ]]
  assert_equal "$output" "installed AGENTS.md
replaced settings.json
installed skill tdd
replaced skill wizard
what it replaced is in ~/.claude/backups/${backup##*/}/"
  # Copies, not links, and the old ones in the backup.
  [[ ! -L $HOME/.claude/settings.json && ! -L $HOME/.claude/skills/tdd ]]
  cmp "$shared/settings.json" "$HOME/.claude/settings.json"
  diff -r "$shared/skills/wizard" "$HOME/.claude/skills/wizard"
  assert_equal "$(cat "$backup/settings.json")" '{"model": "sonnet"}'
  assert_contains "$(cat "$backup/skills/wizard/references/steps.md")" "Changed here."
  assert_equal "$(cd "$backup" && find . -type f | LC_ALL=C sort)" "./settings.json
./skills/wizard/SKILL.md
./skills/wizard/references/steps.md"
  # The local-only skill stays, and is all diff still lists.
  [[ -f $HOME/.claude/skills/retro/SKILL.md ]]
  run_bin -1 team-config diff
  assert_equal "$output" "skill retro local only"

  run_bin -0 team-config apply
  assert_equal "$output" "nothing to apply"
  assert_equal "$(backups)" "$backup"
  # The lock and the plugins are not apply's: a lock here that differs stays as it is.
  echo '{"version": 3, "skills": {"lavish": {}}}' >"$HOME/.agents/.skill-lock.json"
  plugins_installed discord@claude-plugins-official
  run_bin -0 team-config apply
  assert_equal "$output" "nothing to apply"
  assert_equal "$(cat "$HOME/.agents/.skill-lock.json")" '{"version": 3, "skills": {"lavish": {}}}'
  assert_equal "$(stub_calls claude | jq -r '.[0:2] | join(" ")' | sort -u)" "plugin list
plugin marketplace"
}

@test "apply into an empty HOME installs everything and backs up nothing" {
  rm -rf "$HOME/.claude/skills" "$HOME/.claude"/{CLAUDE.md,AGENTS.md,settings.json}
  run_bin -0 team-config apply
  assert_equal "$output" "installed CLAUDE.md
installed AGENTS.md
installed settings.json
installed skill tdd
installed skill wizard"
  assert_equal "$(backups)" ""
  run_bin -0 team-config diff
}

@test "a skill that is a symlink here is compared, backed up and captured as the folder it points at" {
  mkdir -p "$HOME/.agents/skills"
  mv "$HOME/.claude/skills/tdd" "$HOME/.agents/skills/tdd"
  ln -s ../../.agents/skills/tdd "$HOME/.claude/skills/tdd"
  mkdir -p "$HOME/.agents/skills/lavish"
  echo "Review surfaces." >"$HOME/.agents/skills/lavish/SKILL.md"
  ln -s ../../.agents/skills/lavish "$HOME/.claude/skills/lavish"
  run_bin -1 team-config diff
  assert_equal "$output" "skill lavish local only"

  run_bin -0 team-config capture
  assert_equal "$output" "captured skill lavish (new)"
  [[ -d $shared/skills/lavish && ! -L $shared/skills/lavish ]]
  assert_equal "$(cat "$shared/skills/lavish/SKILL.md")" "Review surfaces."

  echo "Changed here." >>"$HOME/.agents/skills/tdd/SKILL.md"
  run_bin -0 team-config apply
  assert_equal "$(sed -n 1p <<<"$output")" "replaced skill tdd"
  [[ ! -L $HOME/.claude/skills/tdd ]]
  assert_contains "$(cat "$(backups)/skills/tdd/SKILL.md")" "Changed here."
  run_bin -0 team-config diff
}

@test "capture brings an in-place edit and a new skill into machine/claude/, prints them and never commits" {
  local head
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  jq '.model = "sonnet"' "$HOME/.claude/settings.json" >"$BATS_TEST_TMPDIR/s"
  mv "$BATS_TEST_TMPDIR/s" "$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude/skills/retro" "$HOME/.claude/skills/synced/claude-ai"
  echo "Look back." >"$HOME/.claude/skills/retro/SKILL.md"
  echo "claude.ai's own." >"$HOME/.claude/skills/synced/claude-ai/SKILL.md"
  rm -r "$HOME/.claude/skills/tdd"
  echo '{"version": 3, "skills": {"lavish": {}}}' >"$HOME/.agents/.skill-lock.json"
  plugins_installed discord@claude-plugins-official mongodb-atlas@claude-plugins-official ponder@claude-plugins-official
  run_bin -0 team-config capture
  assert_equal "$output" "captured settings.json
captured skill retro (new)
captured skill-lock.json
captured plugin ponder@claude-plugins-official"
  assert_equal "$(jq -r .model "$shared/settings.json")" sonnet
  assert_equal "$(cat "$shared/skills/retro/SKILL.md")" "Look back."
  # Not removed: a skill missing here; never captured: synced/.
  [[ -f $shared/skills/tdd/SKILL.md && ! -e $shared/skills/synced ]]
  cmp "$HOME/.agents/.skill-lock.json" "$shared/skill-lock.json"
  assert_equal "$(grep -v '^#' "$shared/plugins.txt")" "marketplace anthropics/claude-plugins-official
plugin discord@claude-plugins-official
plugin mongodb-atlas@claude-plugins-official
plugin ponder@claude-plugins-official"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain | sort -k2)" " M machine/claude/plugins.txt
 M machine/claude/settings.json
 M machine/claude/skill-lock.json
?? machine/claude/skills/retro/"
  run_bin -1 team-config diff
  assert_equal "$output" "skill tdd missing"

  run_bin -0 team-config capture
  assert_equal "$output" "nothing to capture"
}

@test "settings.json is compared as JSON without this machine's autoMode.environment, which apply keeps and capture leaves out" {
  local environment='["**Organization**: None configured", "**Trusted repo**: the working directory"]'
  # Its own environment, another key order and layout: no difference.
  jq -c --argjson e "$environment" '{autoMode: {environment: $e}, enabledPlugins, model}' "$shared/settings.json" \
    >"$HOME/.claude/settings.json"
  run_bin -0 team-config diff
  # A shared autoMode rule beside it is shared; the environment is still this machine's.
  jq --argjson e '["something else"]' '.autoMode = {environment: $e, allow: ["Run the tests"]}' "$shared/settings.json" >"$BATS_TEST_TMPDIR/s"
  mv "$BATS_TEST_TMPDIR/s" "$shared/settings.json"
  run_bin -1 team-config diff --full
  assert_equal "$(sed -n 1p <<<"$output")" "settings.json differs"
  assert_contains "$output" '-    "allow": ['
  [[ $output != *"something else"* && $output != *"Trusted repo"* ]]

  run_bin -0 team-config apply
  assert_equal "$(sed -n 1p <<<"$output")" "replaced settings.json"
  assert_equal "$(jq -c .autoMode "$HOME/.claude/settings.json")" \
    "$(jq -nc --argjson e "$environment" '{environment: $e, allow: ["Run the tests"]}')"
  assert_equal "$(jq -c .autoMode.environment "$(backups)/settings.json")" "$(jq -nc --argjson e "$environment" '$e')"
  run_bin -0 team-config diff

  # Captured, it leaves the environment out, and an autoMode with nothing else goes too.
  jq 'del(.autoMode.allow) | .model = "sonnet"' "$HOME/.claude/settings.json" >"$BATS_TEST_TMPDIR/s"
  mv "$BATS_TEST_TMPDIR/s" "$HOME/.claude/settings.json"
  run_bin -0 team-config capture
  assert_equal "$output" "captured settings.json"
  jq -e '.model == "sonnet" and (has("autoMode") | not)' "$shared/settings.json"
  run_bin -0 team-config diff
}

@test "own says whether each of this machine's own settings is set here" {
  run_bin -0 team-config own
  assert_equal "$output" "autoMode.environment unset"
  run_bin -0 team-config own --json
  assert_equal "$(jq -c . <<<"$output")" '[{"setting":"autoMode.environment","set":false}]'
  jq '.autoMode.environment = ["**Organization**: None configured"]' "$HOME/.claude/settings.json" >"$BATS_TEST_TMPDIR/s"
  mv "$BATS_TEST_TMPDIR/s" "$HOME/.claude/settings.json"
  run_bin -0 team-config own
  assert_equal "$output" "autoMode.environment set"
  # It needs no team home config, and no settings file is unset.
  rm -r "$shared" "$HOME/.claude/settings.json"
  run_bin -0 team-config own
  assert_equal "$output" "autoMode.environment unset"
  echo 'not json' >"$HOME/.claude/settings.json"
  run_bin -1 --separate-stderr team-config own
  assert_equal "$stderr" "team-config: $HOME/.claude/settings.json is not JSON"
}

@test "the first capture makes machine/claude/; diff and apply refuse without it" {
  rm -rf "$shared"
  run_bin -1 --separate-stderr team-config diff
  assert_equal "$stderr" "team-config: no machine/claude/ in $TEAM_HOME; run team-config capture on the machine whose config the team shares"
  run_bin -1 --separate-stderr team-config apply
  [[ -z $(backups) ]]
  run_bin -0 team-config capture
  assert_equal "$output" "captured CLAUDE.md (new)
captured AGENTS.md (new)
captured settings.json (new)
captured skill tdd (new)
captured skill wizard (new)
captured skill-lock.json (new)
captured marketplace anthropics/claude-plugins-official
captured plugin discord@claude-plugins-official
captured plugin mongodb-atlas@claude-plugins-official"
  assert_equal "$(cat "$shared/plugins.txt")" "# User-scope plugins every machine installs, and their marketplaces (team-config).
marketplace anthropics/claude-plugins-official
plugin discord@claude-plugins-official
plugin mongodb-atlas@claude-plugins-official"
  run_bin -0 team-config diff
}

@test "capture with claude not answering captures the rest, leaves plugins.txt and exits 1" {
  echo "More." >>"$HOME/.claude/CLAUDE.md"
  rm "$STUB_FIXTURES/claude.sh"
  stub_reply claude "" 1
  run_bin -1 --separate-stderr team-config capture
  assert_equal "$output" "captured CLAUDE.md"
  assert_equal "$stderr" "team-config: \`claude plugin list\` did not answer, so plugins.txt is unchanged"
  run git -C "$TEAM_HOME" status --porcelain
  assert_equal "$output" " M machine/claude/CLAUDE.md"
}

@test "no output or copy carries the credentials, ~/.claude.json, the channels' tokens or a transcript" {
  local secrets=(sk-ant-oat-fake-secret daniel@example.invalid "$FAKE_DISCORD_TOKEN" transcript-fake-line project-fake-line)
  echo '{"claudeAiOauth": {"accessToken": "sk-ant-oat-fake-secret"}}' >"$HOME/.claude/.credentials.json"
  echo '{"oauthAccount": {"emailAddress": "daniel@example.invalid"}}' >"$HOME/.claude.json"
  mkdir -p "$HOME/.claude/transcripts" "$HOME/.claude/projects/-home-x"
  echo '{"line": "transcript-fake-line"}' >"$HOME/.claude/transcripts/a.jsonl"
  echo '{"line": "project-fake-line"}' >"$HOME/.claude/projects/-home-x/b.jsonl"
  echo "Changed here." >>"$HOME/.claude/CLAUDE.md"
  mkdir -p "$HOME/.claude/skills/retro"
  echo "Look back." >"$HOME/.claude/skills/retro/SKILL.md"
  local all=''
  run_bin -1 team-config diff --full
  all+=$output
  run_bin -1 team-config diff --json
  all+=$output
  run_bin -0 team-config capture
  all+=$output
  echo "Changed again." >>"$HOME/.claude/CLAUDE.md"
  run_bin -0 team-config apply
  all+=$output
  local secret
  for secret in "${secrets[@]}"; do
    [[ $all != *"$secret"* ]] || { echo "team-config printed $secret" >&2; return 1; }
    run -1 grep -rlF -- "$secret" "$shared" "$HOME/.claude/backups"
  done
  # Only the shared names are copied, so nothing else of ~/.claude reaches the team home.
  assert_equal "$(cd "$shared" && find . -maxdepth 1 | sort)" ".
./AGENTS.md
./CLAUDE.md
./plugins.txt
./settings.json
./skill-lock.json
./skills"
  # The code, its comments aside, names none of them.
  run -1 grep -nE 'credentials|\.claude\.json|channels|transcripts' \
    <(grep -v '^[[:space:]]*#' "$REPO_ROOT/bin/team-config")
  # Of ~/.claude/projects/, it names only the memory folders.
  run -1 grep -nE 'projects/' \
    <(grep -v '^[[:space:]]*#' "$REPO_ROOT/bin/team-config" | grep -vE 'projects/[^[:space:]]*/memory')
}

@test "team-config refuses an unknown command or option" {
  run_bin -2 --separate-stderr team-config
  assert_equal "$stderr" "team-config: usage: team-config diff [--full] [--json] | apply | capture | own [--json]"
  run_bin -2 team-config diff --yes
  run_bin -2 team-config apply --full
  run_bin -2 team-config push
  run_bin -2 team-config own --full
}
