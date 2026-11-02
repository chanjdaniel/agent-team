# The setup and helpers of team-merge's tests, shared by every file that tests it
# (tests/team-merge.bats, and the files split from it): load it after helpers/common and
# helpers/inbox, whose inbox_discord its setup calls, and it defines setup itself.
#
# setup gives the sandbox the project proj (owner/proj, base dev, squash, required check test),
# Daniel (user 757) in allowFrom, PR #5 green on the head $head (green_pr) with Daniel's word in
# message 1562661774950400000 in T14's thread 1563 (approved_by), the stub gh and Discord
# (stub_gh, stub_discord, inbox_discord) answering from $GH_DIR and $DISCORD_DIR, and T14 open
# with its thread, its pr event and its merge-approved (open_task). Each helper below says what it
# sets or checks.
# shellcheck shell=bash

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
  inbox_discord
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

# PR #5 as GitHub shows it: open, mergeable, on dev, every check green on the head, two
# commits with clean messages and two changed files under src/; edit the files under $GH_DIR to
# break one fact.
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
  files src/tooling.py src/tooling_test.py
}

# PR #5's changed files as GitHub lists them, one page, and its changed-file count to match:
# files <path>... (<old>=><new> is a rename)
files() {
  printf '%s\n' "$@" | jq -sR 'split("\n")[:-1] | map(if test("=>") then split("=>")
    | {filename: .[1], previous_filename: .[0], status: "renamed"} else {filename: ., status: "modified"} end)' \
    >"$gh_dir/files.json"
  pr_field ".changedFiles = $#"
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
  "api repos/owner/proj/pulls/5/files --paginate") cat "$GH_DIR/files.json" ;;
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
# missing one fails as curl -f does on a 404. A POST to channels/<c>/messages (team-post's) is
# kept as a line {channel, content, merged} in $DISCORD_DIR/posts, merged counting the ledger's
# merged events when it came, and answered with a new id, or fails with a 500 when
# $DISCORD_DIR/refuse lists the channel. The headers curl read from stdin are kept.
# team-inbox's calls go to the fake Discord of helpers/inbox.
stub_discord() {
  stub_script curl <<'EOF'
[[ ! -f $STUB_FIXTURES/inbox.sh ]] || source "$STUB_FIXTURES/inbox.sh"
cat >>"$DISCORD_DIR/stdin"
url=${*: -1} args=("$@")
if [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)/messages$ && " $* " == *" -X POST "* ]]; then
  channel=${BASH_REMATCH[1]}
  for ((i = 0; i < ${#args[@]} - 1; i++)); do
    case ${args[i]} in
      -d) body=${args[i + 1]} ;;
      -D) headers=${args[i + 1]} ;;
    esac
  done
  if grep -qx "$channel" "$DISCORD_DIR/refuse" 2>/dev/null; then
    echo "HTTP/1.1 500 Internal Server Error" >"$headers"
    echo "curl: (22) The requested URL returned error: 500" >&2
    exit 22
  fi
  merged=$(grep -c '"event":"merged"' "$TEAM_HOME/ledger.jsonl" || true)
  jq -c --arg c "$channel" --argjson merged "$merged" '{channel: $c, content, merged: $merged}' <<<"$body" >>"$DISCORD_DIR/posts"
  echo "HTTP/1.1 200 OK" >"$headers"
  echo "{\"id\": \"$((1571000000000000000 + $(wc -l <"$DISCORD_DIR/posts")))\"}"
elif [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)/messages/([0-9]+)$ &&
  -f $DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json ]]; then
  cat "$DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
EOF
}

# The reads of a message by id, team-inbox's calls left out.
reads() {
  stub_calls curl | jq -c 'select(.[-1] | test("/messages/[0-9]+$")) | select(index("-X") | not)'
}

# What team-post sent, one "<channel> <content as JSON>" per line.
posts() {
  jq -r '"\(.channel) \(.content | @json)"' "$discord/posts" 2>/dev/null || true
}

# The post after a plan-time merge, Daniel's message in <channel> and <revert> the revert on dev:
# merge_post <channel> <revert>
merge_post() {
  printf '%s\n' "T14 The tooling: merged https://github.com/owner/proj/pull/5 on your plan-time word, https://discord.com/channels/$INBOX_GUILD/$1/1562661774950400000" \
    "Merge commit: $MERGE_SHA on dev." \
    "To revert: the Revert button on the PR's page opens a revert PR; or, on dev, $2."
}

# Undo a merge for the test's next run: the merged event and the posts gone, PR #5 open and green again.
merge_again() {
  jq -c 'select(.event != "merged")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  rm -f "$discord/posts"
  green_pr
}

# Message 1562661774950400000 in the task's thread (or the channel given), written by the user id given.
approved_by() {
  rm -f "$discord"/*-1562661774950400000.json
  jq -n --arg author "$1" --arg channel "${2:-1563}" '{id: "1562661774950400000", channel_id: $channel,
    content: "merge it", author: {id: $author, username: "daniel"}}' >"$discord/${2:-1563}-1562661774950400000.json"
}

# Run team-merge expecting a refusal: exit 1, stderr naming every reason given, gh pr merge never
# called and nothing appended to the ledger.
# shellcheck disable=SC2154 # bats' run sets output and stderr
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

# PR #5's branch is real on proj's origin: commit A, its head when Daniel was asked, then what
# the arguments add, in order: "base" (a commit on origin's dev merged into the branch) or "own"
# (a commit of the branch's own). The ledger's pr event and Daniel's word name A, the PR's head is
# the branch's tip, and $approved is A, $own the first commit of its own after A.
moved_head() {
  local primary step
  primary=$(make_repo proj dev)
  git -C "$primary" checkout -q -b feat/T14-tooling
  git -C "$primary" commit -q --allow-empty -m "feat: A"
  approved=$(git -C "$primary" rev-parse HEAD) own=''
  for step in "$@"; do
    if [[ $step == base ]]; then
      git -C "$primary" checkout -q dev
      git -C "$primary" commit -q --allow-empty -m "feat: another task on dev"
      git -C "$primary" push -q origin dev
      git -C "$primary" checkout -q feat/T14-tooling
      git -C "$primary" merge -q --no-ff -m "Merge origin/dev" dev
    else
      git -C "$primary" commit -q --allow-empty -m "fix: after the ask"
      own=${own:-$(git -C "$primary" rev-parse HEAD)}
    fi
  done
  git -C "$primary" push -q origin feat/T14-tooling
  git -C "$primary" checkout -q dev
  head=$(git -C "$primary" rev-parse feat/T14-tooling)
  green_pr
  jq -c 'select(.event != "pr" and .event != "merge-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$approved\", project: \"proj\"}"
  event T14 merge-approved "{url: \"https://github.com/owner/proj/pull/5\", discord_message: \"1562661774950400000\", head: \"$approved\"}"
}

# A review of PR #5 at <head> with <verdict>, logged now: review <head> <verdict>
review() {
  event T14 review "{verdict: \"$2\", head: \"$1\"}"
}

# The worktrees of proj's primary checkout, one path per line.
proj_worktrees() {
  git -C "$HOME/projects/proj" worktree list --porcelain | sed -n 's/^worktree //p'
}

# proj is the code: a bare origin whose dev is proj's base, named https://github.com/owner/proj.git
# (git's url.insteadOf leads there), and its primary checkout at $HOME/agent-team, a clone of it,
# is the code checkout team-merge runs from. PR #5's head is a real commit on origin's
# feat/T14-tooling, and gh pr merge merges it on origin with a merge commit that GitHub then names
# as PR #5's.
merging_the_code() {
  local pr_clone=$BATS_TEST_TMPDIR/pr start=$BATS_TEST_TMPDIR/start
  export PROJ_ORIGIN=$BATS_TEST_TMPDIR/origin/proj.git
  git init -q --bare -b dev "$PROJ_ORIGIN"
  git clone -q "$PROJ_ORIGIN" "$start" 2>/dev/null
  git -C "$start" checkout -q -B dev
  echo "code" >"$start/README.md"
  git -C "$start" add README.md
  git -C "$start" commit -q -m "chore: start the code"
  git -C "$start" push -q origin dev
  git config --global url."$PROJ_ORIGIN".insteadOf https://github.com/owner/proj.git
  sed -i 's|^path = "projects/proj"$|path = "agent-team"|' "$TEAM_HOME/projects.toml"
  git clone -q https://github.com/owner/proj.git "$HOME/agent-team"
  code_checkout "$HOME/agent-team"
  # shellcheck disable=SC2034 # the tests read code
  code=$CODE_CHECKOUT
  git clone -q "$PROJ_ORIGIN" "$pr_clone"
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
git clone -q "$PROJ_ORIGIN" "$clone"
git -C "$clone" checkout -q dev
git -C "$clone" merge -q --no-ff -m "Merge pull request #5 from owner/feat/T14-tooling" origin/feat/T14-tooling
git -C "$clone" push -q origin dev
m=$(git -C "$clone" rev-parse HEAD)
jq --arg m "$m" '.state = "MERGED" | .mergeCommit = {oid: $m}' "$GH_DIR/pr.json" >"$GH_DIR/pr.next"
mv "$GH_DIR/pr.next" "$GH_DIR/pr.json"
SH
}

# Daniel's plan-time word in place of the per-head one: proj opts in, the merge-approved is gone,
# and T14 logs the plan ask plan-T14 at 02:00, Daniel's merge-preapproved of proj answering it in
# message 1562661774950400000 (03:00), and a passing review of the head, its findings counted and
# no guarded area.
plan_word() {
  sed -i 's|^toolkits = \[\]$|toolkits = []\nmerge_with_plan = true|' "$TEAM_HOME/projects.toml"
  jq -c 'select(.event != "merge-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 asked '{id: "plan-T14", text: "Approve the plan, and the merge with it?"}'
  preapproved
  passed
}

# Daniel's plan-time word on proj: preapproved [<message>] [<ask>] [<scope as JSON>]
preapproved() {
  event T14 merge-preapproved "{project: \"proj\", ask: \"${2:-plan-T14}\",
    discord_message: \"${1:-1562661774950400000}\", scope: ${3:-[\"src/\"]}}"
}

# Daniel's withdrawal in message 1562676874444800000, sent at 04:00.
withdrawn() {
  event T14 merge-preapproval-withdrawn '{project: "proj", discord_message: "1562676874444800000"}'
}

# A passing review of <head> (the PR's by default), its findings counted, logged now: passed [<head>]
passed() {
  event T14 review "{verdict: \"pass\", head: \"${1:-$head}\",
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}, guarded: []}"
}

# The line a refusal on the plan-time word ends with.
ask_per_head() {
  echo "(Daniel's plan-time word does not hold: ask them for the per-head word on the head ${head:0:7} with team-ask, naming https://github.com/owner/proj/pull/5)"
}

# Run team-merge expecting the registry's refusal of merge_with_plan on the team's own project:
# exit 1 naming it, gh pr merge never called and nothing appended to the ledger.
registry_refused() {
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "$1"
  no_merge_call
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
}
