#!/usr/bin/env bats
# team-merge: the coordinator's only merge path, on Daniel's recorded word and a green head.

load helpers/common

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "dev"
delivery = "direct-pr"
merge_method = "squash"
required_checks = ["test"]
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1", "slots/proj/2"]
TOML
  echo '{"dmPolicy": "allowlist", "allowFrom": ["757"], "groups": {}, "pending": {}}' \
    >"$HOME/.claude/channels/discord/access.json"
  head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
  merge=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
  gh_dir=$BATS_TEST_TMPDIR/gh discord=$BATS_TEST_TMPDIR/discord
  mkdir -p "$gh_dir" "$discord"
  export GH_DIR=$gh_dir DISCORD_DIR=$discord MERGE_SHA=$merge
  green_pr
  approved_by 757
  stub_gh
  stub_discord
  open_task
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for its writer.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

# event <task> <kind> [<jq object of more fields>]
event() {
  ledger_line --arg t "$1" --arg e "$2" "{ts: \"2026-10-22T02:00:00Z\", task: \$t, event: \$e} + (${3:-{\}})"
}

# T14 of proj with its thread 1563, PR #5 at the head and Daniel's word in message 1562661774950400000,
# sent at 03:00, an hour after the pr event.
open_task() {
  event T14 opened '{project: "proj", path: "feature", type: "feat", title: "The tooling",
    branch: "feat/T14-tooling", base: "dev", base_sha: "0123456", worktree: "/w/1"}'
  event T14 thread '{discord_thread: "1563"}'
  event T14 pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d4", project: "proj"}'
  event T14 merge-approved '{url: "https://github.com/owner/proj/pull/5", discord_message: "1562661774950400000"}'
}

# PR #5 as GitHub shows it: open, mergeable, on dev, every check green on the head, and two
# commits with clean messages; edit the files under $GH_DIR to break one fact.
green_pr() {
  jq -n --arg head "$head" '{number: 5, state: "OPEN", isDraft: false, mergeable: "MERGEABLE",
    baseRefName: "dev", headRefName: "feat/T14-tooling", headRefOid: $head,
    mergeCommit: null, autoMergeRequest: null}' >"$gh_dir/pr.json"
  echo '[
    {"name": "test", "bucket": "pass", "state": "SUCCESS"},
    {"name": "lint", "bucket": "pass", "state": "SUCCESS"},
    {"name": "docs", "bucket": "skipping", "state": "SKIPPED"},
    {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}
  ]' >"$gh_dir/checks.json"
  echo '[{"name": "lint", "bucket": "pass", "state": "SUCCESS"}]' >"$gh_dir/required.json"
  echo '{"name": "dev", "protected": true, "protection": {"enabled": true,
    "required_status_checks": {"contexts": ["lint", "agent-review"]}}}' >"$gh_dir/branch.json"
  jq -n --arg head "$head" '[
    {sha: "1111111111111111111111111111111111111111", commit: {message: "feat: one\n\nBody."}},
    {sha: $head, commit: {message: "test: two"}}]' >"$gh_dir/commits.json"
}

# Set one field of the PR as GitHub shows it: pr_field <jq assignment>
pr_field() {
  jq "$1" "$gh_dir/pr.json" >"$gh_dir/pr.next" && mv "$gh_dir/pr.next" "$gh_dir/pr.json"
}

# Set the checks on the head: checks '<json list>'
checks() {
  echo "$1" >"$gh_dir/checks.json"
}

# gh answers from the files under $GH_DIR (the second read of the PR from pr-again.json when a
# test wrote one). pr merge marks the PR merged (or runs merge.sh when
# a test wrote one); anything unplanned fails.
stub_gh() {
  stub_script gh <<'EOF'
case "$*" in
  "pr view 5 --repo owner/proj --json isDraft,"*) cat "$GH_DIR/pr-again.json" 2>/dev/null || cat "$GH_DIR/pr.json" ;;
  "pr view 5 --repo owner/proj "*) cat "$GH_DIR/pr.json" ;;
  "pr checks 5 --repo owner/proj --required "*) cat "$GH_DIR/required.json" ;;
  "pr checks 5 --repo owner/proj "*) cat "$GH_DIR/checks.json" ;;
  "api repos/owner/proj/branches/dev") cat "$GH_DIR/branch.json" ;;
  "api repos/owner/proj/pulls/5/commits --paginate") cat "$GH_DIR/commits.json" ;;
  "api repos/owner/proj/pulls/5") cat "$GH_DIR/pull.json" ;;
  "api repos/owner/proj/commits/"*"/pulls") cat "$GH_DIR/pulls.json" ;;
  "pr merge 5 --repo owner/proj "*)
    if [[ -f $GH_DIR/merge.sh ]]; then source "$GH_DIR/merge.sh"; exit; fi
    jq --arg m "$MERGE_SHA" '.state = "MERGED" | .mergeCommit = {oid: $m}' "$GH_DIR/pr.json" >"$GH_DIR/pr.next"
    mv "$GH_DIR/pr.next" "$GH_DIR/pr.json"
    echo "✓ Squashed and merged pull request owner/proj#5" >&2 ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
EOF
}

# The fake Discord API: GET channels/<c>/messages/<m> answers $DISCORD_DIR/<c>-<m>.json, a
# missing one fails as curl -f does on a 404. The headers curl read from stdin are kept.
stub_discord() {
  stub_script curl <<'EOF'
cat >>"$DISCORD_DIR/stdin"
url=${*: -1}
if [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)/messages/([0-9]+)$ &&
  -f $DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json ]]; then
  cat "$DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
EOF
}

# Message 1562661774950400000 in the task's thread (or the channel given), written by the user id given.
approved_by() {
  rm -f "$discord"/*-1562661774950400000.json
  jq -n --arg author "$1" --arg channel "${2:-1563}" '{id: "1562661774950400000", channel_id: $channel,
    content: "merge it", author: {id: $author, username: "daniel"}}' >"$discord/${2:-1563}-1562661774950400000.json"
}

# Run team-merge expecting a refusal: exit 1, stderr naming every reason given, gh pr merge never
# called and nothing appended to the ledger.
refused() {
  local before reason
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$output" ""
  assert_contains "$stderr" "team-merge: T14 cannot merge PR #5, so nothing changed:"
  for reason in "$@"; do assert_contains "$stderr" "  $reason"; done
  no_merge_call
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

no_merge_call() {
  if stub_calls gh | jq -e 'select(.[0:2] == ["pr", "merge"])' >/dev/null; then
    echo "gh pr merge was called:" >&2
    stub_calls gh >&2
    return 1
  fi
}

merged_events() {
  jq -c 'select(.event == "merged") | del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

# proj gets local_checks ./check.sh, and PR #5's head becomes a real commit on origin's
# feat/T14-tooling holding check.sh, which logs where it ran to $GH_DIR/ran, prints its output
# and exits with $GH_DIR/check.status (default 0), sourcing $GH_DIR/check.extra first when a test
# wrote one.
with_local_checks() {
  local primary
  primary=$(make_repo proj dev)
  git -C "$primary" checkout -q -b feat/T14-tooling
  cat >"$primary/check.sh" <<'SH'
#!/usr/bin/env bash
echo "$PWD $(git rev-parse HEAD)" >>"$GH_DIR/ran"
echo "checking the head"
if [[ -f $GH_DIR/check.extra ]]; then source "$GH_DIR/check.extra"; fi
exit "$(cat "$GH_DIR/check.status" 2>/dev/null || echo 0)"
SH
  chmod +x "$primary/check.sh"
  git -C "$primary" add check.sh
  git -C "$primary" commit -q -m "test: the local check"
  git -C "$primary" push -q origin feat/T14-tooling
  git -C "$primary" checkout -q dev
  head=$(git -C "$primary" rev-parse feat/T14-tooling)
  sed -i 's|^toolkits = \[\]$|toolkits = []\nlocal_checks = ["./check.sh"]|' "$TEAM_HOME/projects.toml"
  green_pr
}

# The worktrees of proj's primary checkout, one path per line.
proj_worktrees() {
  git -C "$HOME/projects/proj" worktree list --porcelain | sed -n 's/^worktree //p'
}

# proj is the team home's repo: TEAM_HOME is a clone of a bare origin whose dev is proj's base,
# named https://github.com/owner/proj.git (git's url.insteadOf leads there), with a merged event
# for an earlier PR at dev's first commit. Its primary checkout is the team home itself, at
# $HOME/agent-team; or, with `apart`, a second clone of the same origin there while the team home
# is $HOME/agent-team-records. PR #5's head is a real commit on origin's feat/T14-tooling, and gh
# pr merge merges it on origin with a merge commit that GitHub then names as PR #5's.
as_team_home() {
  local pr_clone=$BATS_TEST_TMPDIR/pr home=$HOME/agent-team
  [[ ${1:-} != apart ]] || home=$HOME/agent-team-records
  mv "$TEAM_HOME" "$home"
  export TEAM_HOME=$home
  sed -i 's|^path = "projects/proj"$|path = "agent-team"|' "$TEAM_HOME/projects.toml"
  export TEAM_ORIGIN
  TEAM_ORIGIN=$(make_team_home)
  git config --global url."$TEAM_ORIGIN".insteadOf https://github.com/owner/proj.git
  git -C "$TEAM_HOME" remote set-url origin https://github.com/owner/proj.git
  [[ ${1:-} != apart ]] || git clone -q https://github.com/owner/proj.git "$HOME/agent-team"
  event T13 merged "{pr: 4, merge: \"$(git -C "$TEAM_HOME" rev-parse HEAD)\", head: \"0000000\", by: \"x\", project: \"proj\"}"
  git clone -q "$TEAM_ORIGIN" "$pr_clone"
  git -C "$pr_clone" checkout -q -b feat/T14-tooling
  echo "tool" >"$pr_clone/tool.sh"
  git -C "$pr_clone" add tool.sh
  git -C "$pr_clone" commit -q -m "feat: the tooling"
  git -C "$pr_clone" push -q origin feat/T14-tooling
  head=$(git -C "$pr_clone" rev-parse HEAD)
  green_pr
  cat >"$GH_DIR/merge.sh" <<'SH'
clone=$GH_DIR/merging
rm -rf "$clone"
git clone -q "$TEAM_ORIGIN" "$clone"
git -C "$clone" checkout -q dev
git -C "$clone" merge -q --no-ff -m "Merge pull request #5 from owner/feat/T14-tooling" origin/feat/T14-tooling
git -C "$clone" push -q origin dev
m=$(git -C "$clone" rev-parse HEAD)
jq --arg m "$m" '.state = "MERGED" | .mergeCommit = {oid: $m}' "$GH_DIR/pr.json" >"$GH_DIR/pr.next"
mv "$GH_DIR/pr.next" "$GH_DIR/pr.json"
# GitHub answers the PR at once, and indexes the merge commit's pull requests only later.
jq -n --arg m "$m" --arg h "$(git -C "$clone" rev-parse HEAD^2)" \
  '{number: 5, merge_commit_sha: $m, head: {sha: $h}, base: {ref: "dev"}, merged_at: "2026-10-23T03:00:00Z"}' >"$GH_DIR/pull.json"
echo '[]' >"$GH_DIR/pulls.json"
SH
}

# Push a commit straight to the team home origin's dev, as a web edit would, touching <path>.
direct_commit() {
  local clone=$BATS_TEST_TMPDIR/direct
  git clone -q "$TEAM_ORIGIN" "$clone"
  git -C "$clone" checkout -q dev
  mkdir -p "$(dirname "$clone/$1")"
  echo "direct" >"$clone/$1"
  git -C "$clone" add "$1"
  git -C "$clone" commit -q -m "chore: straight to dev"
  git -C "$clone" push -q origin dev
}

@test "a malformed command line is a usage error and an unknown task is refused" {
  run_bin -2 team-merge
  run_bin -2 team-merge 14
  run_bin -2 team-merge T14 --auto
  run_bin -2 team-merge T14 --pr
  run_bin -2 team-merge T14 T15
  run_bin -1 team-merge T99
  assert_contains "$output" "team-merge: unknown task T99: the ledger has no events for it"
  assert_equal "$(stub_calls gh)" ""
  assert_equal "$(stub_calls curl)" ""
}

@test "a task with no pr event is refused" {
  event T15 opened '{project: "proj", path: "fix", type: "fix", title: "x", branch: "fix/T15-x",
    base: "dev", base_sha: "0123456", worktree: "/w/2"}'
  run_bin -1 team-merge T15
  assert_equal "$output" "team-merge: T15 has no pr event, so there is no PR to merge"
  assert_equal "$(stub_calls gh)" ""
}

@test "a green, approved PR is merged with the project's method on the exact head and logged" {
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "merge"])')" \
    "[\"pr\",\"merge\",\"5\",\"--repo\",\"owner/proj\",\"--squash\",\"--match-head-commit\",\"$head\"]"
  assert_equal "$(merged_events)" "$(jq -cn --arg m "$merge" --arg h "$head" '{task: "T14", event: "merged",
    pr: 5, merge: $m, head: $h,
    by: "Discord message 1562661774950400000 in the task'"'"'s thread 1563, from daniel (757)",
    project: "proj", branch: "feat/T14-tooling", discord_message: "1562661774950400000", discord_channel: "1563",
    url: "https://github.com/owner/proj/pull/5"}')"
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg m "$merge" --arg h "$head" '{task: "T14",
    pr: "https://github.com/owner/proj/pull/5", merge: $m, head: $h,
    by: "Discord message 1562661774950400000 in the task'"'"'s thread 1563, from daniel (757)"}')"
  # The merge is confirmed by reading the PR again after gh pr merge.
  assert_equal "$(stub_calls gh | jq -r 'select(.[0:2] == ["pr", "view"]) | .[0:2] | join(" ")' | wc -l)" 3
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "view"])' | tail -n 1 | jq -r '.[-1]')" \
    "state,mergeCommit,headRefOid,autoMergeRequest"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "the message is read with the bot token on stdin, never on the command line or in the output" {
  run_bin -0 team-merge T14
  assert_equal "$(stub_calls curl | jq -c .)" \
    '["-fsS","-H","@-","https://discord.com/api/v10/channels/1563/messages/1562661774950400000"]'
  assert_equal "$(cat "$discord/stdin")" "Authorization: Bot $FAKE_DISCORD_TOKEN"
  [[ $output != *"$FAKE_DISCORD_TOKEN"* ]]
  [[ $(cat "$STUB_CALLS"/*.log) != *"$FAKE_DISCORD_TOKEN"* ]]
}

@test "Daniel's word in #coordinator counts when it is not in the task's thread" {
  approved_by 757 1562486564871995482
  run_bin -0 team-merge T14
  assert_equal "$(stub_calls curl | jq -r '.[-1]')" \
    "https://discord.com/api/v10/channels/1563/messages/1562661774950400000
https://discord.com/api/v10/channels/1562486564871995482/messages/1562661774950400000"
  assert_equal "$(merged_events | jq -r .by)" "Discord message 1562661774950400000 in #coordinator 1562486564871995482, from daniel (757)"
}

@test "a task without a thread has its word looked up in #coordinator only" {
  jq -c 'select(.event != "thread")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  approved_by 757 1562486564871995482
  run_bin -0 team-merge T14
  assert_equal "$(stub_calls curl | jq -r '.[-1]')" "https://discord.com/api/v10/channels/1562486564871995482/messages/1562661774950400000"
}

@test "the PR is the latest pr event, or --pr naming one of the task's pr events" {
  event T14 pr '{url: "https://github.com/owner/proj/pull/6", head: "b2c3d4e5", project: "proj"}'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: T14 cannot merge PR #6, so nothing changed:"
  no_merge_call

  : >"$STUB_CALLS/gh.log"
  run_bin -0 team-merge T14 --pr https://github.com/owner/proj/pull/5/
  assert_equal "$(merged_events | jq -r .pr)" 5

  run_bin -1 --separate-stderr team-merge --pr https://github.com/owner/proj/pull/7 T14
  assert_equal "$stderr" "team-merge: https://github.com/owner/proj/pull/7 is not one of T14's pr events:
  https://github.com/owner/proj/pull/5
  https://github.com/owner/proj/pull/6"
}

@test "no merge-approved for the PR is refused without asking Discord" {
  jq -c 'if .event == "merge-approved" then .url = "https://github.com/owner/proj/pull/6" else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  refused "no merge-approved event for https://github.com/owner/proj/pull/5: Daniel's word is not recorded"
  assert_equal "$(stub_calls curl)" ""
}

@test "an approval of a PR with the same number in another repo, or naming only the number, does not count" {
  jq -c 'select(.event != "merge-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 pr '{url: "https://github.com/other/repo/pull/5", head: "b2c3d4e5"}'
  event T14 merge-approved '{url: "https://github.com/other/repo/pull/5", discord_message: "1562661774950400000"}'
  event T14 merge-approved '{pr: 5, discord_message: "1562661774950400000"}'
  run_bin -1 --separate-stderr team-merge T14 --pr https://github.com/owner/proj/pull/5
  assert_contains "$stderr" "  no merge-approved event for https://github.com/owner/proj/pull/5: Daniel's word is not recorded"
  no_merge_call
  assert_equal "$(stub_calls curl)" ""
}

@test "an approval sent before the PR's pr event is refused without asking Discord" {
  # 1562631575961600000 is 01:00, an hour before the pr event at 02:00.
  jq -c 'if .event == "merge-approved" then .discord_message = "1562631575961600000" else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  refused "Discord message 1562631575961600000 was sent at 2026-10-22T01:00:00Z, before the pr event of https://github.com/owner/proj/pull/5 at 2026-10-22T02:00:00Z, so it is not Daniel's word on this PR"
  assert_equal "$(stub_calls curl)" ""
}

@test "an approval whose message cannot be fetched is refused" {
  rm "$discord/1563-1562661774950400000.json"
  refused "Discord message 1562661774950400000 cannot be fetched from the task's thread 1563 or #coordinator 1562486564871995482: curl: (22) The requested URL returned error: 404"
}

@test "an answer from Discord that is not the approval's message does not count" {
  jq '.id = "1562661774950400001"' "$discord/1563-1562661774950400000.json" >"$discord/x" && mv "$discord/x" "$discord/1563-1562661774950400000.json"
  refused "Discord message 1562661774950400000 cannot be fetched from the task's thread 1563 or #coordinator 1562486564871995482: curl: (22) The requested URL returned error: 404; not that message"
}

@test "an approval whose message is not a Discord message id is refused without asking Discord" {
  jq -c 'if .event == "merge-approved" then .discord_message = "1562661774950400000/../x" else . end' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  refused "merge-approved names discord_message '1562661774950400000/../x', which is not a Discord message id"
  assert_equal "$(stub_calls curl)" ""
}

@test "an approval by an author not in the plugin's allowFrom list is refused" {
  approved_by 999
  refused "Discord message 1562661774950400000 is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json"
}

@test "an approval that cannot be checked, with no token or no allowlist, is refused" {
  rm "$HOME/.claude/channels/discord/access.json"
  refused "cannot read allowFrom from ~/.claude/channels/discord/access.json, so the approval cannot be checked"
  echo '{"allowFrom": "757"}' >"$HOME/.claude/channels/discord/access.json"
  refused "cannot read allowFrom from ~/.claude/channels/discord/access.json, so the approval cannot be checked"
  echo '{"allowFrom": ["757"]}' >"$HOME/.claude/channels/discord/access.json"
  : >"$HOME/.claude/channels/discord/.env"
  refused "no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, so the approval cannot be checked"
  assert_equal "$(stub_calls curl)" ""
}

@test "a PR that is not open, is a draft or conflicts is refused" {
  pr_field '.state = "CLOSED"'
  refused "PR #5 is closed, not open"
  pr_field '.state = "OPEN" | .isDraft = true'
  refused "PR #5 is a draft"
  pr_field '.isDraft = false | .mergeable = "CONFLICTING"'
  refused "PR #5 conflicts with its base"
  pr_field '.mergeable = "UNKNOWN"'
  refused "GitHub has not worked out yet whether PR #5 conflicts with its base; try again in a minute"
}

@test "a PR whose base is not the project's base is refused, so main never changes here" {
  pr_field '.baseRefName = "main"'
  refused "PR #5 targets main, not proj's base dev"
}

@test "a required check missing on the head is refused, whether the server or the project requires it" {
  checks '[{"name": "lint", "bucket": "pass", "state": "SUCCESS"},
    {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  refused "required check test is missing on the head"
  # agent-review is required by the branch's protection, which gh pr checks --required cannot
  # show before it reports.
  checks '[{"name": "lint", "bucket": "pass", "state": "SUCCESS"},
    {"name": "test", "bucket": "pass", "state": "SUCCESS"}]'
  refused "required check agent-review is missing on the head" "agent-review is missing on the head, not success"
}

@test "a required check that has not passed is refused" {
  checks '[{"name": "test", "bucket": "fail", "state": "FAILURE"},
    {"name": "lint", "bucket": "pending", "state": "IN_PROGRESS"},
    {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  refused "required check lint has not passed on the head" "required check test has not passed on the head"
}

@test "any check failing or pending on the head is refused, required or not" {
  checks '[{"name": "test", "bucket": "pass", "state": "SUCCESS"},
    {"name": "lint", "bucket": "pass", "state": "SUCCESS"},
    {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"},
    {"name": "e2e", "bucket": "cancel", "state": "CANCELLED"},
    {"name": "deploy-preview", "bucket": "pending", "state": "QUEUED"}]'
  refused "checks failing on the head: e2e" "checks pending on the head: deploy-preview"
}

@test "agent-review not success on the head is refused" {
  checks '[{"name": "test", "bucket": "pass", "state": "SUCCESS"},
    {"name": "lint", "bucket": "pass", "state": "SUCCESS"},
    {"name": "agent-review", "bucket": "fail", "state": "FAILURE"}]'
  refused "agent-review is failure on the head, not success"
  # A skipped agent-review passes as a check but is not a review.
  checks '[{"name": "test", "bucket": "pass", "state": "SUCCESS"},
    {"name": "lint", "bucket": "pass", "state": "SUCCESS"},
    {"name": "agent-review", "bucket": "skipping", "state": "SKIPPED"}]'
  refused "agent-review is skipped on the head, not success"
}

@test "an attribution line in any commit of the PR is refused, naming the commit and the line" {
  jq -n --arg head "$head" '[
    {sha: "1111111111111111111111111111111111111111",
     commit: {message: "feat: one\n\nCo-Authored-By: Claude <noreply@anthropic.com>"}},
    {sha: $head, commit: {message: "test: two\n\nCo-Authored-By: Ada Lovelace <ada@example.com>"}}]' \
    >"$gh_dir/commits.json"
  refused "commit 1111111 (feat: one) carries an attribution line: Co-Authored-By: Claude <noreply@anthropic.com>"
  [[ $stderr != *"Ada Lovelace"* ]]
  [[ $stderr == *"team-clean-messages"* ]]
}

@test "commits read across pages are all checked, and a list that does not end at the head is refused" {
  jq -n --arg head "$head" '[{sha: "1111111111111111111111111111111111111111", commit: {message: "feat: one"}}],
    [{sha: $head, commit: {message: "test: two\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"}}]' \
    >"$gh_dir/commits.json"
  refused "commit a1b2c3d (test: two) carries an attribution line: 🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  echo '[{"sha": "1111111111111111111111111111111111111111", "commit": {"message": "feat: one"}}]' >"$gh_dir/commits.json"
  refused "the PR's commit list ends at 1111111, not at the head a1b2c3d, so not every commit could be checked"
}

@test "a head that moves between the reads is refused" {
  jq '.headRefOid = "b2c3d4e5f60718293a4b5c6d7e8f901234567890"' "$gh_dir/pr.json" >"$gh_dir/pr-again.json"
  refused "the head moved while it was read (a1b2c3d, then b2c3d4e); run team-merge again"
}

@test "a PR whose repo is not a registered project is refused" {
  event T14 pr '{url: "https://github.com/someone/else/pull/9", head: "a1b2c3d4"}'
  run_bin -1 team-merge T14
  assert_equal "$output" "team-merge: PR #9 is in someone/else, which is not a project in projects.toml, so it has no base or merge method"
  no_merge_call
}

@test "GitHub down is a refusal, never a merge" {
  stub_script gh <<'EOF'
echo "error connecting to api.github.com" >&2
exit 1
EOF
  refused "GitHub cannot be read: gh pr view: error connecting to api.github.com"
}

@test "every reason is listed at once" {
  approved_by 999
  pr_field '.isDraft = true | .baseRefName = "main"'
  checks '[{"name": "test", "bucket": "pass", "state": "SUCCESS"}]'
  refused "Discord message 1562661774950400000 is by daniel (999)" "PR #5 is a draft" "PR #5 targets main" \
    "required check lint is missing" "required check agent-review is missing" \
    "agent-review is missing on the head, not success"
}

@test "a refused gh pr merge (the head moved) logs nothing" {
  echo 'echo "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)" >&2; exit 1' \
    >"$gh_dir/merge.sh"
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "Head branch was modified"
  assert_contains "$stderr" "team-merge: gh pr merge did not merge PR #5"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "a PR left unmerged with auto-merge on has auto-merge turned off and logs nothing" {
  cat >"$gh_dir/merge.sh" <<'EOF'
if [[ " $* " == *" --disable-auto "* ]]; then
  jq '.autoMergeRequest = null' "$GH_DIR/pr.json" >"$GH_DIR/pr.next" && mv "$GH_DIR/pr.next" "$GH_DIR/pr.json"
else
  jq '.autoMergeRequest = {enabledAt: "2026-10-22T03:00:00Z"}' "$GH_DIR/pr.json" >"$GH_DIR/pr.next" && mv "$GH_DIR/pr.next" "$GH_DIR/pr.json"
  echo "! Pull request owner/proj#5 will be automatically merged when all requirements are met" >&2
fi
EOF
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: PR #5 is still open after gh pr merge, with auto-merge on; turned auto-merge off"
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "merge"])' | tail -n 1)" \
    '["pr","merge","5","--repo","owner/proj","--disable-auto"]'
  assert_equal "$(jq -c .autoMergeRequest "$gh_dir/pr.json")" null
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}

@test "gh pr merge is never given --auto or --admin" {
  run_bin -0 team-merge T14
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "merge"]) | map(select(. == "--auto" or . == "--admin"))')" "[]"
}

@test "coordinator.settings.json denies gh pr merge, gh-axi pr merge and the API's merge, and no settings file allows a merge" {
  jq -e '.permissions.deny | index("Bash(gh pr merge*)") and index("Bash(gh-axi pr merge*)")
    and index("Bash(gh api*pulls/*/merge*)")' \
    "$REPO_ROOT/coordinator.settings.json"
  local file
  for file in "$REPO_ROOT/coordinator.settings.json" "$REPO_ROOT"/settings/*.json; do
    jq -e '[.permissions.allow[]? | select(test("merge"))] == []' "$file"
  done
}

@test "a project's local checks run on the PR's exact head before the merge, and the merged event records them" {
  with_local_checks
  run_bin -0 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: running ./check.sh on ${head:0:7}"
  # It ran once, in a checkout of the head that is gone after.
  assert_equal "$(wc -l <"$GH_DIR/ran")" 1
  assert_equal "$(cut -d' ' -f2 "$GH_DIR/ran")" "$head"
  [[ ! -e $(cut -d' ' -f1 "$GH_DIR/ran") ]]
  assert_equal "$(proj_worktrees)" "$HOME/projects/proj"
  assert_equal "$(merged_events | jq -c '[.head, .local_checks]')" "[\"$head\",[\"./check.sh\"]]"
  TEAM_HOME=$TEAM_HOME run -0 "$REPO_ROOT/bin/team-log" --check
}

@test "a project's local checks run under the heavy-run lock, and wait for another holder" {
  with_local_checks
  echo "\"$REPO_ROOT/bin/team-heavy\" status >>\"\$GH_DIR/heavy\"" >"$GH_DIR/check.extra"
  run_bin -0 --separate-stderr team-merge T14
  [[ $(cat "$GH_DIR/heavy") =~ ^held\ by\ team-merge\ T14:\ ./check.sh\ on\ ${head:0:7}\ \(pid\ [0-9]+\)\ since\  ]]
}

@test "a local check that cannot take the heavy-run lock is refused, naming its holder" {
  with_local_checks
  mkdir -p "$HOME/.local/state/agent-team"
  exec {held}<>"$HOME/.local/state/agent-team/heavy.lock"
  echo "first (pid 1) since 2026-10-25 10:00:00 +0000" >"$HOME/.local/state/agent-team/heavy.lock"
  flock -x "$held"
  TEAM_HEAVY_WAIT_MINUTES=0 refused "local check './check.sh' could not run on the head ${head:0:7} yet (exit 75, try again later); its last lines:"
  assert_contains "$stderr" "team-heavy: the heavy-run lock is held by first (pid 1) since 2026-10-25 10:00:00 +0000"
  exec {held}<&-
  [[ ! -e $GH_DIR/ran ]]
}

@test "a local check that fails is refused with its last lines, and nothing merges" {
  with_local_checks
  echo 3 >"$GH_DIR/check.status"
  refused "local check './check.sh' failed on the head ${head:0:7} (exit 3); its last lines:"
  assert_contains "$stderr" "      checking the head"
  assert_equal "$(proj_worktrees)" "$HOME/projects/proj"
}

@test "a head that moves while the local checks run is refused" {
  with_local_checks
  # GitHub's PR moves to another head while the check runs.
  echo 'jq ".headRefOid = \"5555555555555555555555555555555555555555\"" "$GH_DIR/pr.json" >"$GH_DIR/pr.next" && mv "$GH_DIR/pr.next" "$GH_DIR/pr.json"' \
    >"$GH_DIR/check.extra"
  refused "the head moved while the local checks ran (${head:0:7}, then 5555555); run team-merge again"
}

@test "local checks never run while another reason refuses the merge" {
  with_local_checks
  checks '[{"name": "test", "bucket": "fail", "state": "FAILURE"}, {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  refused "checks failing on the head: test"
  [[ ! -e $GH_DIR/ran ]]
}

@test "merging into the team home checks dev against the records rule since the last merge" {
  as_team_home
  direct_commit ledger.jsonl
  run_bin -0 --separate-stderr team-merge T14
  assert_contains "$stderr" "2 commits on dev checked: each touches records only or is a pull request's merge into dev"
  # The PR's own merge passed on the PR it names, before GitHub indexed the merge commit.
  stub_calls gh | jq -e 'select(. == ["api", "repos/owner/proj/pulls/5"])' >/dev/null
  assert_equal "$(merged_events | jq -r '.project' | tail -n 1)" proj
}

@test "a commit on the team home's dev that is neither records nor a PR's merge is reported after the merge" {
  as_team_home
  direct_commit bin/sneaky
  run_bin -1 --separate-stderr team-merge T14
  # The merge happened and is logged; the report says so and names the commit.
  assert_equal "$(jq -r .task <<<"$output")" T14
  assert_equal "$(merged_events | wc -l)" 2
  assert_contains "$stderr" "chore: straight to dev"
  assert_contains "$stderr" "bin/sneaky"
  assert_contains "$stderr" "team-merge: PR #5 is merged and logged, but dev breaks the records rule since the last merge (above): tell Daniel"
}

@test "the team home's repo is checked against the records rule when its primary checkout is a second clone" {
  as_team_home apart
  direct_commit bin/sneaky
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(merged_events | wc -l)" 2
  assert_contains "$stderr" "bin/sneaky"
  assert_contains "$stderr" "team-merge: PR #5 is merged and logged, but dev breaks the records rule since the last merge (above): tell Daniel"
}

@test "a project whose repo is not the team home's origin's is not checked, whatever its primary checkout" {
  as_team_home
  git -C "$TEAM_HOME" remote set-url origin https://github.com/owner/agent-team-records.git
  git config --global url."$TEAM_ORIGIN".insteadOf https://github.com/owner/agent-team-records.git
  direct_commit bin/sneaky
  run_bin -0 team-merge T14
  if stub_calls gh | jq -e 'select(.[0] == "api" and (.[1] | endswith("/pulls")))' >/dev/null; then
    echo "team-records-check ran for a project that is not the team home's repo" >&2
    return 1
  fi
}

@test "a project that is not the team home is not checked against the records rule" {
  run_bin -0 team-merge T14
  if stub_calls gh | jq -e 'select(.[0] == "api" and (.[1] | endswith("/pulls")))' >/dev/null; then
    echo "team-records-check ran for a project that is not the team home" >&2
    return 1
  fi
}

# proj is the team home's repo, and its primary checkout at $HOME/agent-team, a second clone
# (as_team_home apart), is the code checkout team-merge runs from.
merging_the_code() {
  as_team_home apart
  code_checkout "$HOME/agent-team"
  code=$CODE_CHECKOUT
}

@test "after a merge of its own project, the code checkout's base is fast-forwarded to origin's, untracked files aside" {
  merging_the_code
  echo "a note" >"$code/notes.txt"
  run_bin -0 --separate-stderr team-merge T14
  merge=$(jq -r .merge <<<"$output")
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$merge"
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$(git -C "$TEAM_ORIGIN" rev-parse dev)"
  assert_equal "$(cat "$code/tool.sh")" tool
  assert_equal "$(grep -c 'code checkout' <<<"$stderr")" 1
  assert_contains "$stderr" "team-merge: the code checkout $code: dev fast-forwarded to ${merge:0:7}"
}

@test "a code checkout on another branch is left as it is, saying why and how, and the merge exits 0" {
  merging_the_code
  git -C "$code" switch -q -c feat/elsewhere
  before=$(git -C "$code" rev-parse HEAD)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | wc -l)" 2
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$before"
  assert_equal "$(git -C "$code" rev-parse dev)" "$before"
  assert_contains "$stderr" "team-merge: the code checkout $code is left as it is: it is on feat/elsewhere, not dev; to bring in the merged code: git -C $code switch dev && git -C $code pull --ff-only origin dev"
}

@test "a code checkout on a detached HEAD is left as it is" {
  merging_the_code
  git -C "$code" switch -q --detach
  before=$(git -C "$code" rev-parse HEAD)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$before"
  assert_contains "$stderr" "team-merge: the code checkout $code is left as it is: it is on a detached HEAD, not dev; to bring in the merged code: git -C $code switch dev && git -C $code pull --ff-only origin dev"
}

@test "a code checkout with local changes is left as it is, even when they are not in the way" {
  merging_the_code
  echo "edited" >>"$code/ledger.jsonl"
  before=$(git -C "$code" rev-parse HEAD)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$before"
  assert_equal "$(tail -n 1 "$code/ledger.jsonl")" edited
  assert_contains "$stderr" "team-merge: the code checkout $code is left as it is: it has local changes to ledger.jsonl; to bring in the merged code: git -C $code switch dev && git -C $code pull --ff-only origin dev"
}

@test "a code checkout whose base has diverged from origin's is left as it is" {
  merging_the_code
  echo "mine" >"$code/mine.txt"
  git -C "$code" add mine.txt
  git -C "$code" commit -q -m "chore: a commit of its own"
  before=$(git -C "$code" rev-parse HEAD)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$before"
  assert_contains "$stderr" "team-merge: the code checkout $code is left as it is: dev has diverged from origin's; to bring in the merged code: git -C $code switch dev && git -C $code pull --ff-only origin dev"
}

@test "an untracked file in the way leaves the code checkout as it is" {
  merging_the_code
  echo "mine" >"$code/tool.sh"
  before=$(git -C "$code" rev-parse HEAD)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$before"
  assert_equal "$(cat "$code/tool.sh")" mine
  assert_contains "$stderr" "team-merge: the code checkout $code is left as it is: local changes to tool.sh are in the way; to bring in the merged code: git -C $code switch dev && git -C $code pull --ff-only origin dev"
}

@test "a base that breaks the records rule is not brought into the code checkout" {
  merging_the_code
  direct_commit bin/sneaky
  before=$(git -C "$code" rev-parse HEAD)
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$before"
  assert_contains "$stderr" "breaks the records rule"
}

@test "a code checkout that is the team home is left to the next records push" {
  as_team_home
  code_checkout "$TEAM_HOME"
  before=$(git -C "$TEAM_HOME" rev-parse HEAD)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(git -C "$TEAM_HOME" rev-parse HEAD)" "$before"
  assert_contains "$stderr" "team-merge: the code checkout is the team home, so the next records push (team-checkpoint, team-handoff) brings it level with origin's dev"
}

@test "the code checkout is the merged project's primary checkout however the registry spells it (report F6)" {
  merging_the_code
  local other
  other=$(other_spelling "$code")
  sed -i "s|^path = \"agent-team\"\$|path = \"${other##*/}\"|" "$TEAM_HOME/projects.toml"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$(jq -r .merge <<<"$output")"
}

@test "a code checkout that is the team home spelled otherwise is left to the next records push (report F6)" {
  as_team_home
  code_checkout "$TEAM_HOME"
  TEAM_HOME=$(other_spelling "$TEAM_HOME") run_bin -0 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: the code checkout is the team home, so the next records push"
}

@test "a merge of any other project leaves the code checkout alone" {
  code_checkout
  push_to_dev "$CODE_ORIGIN" bin-change.txt >/dev/null
  before=$(git -C "$CODE_CHECKOUT" rev-parse HEAD)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(git -C "$CODE_CHECKOUT" rev-parse HEAD)" "$before"
  [[ $stderr != *"code checkout"* ]]
  [[ -z $(git -C "$CODE_CHECKOUT" for-each-ref refs/remotes/origin/dev --contains "$(git -C "$CODE_ORIGIN" rev-parse dev)") ]]
}
