#!/usr/bin/env bats
# team-config's auto memory: every registered project's memory in the team home's memory/<project>/,
# and the team home's own in memory/coordinator/ when it is no project's primary checkout.
# The team home is at ~/agent-team, as on Daniel's machines, and registers itself and two projects
# with primary checkouts here (conv, site) and one with none (away); `apart` registers the team
# home no more. machine/claude/ is empty and claude lists no plugins, so diff prints memory lines
# alone.

# shellcheck disable=SC2088 # autoMemoryDirectory holds the ~ itself, for Claude Code to expand
load helpers/common

setup() {
  sandbox
  export TEAM_HOME=$HOME/agent-team
  mkdir -p "$TEAM_HOME/machine/claude"
  : >"$TEAM_HOME/ledger.jsonl"
  conv=$(make_repo conv)
  site=$(make_repo site)
  {
    project agent-team agent-team
    project conv projects/conv
    project site projects/site
    project away projects/away
  } >"$TEAM_HOME/projects.toml"
  make_team_home >/dev/null
  stub_script claude <<'EOF'
case $* in
  'plugin list --json' | 'plugin marketplace list --json') echo '[]' ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 127 ;;
esac
EOF
}

# A projects.toml table: project <name> <path relative to HOME>
project() {
  cat <<TOML
[$1]
repo = "owner/$1"
path = "$2"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[$1.pool]
provider = "git"
slots = []

TOML
}

# The registry without the team home's own project, as once the code lives in a checkout of its own.
apart() {
  {
    project conv projects/conv
    project site projects/site
    project away projects/away
  } >"$TEAM_HOME/projects.toml"
  git -C "$TEAM_HOME" commit -q -m "chore: the team home apart" projects.toml
}

# The folder Claude Code keeps a checkout's auto memory in by default: every character of its
# absolute path but letters and digits as "-".
old_memory() {
  printf '%s/.claude/projects/%s/memory\n' "$HOME" "$(realpath "$1" | sed 's/[^A-Za-z0-9]/-/g')"
}

# Every file and folder under HOME (the team home's included) with its inode, size and
# modification time to the nanosecond, so a rewrite in place or by a move shows.
snapshot() {
  find "$HOME" -exec stat -c '%n %i %s %y' {} + | sort
}

# Write a note with the given modification time: note <file> <text> <touch -d date>
note() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
  touch -d "$3" "$1"
}

@test "apply moves every note into memory/<project>/, keeps the newer on a clash and leaves the old folders empty" {
  note "$(old_memory "$conv")/MEMORY.md" "- [Deploys](deploys.md) - conv's" "2026-10-01 10:00"
  note "$(old_memory "$conv")/deploys.md" "Deploys go through CI." "2026-10-01 10:00"
  note "$(old_memory "$conv")/older.md" "Older here." "2026-10-01 10:00"
  note "$(old_memory "$site")/MEMORY.md" "- [Fonts](fonts.md)" "2026-10-02 10:00"
  note "$(old_memory "$site")/fonts.md" "Inter, self-hosted." "2026-10-02 10:00"
  note "$(old_memory "$TEAM_HOME")/MEMORY.md" "- [Team](team.md)" "2026-10-02 10:00"
  note "$(old_memory "$TEAM_HOME")/team.md" "The team's own." "2026-10-02 10:00"
  # The team home already holds notes of conv, from another machine: one newer, one older.
  note "$TEAM_HOME/memory/conv/MEMORY.md" "- [Deploys](deploys.md) - the laptop's" "2026-10-05 10:00"
  note "$TEAM_HOME/memory/conv/older.md" "Older in the team home." "2026-09-01 10:00"

  run_bin -0 team-config apply
  assert_contains "$output" "memory conv: moved 3 notes from ~/.claude/projects/$(basename "$(dirname "$(old_memory "$conv")")")/memory/"
  assert_contains "$output" "memory site: moved 2 notes"
  assert_contains "$output" "memory agent-team: moved 2 notes"
  assert_equal "$(cat "$TEAM_HOME/memory/conv/MEMORY.md")" "- [Deploys](deploys.md) - the laptop's"
  assert_equal "$(cat "$TEAM_HOME/memory/conv/deploys.md")" "Deploys go through CI."
  assert_equal "$(cat "$TEAM_HOME/memory/conv/older.md")" "Older here."
  assert_equal "$(cat "$TEAM_HOME/memory/site/fonts.md")" "Inter, self-hosted."
  assert_equal "$(cat "$TEAM_HOME/memory/agent-team/team.md")" "The team's own."
  # The note that lost a clash is kept in the backup folder, not lost.
  assert_contains "$output" "what it replaced is in ~/.claude/backups/team-config-"
  assert_equal "$(cat "$HOME"/.claude/backups/team-config-*/memory/conv/MEMORY.md)" "- [Deploys](deploys.md) - conv's"
  assert_equal "$(cat "$HOME"/.claude/backups/team-config-*/memory/conv/older.md)" "Older in the team home."
  local dir
  for dir in "$conv" "$site" "$TEAM_HOME"; do
    [[ -d $(old_memory "$dir") ]]
    assert_equal "$(find "$(old_memory "$dir")" -mindepth 1)" ""
  done
  # A project with no checkout on this machine is left alone.
  [[ ! -e $TEAM_HOME/memory/away ]]
}

@test "apply merges autoMemoryDirectory into each checkout's settings.local.json and keeps it out of git" {
  mkdir -p "$conv/.claude"
  echo '{"permissions": {"allow": ["Bash(npm test)"]}}' >"$conv/.claude/settings.local.json"
  # site's own .gitignore already ignores it, so its exclude file stays as it was.
  printf '%s\n' '.claude/settings.local.json' >"$site/.gitignore"
  git -C "$site" add .gitignore
  git -C "$site" commit -q -m "chore: ignore local settings"
  note "$(old_memory "$TEAM_HOME")/team.md" "The team's own." "2026-10-02 10:00"
  run_bin -0 team-config apply
  assert_contains "$output" "memory conv: autoMemoryDirectory set"
  assert_contains "$output" "memory conv: .claude/settings.local.json excluded from git"
  [[ $output != *"memory site: .claude/settings.local.json excluded"* ]]
  assert_equal "$(jq -c . "$conv/.claude/settings.local.json")" \
    '{"permissions":{"allow":["Bash(npm test)"]},"autoMemoryDirectory":"~/agent-team/memory/conv"}'
  assert_equal "$(jq -r .autoMemoryDirectory "$site/.claude/settings.local.json")" "~/agent-team/memory/site"
  assert_equal "$(jq -r .autoMemoryDirectory "$TEAM_HOME/.claude/settings.local.json")" "~/agent-team/memory/agent-team"
  run -1 grep -F settings.local.json "$site/.git/info/exclude"
  assert_equal "$(git -C "$conv" status --porcelain)" ""
  assert_equal "$(git -C "$site" status --porcelain)" ""
  # In the team home only memory/ is new (the note moved there), left for the checkpoint to commit.
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" "?? memory/"
}

@test "a second apply changes nothing" {
  note "$(old_memory "$conv")/deploys.md" "Deploys go through CI." "2026-10-01 10:00"
  run_bin -0 team-config apply
  local before
  before=$(snapshot)
  run_bin -0 team-config apply
  assert_equal "$output" "nothing to apply"
  assert_equal "$(snapshot)" "$before"
  run_bin -0 team-config diff
  assert_equal "$output" ""
}

@test "diff lists a project whose setting is missing or points elsewhere, notes left behind and an unignored settings file" {
  run_bin -0 team-config apply
  run_bin -0 team-config diff
  jq '.autoMemoryDirectory = "~/elsewhere"' "$site/.claude/settings.local.json" >"$BATS_TEST_TMPDIR/s"
  mv "$BATS_TEST_TMPDIR/s" "$site/.claude/settings.local.json"
  echo '{}' >"$conv/.claude/settings.local.json"
  : >"$conv/.git/info/exclude"
  note "$(old_memory "$TEAM_HOME")/late.md" "Written before the setting took." "2026-10-03 10:00"
  run_bin -1 team-config diff
  assert_equal "$output" "memory agent-team notes left in ~/.claude/projects/$(basename "$(dirname "$(old_memory "$TEAM_HOME")")")/memory/
memory conv setting missing
memory conv settings.local.json not ignored by git
memory site setting points to ~/elsewhere"
  run_bin -1 team-config diff --json
  jq -e 'length == 4 and .[1] == {item: "memory conv", state: "setting missing"}' <<<"$output"

  run_bin -0 team-config apply
  assert_contains "$output" "memory site: autoMemoryDirectory set (was ~/elsewhere)"
  run_bin -0 team-config diff
}

@test "a settings.local.json that is not JSON is refused for its project alone" {
  mkdir -p "$conv/.claude"
  echo 'not json' >"$conv/.claude/settings.local.json"
  note "$(old_memory "$conv")/deploys.md" "Deploys go through CI." "2026-10-01 10:00"
  run_bin -1 team-config diff
  assert_contains "$output" "memory conv settings.local.json not JSON"
  run_bin -1 team-config apply
  assert_contains "$output" "settings.local.json is not JSON, so conv's memory is left where it is"
  assert_equal "$(cat "$conv/.claude/settings.local.json")" "not json"
  [[ -f $(old_memory "$conv")/deploys.md ]]
  assert_equal "$(jq -r .autoMemoryDirectory "$site/.claude/settings.local.json")" "~/agent-team/memory/site"
}

@test "a settings.local.json git tracks is refused for its project alone" {
  mkdir -p "$conv/.claude"
  echo '{}' >"$conv/.claude/settings.local.json"
  git -C "$conv" add .claude/settings.local.json
  git -C "$conv" commit -q -m "chore: share local settings"
  run_bin -1 team-config diff
  assert_contains "$output" "memory conv settings.local.json tracked by git"
  run_bin -1 team-config apply
  assert_contains "$output" "settings.local.json is tracked by git, so conv's memory is left where it is"
  assert_equal "$(cat "$conv/.claude/settings.local.json")" "{}"
}

@test "a team home outside HOME is named by its absolute path" {
  local away_home=$BATS_TEST_TMPDIR/elsewhere/agent-team
  mkdir -p "$(dirname "$away_home")"
  mv "$TEAM_HOME" "$away_home"
  TEAM_HOME=$away_home run_bin -0 team-config apply
  assert_equal "$(jq -r .autoMemoryDirectory "$conv/.claude/settings.local.json")" "$away_home/memory/conv"
}

@test "team-config never commits memory/" {
  local head
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  note "$(old_memory "$conv")/deploys.md" "Deploys go through CI." "2026-10-01 10:00"
  run_bin -0 team-config apply
  run_bin -0 team-config capture
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$TEAM_HOME" ls-files memory)" ""
}

@test "a team home apart from every project keeps its memory in memory/coordinator/, with each fix" {
  apart
  note "$(old_memory "$TEAM_HOME")/MEMORY.md" "- [Team](team.md)" "2026-10-02 10:00"
  note "$(old_memory "$TEAM_HOME")/team.md" "The team's own." "2026-10-02 10:00"
  run_bin -1 team-config diff
  assert_equal "$(grep coordinator <<<"$output")" "memory coordinator setting missing
memory coordinator settings.local.json not ignored by git
memory coordinator notes left in ~/.claude/projects/$(basename "$(dirname "$(old_memory "$TEAM_HOME")")")/memory/"
  run_bin -0 team-config apply
  assert_contains "$output" "memory coordinator: .claude/settings.local.json excluded from git
memory coordinator: autoMemoryDirectory set
memory coordinator: moved 2 notes from ~/.claude/projects/"
  assert_equal "$(jq -r .autoMemoryDirectory "$TEAM_HOME/.claude/settings.local.json")" "~/agent-team/memory/coordinator"
  assert_equal "$(cat "$TEAM_HOME/memory/coordinator/team.md")" "The team's own."
  assert_equal "$(find "$(old_memory "$TEAM_HOME")" -mindepth 1)" ""
  [[ ! -e $TEAM_HOME/memory/agent-team ]]
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" "?? memory/"
  run_bin -0 team-config diff

  jq '.autoMemoryDirectory = "~/elsewhere"' "$TEAM_HOME/.claude/settings.local.json" >"$BATS_TEST_TMPDIR/s"
  mv "$BATS_TEST_TMPDIR/s" "$TEAM_HOME/.claude/settings.local.json"
  run_bin -1 team-config diff
  assert_equal "$output" "memory coordinator setting points to ~/elsewhere"
  run_bin -1 team-config diff --json
  assert_equal "$(jq -c . <<<"$output")" '[{"item":"memory coordinator","state":"setting points to ~/elsewhere"}]'
  run_bin -0 team-config apply
  assert_equal "$output" "memory coordinator: autoMemoryDirectory set (was ~/elsewhere)"
  run_bin -0 team-config diff
}

@test "a team home that is a project's primary checkout keeps its memory in that project's folder alone" {
  # The setup registers agent-team at ~/agent-team, the team home, reached here through a symlink.
  ln -s agent-team "$HOME/team-link"
  note "$(old_memory "$TEAM_HOME")/team.md" "The team's own." "2026-10-02 10:00"
  run_bin -1 team-config diff
  [[ $output != *coordinator* ]]
  TEAM_HOME=$HOME/team-link run_bin -1 team-config diff
  [[ $output != *coordinator* ]]
  run_bin -0 team-config apply
  [[ $output != *coordinator* ]]
  assert_equal "$(jq -r .autoMemoryDirectory "$TEAM_HOME/.claude/settings.local.json")" "~/agent-team/memory/agent-team"
  [[ ! -e $TEAM_HOME/memory/coordinator ]]
}

@test "without a registry the team home's memory is the only one set up" {
  rm "$TEAM_HOME/projects.toml"
  run_bin -1 team-config diff
  assert_equal "$output" "memory coordinator setting missing
memory coordinator settings.local.json not ignored by git"
  run_bin -0 team-config apply
  assert_equal "$output" "memory coordinator: .claude/settings.local.json excluded from git
memory coordinator: autoMemoryDirectory set"
  run_bin -0 team-config diff
}
