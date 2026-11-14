#!/usr/bin/env bats
# shellcheck disable=SC2154 # head, approved, own, gh_dir and discord are helpers/merge.bash's
# team-merge on the default word, the task's approved plan: a ready PR merges with no other word,
# and one the word does not hold for comes back to Daniel as the per-head ask.

load helpers/common
load helpers/inbox
load helpers/merge

COORDINATOR=1562486564871995482

# The plan's spec.md in the task directory.
SPEC() {
  echo "$BATS_TEST_TMPDIR/wt/.scratch/task/spec.md"
}

# The line a post on Daniel's plan names it by, linked: daniel_plan [<channel>]
daniel_plan() {
  echo "you approved, https://discord.com/channels/$INBOX_GUILD/${1:-1563}/1562661774950400000"
}

# The PR is of the team's own project by repo: proj's repo is the origin of the code checkout.
own_by_repo() {
  code_checkout
  git -C "${CODE_CHECKOUT:?}" remote set-url origin git@github.com:Owner/Proj.git
}

# The reason the default word gives on a PR of the team's own project.
OWN_REASON="the team's own project merges unattended only behind the reviewer App's check, which is not set up"

@test "a ready PR on a plan the coordinator approved merges on the default word with no other word" {
  default_word
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "merge"])')" \
    "[\"pr\",\"merge\",\"5\",\"--repo\",\"owner/proj\",\"--squash\",\"--match-head-commit\",\"$head\"]"
  assert_equal "$(merged_events)" "$(jq -cn --arg m "$MERGE_SHA" --arg h "$head" --arg by "the plan $COORDINATOR_PLAN" '{task: "T14",
    event: "merged", pr: 5, merge: $m, head: $h, by: $by, project: "proj", branch: "feat/T14-tooling",
    url: "https://github.com/owner/proj/pull/5", approval: "default"}')"
  # No message of Daniel's is read for a plan the coordinator approved.
  assert_equal "$(reads)" ""
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "a ready PR on a plan Daniel approved merges on the default word, their message read back and linked" {
  default_word Daniel
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events)" "$(jq -cn --arg m "$MERGE_SHA" --arg h "$head" '{task: "T14", event: "merged",
    pr: 5, merge: $m, head: $h,
    by: "Discord message 1562661774950400000 in the task'"'"'s thread 1563, from daniel (757)",
    project: "proj", branch: "feat/T14-tooling", discord_message: "1562661774950400000", discord_channel: "1563",
    url: "https://github.com/owner/proj/pull/5", approval: "default"}')"
  assert_equal "$(reads | jq -r '.[-1]')" "https://discord.com/api/v10/channels/1563/messages/1562661774950400000"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "Daniel's approval in #coordinator counts when it is not in the task's thread" {
  default_word Daniel
  approved_by 757 "$COORDINATOR"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .by] | join(" ")')" \
    "default Discord message 1562661774950400000 in #coordinator $COORDINATOR, from daniel (757)"
}

@test "an approval team-log records hashes the plan's files as team-merge does, so the PR merges on it" {
  default_word
  jq -c 'select(.event != "plan-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log T14 plan-approved by=coordinator
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

@test "a legacy approval merges a product project's PR with no hash or scope check, as the coordinator's" {
  default_word
  jq -c 'select(.event != "plan-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 plan-approved '{by: "Daniel"}'
  echo "# changed" >"$(SPEC)"
  files src/tooling.py docs/tooling.md
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .by] | join(" ")')" "default the plan $COORDINATOR_PLAN"
  assert_equal "$(reads)" ""
}

@test "a plan changed since its approval is refused, naming each file that differs, is new or is gone, until approved again" {
  default_word
  echo "# T14 spec, edited" >"$(SPEC)"
  refused "the plan changed since its approval at 2026-10-22T02:00:00Z (.scratch/task/spec.md): approve it again" "$(ask_per_head)"
  rm "$BATS_TEST_TMPDIR/wt/.scratch/task/scope.txt"
  refused "the plan changed since its approval at 2026-10-22T02:00:00Z (.scratch/task/spec.md, .scratch/task/scope.txt): approve it again" \
    "$(ask_per_head)"
  # A file the approval did not hold is named too.
  scope
  echo src/ >"$BATS_TEST_TMPDIR/wt/.scratch/task/scope.txt"
  refused "the plan changed since its approval at 2026-10-22T02:00:00Z (.scratch/task/scope.txt): approve it again" "$(ask_per_head)"
  # Approved again over the plan as it is now, it merges.
  scope src/
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

@test "a plan whose worktree is not on this machine is refused as changed, since its spec and scope cannot be read" {
  default_word
  mv "$BATS_TEST_TMPDIR/wt" "$BATS_TEST_TMPDIR/elsewhere"
  refused "the plan changed since its approval at 2026-10-22T02:00:00Z (.scratch/task/spec.md, .scratch/task/scope.txt): approve it again" \
    "$(ask_per_head)"
}

@test "a withdrawn plan approval is refused, naming the withdrawal, without asking Discord, and an approval again merges" {
  default_word Daniel
  event T14 plan-approval-withdrawn '{discord_message: "1562676874444800000"}'
  refused "T14's plan approval was withdrawn at 2026-10-22T02:00:00Z in Discord message 1562676874444800000: approve the plan again" \
    "$(ask_per_head)"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
  assert_equal "$(reads)" ""
  scope src/
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

# A merge-default-<kind> logged under <task> for <scope> in Discord message <message>, in <channel>
# (#coordinator's by default): default_said <kind> <task> <scope> <message> [<channel>]
default_said() {
  event "$2" "merge-default-$1" "{scope: \"$3\", discord_message: \"$4\", discord_channel: \"${5:-$COORDINATOR}\"}"
}

# Discord's message <message> in <channel> (#coordinator's by default), by user <author> (757,
# Daniel, by default): discord_has <message> [<channel>] [<author>]
discord_has() {
  jq -n --arg m "$1" --arg c "${2:-$COORDINATOR}" --arg a "${3:-757}" \
    '{id: $m, channel_id: $c, content: "give it back", author: {id: $a, username: "daniel"}}' >"$discord/${2:-$COORDINATOR}-$1.json"
}

@test "the default word withdrawn for the task, its project or every project is refused, naming the withdrawal, its message never read" {
  default_word
  local scope named before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  for scope in task proj all; do
    case $scope in task) named=T14 ;; proj) named="project proj" ;; all) named="every project" ;; esac
    printf '%s\n' "$before" >"$TEAM_HOME/ledger.jsonl"
    default_said withdrawn "$(if [[ $scope == task ]]; then echo T14; else echo T9; fi)" $scope 1562676874444800000
    refused "the default word was withdrawn for $named at 2026-10-22T02:00:00Z in Discord message 1562676874444800000, and not given back since" \
      "$(ask_per_head)"
    assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
    assert_equal "$(reads)" ""
  done
  # Another task's withdrawal, and another project's, do not touch it.
  printf '%s\n' "$before" >"$TEAM_HOME/ledger.jsonl"
  default_said withdrawn T9 task 1562676874444800000
  default_said withdrawn T9 conv 1562676874444800001
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

@test "a giving back read back from Discord in #coordinator or its task's thread gives the default word back" {
  default_word
  default_said withdrawn T9 all 1562676874444800000
  default_said restored T9 all 1562692000000000000
  discord_has 1562692000000000000
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .by] | join(" ")')" "default the plan $COORDINATOR_PLAN"
  # The giving back's message is read, the withdrawal's never.
  assert_equal "$(reads | jq -r '.[-1]')" "https://discord.com/api/v10/channels/$COORDINATOR/messages/1562692000000000000"

  # In the thread of the task it was logged under, read there.
  merge_again
  jq -c 'select(.event != "merge-default-restored")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T9 thread '{discord_thread: "1999"}'
  default_said restored T9 all 1562692000000000000 1999
  discord_has 1562692000000000000 1999
  rm -f "$STUB_CALLS/curl.log"
  run_bin -0 team-merge T14
  assert_equal "$(reads | jq -r '.[-1]')" "https://discord.com/api/v10/channels/1999/messages/1562692000000000000"
}

@test "a giving back Discord cannot show, by an author not in allowFrom, or in a channel neither #coordinator nor its task's thread holds nothing" {
  default_word
  default_said withdrawn T9 proj 1562676874444800000
  default_said restored T9 all 1562692000000000000
  local given="the default word was given back for every project at 2026-10-22T02:00:00Z in Discord message 1562692000000000000"
  refused "$given, which does not read back: Discord message 1562692000000000000 cannot be fetched from #coordinator $COORDINATOR: curl: (22) The requested URL returned error: 404" \
    "$(ask_per_head)"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
  discord_has 1562692000000000000 "$COORDINATOR" 999
  refused "$given, which does not read back: Discord message 1562692000000000000 is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json"
  # T14's thread is not T9's, so a giving back logged under T9 is never read there.
  jq -c 'select(.event != "merge-default-restored")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  default_said restored T9 all 1562692000000000000 1563
  discord_has 1562692000000000000 1563
  rm -f "$STUB_CALLS/curl.log"
  refused "$given, in channel 1563, which is neither #coordinator nor T9's thread"
  assert_equal "$(reads)" ""
}

@test "a giving back of all after a project's withdrawal gives that project back (T278 C3); one of another project leaves it withdrawn" {
  default_word
  default_said withdrawn T9 proj 1562676874444800000
  default_said restored T10 all 1562692000000000000
  discord_has 1562692000000000000
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default

  merge_again
  default_said withdrawn T9 all 1562676874444800002
  default_said restored T9 conv 1562692000000000001
  discord_has 1562692000000000001
  refused "the default word was withdrawn for every project at 2026-10-22T02:00:00Z in Discord message 1562676874444800002, and not given back since"
  default_said restored T14 task 1562692000000000003
  discord_has 1562692000000000003
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

@test "a task with only the retired plan-time and standing words, and no approved plan, merges nothing unattended" {
  jq -c 'select(.event != "merge-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  passed
  event T14 asked '{id: "plan-T14", text: "Approve the plan, and the merge with it?"}'
  event T14 merge-preapproved '{project: "proj", ask: "plan-T14", discord_message: "1562661774950400000", scope: ["src/"]}'
  event T14 merge-standing "{project: \"all\", discord_message: \"1562661774950400000\", discord_channel: \"$COORDINATOR\"}"
  approved_by 757 "$COORDINATOR"
  refused "no merge-approved event for https://github.com/owner/proj/pull/5: Daniel's word is not recorded" \
    "T14 has no approved plan: no plan-approved is logged" "$(ask_per_head)"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 3
  assert_equal "$(reads)" ""
}

@test "an approval of Daniel's sent before the ask it answers, or answering no ask of the task, is refused without asking Discord" {
  default_word Daniel
  # 1562631575961600000 is 01:00, an hour before the ask at 02:00.
  plan_approved Daniel 1562631575961600000
  refused "Discord message 1562631575961600000 was sent at 2026-10-22T01:00:00Z, before the asked plan-T14 at 2026-10-22T02:00:00Z, so it is not Daniel's word on this PR" \
    "$(ask_per_head)"
  assert_equal "$(reads)" ""

  jq -c 'select(.event != "asked")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  plan_approved Daniel
  refused "plan-approved answers the ask plan-T14, which T14 did not log before it" "$(ask_per_head)"
  assert_equal "$(reads)" ""
}

@test "an approval of Daniel's that Discord cannot show, or by an author not in allowFrom, is refused" {
  default_word Daniel
  rm "$discord/1563-1562661774950400000.json"
  refused "Discord message 1562661774950400000 cannot be fetched from the task's thread 1563 or #coordinator $COORDINATOR" \
    "$(ask_per_head)"
  approved_by 999
  refused "Discord message 1562661774950400000 is by daniel (999), who is not in allowFrom" "$(ask_per_head)"
}

@test "the team's own project is refused on the default word by repo, by name and by path, with any approval, reading nothing more" {
  local by
  own_by_repo
  for by in coordinator Daniel legacy; do
    default_word "${by/legacy/coordinator}"
    if [[ $by == legacy ]]; then event T14 plan-approved '{by: "Daniel"}'; fi
    files src/tooling.py .github/workflows/test.yml
    echo "# changed" >"$(SPEC)"
    refused "$OWN_REASON" "$(ask_per_head)"
    # Its one reason: no check of the plan, Daniel's message, the reviews or the paths.
    assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
    assert_equal "$(reads)" ""
    [[ -z $(stub_calls gh | jq -c 'select(.[1] // "" | test("/files"))') ]]
  done
}

@test "the team's own project by name is refused on the default word, whatever its repo" {
  review_app_off
  default_word Daniel
  as_project agent-team
  refused "$OWN_REASON" "$(ask_per_head)"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
}

@test "the team's own project by path is refused on the default word" {
  review_app_off
  merging_the_code
  default_word Daniel
  refused "$OWN_REASON" "$(ask_per_head)"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
}

@test "the team's own project is refused on the default word after a per-head word that does not hold, both reasons named" {
  own_by_repo
  default_word Daniel
  event T14 merge-approved '{url: "https://github.com/owner/proj/pull/5", discord_message: "1562661774950400000"}'
  approved_by 999
  refused "Discord message 1562661774950400000 is by daniel (999), who is not in allowFrom" "$OWN_REASON" "$(ask_per_head)"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 3
  assert_equal "$(tail -n 1 <<<"$stderr")" "  $(ask_per_head)"
}

@test "the team's own project still merges on the per-head word, its plan approved" {
  own_by_repo
  plan_md T14
  event T14 plan-approved '{by: "Daniel"}'
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .discord_message] | join(" ")')" "head 1562661774950400000"
  assert_equal "$(posts)" ""
}

@test "another project merges on the default word with the team's own registered beside it" {
  code_checkout
  git -C "${CODE_CHECKOUT:?}" remote set-url origin https://github.com/owner/agent-team.git
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'

[agent-team]
repo = "owner/agent-team"
path = "agent-team"
base = "dev"
delivery = "direct-pr"
merge_method = "squash"
required_checks = ["test"]
task_dir = ".scratch/task"
docs = []
toolkits = []

[agent-team.pool]
provider = "git"
slots = ["slots/agent-team/1"]
TOML
  default_word
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | jq -r '[.project, .approval] | join(" ")')" "proj default"
  assert_equal "$(jq -r .content "$discord/posts" | grep -c "on the plan $COORDINATOR_PLAN")" 2
}

@test "a PR from a branch that is not the task's is refused on the default word" {
  default_word
  pr_field '.headRefName = "feat/T15-other"'
  refused "PR #5 comes from feat/T15-other, not feat/T14-tooling, T14's branch for proj" "$(ask_per_head)"
}

@test "a PR from the branch a branch-renamed logged for the task merges on the default word, and one from the old branch does not" {
  default_word
  pr_field '.headRefName = "feat/T14-tooling-fresh"'
  refused "PR #5 comes from feat/T14-tooling-fresh, not feat/T14-tooling, T14's branch for proj" "$(ask_per_head)"
  event T14 branch-renamed '{project: "proj", branch: "feat/T14-tooling-fresh"}'
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .branch] | join(" ")')" "default feat/T14-tooling-fresh"
  merge_again
  pr_field '.headRefName = "feat/T14-tooling"'
  refused "PR #5 comes from feat/T14-tooling, not feat/T14-tooling-fresh, T14's branch for proj" "$(ask_per_head)"
}

@test "the task's branch for a project added by team-open --add is its worktree-added event's" {
  default_word
  jq -c 'if .event == "opened" then .project = "lib" | .branch = "feat/T14-lib" else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 worktree-added '{project: "proj", branch: "feat/T14-tooling", base: "dev", base_sha: "0123456", worktree: "/w/4"}'
  # The plan's task directory is its first project's, lib's, read through the registry.
  refused "the plan's files cannot be read" "$(ask_per_head)"
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'

[lib]
repo = "owner/lib"
path = "projects/lib"
base = "dev"
delivery = "direct-pr"
merge_method = "squash"
required_checks = ["test"]
task_dir = ".scratch/task"
docs = []
toolkits = []

[lib.pool]
provider = "git"
slots = ["slots/lib/1"]
TOML
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .branch] | join(" ")')" "default feat/T14-tooling"
}

@test "a release-shaped PR, the base into another branch, is refused on the default word" {
  default_word
  pr_field '.baseRefName = "main" | .headRefName = "dev"'
  refused "PR #5 targets main, not proj's base dev" "PR #5 comes from dev, not feat/T14-tooling, T14's branch for proj" \
    "$(ask_per_head)"
}

@test "a PR with no review of its head is refused on the default word" {
  default_word
  jq -c 'select(.event != "review")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  passed 0fedcba9876543210
  refused "no review of the head ${head:0:7} is logged, so no reviewer has passed it" "$(ask_per_head)"
}

@test "a PR whose latest review of its head found something is refused on the default word, and a later pass merges it" {
  default_word
  event T14 review "{verdict: \"findings\", head: \"${head:0:8}\",
    findings: {blocking: 0, correctness: 1, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}, guarded: []}"
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, is findings, not pass" "$(ask_per_head)"
  passed "${head:0:7}"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

@test "a PR whose latest review of its head, a pass logged through team-log, sent findings back is refused on the default word" {
  default_word
  local counts='findings=blocking:0,correctness:1,security:0,real-data:0,note-change:0,note-before:0'
  run_bin -0 team-log T14 review verdict=pass head="$head" "$counts" sent_back=1 guarded=none
  local at
  at=$(jq -r 'select(.event == "review") | .ts' "$TEAM_HOME/ledger.jsonl" | tail -n 1)
  refused "the latest review of the head ${head:0:7}, at $at, is findings, not pass" "$(ask_per_head)"
  # The verify pass that sends nothing back merges it.
  run_bin -0 team-log T14 review verdict=pass head="$head" "$counts" sent_back=none guarded=none
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

@test "a latest review of the head that logged no guarded areas, or named some, is refused, naming them" {
  default_word
  event T14 review "{verdict: \"pass\", head: \"$head\",
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}}"
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, logged no guarded areas, so no reviewer has said the change touches none" \
    "$(ask_per_head)"
  event T14 review "{verdict: \"pass\", head: \"${head:0:7}\",
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}, guarded: [\"deploy\", \"secrets\"]}"
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, found the change touching guarded areas: deploy, secrets" \
    "$(ask_per_head)"
  passed
  run_bin -0 team-merge T14
}

@test "each of the six guarded areas a review names holds the PR back; a retired one a review logged before names does not" {
  default_word
  local area
  for area in ci migrations deploy permissions secrets guardrails; do
    event T14 review "{verdict: \"pass\", head: \"$head\",
      findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0}, guarded: [\"$area\"]}"
    refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, found the change touching guarded areas: $area" \
      "$(ask_per_head)"
  done
  # A review logged before T276 that named dependencies or settings, as team-log took then.
  event T14 review "{verdict: \"pass\", head: \"$head\",
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0},
    guarded: [\"dependencies\", \"settings\", \"migrations\"]}"
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, found the change touching guarded areas: migrations" \
    "$(ask_per_head)"
  [[ $stderr != *dependencies* && $stderr != *settings* ]]
  event T14 review "{verdict: \"pass\", head: \"$head\",
    findings: {blocking: 0, correctness: 0, security: 0, \"real-data\": 0, \"note-change\": 0, \"note-before\": 0},
    guarded: [\"dependencies\", \"settings\"]}"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

@test "a review of the task with a security or real-data finding, even fixed later, or with no finding counts, is refused, naming its head and time" {
  default_word
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

@test "the default word reads the PR's files across pages, each rename's old path too" {
  default_word
  files src/a.py 'old/b.py=>src/b.py'
  jq -c '.[:1], .[1:]' "$gh_dir/files.json" >"$gh_dir/pages" && mv "$gh_dir/pages" "$gh_dir/files.json"
  refused "old/b.py, renamed to src/b.py, is outside the approved plan's scope: src/" "$(ask_per_head)"
  [[ $stderr != *"src/a.py"* ]]

  files src/a.py 'src/c.py=>src/b.py'
  jq -c '.[:1], .[1:]' "$gh_dir/files.json" >"$gh_dir/pages" && mv "$gh_dir/pages" "$gh_dir/files.json"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

@test "a file list shorter than the PR's changed-file count is refused as one not read in full" {
  default_word
  pr_field '.changedFiles = 3'
  refused "GitHub's list of PR #5's files holds 2 files, not its 3 changed files, so not every file could be checked" \
    "$(ask_per_head)"
  pr_field 'del(.changedFiles)'
  refused "GitHub's list of PR #5's files holds 2 files, not its unknown number of changed files, so not every file could be checked" \
    "$(ask_per_head)"
}

@test "each changed file outside the scope is named; a directory entry covers what is under it and a file entry that file only" {
  default_word
  scope src/a/ README.md
  files src/a/b.py src/a/c/d.py src/ab.py README.md docs/README.md README.md.bak
  refused "src/ab.py is outside the approved plan's scope: src/a/, README.md" \
    "docs/README.md is outside the approved plan's scope: src/a/, README.md" \
    "README.md.bak is outside the approved plan's scope: src/a/, README.md" "$(ask_per_head)"
  [[ $stderr != *"src/a/b.py"* && $stderr != *"src/a/c/d.py"* && $stderr != *"  README.md is"* ]]
}

@test "a plan with no scope.txt has no scope check, and the short list still holds" {
  default_word
  scope
  files src/tooling.py docs/tooling.md
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
  merge_again
  files src/tooling.py .github/workflows/test.yml
  refused ".github/workflows/test.yml is a guarded path (ci): a change there comes back to Daniel" "$(ask_per_head)"
}

@test "a path every project's lines guard is named with its areas; test configs, scripts, dependencies, instruction files and auth words in names are not" {
  default_word
  guarded_case \
    .github/workflows/test.yml:ci .circleci/config.yml:ci .gitlab-ci.yml:ci .no-mistakes.yaml:ci \
    ".github/workflows/deploy.yml:ci, deploy" ".github/CODEOWNERS:ci, permissions" docs/CODEOWNERS:permissions \
    back-end/migrations/migrate_roles.py:migrations db/migration/0001.py:migrations schema/init.sql:migrations \
    back-end/reset_database.py:migrations back-end/init_database.py:migrations back-end/mongo-init.js:migrations \
    front-end/vercel.json:deploy back-end/vercel.json:deploy netlify.toml:deploy fly.toml:deploy Procfile:deploy \
    render.yaml:deploy railway.toml:deploy back-end/utils/deployment.py:deploy scripts/deploy.sh:deploy \
    front-end/.env.example:secrets .env:secrets back-end/.env.production:secrets certs/server.pem:secrets \
    certs/client.p12:secrets certs/client.pfx:secrets deploy/id.key:secrets config/credentials.json:secrets \
    back-end/utils/secret_key.py:secrets \
    front-end/e2e/auth.spec.ts back-end/tests/conftest.py front-end/package.json front-end/package-lock.json \
    back-end/requirements.txt pyproject.toml back-end/Dockerfile docker-compose.yml AGENTS.md CLAUDE.md \
    .claude/settings.json .vscode/launch.json .mcp.json back-end/settings.py scripts/nm-test.sh Makefile \
    .husky/pre-push front-end/vite.config.ts front-end/tsconfig.app.json front-end/playwright.config.ts \
    front-end/src/views/LoginView.vue back-end/guards.py back-end/api/permissions.py back-end/utils/tokens.py \
    back-end/utils/session_storage.py src/jwt.ts src/csrf.ts docs/deploy.md back-end/lookup_indexes.py \
    scripts/migrate_users.py db/add_roles_migration.py bin/team-merge bin/lib/team.sh roles/reviewer.md \
    settings/worker.json bin/lib/guarded
}

@test "a camelCase name counts its humps as words, as the snake_case name it stands for" {
  default_word
  guarded_case back-end/resetDatabase.py:migrations back-end/InitDatabase.py:migrations back-end/resetDb.py
}

@test "a Conventioner PR names its auth code and every project's lines; its tests, dependencies, instruction files and views match nothing" {
  default_word
  as_project conventioner
  guarded_case back-end/guards.py:permissions .github/workflows/test.yml:ci back-end/migrations/migrate_roles.py:migrations \
    back-end/vercel.json:deploy back-end/.env.example:secrets \
    back-end/api/applicant_auth.py:permissions back-end/api/permissions.py:permissions \
    back-end/remembered_sign_ins.py:permissions back-end/sign_in_limits.py:permissions \
    back-end/utils/application_token.py:permissions "back-end/utils/configured_secret.py:permissions, secrets" \
    back-end/utils/cors.py:permissions "back-end/utils/secret_key.py:permissions, secrets" \
    "back-end/utils/secretKey.py:permissions, secrets" back-end/utils/security_headers.py:permissions \
    back-end/utils/session_storage.py:permissions back-end/utils/tokens.py:permissions \
    front-end/e2e/auth.spec.ts back-end/tests/conftest.py front-end/package.json AGENTS.md \
    front-end/src/views/LoginView.vue back-end/tests/test_guards.py front-end/guards.py back-end/api/guards.py \
    bin/team-merge settings/worker.json
}

@test "a rename's old path on a project's own line is named, as the new one would be" {
  default_word
  as_project conventioner
  files 'back-end/guards.py=>back-end/access.py'
  scope back-end/
  refused "back-end/guards.py, renamed to back-end/access.py, is a guarded path (permissions): a change there comes back to Daniel" \
    "$(ask_per_head)"
  assert_equal "$(grep -c 'is a guarded path' <<<"$stderr")" 1
}

@test "another project's auth code by Conventioner's names matches nothing, so its PR merges on the default word" {
  default_word
  files back-end/guards.py back-end/utils/tokens.py src/tooling.py
  scope back-end/ src/
  as_project agent-company
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | jq -r '[.project, .approval] | join(" ")')" "agent-company default"
}

# The library's file reasons for PR #5 of proj, one per line: file_reasons
file_reasons() {
  run --separate-stderr bash -c 'source "$1/bin/lib/team.sh"; dir=$(mktemp -d)
    pr_file_reasons "$dir" proj owner/proj 5 "$2"; printf "%s\n" "${PR_FILE_REASONS[@]}"' _ "${CODE_CHECKOUT:-$REPO_ROOT}" "$(jq length "$gh_dir/files.json")"
}

@test "an agent-team PR's file reasons name its critical list as guardrails, and its other code, docs and tests match nothing" {
  # By repo: proj's repo is the origin of the code checkout team-merge runs from. The default word
  # reads no file of the team's own project while the reviewer App is not set up, so the list is
  # read through the library, as every word that reads files reads it.
  own_by_repo
  local path paths=() expected=()
  for path in bin/team-merge bin/team-checks bin/team-heavy bin/team-review-status bin/team-ask bin/team-run-approved \
    bin/team-worker bin/team-lease bin/claude-coordinator bin/lib/guarded bin/lib/ledger-contract.json bin/lib/data-check \
    bin/lib/records bin/lib/code bin/lib/command_rules.py bin/lib/command_text.py bin/lib/outbound.py bin/hooks/git/pre-push \
    bin/hooks/records-git/pre-commit bin/hooks/lease-fence settings/worker.json settings/reviewer.json coordinator.settings.json \
    bin/lib/team.sh bin/lib/platform.sh bin/lib/ledger.jq bin/lib/messages.jq bin/lib/review-app bin/team-next \
    bin/team-catch-up bin/team-review-check bin/team-log bin/team-project bin/lib/lifecycle.json roles/reviewer.md \
    roles/coordinator.md; do
    paths+=("$path")
    expected+=("$path is a guarded path (guardrails): a change there comes back to Daniel")
  done
  expected+=(".github/workflows/ci.yml is a guarded path (ci): a change there comes back to Daniel")
  files "${paths[@]}" bin/team-time sops/docker.md tests/team-time.bats bin/lib/time.jq bin/team-state \
    bin/lib/capacity.jq README.md src/bin/team-merge.md roles.md .github/workflows/ci.yml
  file_reasons
  assert_equal "$status" 0
  assert_equal "$output" "$(printf '%s\n' "${expected[@]}")"
}

@test "agent-team's critical paths in another project match nothing, so its PR merges on the default word" {
  default_word
  files bin/team-merge bin/lib/team.sh roles/reviewer.md settings/worker.json bin/lib/guarded
  scope bin/ roles/ settings/
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
}

@test "a changed path with a line break, which grep would read as two, is refused" {
  default_word
  jq -n '[{filename: "src/a.py\n.github/workflows/test.yml", status: "added"}]' >"$gh_dir/files.json"
  pr_field '.changedFiles = 1'
  refused '"src/a.py\n.github/workflows/test.yml" holds a line break, so no guarded pattern can be matched against it' \
    "$(ask_per_head)"
}

@test "a refusal on the default word lists every reason at once, the checks every merge gets among them" {
  default_word
  review "$head" findings
  pr_field '.headRefName = "feat/T15-other"'
  files src/tooling.py .github/workflows/test.yml
  checks '[{"name": "test", "bucket": "fail", "state": "FAILURE"},
    {"name": "agent-review", "bucket": "pending", "state": "IN_PROGRESS"}]'
  jq -n --arg head "$head" '[
    {sha: "1111111111111111111111111111111111111111",
     commit: {message: "feat: one\n\nCo-Authored-By: Claude <noreply@anthropic.com>"}},
    {sha: $head, commit: {message: "test: two"}}]' >"$gh_dir/commits.json"
  refused "PR #5 comes from feat/T15-other, not feat/T14-tooling, T14's branch for proj" \
    "the latest review of the head ${head:0:7}, at 2026-10-22T02:00:00Z, is findings, not pass" \
    ".github/workflows/test.yml is a guarded path (ci): a change there comes back to Daniel" \
    "required check lint is missing on the head" "required check test has not passed on the head" \
    "checks failing on the head: test" "checks pending on the head: agent-review" \
    "agent-review is in_progress on the head, not success" \
    "commit 1111111 (feat: one) carries an attribution line: Co-Authored-By: Claude <noreply@anthropic.com>"
  [[ $stderr != *"merge-approved"* ]]
  assert_equal "$(tail -n 1 <<<"$stderr")" "  $(ask_per_head)"
}

@test "every check every merge gets refuses on a default word that holds, with no ask line" {
  default_word
  local reason
  # Each broken fact and the reason it gives; the PR is green again between them.
  while IFS='|' read -r fact reason; do
    green_pr
    case $fact in
      check) checks '[{"name": "test", "bucket": "fail", "state": "FAILURE"}, {"name": "lint", "bucket": "pass", "state": "SUCCESS"}, {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]' ;;
      pending) checks '[{"name": "test", "bucket": "pass", "state": "SUCCESS"}, {"name": "lint", "bucket": "pending", "state": "IN_PROGRESS"}, {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]' ;;
      missing) checks '[{"name": "test", "bucket": "pass", "state": "SUCCESS"}, {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]' ;;
      review) checks '[{"name": "test", "bucket": "pass", "state": "SUCCESS"}, {"name": "lint", "bucket": "pass", "state": "SUCCESS"}, {"name": "agent-review", "bucket": "fail", "state": "FAILURE"}]' ;;
      draft) pr_field '.isDraft = true' ;;
      conflict) pr_field '.mergeable = "CONFLICTING"' ;;
      base) pr_field '.baseRefName = "main"' ;;
      moved) jq '.headRefOid = "0000000000000000000000000000000000000000"' "$gh_dir/pr.json" >"$gh_dir/pr-again.json" ;;
      attributed) jq -n --arg head "$head" '[{sha: $head, commit: {message: "test: two\n\nCo-Authored-By: Claude <noreply@anthropic.com>"}}]' >"$gh_dir/commits.json" ;;
    esac
    refused "$reason"
    rm -f "$gh_dir/pr-again.json"
    [[ $stderr != *"(Daniel's"* ]]
  done <<'CASES'
check|checks failing on the head: test
pending|checks pending on the head: lint
missing|required check lint is missing on the head
review|agent-review is failure on the head, not success
draft|PR #5 is a draft
conflict|PR #5 conflicts with its base
base|PR #5 targets main, not proj's base dev
moved|the head moved while it was read
attributed|commit a1b2c3d (test: two) carries an attribution line: Co-Authored-By: Claude <noreply@anthropic.com>
CASES
}

@test "a project's local checks run on the default word's head, and a failing one is refused" {
  with_local_checks
  default_word
  echo 1 >"$GH_DIR/check.status"
  refused "the local checks did not pass on the head ${head:0:7} (team-checks exit 1):"
  [[ $stderr != *"(Daniel's"* ]]
  echo 0 >"$GH_DIR/check.status"
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -c '[.approval, .local_checks]')" '["default",["./check.sh"]]'
}

@test "a default merge on the coordinator's plan posts to the task's thread and #coordinator once merged is logged, before the inbox refresh" {
  default_word
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(jq -r .merge <<<"$output")" "$MERGE_SHA"
  assert_equal "$(posts)" "1563 $(merge_post "$COORDINATOR_PLAN" "\`git revert $MERGE_SHA\`" | jq -Rsc 'rtrimstr("\n")')
$COORDINATOR $(merge_post "$COORDINATOR_PLAN" "\`git revert $MERGE_SHA\`" | jq -Rsc 'rtrimstr("\n")')"
  assert_equal "$(jq -r .merged "$discord/posts" | sort -u)" 1
  [[ $stderr != *post* ]]
  # No guild is read for a post that links no message; team-inbox reads it, and posts nothing.
  assert_equal "$(inbox_calls)" "GET channels/$COORDINATOR"
}

@test "a default merge on Daniel's plan links their message, with the guild read from #coordinator's channel" {
  default_word Daniel
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(posts)" "1563 $(merge_post "$(daniel_plan)" "\`git revert $MERGE_SHA\`" | jq -Rsc 'rtrimstr("\n")')
$COORDINATOR $(merge_post "$(daniel_plan)" "\`git revert $MERGE_SHA\`" | jq -Rsc 'rtrimstr("\n")')"
  assert_equal "$(inbox_calls)" "GET channels/$COORDINATOR
GET channels/$COORDINATOR"
}

@test "the post's revert is the project's merge method's: git revert -m 1 for a merge, the rebased commits' range for a rebase" {
  default_word
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

@test "a default merge with no thread posts to #coordinator alone, saying so" {
  default_word Daniel
  jq -c 'select(.event != "thread")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  approved_by 757 "$COORDINATOR"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(posts)" "$COORDINATOR $(merge_post "$(daniel_plan "$COORDINATOR")" "\`git revert $MERGE_SHA\`" | jq -Rsc 'rtrimstr("\n")')"
  assert_contains "$stderr" "team-merge: T14 has no Discord thread, so Daniel hears of the merge in #coordinator alone"
}

@test "a default merge's post links Daniel's message with the guild the inbox kept, and names it when no guild is known" {
  default_word Daniel
  inbox_kept
  run_bin -0 team-merge T14
  assert_equal "$(inbox_calls)" "PATCH channels/$COORDINATOR/messages/1569000000000000000"
  assert_equal "$(jq -r .content "$discord/posts" | head -n 1)" "$(merge_post "$(daniel_plan)" x | head -n 1)"

  # A guild Discord does not name leaves the message named, not linked, saying why.
  merge_again
  rm "$HOME/.local/state/agent-team/inbox.json"
  echo 500 >"$STUB_FIXTURES/inbox/fail"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(jq -r .content "$discord/posts" | head -n 1)" \
    "T14 The tooling: merged https://github.com/owner/proj/pull/5 on the plan you approved, Discord message 1562661774950400000 in the task's thread 1563, from daniel (757)"
  assert_contains "$stderr" "team-merge: the posts name Daniel's message without a link: Discord named no guild for #coordinator: curl: (22) The requested URL returned error: 500"
}

@test "a post that fails leaves the merge logged and the exit 0, and prints which post failed and its text" {
  default_word
  echo 1563 >"$discord/refuse"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
  assert_equal "$(jq -r .channel "$discord/posts")" "$COORDINATOR"
  assert_contains "$stderr" "team-merge: PR #5 is merged, but its post to the task's thread 1563 failed (team-post: Discord refused the post: curl: (22) The requested URL returned error: 500; nothing was posted); post this text with team-post T14 --file <its file>:
$(merge_post "$COORDINATOR_PLAN" "\`git revert $MERGE_SHA\`")"
  [[ $stderr != *"post to #coordinator"* ]]
}

@test "a fenced machine's posts fail, each said with its text, and the merge stands" {
  default_word
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events | jq -r .approval)" default
  assert_equal "$(posts)" ""
  assert_contains "$stderr" "team-merge: PR #5 is merged, but its post to the task's thread 1563 failed (team-post: "
  assert_contains "$stderr" "team-merge: PR #5 is merged, but its post to #coordinator $COORDINATOR failed (team-post: "
  assert_contains "$stderr" "is fenced since 2026-10-22T14:00:00Z"
  assert_contains "$stderr" "post this text with team-post --coordinator --file <its file>:
$(merge_post "$COORDINATOR_PLAN" "\`git revert $MERGE_SHA\`")"
}

# The default word on a head team-catch-up made: PR #5 is A with what moved_head adds (<step>...),
# the merge-approved gone, the plan approved, the review of A passed with no guarded area, and
# caught-up naming the PR's head as made from A: caught_up_default <step>...
caught_up_default() {
  moved_head "$@"
  default_word
  jq -c 'select(.event != "review")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  passed "$approved"
  caught_up
}

@test "a head team-catch-up made cleanly from a passing, unguarded review merges on the default word with no rereview" {
  caught_up_default base
  run_bin -0 team-merge T14
  assert_equal "$(merged_events | jq -r '[.approval, .head] | join(" ")')" "default $head"
}

@test "a caught-up head is still refused on the default word for a guarded path, or a later review of the head it was made from that found something" {
  caught_up_default base
  files src/tooling.py .github/workflows/test.yml
  refused ".github/workflows/test.yml is a guarded path (ci): a change there comes back to Daniel" "$(ask_per_head)"

  # The review that stands for the caught-up head is named with both heads.
  files src/tooling.py
  ledger_line --arg h "$approved" '{ts: "2026-10-22T05:00:00Z", task: "T14", event: "review", verdict: "findings", head: $h,
    findings: {blocking: 1, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0}, guarded: []}'
  refused "the latest review of the head ${approved:0:7} (caught up to ${head:0:7}), at 2026-10-22T05:00:00Z, is findings, not pass" \
    "$(ask_per_head)"
}

@test "a head a caught-up event names is refused on the default word when git shows its merge is not clean" {
  caught_up_default base evil
  refused "the head ${head:0:7} does not stand on the review of ${approved:0:7}, which team-catch-up made it from: ${head:0:7} changes more than the merge of its parents" \
    "$(ask_per_head)"

  # With no caught-up event, the review of A does not stand for the head at all.
  jq -c 'select(.event != "caught-up")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  refused "no review of the head ${head:0:7} is logged, so no reviewer has passed it" "$(ask_per_head)"
  [[ $stderr != *"does not stand on the review"* ]]
}

@test "a caught-up head whose own review is logged is judged on that review, not on the review of the head it was made from" {
  caught_up_default base
  ledger_line --arg h "$head" '{ts: "2026-10-22T05:00:00Z", task: "T14", event: "review", verdict: "findings", head: $h,
    findings: {blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 1, "note-before": 0},
    sent_back: [1], guarded: ["secrets"]}'
  refused "the latest review of the head ${head:0:7}, at 2026-10-22T05:00:00Z, is findings, not pass" \
    "the latest review of the head ${head:0:7}, at 2026-10-22T05:00:00Z, found the change touching guarded areas: secrets" \
    "$(ask_per_head)"
  [[ $stderr != *"caught up to"* ]]
}

# T14's PR of agent-team (by name) with the reviewer App on (app_on), its plan approved by
# <by> (Daniel by default): app_default [<by>]
app_default() {
  as_project agent-team
  app_on
  default_word "${1:-Daniel}"
}

# The reasons the default word gives the team's own project with the App on, for a plan not
# Daniel's: the coordinator's, or a legacy approval.
OWN_COORDINATOR="the team's own project merges unattended only on a plan Daniel approved, and the coordinator approved T14's at 2026-10-22T02:00:00Z: ask Daniel to approve it"
OWN_LEGACY="the team's own project merges unattended only on a plan Daniel approved, and T14's approval at 2026-10-22T02:00:00Z is a legacy one, logged with no plan: ask Daniel to approve it"

@test "with the reviewer App on, its check on the head and dev's pin, an agent-team PR on Daniel's plan merges on the default word, logging the check run" {
  app_default
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(merged_events)" "$(jq -cn --arg m "$MERGE_SHA" --arg h "$head" '{task: "T14", event: "merged",
    pr: 5, merge: $m, head: $h,
    by: "Discord message 1562661774950400000 in the task'"'"'s thread 1563, from daniel (757)",
    project: "agent-team", branch: "feat/T14-tooling", discord_message: "1562661774950400000", discord_channel: "1563",
    url: "https://github.com/owner/proj/pull/5", approval: "default", check_run: 4242}')"
  assert_equal "$(reads | jq -r '.[-1]')" "https://discord.com/api/v10/channels/1563/messages/1562661774950400000"
  assert_equal "$(posts | wc -l)" 2
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "with the reviewer App on, an agent-team PR is refused on the default word unless dev's protection pins agent-review to the App, enforced for everyone" {
  app_default
  pinned none everyone
  refused "dev's protection does not require agent-review from the reviewer App 123456, so GitHub does not hold its check: the team's own project merges unattended only once it does" \
    "$(ask_per_head)"
  : >"$STUB_CALLS/gh.log"
  green_pr
  pinned 15368 everyone
  refused "dev's protection does not require agent-review from the reviewer App 123456"
  : >"$STUB_CALLS/gh.log"
  green_pr
  pinned 123456 non_admins
  refused "dev's protection enforces its required checks for non_admins, not everyone, so an administrator could merge past them"
  # The App's check is still required, on the default word as on every word.
  : >"$STUB_CALLS/gh.log"
  green_pr
  pinned 123456 everyone
  app_runs
  refused "the reviewer App's agent-review check is missing on the head ${head:0:7}"
}

@test "with the reviewer App on, an agent-team PR on a plan the coordinator approved, or a legacy approval, is refused on the default word, naming Daniel's approval" {
  app_default coordinator
  refused "$OWN_COORDINATOR" "$(ask_per_head)"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
  jq -c 'select(.event != "plan-approved")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 plan-approved '{by: "Daniel"}'
  : >"$STUB_CALLS/gh.log"
  refused "$OWN_LEGACY" "$(ask_per_head)"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
}

@test "with the reviewer App on, an agent-team PR's default word reads its files: its critical list comes back to Daniel, and a changed plan is refused" {
  app_default
  files src/tooling.py bin/team-merge bin/lib/review-app
  scope src/ bin/
  refused "bin/team-merge is a guarded path (guardrails): a change there comes back to Daniel" \
    "bin/lib/review-app is a guarded path (guardrails): a change there comes back to Daniel" "$(ask_per_head)"
  [[ $stderr != *"src/tooling.py is a guarded path"* ]]
  files src/tooling.py
  echo "# changed" >"$(SPEC)"
  : >"$STUB_CALLS/gh.log"
  refused "the plan changed since its approval at 2026-10-22T02:00:00Z (.scratch/task/spec.md): approve it again"
}

@test "with the reviewer App off, an agent-team PR on Daniel's plan has the one not-set-up reason, whatever the check runs show" {
  review_app_off
  as_project agent-team
  default_word Daniel
  refused "$OWN_REASON" "$(ask_per_head)"
  assert_equal "$(grep -c '^  ' <<<"$stderr")" 2
  [[ -z $(stub_calls gh | jq -c 'select(.[1] // "" | test("/commits/|/files"))') ]]
}
