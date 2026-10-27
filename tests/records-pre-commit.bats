#!/usr/bin/env bats
# hooks/records-git/pre-commit: with the team home's core.hooksPath set to it by absolute path, a
# records commit that adds an email address at a public provider or any image is refused, naming
# the path. tests/data-check.bats covers the scan itself.
# No address at a real provider is written out here (ci.yml's data job would refuse this file):
# each is built from $provider.

load helpers/common

setup() {
  sandbox
  make_team_home >/dev/null
  git -C "$TEAM_HOME" config core.hooksPath "$REPO_ROOT/bin/hooks/records-git"
  provider=gmail.com
}

# Write <content> to the team home's <path>: record <path> <content>
record() {
  mkdir -p "$(dirname "$TEAM_HOME/$1")"
  printf '%s\n' "$2" >"$TEAM_HOME/$1"
}

# Commit in the team home with bats' run, stderr apart: commit <status> [git commit arguments...]
commit() {
  run "$1" --separate-stderr git -C "$TEAM_HOME" commit -q -m "chore: records" "${@:2}"
}

@test "a records commit adding an address at a public provider is refused, naming the path, never the address" {
  local head
  head=$(git -C "$TEAM_HOME" rev-parse HEAD)
  record tasks/T1/plan.md "Discord: reply to ann.applicant@$provider"
  record tasks/T1/brief.md "nothing private"
  git -C "$TEAM_HOME" add tasks
  commit -1
  assert_equal "$stderr" "data-check: refused: tasks/T1/plan.md adds an email address at a public \
provider or an image, which the records never take: other people's addresses and screenshots stay \
out of git; take each out, then commit again:
  tasks/T1/plan.md: 1 email address at a public provider"
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$head"
  # Taken out, the commit goes ahead.
  record tasks/T1/plan.md "Discord: reply to the applicant"
  git -C "$TEAM_HOME" add tasks
  commit -0
  assert_equal "$stderr" ""
}

@test "a commit of named paths only (commit_records' --only) is scanned through its own index" {
  record ledger.jsonl '{"kind": "note"}'
  record tasks/T1/notes.md "bo@$provider"
  git -C "$TEAM_HOME" add tasks
  # The staged notes stay out of a commit of the ledger alone, as commit_records makes it.
  commit -0 --only -- ledger.jsonl
  record ledger.jsonl "{\"from\": \"cy@$provider\"}"
  commit -1 --only -- ledger.jsonl
  assert_contains "${stderr%%$'\n'*}" "refused: ledger.jsonl adds an email address at a public provider"
  [[ $stderr != *notes.md* ]]
}

@test "a screenshot is refused, and git's own address is not" {
  git -C "$TEAM_HOME" config user.email "Daniel@$provider"
  record tasks/T1/notes.md "signed in as daniel@$provider"
  git -C "$TEAM_HOME" add tasks
  commit -0
  mkdir -p "$TEAM_HOME/tasks/T1/scratch"
  printf '\x89PNG\r\n\x1a\n%s' "$RANDOM" >"$TEAM_HOME/tasks/T1/scratch/shot.png"
  git -C "$TEAM_HOME" add tasks
  commit -1
  assert_contains "$stderr" "commit again:
  tasks/T1/scratch/shot.png: an image"
}
