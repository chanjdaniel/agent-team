#!/usr/bin/env bats
# shellcheck disable=SC2154 # head, approved, own, code, gh_dir and discord are helpers/merge.bash's
# team-merge: the coordinator's only merge path, on Daniel's recorded word and a green head.

load helpers/common
load helpers/inbox
load helpers/merge

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
    url: "https://github.com/owner/proj/pull/5", approval: "head"}')"
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg m "$merge" --arg h "$head" '{task: "T14",
    pr: "https://github.com/owner/proj/pull/5", merge: $m, head: $h,
    by: "Discord message 1562661774950400000 in the task'"'"'s thread 1563, from daniel (757)"}')"
  # The merge is confirmed by reading the PR again after gh pr merge.
  assert_equal "$(stub_calls gh | jq -r 'select(.[0:2] == ["pr", "view"]) | .[0:2] | join(" ")' | wc -l)" 3
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "view"])' | tail -n 1 | jq -r '.[-1]')" \
    "state,mergeCommit,headRefOid,autoMergeRequest"
  # Daniel's per-head word needs no post: nothing is posted.
  assert_equal "$(posts)" ""
  [[ $stderr != *post* ]]
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

# The task's opened event names the story <id>, as team-open --story logs it: story_of <id>
story_of() {
  jq -c --arg s "$1" 'if .event == "opened" then .story = $s else . end' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
}

@test "a merge marks the task's story done with the PR in the project's backlog, naming the file to commit" {
  local file=$TEAM_HOME/projects/proj/backlog/E40-history/F01-the-markets/S02-every-write.md
  backlog_story proj E40-history/F01-the-markets/S02-every-write.md E40/F01/S02 ready "[71]"
  story_of E40/F01/S02
  run_bin -0 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: marked E40/F01/S02 done with PR 5 in projects/proj/backlog/E40-history/F01-the-markets/S02-every-write.md; commit it with the records"
  # Only the front matter changes.
  assert_equal "$(cat "$file")" "---
id: E40/F01/S02
title: A story
type: story
status: done
blocked_by: []
pr: [71, 5]
---

## What to build

status: ready
pr: []"
  TEAM_HOME=$TEAM_HOME run -0 "$REPO_ROOT/bin/team-log" --check
}

@test "the story's pr list keeps its own style, an empty one takes the bare number, and a story that reads so already is left as it is" {
  local dir=$TEAM_HOME/projects/proj/backlog/E9-x/F1-y
  story_of E9/F1/S1
  backlog_story proj E9-x/F1-y/S1-z.md E9/F1/S1 in-progress "[#66, #67]"
  run_bin -0 team-merge T14
  assert_equal "$(sed -n 's/^\(status\|pr\): //p' "$dir/S1-z.md" | head -n 2 | paste -sd ' ')" "done [#66, #67, #5]"

  backlog_story proj E9-x/F1-y/S1-z.md E9/F1/S1 ready "[]"
  green_pr
  run_bin -0 team-merge T14
  assert_equal "$(sed -n 's/^\(status\|pr\): //p' "$dir/S1-z.md" | head -n 2 | paste -sd ' ')" "done [5]"

  green_pr
  run_bin -0 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: E9/F1/S1 reads done with PR 5 already in projects/proj/backlog/E9-x/F1-y/S1-z.md"
  assert_equal "$(sed -n 's/^\(status\|pr\): //p' "$dir/S1-z.md" | head -n 2 | paste -sd ' ')" "done [5]"
}

@test "a story that cannot be marked is said on stderr, and the merge stands" {
  story_of E40/F01/S02
  run_bin -0 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: PR #5 is merged, but its story E40/F01/S02 is not marked done: proj's backlog has no story E40/F01/S02 (a file projects/proj/backlog/E40-*/F01-*/S02-*.md whose id is E40/F01/S02)"
  assert_equal "$(merged_events | wc -l)" 1

  local file=$TEAM_HOME/projects/proj/backlog/E40-h/F01-m/S02-w.md
  backlog_story proj E40-h/F01-m/S02-w.md E40/F01/S02 ready "#71"
  green_pr
  run_bin -0 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: PR #5 is merged, but its story E40/F01/S02 is not marked done: its pr: line is no [...] list: pr: #71"
  assert_equal "$(sed -n 's/^status: //p' "$file" | head -n 1)" ready
}

@test "a task with no story changes no backlog file" {
  backlog_story proj E40-h/F01-m/S02-w.md E40/F01/S02
  run_bin -0 --separate-stderr team-merge T14
  [[ $stderr != *story* ]]
  assert_equal "$(sed -n 's/^status: //p' "$TEAM_HOME/projects/proj/backlog/E40-h/F01-m/S02-w.md" | head -n 1)" ready
}

@test "a merge brings the Waiting on you message up to date" {
  # Reviewed at the head and not yet approved, the PR waits on Daniel.
  jq -c 'select(.event != "merge-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 review '{head: "a1b2c3d4", verdict: "pass"}'
  run_bin -0 team-inbox
  assert_equal "$(inbox_items_shown)" "**PRs ready to merge**
- T14 The tooling: https://github.com/owner/proj/pull/5"
  event T14 merge-approved '{url: "https://github.com/owner/proj/pull/5", discord_message: "1562661774950400000", head: "a1b2c3d4"}'
  : >"$STUB_FIXTURES/inbox/calls"
  run_bin -0 --separate-stderr team-merge T14
  [[ $stderr != *"Waiting on you"* ]]
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000001"
  assert_equal "$(inbox_items_shown)" "Nothing waits on you."
}

@test "Discord refusing the Waiting on you message is a line on stderr, and the merge stands" {
  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin -0 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: the Waiting on you message is not updated: Discord refused the read of #coordinator's channel: curl: (22) The requested URL returned error: 500"
  assert_equal "$(merged_events | wc -l)" 1
}

@test "the message is read with the bot token on stdin, never on the command line or in the output" {
  run_bin -0 team-merge T14
  assert_equal "$(reads)" \
    '["-fsS","-H","@-","https://discord.com/api/v10/channels/1563/messages/1562661774950400000"]'
  assert_equal "$(cat "$discord/stdin")" "Authorization: Bot $FAKE_DISCORD_TOKEN"
  [[ $output != *"$FAKE_DISCORD_TOKEN"* ]]
  [[ $(cat "$STUB_CALLS"/*.log) != *"$FAKE_DISCORD_TOKEN"* ]]
}

@test "Daniel's word in #coordinator counts when it is not in the task's thread" {
  approved_by 757 1562486564871995482
  run_bin -0 team-merge T14
  assert_equal "$(reads | jq -r '.[-1]')" \
    "https://discord.com/api/v10/channels/1563/messages/1562661774950400000
https://discord.com/api/v10/channels/1562486564871995482/messages/1562661774950400000"
  assert_equal "$(merged_events | jq -r .by)" "Discord message 1562661774950400000 in #coordinator 1562486564871995482, from daniel (757)"
}

@test "a task without a thread has its word looked up in #coordinator only" {
  jq -c 'select(.event != "thread")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  approved_by 757 1562486564871995482
  run_bin -0 team-merge T14
  assert_equal "$(reads | jq -r '.[-1]')" "https://discord.com/api/v10/channels/1562486564871995482/messages/1562661774950400000"
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

@test "Daniel's word on a head merges the PR at that head" {
  moved_head
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .head)" "$approved"
}

@test "Daniel's word on a fix head a review logged, though no pr event did, merges the PR at that head" {
  # The pr event at A, findings, then the fix B, reviewed and passed with no new pr event.
  moved_head own
  jq -c 'select(.event != "merge-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  review "$approved" findings
  review "$head" pass
  event T14 merge-approved "{url: \"https://github.com/owner/proj/pull/5\", discord_message: \"1562661774950400000\", head: \"$head\"}"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .head)" "$head"
}

@test "Daniel's word is timed against the first event that logged its head, a review included" {
  moved_head own
  jq -c 'select(.event != "merge-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  # The review of B at 03:30, after the message at 03:00; a pr event of B after it does not move it.
  ledger_line --arg h "$head" '{ts: "2026-10-22T03:30:00Z", task: "T14", event: "review", verdict: "pass", head: $h}'
  ledger_line --arg h "$head" '{ts: "2026-10-22T04:00:00Z", task: "T14", event: "pr", url: "https://github.com/owner/proj/pull/5", head: $h}'
  event T14 merge-approved "{url: \"https://github.com/owner/proj/pull/5\", discord_message: \"1562661774950400000\", head: \"$head\"}"
  refused "Discord message 1562661774950400000 was sent at 2026-10-22T03:00:00Z, before the review event of https://github.com/owner/proj/pull/5 at ${head:0:7} at 2026-10-22T03:30:00Z, so it is not Daniel's word on this PR"
  assert_equal "$(stub_calls curl)" ""
}

@test "Daniel's word holds through a merge of the base whose passing review was logged after it" {
  moved_head base
  review "$head" pass
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .head)" "$head"
}

@test "a merge of the base after Daniel's word with no passing review of it logged after the word is refused" {
  moved_head base
  review "$approved" pass
  review "$head" findings
  refused "the head ${head:0:7} is ${approved:0:7}, Daniel's word, with merges of the base, but no passing review of ${head:0:7} is logged after the word: review it, or ask again"
  # A pass logged before the word does not count either.
  jq -c 'select(.event != "review" and .event != "merge-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  review "$head" pass
  event T14 merge-approved "{url: \"https://github.com/owner/proj/pull/5\", discord_message: \"1562661774950400000\", head: \"$approved\"}"
  refused "the head ${head:0:7} is ${approved:0:7}, Daniel's word, with merges of the base, but no passing review of ${head:0:7} is logged after the word: review it, or ask again"
}

@test "a commit of the PR's own after Daniel's word is refused naming it, even with a passing review" {
  moved_head base own base
  review "$head" pass
  refused "the head moved past Daniel's word with ${own:0:7}: ask again"
}

@test "a head that does not hold the one Daniel's word named is refused" {
  moved_head
  jq -c 'if .event == "pr" or .event == "merge-approved" then .head = "0123456789abcdef0123456789abcdef01234567" else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  review "$head" pass
  refused "the head ${head:0:7} does not hold 0123456, the head Daniel's word named: ask again"
}

@test "Daniel's word on a head no pr event or review logged is refused without asking Discord" {
  moved_head
  jq -c 'if .event == "merge-approved" then .head = "0123456789abcdef0123456789abcdef01234567" else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  refused "merge-approved names the head 0123456, which no pr event of https://github.com/owner/proj/pull/5, nor a review since, logged: ask again on the PR's head"
  assert_equal "$(stub_calls curl)" ""
}

@test "Daniel's word sent before the pr event of the head it names is refused, though a later pr event logged another" {
  moved_head base
  # The pr event of A at 03:30, after the message at 03:00; one of the PR's head at 02:00.
  jq -c 'if .event == "pr" then .ts = "2026-10-22T03:30:00Z" else . end' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\", project: \"proj\"}"
  review "$head" pass
  refused "Discord message 1562661774950400000 was sent at 2026-10-22T03:00:00Z, before the pr event of https://github.com/owner/proj/pull/5 at ${approved:0:7} at 2026-10-22T03:30:00Z, so it is not Daniel's word on this PR"
  assert_equal "$(stub_calls curl)" ""
}

@test "a legacy approval with no head holds for the PR's head, as before" {
  moved_head own
  jq -c 'if .event == "merge-approved" then del(.head) else . end' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .head)" "$head"
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
  assert_contains "$stderr" "team-checks: running ./check.sh on ${head:0:7}"
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

@test "after a merge of its own project, the code checkout's base is fast-forwarded to origin's, untracked files aside" {
  merging_the_code
  echo "a note" >"$code/notes.txt"
  run_bin -0 --separate-stderr team-merge T14
  merge=$(jq -r .merge <<<"$output")
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$merge"
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$(git -C "$PROJ_ORIGIN" rev-parse dev)"
  assert_equal "$(cat "$code/tool.sh")" tool
  assert_equal "$(grep -c 'code checkout' <<<"$stderr")" 1
  assert_contains "$stderr" "team-merge: the code checkout $code: dev fast-forwarded to ${merge:0:7}"
}

@test "a code checkout on another branch is left as it is, saying why and how, and the merge exits 0" {
  merging_the_code
  git -C "$code" switch -q -c feat/elsewhere
  before=$(git -C "$code" rev-parse HEAD)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | wc -l)" 1
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
  echo "edited" >>"$code/README.md"
  before=$(git -C "$code" rev-parse HEAD)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$before"
  assert_equal "$(tail -n 1 "$code/README.md")" edited
  assert_contains "$stderr" "team-merge: the code checkout $code is left as it is: it has local changes to README.md; to bring in the merged code: git -C $code switch dev && git -C $code pull --ff-only origin dev"
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

@test "the code checkout is the merged project's primary checkout however the registry spells it (report F6)" {
  merging_the_code
  local other
  other=$(other_spelling "$code")
  sed -i "s|^path = \"agent-team\"\$|path = \"${other##*/}\"|" "$TEAM_HOME/projects.toml"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(git -C "$code" rev-parse HEAD)" "$(jq -r .merge <<<"$output")"
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

@test "a pre-approved PR of a project that opts in merges on Daniel's plan-time word, with no merge-approved" {
  plan_word
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "merge"])')" \
    "[\"pr\",\"merge\",\"5\",\"--repo\",\"owner/proj\",\"--squash\",\"--match-head-commit\",\"$head\"]"
  assert_equal "$(merged_events)" "$(jq -cn --arg m "$MERGE_SHA" --arg h "$head" '{task: "T14", event: "merged",
    pr: 5, merge: $m, head: $h,
    by: "Discord message 1562661774950400000 in the task'"'"'s thread 1563, from daniel (757)",
    project: "proj", branch: "feat/T14-tooling", discord_message: "1562661774950400000", discord_channel: "1563",
    url: "https://github.com/owner/proj/pull/5", approval: "plan"}')"
  assert_equal "$(reads | jq -r '.[-1]')" "https://discord.com/api/v10/channels/1563/messages/1562661774950400000"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "Daniel's plan-time word in #coordinator counts when it is not in the task's thread" {
  plan_word
  approved_by 757 1562486564871995482
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .by] | join(" ")')" \
    "plan Discord message 1562661774950400000 in #coordinator 1562486564871995482, from daniel (757)"
}

@test "with a merge-approved for the PR, the per-head word is read as today and the plan-time one is not" {
  plan_word
  # The per-head word, sent at 01:00 before the pr event, is refused though the plan-time word stands.
  event T14 merge-approved '{url: "https://github.com/owner/proj/pull/5", discord_message: "1562631575961600000"}'
  refused "Discord message 1562631575961600000 was sent at 2026-10-22T01:00:00Z, before the pr event of https://github.com/owner/proj/pull/5 at 2026-10-22T02:00:00Z, so it is not Daniel's word on this PR"
  [[ $stderr != *"plan-time"* ]]

  event T14 merge-approved '{url: "https://github.com/owner/proj/pull/5", discord_message: "1562661774950400000"}'
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" head
}

@test "a withdrawn plan-time word is refused, naming the withdrawal" {
  plan_word
  withdrawn
  refused "no merge-approved event for https://github.com/owner/proj/pull/5: Daniel's word is not recorded" \
    "Daniel's plan-time word on proj, Discord message 1562661774950400000, was withdrawn at 2026-10-22T02:00:00Z in Discord message 1562676874444800000"
  [[ $stderr != *"$(ask_per_head)"* ]]
  assert_equal "$(stub_calls curl)" ""
}

@test "a plan-time word granted again after a withdrawal merges" {
  plan_word
  withdrawn
  event T14 asked '{id: "plan-T14-again", text: "Approve the merge with the plan again?"}'
  # Message 1562691973939200000, sent at 05:00.
  jq '.id = "1562691973939200000"' "$discord/1563-1562661774950400000.json" >"$discord/1563-1562691973939200000.json"
  preapproved 1562691973939200000 plan-T14-again
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .discord_message] | join(" ")')" "plan 1562691973939200000"
}

@test "a project that does not opt in now is refused on the plan-time word" {
  plan_word
  sed -i '/^merge_with_plan = true$/d' "$TEAM_HOME/projects.toml"
  refused "proj does not opt in to plan-time merges now: its merge_with_plan in projects.toml is false" "$(ask_per_head)"
}

@test "the team's own project is refused on the plan-time word, by name, by path and by repo" {
  # By repo: proj's repo is the origin of the code checkout team-merge runs from.
  plan_word
  code_checkout
  git -C "$CODE_CHECKOUT" remote set-url origin git@github.com:Owner/Proj.git
  refused "proj is the team's own project, whose PRs merge only on Daniel's word per head" "$(ask_per_head)"
}

@test "the team's own project by name is refused on the plan-time word, whatever the registry says" {
  plan_word
  sed -i 's/^\[proj/[agent-team/' "$TEAM_HOME/projects.toml"
  jq -c 'if .project == "proj" then .project = "agent-team" else . end' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  registry_refused "agent-team.merge_with_plan: agent-team is the team's own project"
  sed -i '/^merge_with_plan = true$/d' "$TEAM_HOME/projects.toml"
  refused "agent-team is the team's own project, whose PRs merge only on Daniel's word per head" "$(ask_per_head)"
}

@test "the team's own project by path is refused on the plan-time word, whatever the registry says" {
  merging_the_code
  plan_word
  registry_refused "proj.merge_with_plan: its path is the code checkout team-project runs from"
  sed -i '/^merge_with_plan = true$/d' "$TEAM_HOME/projects.toml"
  refused "proj is the team's own project, whose PRs merge only on Daniel's word per head" "$(ask_per_head)"
}

@test "a PR from a branch that is not the task's is refused on the plan-time word" {
  plan_word
  pr_field '.headRefName = "feat/T15-other"'
  refused "PR #5 comes from feat/T15-other, not feat/T14-tooling, T14's branch for proj" "$(ask_per_head)"
}

@test "a PR from the branch a branch-renamed logged for the task merges on the plan-time word, and one from the old branch does not" {
  plan_word
  pr_field '.headRefName = "feat/T14-tooling-fresh"'
  refused "PR #5 comes from feat/T14-tooling-fresh, not feat/T14-tooling, T14's branch for proj" "$(ask_per_head)"
  event T14 branch-renamed '{project: "proj", branch: "feat/T14-tooling-fresh"}'
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .branch] | join(" ")')" "plan feat/T14-tooling-fresh"
}

@test "after a branch-renamed, a PR from the task's old branch is refused on the plan-time word" {
  plan_word
  event T14 branch-renamed '{project: "proj", branch: "feat/T14-tooling-fresh"}'
  refused "PR #5 comes from feat/T14-tooling, not feat/T14-tooling-fresh, T14's branch for proj" "$(ask_per_head)"
}

@test "the task's branch for a project added by team-open --add is its worktree-added event's" {
  plan_word
  jq -c 'if .event == "opened" then .project = "lib" | .branch = "feat/T14-lib" else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 worktree-added '{project: "proj", branch: "feat/T14-tooling", base: "dev", base_sha: "0123456", worktree: "/w/4"}'
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" plan
}

@test "a release-shaped PR, the base into another branch, is refused on the plan-time word" {
  plan_word
  pr_field '.baseRefName = "main" | .headRefName = "dev"'
  refused "PR #5 targets main, not proj's base dev" "PR #5 comes from dev, not feat/T14-tooling, T14's branch for proj" \
    "$(ask_per_head)"
}

@test "a plan-time word sent before the ask it answers, or answering no ask of the task, is refused without asking Discord" {
  plan_word
  # 1562631575961600000 is 01:00, an hour before the ask at 02:00.
  preapproved 1562631575961600000
  refused "Discord message 1562631575961600000 was sent at 2026-10-22T01:00:00Z, before the asked plan-T14 at 2026-10-22T02:00:00Z, so it is not Daniel's word on this PR" \
    "$(ask_per_head)"
  assert_equal "$(stub_calls curl)" ""

  preapproved 1562661774950400000 plan-T99
  refused "merge-preapproved answers the ask plan-T99, which T14 did not log before it" "$(ask_per_head)"
  assert_equal "$(stub_calls curl)" ""
}

@test "a plan-time word Discord cannot show, or by an author not in allowFrom, is refused" {
  plan_word
  rm "$discord/1563-1562661774950400000.json"
  refused "Discord message 1562661774950400000 cannot be fetched from the task's thread 1563 or #coordinator 1562486564871995482" \
    "$(ask_per_head)"
  approved_by 999
  refused "Discord message 1562661774950400000 is by daniel (999), who is not in allowFrom" "$(ask_per_head)"
}

@test "a PR with no review of its head is refused on the plan-time word" {
  plan_word
  jq -c 'select(.event != "review")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  passed 0fedcba9876543210
  refused "no review of the head ${head:0:7} is logged, so no reviewer has passed it" "$(ask_per_head)"
}

@test "a PR whose latest review of its head found something is refused on the plan-time word, and a later pass merges it" {
  plan_word
  event T14 review "{verdict: \"findings\", head: \"${head:0:8}\",
    findings: {blocking: 0, correctness: 1, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}, guarded: []}"
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, is findings, not pass" "$(ask_per_head)"
  passed "${head:0:7}"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" plan
}

@test "a refusal on the plan-time word lists every reason at once, the checks every merge gets among them" {
  plan_word
  review "$head" findings
  pr_field '.headRefName = "feat/T15-other"'
  checks '[{"name": "test", "bucket": "fail", "state": "FAILURE"},
    {"name": "agent-review", "bucket": "pending", "state": "IN_PROGRESS"}]'
  jq -n --arg head "$head" '[
    {sha: "1111111111111111111111111111111111111111",
     commit: {message: "feat: one\n\nCo-Authored-By: Claude <noreply@anthropic.com>"}},
    {sha: $head, commit: {message: "test: two"}}]' >"$gh_dir/commits.json"
  refused "PR #5 comes from feat/T15-other, not feat/T14-tooling, T14's branch for proj" \
    "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, is findings, not pass" \
    "required check lint is missing on the head" "required check test has not passed on the head" \
    "checks failing on the head: test" "checks pending on the head: agent-review" \
    "agent-review is in_progress on the head, not success" \
    "commit 1111111 (feat: one) carries an attribution line: Co-Authored-By: Claude <noreply@anthropic.com>"
  assert_equal "$(tail -n 1 <<<"$stderr")" "  $(ask_per_head)"
}

@test "a per-head merge reads no file list" {
  run_bin -0 team-merge T14
  [[ -z $(stub_calls gh | jq -c 'select(.[1] | test("/files$"))') ]]
}

@test "the plan-time word reads the PR's files across pages, each rename's old path too" {
  plan_word
  files src/a.py 'old/b.py=>src/b.py'
  jq -c '.[:1], .[1:]' "$gh_dir/files.json" >"$gh_dir/pages" && mv "$gh_dir/pages" "$gh_dir/files.json"
  refused "old/b.py, renamed to src/b.py, is outside the scope of Daniel's plan-time word: src/" "$(ask_per_head)"
  [[ $stderr != *"src/a.py"* ]]

  files src/a.py 'src/c.py=>src/b.py'
  jq -c '.[:1], .[1:]' "$gh_dir/files.json" >"$gh_dir/pages" && mv "$gh_dir/pages" "$gh_dir/files.json"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" plan
}

@test "a file list shorter than the PR's changed-file count is refused as one not read in full" {
  plan_word
  pr_field '.changedFiles = 3'
  refused "GitHub's list of PR #5's files holds 2 files, not its 3 changed files, so not every file could be checked" \
    "$(ask_per_head)"
  pr_field 'del(.changedFiles)'
  refused "GitHub's list of PR #5's files holds 2 files, not its unknown number of changed files, so not every file could be checked" \
    "$(ask_per_head)"
}

@test "each changed file outside the scope is named; a directory entry covers what is under it and a file entry that file only" {
  plan_word
  preapproved 1562661774950400000 plan-T14 '["src/a/", "README.md"]'
  files src/a/b.py src/a/c/d.py src/ab.py README.md docs/README.md README.md.bak
  refused "src/ab.py is outside the scope of Daniel's plan-time word: src/a/, README.md" \
    "docs/README.md is outside the scope of Daniel's plan-time word: src/a/, README.md" \
    "README.md.bak is outside the scope of Daniel's plan-time word: src/a/, README.md" "$(ask_per_head)"
  [[ $stderr != *"src/a/b.py"* && $stderr != *"src/a/c/d.py"* && $stderr != *"  README.md is"* ]]
}

@test "each changed file a guarded pattern matches is named with its area, Conventioner's among them, and plain source and tests are not" {
  plan_word
  local guarded=(
    .github/workflows/test.yml:ci .circleci/config.yml:ci .gitlab-ci.yml:ci .no-mistakes.yaml:ci
    .pre-commit-config.yaml:ci .githooks/pre-commit:ci release-please-config.json:ci
    .release-please-manifest.json:ci
    front-end/package-lock.json:dependencies front-end/package.json:dependencies
    back-end/requirements.txt:dependencies back-end/requirements-dev.in:dependencies
    constraints.txt:dependencies npm-shrinkwrap.json:dependencies yarn.lock:dependencies
    pnpm-lock.yaml:dependencies bun.lockb:dependencies Pipfile:dependencies Pipfile.lock:dependencies
    pyproject.toml:dependencies poetry.lock:dependencies uv.lock:dependencies setup.py:dependencies
    setup.cfg:dependencies go.mod:dependencies go.sum:dependencies Cargo.toml:dependencies
    Cargo.lock:dependencies Gemfile:dependencies Gemfile.lock:dependencies composer.json:dependencies
    composer.lock:dependencies .nvmrc:dependencies .node-version:dependencies
    back-end/.python-version:dependencies .tool-versions:dependencies back-end/Dockerfile:dependencies
    web.dockerfile:dependencies docker-compose.prod.yml:dependencies compose.yml:dependencies
    .dockerignore:dependencies
    "back-end/migrations/migrate_roles.py:migrations, permissions" db/migration/0001.py:migrations
    "scripts/migrate_users.py:ci, migrations" "db/add_roles_migration.py:migrations, permissions" schema/init.sql:migrations
    .vscode/launch.json:settings .mcp.json:settings CLAUDE.md:settings front-end/AGENTS.md:settings
    front-end/.env.example:settings .env:settings back-end/settings.py:settings treehouse.toml:settings
    back-end/api/permissions.py:permissions src/rbac/roles.py:permissions src/ACL.py:permissions
    docs/CODEOWNERS:permissions
    back-end/utils/secret_key.py:secrets config/credentials.json:secrets certs/server.pem:secrets
    "deploy/id.key:settings, secrets" certs/client.p12:secrets certs/client.pfx:secrets
    ".claude/settings.json:settings" ".github/CODEOWNERS:ci, permissions"
    # What the workflows, hooks and gate run, deploy and agent settings, a container's entrypoint,
    # the real-data guard and the database's shape outside migrations/, and authentication and
    # session handling by the words in their paths.
    scripts/nm-test.sh:ci scripts/lock-backend-requirements.sh:ci scripts/knowledge_graph.py:ci
    front-end/scripts/no-eval.ts:ci front-end/scripts/bundle-budget.ts:ci scripts/treehouse-setup.sh:ci
    .husky/pre-push:ci lefthook.yml:ci Makefile:ci back-end/justfile:ci
    scripts/real_data_check.py:ci tools/real_data_terms.txt:ci
    back-end/docker-entrypoint.sh:dependencies docker-entrypoint-initdb.d/seed.js:dependencies
    back-end/reset_database.py:migrations back-end/init_database.py:migrations back-end/mongo-init.js:migrations
    back-end/lookup_indexes.py:migrations back-end/db_config.py:migrations
    front-end/vercel.json:settings back-end/vercel.json:settings netlify.toml:settings fly.toml:settings
    Procfile:settings render.yaml:settings .agents/plugins/marketplace.json:settings .cursor/rules.md:settings
    back-end/api/applicant_auth.py:permissions back-end/utils/cors.py:permissions
    back-end/utils/security_headers.py:permissions back-end/utils/request_origin.py:permissions
    back-end/utils/proxy.py:permissions back-end/utils/captcha.py:permissions back-end/sign_in_limits.py:permissions
    back-end/guards.py:permissions src/csrf.ts:permissions src/oauth/callback.ts:permissions
    src/login-form.tsx:permissions src/authz.py:permissions src/authentication/views.py:permissions
    back-end/utils/tokens.py:secrets back-end/utils/application_token.py:secrets
    back-end/utils/session_storage.py:secrets src/jwt.ts:secrets src/password_reset.py:secrets
    back-end/api/floorplans_access.py:permissions back-end/tests/test_markets_roles.py:permissions
    back-end/utils/env_file.py:settings front-end/env.d.ts:settings back-end/utils/deployment.py:settings
    front-end/eslint.config.ts:ci front-end/vite.config.ts:ci front-end/playwright.config.ts:ci
    back-end/pytest.ini:ci .gitattributes:ci front-end/tsconfig.app.json:ci
    # A camelCase or PascalCase name counts its humps as words.
    front-end/src/views/LoginView.vue:permissions front-end/src/utils/signedIn.ts:permissions
    front-end/src/views/EmailVerificationView.vue:permissions front-end/src/utils/permissionTable.ts:permissions
    front-end/src/utils/applicantSessionExpiry.ts:secrets front-end/src/views/PasswordResetView.vue:secrets
    "src/CSRFToken.ts:permissions, secrets"
    # The permissions words' verb forms, and a hump ending in a digit.
    back-end/api/authenticate.py:permissions src/authorize.ts:permissions
    front-end/src/utils/isAuthenticated.ts:permissions back-end/api/authorizedRoutes.py:permissions
    front-end/src/views/OAuth2Callback.ts:permissions src/Login2fa.ts:permissions
  )
  local plain=(back-end/api/views.py front-end/src/App.test.tsx src/oracle.py src/environment.py src/keyboard.py
    src/settled.py src/author.py src/tokenizer.py docs/scripts.md src/guardian.ts src/descriptions.py
    src/indexes_doc/readme.md src/assigning.py front-end/src/utils/accessibleNames.ts src/AuthorList.vue
    front-end/src/utils/marketGuide.ts src/environmentPicker.ts)
  local entry paths=() reasons=()
  for entry in "${guarded[@]}"; do
    paths+=("${entry%%:*}")
    reasons+=("${entry%%:*} is a guarded path (${entry#*:}): a change there comes back to Daniel")
  done
  files "${paths[@]}" "${plain[@]}"
  refused "${reasons[@]}" "$(ask_per_head)"
  for entry in "${plain[@]}"; do [[ $stderr != *"$entry is a guarded path"* ]]; done
  assert_equal "$(grep -c 'is a guarded path' <<<"$stderr")" "${#guarded[@]}"
}

@test "the guarded patterns' areas are exactly the ledger's guarded areas" {
  assert_equal "$(grep -v -e '^#' -e '^$' "$REPO_ROOT/bin/lib/guarded" | cut -d ' ' -f 1 | uniq | jq -Rsc 'split("\n")[:-1]')" \
    "$(jq -L "$REPO_ROOT/bin/lib" -nc 'include "ledger"; guarded_areas')"
}

@test "a latest review of the head that logged no guarded areas, or named some, is refused, naming them" {
  plan_word
  event T14 review "{verdict: \"pass\", head: \"$head\",
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}}"
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, logged no guarded areas, so no reviewer has said the change touches none" \
    "$(ask_per_head)"
  event T14 review "{verdict: \"pass\", head: \"${head:0:7}\",
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}, guarded: [\"settings\", \"secrets\"]}"
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, found the change touching guarded areas: settings, secrets" \
    "$(ask_per_head)"
  passed
  run_bin -0 team-merge T14
}

@test "a review of the task with a security or real-data finding, even fixed later, or with no finding counts, is refused, naming its head and time" {
  plan_word
  ledger_line '{ts: "2026-10-21T10:00:00Z", task: "T14", event: "review", verdict: "findings", head: "0fedcba98",
    findings: {blocking: 1, correctness: 0, security: 1, "real-data": 0, "note-change": 0, "note-before": 0}, guarded: []}'
  ledger_line '{ts: "2026-10-21T11:00:00Z", task: "T14", event: "review", verdict: "findings", head: "1234567ab",
    findings: {blocking: 0, correctness: 0, security: 2, "real-data": 3, "note-change": 1, "note-before": 0}, guarded: []}'
  ledger_line '{ts: "2026-10-21T12:00:00Z", task: "T14", event: "review", verdict: "findings", head: "7654321cd"}'
  ledger_line '{ts: "2026-10-21T13:00:00Z", task: "T15", event: "review", verdict: "findings", head: "abcdef012"}'
  passed
  refused "the review of the head 0fedcba, at 2026-10-21T10:00:00Z, counted 1 security finding: such a finding on the task, even fixed, comes back to Daniel" \
    "the review of the head 1234567, at 2026-10-21T11:00:00Z, counted 2 security findings and 3 real-data findings: such a finding on the task, even fixed, comes back to Daniel" \
    "the review of the head 7654321, at 2026-10-21T12:00:00Z, logged no finding counts, so whether it found a security or real-data issue is not known" \
    "$(ask_per_head)"
  [[ $stderr != *abcdef0* ]]
}

@test "a changed path with a line break, which grep would read as two, is refused" {
  plan_word
  jq -n '[{filename: "src/a.py\n.github/workflows/test.yml", status: "added"}]' >"$gh_dir/files.json"
  pr_field '.changedFiles = 1'
  refused '"src/a.py\n.github/workflows/test.yml" holds a line break, so no guarded pattern can be matched against it' \
    "$(ask_per_head)"
}

@test "a plan-time merge posts to the task's thread and #coordinator once merged is logged, before the inbox refresh" {
  plan_word
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(jq -r .merge <<<"$output")" "$MERGE_SHA"
  assert_equal "$(posts)" "1563 $(merge_post 1563 "\`git revert $MERGE_SHA\`" | jq -Rsc 'rtrimstr("\n")')
1562486564871995482 $(merge_post 1563 "\`git revert $MERGE_SHA\`" | jq -Rsc 'rtrimstr("\n")')"
  assert_equal "$(jq -r .merged "$discord/posts" | sort -u)" 1
  [[ $stderr != *post* ]]
  # The guild for the link is read from #coordinator's channel, then the Waiting on you message is posted.
  assert_equal "$(stub_calls curl | jq -r '.[-1] | capture("v10/(?<p>.*)").p' | grep -v '/messages/[0-9]*$')" \
    "channels/1562486564871995482
channels/1563/messages
channels/1562486564871995482/messages
channels/1562486564871995482
channels/1562486564871995482/messages"
  assert_equal "$(inbox_calls)" "GET channels/1562486564871995482
GET channels/1562486564871995482
POST channels/1562486564871995482/messages"
}

@test "the post's revert is the project's merge method's: git revert -m 1 for a merge, the rebased commits' range for a rebase" {
  plan_word
  sed -i 's/^merge_method = "squash"$/merge_method = "merge"/' "$TEAM_HOME/projects.toml"
  run_bin -0 team-merge T14
  assert_equal "$(jq -r .content "$discord/posts" | tail -n 1)" \
    "To revert: the Revert button on the PR's page opens a revert PR; or, on dev, \`git revert -m 1 $MERGE_SHA\`."

  merge_again
  sed -i 's/^merge_method = "merge"$/merge_method = "rebase"/' "$TEAM_HOME/projects.toml"
  # The PR's two commits and a merge of the base, which a rebase leaves out.
  jq -n --arg head "$head" '[
    {sha: "1111111111111111111111111111111111111111", commit: {message: "feat: one"}, parents: [{sha: "0123456"}]},
    {sha: "2222222222222222222222222222222222222222", commit: {message: "Merge dev"}, parents: [{sha: "1111111"}, {sha: "3333333"}]},
    {sha: $head, commit: {message: "test: two"}, parents: [{sha: "2222222"}]}]' >"$gh_dir/commits.json"
  run_bin -0 team-merge T14
  assert_equal "$(jq -r .content "$discord/posts" | tail -n 1)" \
    "To revert: the Revert button on the PR's page opens a revert PR; or, on dev, \`git revert $MERGE_SHA~2..$MERGE_SHA\`, the 2 rebased commits."
}

@test "a plan-time merge with no thread posts to #coordinator alone, saying so" {
  plan_word
  jq -c 'select(.event != "thread")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  approved_by 757 1562486564871995482
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(posts)" "1562486564871995482 $(merge_post 1562486564871995482 "\`git revert $MERGE_SHA\`" | jq -Rsc 'rtrimstr("\n")')"
  assert_contains "$stderr" "team-merge: T14 has no Discord thread, so Daniel hears of the merge in #coordinator alone"
}

@test "a plan-time merge's post links Daniel's message with the guild the inbox kept, and names it when no guild is known" {
  plan_word
  inbox_kept
  run_bin -0 team-merge T14
  assert_equal "$(inbox_calls)" "PATCH channels/1562486564871995482/messages/1569000000000000000"
  assert_equal "$(jq -r .content "$discord/posts" | head -n 1)" "$(merge_post 1563 x | head -n 1)"

  # A guild Discord does not name leaves the message named, not linked, saying why.
  merge_again
  rm "$HOME/.local/state/agent-team/inbox.json"
  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(jq -r .content "$discord/posts" | head -n 1)" \
    "T14 The tooling: merged https://github.com/owner/proj/pull/5 on your plan-time word, Discord message 1562661774950400000 in the task's thread 1563, from daniel (757)"
  assert_contains "$stderr" "team-merge: the posts name Daniel's message without a link: Discord named no guild for #coordinator: curl: (22) The requested URL returned error: 500"
}

@test "a post that fails leaves the merge logged and the exit 0, and prints which post failed and its text" {
  plan_word
  echo 1563 >"$discord/refuse"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" plan
  assert_equal "$(jq -r .channel "$discord/posts")" 1562486564871995482
  assert_contains "$stderr" "team-merge: PR #5 is merged, but its post to the task's thread 1563 failed (team-post: Discord refused the post: curl: (22) The requested URL returned error: 500; nothing was posted); post this text with team-post T14 --file <its file>:
$(merge_post 1563 "\`git revert $MERGE_SHA\`")"
  [[ $stderr != *"post to #coordinator"* ]]
}

@test "a fenced machine's posts fail, each said with its text, and the merge stands" {
  plan_word
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" plan
  assert_equal "$(posts)" ""
  assert_contains "$stderr" "team-merge: PR #5 is merged, but its post to the task's thread 1563 failed (team-post: "
  assert_contains "$stderr" "team-merge: PR #5 is merged, but its post to #coordinator 1562486564871995482 failed (team-post: "
  assert_contains "$stderr" "is fenced since 2026-10-22T14:00:00Z"
  assert_contains "$stderr" "post this text with team-post --coordinator --file <its file>:
$(merge_post 1563 "\`git revert $MERGE_SHA\`")"
}
