#!/usr/bin/env bats
# shellcheck disable=SC2154 # head, gh_dir and discord are helpers/merge.bash's
# team-merge on Daniel's standing word: a ready PR of a project the word stands for merges with no
# ask, and one the word does not hold for comes back to Daniel as the per-head ask.

load helpers/common
load helpers/inbox
load helpers/merge

COORDINATOR=1562486564871995482

# Daniel's standing word in place of the per-head one: the merge-approved gone, a passing review of
# the head with its findings counted and no guarded area, and Daniel's merge-standing of <project>
# (proj) in message 1562661774950400000 (03:00) in <channel> (#coordinator), which Discord shows
# there from Daniel: standing_word [<project>] [<channel>]
standing_word() {
  jq -c 'select(.event != "merge-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  passed
  standing merge-standing "${1:-proj}" 1562661774950400000 "${2:-$COORDINATOR}"
  approved_by 757 "${2:-$COORDINATOR}"
}

# One standing word event of T14 (or <task>): standing <kind> <project> <message> <channel> [<task>]
standing() {
  event "${5:-T14}" "$1" "{project: \"$2\", discord_message: \"$3\", discord_channel: \"$4\"}"
}

# The line a refusal on the standing word ends with.
ask_standing() {
  echo "(Daniel's standing word does not hold: ask them for the per-head word on the head ${head:0:7} with team-ask, naming https://github.com/owner/proj/pull/5)"
}

# The post after a standing merge, Daniel's message in #coordinator: standing_post
standing_post() {
  printf '%s\n' "T14 The tooling: merged https://github.com/owner/proj/pull/5 on your standing word, https://discord.com/channels/$INBOX_GUILD/$COORDINATOR/1562661774950400000" \
    "Merge commit: $MERGE_SHA on dev." \
    "To revert: the Revert button on the PR's page opens a revert PR; or, on dev, \`git revert $MERGE_SHA\`."
}

@test "a ready PR of a project with Daniel's standing word merges on the exact head with no merge-approved" {
  standing_word
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "merge"])')" \
    "[\"pr\",\"merge\",\"5\",\"--repo\",\"owner/proj\",\"--squash\",\"--match-head-commit\",\"$head\"]"
  assert_equal "$(merged_events)" "$(jq -cn --arg m "$MERGE_SHA" --arg h "$head" --arg c "$COORDINATOR" '{task: "T14",
    event: "merged", pr: 5, merge: $m, head: $h,
    by: "Discord message 1562661774950400000 in #coordinator \($c), from daniel (757)",
    project: "proj", branch: "feat/T14-tooling", discord_message: "1562661774950400000", discord_channel: $c,
    url: "https://github.com/owner/proj/pull/5", approval: "standing"}')"
  # The word's message is read in its own channel alone.
  assert_equal "$(reads | jq -r '.[-1]')" "https://discord.com/api/v10/channels/$COORDINATOR/messages/1562661774950400000"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "a standing word for every project merges it, and so does one in the thread of the task it was logged under" {
  standing_word all
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" standing

  merge_again
  standing merge-standing proj 1562661774950400000 1563
  approved_by 757 1563
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .by] | join(" ")')" \
    "standing Discord message 1562661774950400000 in the task's thread 1563, from daniel (757)"

  # A word another task logged in its own thread holds for every task's PR.
  merge_again
  event T9 thread '{discord_thread: "1999"}'
  standing merge-standing all 1562661774950400000 1999 T9
  approved_by 757 1999
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .by] | join(" ")')" \
    "standing Discord message 1562661774950400000 in T9's thread 1999, from daniel (757)"
}

@test "a standing word on the team's own project merges its PR, whatever its merge_with_plan" {
  standing_word
  code_checkout
  git -C "$CODE_CHECKOUT" remote set-url origin git@github.com:Owner/Proj.git
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" standing
}

@test "a changed path matching a guarded pattern is refused on the standing word" {
  standing_word
  files src/tooling.py .github/workflows/test.yml
  refused ".github/workflows/test.yml is a guarded path (ci): a change there comes back to Daniel" "$(ask_standing)"
  assert_equal "$(tail -n 1 <<<"$stderr")" "  $(ask_standing)"
  [[ $stderr != *"merge-approved"* && $stderr != *"plan-time"* ]]
}

@test "a latest review that logged no guarded areas, or named some, is refused on the standing word" {
  standing_word
  event T14 review "{verdict: \"pass\", head: \"$head\",
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}}"
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, logged no guarded areas, so no reviewer has said the change touches none" \
    "$(ask_standing)"
  event T14 review "{verdict: \"pass\", head: \"$head\",
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}, guarded: [\"settings\"]}"
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, found the change touching guarded areas: settings" \
    "$(ask_standing)"
}

@test "a security or real-data finding in any review of the task, even fixed since, is refused on the standing word" {
  standing_word
  ledger_line '{ts: "2026-10-21T10:00:00Z", task: "T14", event: "review", verdict: "findings", head: "0fedcba98",
    findings: {blocking: 0, correctness: 0, security: 1, "real-data": 0, "note-change": 0, "note-before": 0}, guarded: []}'
  ledger_line '{ts: "2026-10-21T11:00:00Z", task: "T14", event: "review", verdict: "findings", head: "1234567ab",
    findings: {blocking: 0, correctness: 0, security: 0, "real-data": 2, "note-change": 0, "note-before": 0}, guarded: []}'
  refused "the review of the head 0fedcba, at 2026-10-21T10:00:00Z, counted 1 security finding: such a finding on the task, even fixed, comes back to Daniel" \
    "the review of the head 1234567, at 2026-10-21T11:00:00Z, counted 2 real-data findings: such a finding on the task, even fixed, comes back to Daniel" \
    "$(ask_standing)"
}

@test "a standing word withdrawn since is refused, naming the withdrawal, without asking Discord" {
  standing_word
  standing merge-standing-withdrawn proj 1562676874444800000 "$COORDINATOR"
  refused "Daniel's standing word on proj, Discord message 1562661774950400000, was withdrawn at 2026-10-22T02:00:00Z in Discord message 1562676874444800000" \
    "$(ask_standing)"
  assert_equal "$(reads)" ""

  # A word for every project withdrawn for this one names every project.
  standing merge-standing all 1562691973939200000 "$COORDINATOR"
  standing merge-standing-withdrawn proj 1562676874444800000 "$COORDINATOR"
  refused "Daniel's standing word on every project, Discord message 1562691973939200000, was withdrawn at 2026-10-22T02:00:00Z in Discord message 1562676874444800000" \
    "$(ask_standing)"

  # A word given again stands again.
  standing merge-standing proj 1562661774950400000 "$COORDINATOR"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" standing
}

@test "a standing word for another project only is refused, without asking Discord" {
  standing_word lib
  refused "no standing word of Daniel's names proj or every project" "$(ask_standing)"
  [[ $stderr != *"merge-approved"* ]]
  assert_equal "$(reads)" ""
}

@test "a standing word by an author not in allowFrom, or one Discord cannot show in its channel, is refused" {
  standing_word
  approved_by 999 "$COORDINATOR"
  refused "Discord message 1562661774950400000 is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json" \
    "$(ask_standing)"

  # In the task's thread, not in #coordinator the word names: only #coordinator is read.
  approved_by 757 1563
  refused "Discord message 1562661774950400000 cannot be fetched from #coordinator $COORDINATOR: curl: (22) The requested URL returned error: 404" \
    "$(ask_standing)"
  assert_equal "$(reads | jq -r '.[-1]' | sort -u)" "https://discord.com/api/v10/channels/$COORDINATOR/messages/1562661774950400000"
}

@test "a standing word in a channel that is neither #coordinator nor its task's thread is refused, without asking Discord" {
  standing_word proj 1999
  refused "merge-standing names discord_channel 1999, which is neither #coordinator nor T14's thread" "$(ask_standing)"
  assert_equal "$(reads)" ""

  # Another task's thread is not the thread of the task the word was logged under.
  event T9 thread '{discord_thread: "1999"}'
  refused "merge-standing names discord_channel 1999, which is neither #coordinator nor T14's thread" "$(ask_standing)"
  assert_equal "$(reads)" ""
}

@test "a PR from a branch that is not the task's is refused on the standing word" {
  standing_word
  pr_field '.headRefName = "feat/T15-other"'
  refused "PR #5 comes from feat/T15-other, not feat/T14-tooling, T14's branch for proj" "$(ask_standing)"
}

@test "a refusal on the standing word lists every reason at once, the checks every merge gets among them" {
  standing_word
  review "$head" findings
  files src/tooling.py package.json
  checks '[{"name": "test", "bucket": "fail", "state": "FAILURE"},
    {"name": "agent-review", "bucket": "pending", "state": "IN_PROGRESS"}]'
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, is findings, not pass" \
    "package.json is a guarded path (dependencies): a change there comes back to Daniel" \
    "required check lint is missing on the head" "required check test has not passed on the head" \
    "checks failing on the head: test" "checks pending on the head: agent-review" \
    "agent-review is in_progress on the head, not success"
  assert_equal "$(tail -n 1 <<<"$stderr")" "  $(ask_standing)"
}

@test "a standing merge posts to the task's thread and #coordinator once merged is logged, linking Daniel's word" {
  standing_word
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(posts)" "1563 $(standing_post | jq -Rsc 'rtrimstr("\n")')
$COORDINATOR $(standing_post | jq -Rsc 'rtrimstr("\n")')"
  assert_equal "$(jq -r .merged "$discord/posts" | sort -u)" 1
  [[ $stderr != *post* ]]
}

@test "a standing merge's failed post is said on stderr with its text, and the merge stands" {
  standing_word
  echo 1563 >"$discord/refuse"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" standing
  assert_equal "$(jq -r .channel "$discord/posts")" "$COORDINATOR"
  assert_contains "$stderr" "team-merge: PR #5 is merged, but its post to the task's thread 1563 failed (team-post: Discord refused the post: curl: (22) The requested URL returned error: 500; nothing was posted); post this text with team-post T14 --file <its file>:
$(standing_post)"
}

@test "a per-head or plan-time word that holds merges on its own approval, with a standing word logged too" {
  standing merge-standing all 1562691973939200000 "$COORDINATOR"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .discord_message] | join(" ")')" "head 1562661774950400000"
  # Only the per-head word's message is read, never the standing word's.
  assert_equal "$(reads | jq -r '.[-1]' | sort -u)" "https://discord.com/api/v10/channels/1563/messages/1562661774950400000"
  assert_equal "$(posts)" ""

  merge_again
  plan_word
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .discord_message] | join(" ")')" "plan 1562661774950400000"
  assert_equal "$(merge_post 1563 x | head -n 1)" "$(jq -r .content "$discord/posts" | head -n 1)"
  assert_equal "$(reads | jq -r '.[-1]' | sort -u)" "https://discord.com/api/v10/channels/1563/messages/1562661774950400000"
}

# Daniel's message <message> in <channel>, by user 757 (or <author>): said <message> <channel> [<author>]
said() {
  jq -n --arg m "$1" --arg c "$2" --arg author "${3:-757}" '{id: $m, channel_id: $c,
    content: "standing order: merge when ready", author: {id: $author, username: "daniel"}}' >"$discord/$2-$1.json"
}

# Daniel's standing word on proj beside the earlier word: a passing review of the head, and their
# merge-standing in message 1562691973939200000 (05:00) in #coordinator, which Discord shows there.
standing_too() {
  passed
  standing merge-standing proj 1562691973939200000 "$COORDINATOR"
  said 1562691973939200000 "$COORDINATOR"
}

# The merged event's approval, message and head.
merged_on() {
  merged_events | jq -r '[.approval, .discord_message, .head, .by] | join(" ")'
}

# Each reason given is on exactly one line of the refusal <text>: once <text> <reason>...
once() {
  local reason
  for reason in "${@:2}"; do assert_equal "$(grep -cFx "  $reason" <<<"$1")" 1; done
}

@test "a PR whose head holds a commit of its own since Daniel's per-head word merges on the standing word" {
  moved_head own
  standing_too
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_on)" "standing 1562691973939200000 $head Discord message 1562691973939200000 in #coordinator $COORDINATOR, from daniel (757)"
  assert_equal "$(merged_events | jq -r .discord_channel)" "$COORDINATOR"
  assert_equal "$(jq -r .content "$discord/posts" | head -n 1 | grep -o 'standing word, .*')" \
    "standing word, https://discord.com/channels/$INBOX_GUILD/$COORDINATOR/1562691973939200000"
}

@test "a per-head word whose message is not Daniel's merges on a standing word that holds" {
  approved_by 999
  standing_too
  run_bin -0 team-merge T14
  assert_equal "$(merged_on)" "standing 1562691973939200000 $head Discord message 1562691973939200000 in #coordinator $COORDINATOR, from daniel (757)"
}

@test "a plan-time word refused for a path outside its scope merges on a standing word that holds" {
  plan_word
  files src/tooling.py docs/tooling.md
  standing merge-standing proj 1562691973939200000 "$COORDINATOR"
  said 1562691973939200000 "$COORDINATOR"
  run_bin -0 team-merge T14
  assert_equal "$(merged_on)" "standing 1562691973939200000 $head Discord message 1562691973939200000 in #coordinator $COORDINATOR, from daniel (757)"
  assert_equal "$(jq -r .content "$discord/posts" | grep -c 'on your standing word')" 2
}

@test "a per-head word that holds is refused for a red check alone, with no standing reason and no ask line" {
  standing_too
  checks '[{"name": "test", "bucket": "fail", "state": "FAILURE"},
    {"name": "lint", "bucket": "pass", "state": "SUCCESS"}, {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  refused "required check test has not passed on the head" "checks failing on the head: test"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
  [[ $stderr != *standing* && $stderr != *"(Daniel's"* ]]
  [[ $(reads) != *1562691973939200000* ]]
}

@test "when neither the per-head and standing words, nor the plan-time and standing words, hold, both words' reasons are named once" {
  moved_head own
  standing_too
  files src/tooling.py package.json
  checks '[{"name": "test", "bucket": "fail", "state": "FAILURE"},
    {"name": "lint", "bucket": "pass", "state": "SUCCESS"}, {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  refused "the head moved past Daniel's word with ${own:0:7}: ask again" \
    "package.json is a guarded path (dependencies): a change there comes back to Daniel" \
    "checks failing on the head: test" "$(ask_standing)"
  once "$stderr" "the head moved past Daniel's word with ${own:0:7}: ask again" \
    "package.json is a guarded path (dependencies): a change there comes back to Daniel" \
    "checks failing on the head: test" "$(ask_standing)"
  assert_equal "$(tail -n 1 <<<"$stderr")" "  $(ask_standing)"

  # The plan-time word and the standing word share the guarded path: it is named once, and the
  # standing word's ask line alone ends the refusal.
  plan_word
  files src/tooling.py package.json
  refused "package.json is outside the scope of Daniel's plan-time word: src/" \
    "package.json is a guarded path (dependencies): a change there comes back to Daniel" \
    "checks failing on the head: test" "$(ask_standing)"
  once "$stderr" "package.json is outside the scope of Daniel's plan-time word: src/" \
    "package.json is a guarded path (dependencies): a change there comes back to Daniel" \
    "checks failing on the head: test" "$(ask_standing)"
  assert_equal "$(tail -n 1 <<<"$stderr")" "  $(ask_standing)"
  [[ $stderr != *"$(ask_per_head)"* ]]
}
