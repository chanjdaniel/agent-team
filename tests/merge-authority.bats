#!/usr/bin/env bats
# shellcheck disable=SC2154 # head, approved and discord are helpers/merge.bash's
# The one table of merge_authority's readers: each case is one ledger and registry of T14's PR #5
# of proj (helpers/merge.bash: green on GitHub, its plan's files real), whose reviewer's pass
# team-next takes, and then team-sweep, team-state --json and team-merge read it, with GitHub and
# Discord stubbed. Every reader must say the same of the default word: whether it holds on the
# ledger, with the same ledger reasons, which team-merge names when it refuses; team-merge then
# merges or refuses as the case says, on what the ledger cannot show (Discord, git, the plan's
# files) as well.

load helpers/common
load helpers/inbox
load helpers/merge

counts="findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0"

# T14's builder and reviewer launches in its worktree, so team-next takes the reviewer's verdict.
launches() {
  local wt=$BATS_TEST_TMPDIR/wt
  event T14 launch "{role: \"builder\", session: \"b0000001\", worktree: \"$wt\", toolkits: [], project: \"proj\",
    branch: \"feat/T14-tooling\"}"
  event T14 launch "{role: \"reviewer\", session: \"r0000001\", worktree: \"$wt\", toolkits: [], project: \"proj\",
    branch: \"feat/T14-tooling\"}"
}

# Daniel's message <message> in channel <channel> (the task's thread by default), from user 757:
# discord_has <message> [<channel>]
discord_has() {
  jq -n --arg id "$1" --arg channel "${2:-1563}" '{id: $id, channel_id: $channel, content: "yes", author: {id: "757", username: "daniel"}}' \
    >"$discord/${2:-1563}-$1.json"
}

# said <kind> <task> <scope> <message> [<channel>]: a merge-default-withdrawn or
# merge-default-restored logged under <task>, in the task's thread by default.
said() {
  event "$2" "$1" "{scope: \"$3\", discord_message: \"$4\", discord_channel: \"${5:-1563}\"}"
}

# Feed the case to every reader and check what each says: readers <holds> <ledger reasons as a
# JSON list> <merge>, <merge> being "default" or "head" (team-merge merges on that word) or
# "refused" (it refuses, naming each ledger reason, then any further reason given after it):
# readers <holds> <reasons> <merge> [<team-merge's reason>...]
readers() {
  local holds=$1 reasons=$2 merge=$3
  stub_reply claude '[]'

  # team-next takes the reviewer's pass and says what to do with it.
  run_bin -0 --separate-stderr team-next T14 -- "T14 DONE pass $head $counts before=none guarded=none"
  if [[ $holds == true ]]; then
    assert_equal "${lines[-1]}" \
      "merge on the default word: run team-merge T14 for https://github.com/owner/proj/pull/5 at $head, agent-review success, checks green"
  else
    assert_equal "${lines[-1]#merge ask: }" "https://github.com/owner/proj/pull/5 at $head, agent-review success, checks green"
  fi

  # team-sweep sends the coordinator to the merge only on a default word that holds.
  if [[ $holds == true ]]; then
    run_bin -1 team-sweep
    assert_equal "$output" "T14 merge-due: awaiting the merge of https://github.com/owner/proj/pull/5 on the default word, the approved plan, with no ask open; next: run team-merge T14; on a refusal, ask Daniel for the per-head word with team-ask"
  else
    run_bin -0 team-sweep
    assert_equal "$output" ""
  fi

  # team-state says the same, with the same ledger reasons.
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.merge_authority.words[] | select(.word == "default") | [.holds, .reasons]' <<<"$output")" \
    "$(jq -c --argjson holds "$holds" '[$holds, .]' <<<"$reasons")"

  # team-merge merges on the word the case names, or refuses naming each reason.
  : >"$STUB_CALLS/gh.log"
  if [[ $merge == refused ]]; then
    local all=()
    mapfile -t all < <(jq -r '.[]' <<<"$reasons")
    refused "${all[@]}" "${@:4}"
  else
    run_bin -0 --separate-stderr team-merge T14
    assert_equal "$(merged_events | jq -r .approval)" "$merge"
  fi
}

@test "a coordinator's approval on a product project: the default word holds, and merges" {
  default_word coordinator
  launches
  readers true '[]' default
}

@test "Daniel's approval on a product project, read back from their message: the default word holds, and merges" {
  default_word Daniel
  event T14 answered '{id: "plan-T14", answer: "yes", discord_message: "1562661774950400000"}'
  launches
  readers true '[]' default
  assert_equal "$(merged_events | jq -r .discord_message)" 1562661774950400000
}

@test "a legacy approval, logged before T276 with no plan, is the coordinator's and holds for a product project" {
  default_word coordinator
  jq -c 'if .event == "plan-approved" then {ts, task, event, by: "Daniel"} else . end' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  launches
  readers true '[]' default
}

@test "a withdrawn approval: no reader says the default word holds, and team-next takes no verdict" {
  default_word coordinator
  launches
  event T14 plan-approval-withdrawn '{discord_message: "1562661774950400001"}'
  local reasons='["T14'"'"'s plan approval was withdrawn at 2026-10-22T02:00:00Z in Discord message 1562661774950400001: approve the plan again"]'
  stub_reply claude '[]'
  run_bin -1 --separate-stderr team-next T14 -- "T14 DONE pass $head $counts before=none guarded=none"
  assert_contains "$stderr" "withdrawn"
  run_bin -0 team-sweep
  assert_equal "$output" ""
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -c '.pr.merge_authority.words[1] | [.holds, .reasons]' <<<"$output")" "$(jq -c '[false, .]' <<<"$reasons")"
  refused "$(jq -r '.[0]' <<<"$reasons")" "$(ask_per_head)"
}

@test "the queued note's case: the team's own project with the coordinator's approval is never due, and refused" {
  default_word coordinator
  as_project agent-team
  launches
  readers false '["the team'"'"'s own project merges unattended only behind the reviewer App'"'"'s check, which is not set up"]' refused \
    "$(ask_per_head)"
}

@test "Daniel's approval on the team's own project, with the reviewer App off: the default word does not hold" {
  default_word Daniel
  event T14 answered '{id: "plan-T14", answer: "yes", discord_message: "1562661774950400000"}'
  as_project agent-team
  launches
  readers false '["the team'"'"'s own project merges unattended only behind the reviewer App'"'"'s check, which is not set up"]' refused
}

@test "a withdrawal for the task, for its project or for all holds the default word back, read by no reader" {
  local scope reasons
  for scope in task proj all; do
    : >"$TEAM_HOME/ledger.jsonl"
    rm -f "$STUB_CALLS"/*.log
    open_task
    default_word coordinator
    launches
    if [[ $scope == task ]]; then said merge-default-withdrawn T14 task 1562661774950400002; else said merge-default-withdrawn T9 "$scope" 1562661774950400002; fi
    case $scope in
      task) reasons=T14 ;;
      proj) reasons="project proj" ;;
      all) reasons="every project" ;;
    esac
    reasons=$(jq -cn --arg w "$reasons" '["the default word was withdrawn for \($w) at 2026-10-22T02:00:00Z in Discord message 1562661774950400002, and not given back since"]')
    readers false "$reasons" refused
    assert_equal "$(reads)" ""
  done
}

@test "T278's C3: a giving back of all after a project's withdrawal gives the default word back, read back from Discord" {
  default_word coordinator
  launches
  said merge-default-withdrawn T9 proj 1562661774950400002
  said merge-default-restored T14 all 1562661774950400003
  discord_has 1562661774950400003
  readers true '[]' default
}

@test "T278's C6: a per-head word on an old head with a commit of its own since falls to the default word, which every reader names" {
  moved_head own
  both_words 1562661774950400000 "$approved"
  # The builder's PR message after its commit logs the PR at the head it moved to.
  event T14 pr "{url: \"https://github.com/owner/proj/pull/5\", head: \"$head\", project: \"proj\"}"
  launches
  readers true '[]' default
}

@test "a plan changed since its approval holds on the ledger for every reader, and team-merge refuses it, to approve it again" {
  default_word coordinator
  launches
  echo "# T14 spec, edited" >"$BATS_TEST_TMPDIR/wt/.scratch/task/spec.md"
  readers true '[]' refused \
    "the plan changed since its approval at 2026-10-22T02:00:00Z (.scratch/task/spec.md): approve it again" "$(ask_per_head)"
}
