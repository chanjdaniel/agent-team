#!/usr/bin/env bats
# A whole task's life with the scripts alone, the way roles/coordinator.md runs it: opened,
# briefed, launched, logged, reviewed, merged on a recorded word and closed. Every ledger line is
# written by a script; the test only plays the workers (their commits, pushes and session states),
# GitHub (gh, merging for real into the bare origin) and Discord (curl).
# After each step, team-state says the phase and team-sweep finds exactly what the coordinator
# would have to act on.

load helpers/common
load helpers/treehouse

setup() {
  sandbox
  home=$(make_repo home dev)
  conv=$(make_repo conv dev)
  ignore_scratch "$home"
  ignore_scratch "$conv"
  conv_slots=("$HOME/.treehouse/conv-abc123/1/conv" "$HOME/.treehouse/conv-abc123/2/conv")
  local slot
  for slot in "${conv_slots[@]}"; do git -C "$conv" worktree add -q --detach "$slot" origin/dev; done
  printf '%s\n' "${conv_slots[@]}" >"$BATS_TEST_TMPDIR/free"
  fake_pool_commands "$conv"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[home]
repo = "owner/home"
path = "projects/home"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = ["test"]
task_dir = ".scratch/task"
docs = []
toolkits = []

[home.pool]
provider = "git"
slots = ["slots/home/1", "slots/home/2"]

[conv]
repo = "owner/conv"
path = "projects/conv"
base = "dev"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = ["test"]
task_dir = ".scratch/task"
docs = []
toolkits = []

[conv.pool]
provider = "treehouse"
lease = "scripts/th-lease.sh"
return = "scripts/th-return.sh"
slots = [".treehouse/conv-abc123/1/conv", ".treehouse/conv-abc123/2/conv"]
TOML
  echo '{"dmPolicy": "allowlist", "allowFrom": ["757"], "groups": {}, "pending": {}}' \
    >"$HOME/.claude/channels/discord/access.json"
  # The team runs on this machine: its team home has an origin, and it holds the lease.
  hold_lease >/dev/null
  export GH_DIR=$BATS_TEST_TMPDIR/gh ORIGINS=$BATS_TEST_TMPDIR/origin
  mkdir -p "$GH_DIR/checks"
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  printf '%s\n' 1a2b3c4d 4f2a9c1e 9c8b7a6d 5e6f7a8b 2b3c4d5e 6c7d8e9f >"$BATS_TEST_TMPDIR/ids"
  fake_claude
  fake_github
  fake_discord
}

# Commit and push a .gitignore with .scratch/ in the primary checkout <path>.
ignore_scratch() {
  echo ".scratch/" >"$1/.gitignore"
  git -C "$1" add .gitignore
  git -C "$1" commit -q -m "chore: ignore scratch"
  git -C "$1" push -q origin dev
}

# claude: --bg starts a session (the next id of $BATS_TEST_TMPDIR/ids, busy and working) and lists
# it; agents --json prints the list; stop and rm take a session off it.
fake_claude() {
  stub_script claude <<'SH'
list=$BATS_TEST_TMPDIR/sessions.json
case $1 in
  agents) cat "$list" ;;
  --bg)
    name='' prev=''
    for arg in "$@"; do
      if [[ $prev == --name ]]; then name=$arg; fi
      prev=$arg
    done
    id=$(head -n 1 "$BATS_TEST_TMPDIR/ids")
    sed -i 1d "$BATS_TEST_TMPDIR/ids"
    jq --arg id "$id" --arg name "$name" --arg cwd "$PWD" '. + [{pid: 4242, cwd: $cwd, kind: "background",
      startedAt: 1761098400000, sessionId: "\($id)-1111-4222-8333-444455556666", name: $name,
      status: "busy", id: $id, state: "working"}]' "$list" >"$list.next" && mv "$list.next" "$list"
    echo "Started background session $id ($name). Attach with: claude attach $id"
    ;;
  stop | rm) jq --arg id "$2" 'map(select(.id != $id))' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  *) echo "unplanned claude call: $*" >&2; exit 64 ;;
esac
SH
}

# A session's status and state change as the worker works: session_is <id> <status> <state>
session_is() {
  local list=$BATS_TEST_TMPDIR/sessions.json
  jq --arg id "$1" --arg status "$2" --arg state "$3" \
    'map(if .id == $id then .status = $status | .state = $state else . end)' "$list" >"$list.next"
  mv "$list.next" "$list"
}

# gh: GitHub as the PRs under $GH_DIR (<owner>_<repo>-<n>.json, with the checks on the head in
# checks/<owner>_<repo>-<n>.json) and the bare origins. pr merge merges the PR's branch into its
# base on the origin for real, with a merge commit.
fake_github() {
  stub_script gh <<'SH'
pr_file() { echo "$GH_DIR/${1//\//_}-$2.json"; }
case "$1 $2" in
  "pr view")
    jq --arg fields "$7" '. as $pr | $fields | split(",") | map({key: ., value: $pr[.]}) | from_entries' "$(pr_file "$5" "$3")" ;;
  "pr checks")
    if [[ $6 == --required ]]; then
      echo "no required checks reported on the '$(jq -r .headRefName "$(pr_file "$5" "$3")")' branch" >&2
      exit 1
    fi
    cat "$GH_DIR/checks/${5//\//_}-$3.json" ;;
  "pr list")
    shopt -s nullglob
    files=("$GH_DIR/${4//\//_}"-*.json)
    jq -s '[.[] | select(.state == "OPEN") | {number, title, url, headRefName, baseRefName, isDraft}]' "${files[@]}" /dev/null ;;
  "pr merge")
    file=$(pr_file "$5" "$3")
    [[ $6 == --merge && $7 == --match-head-commit && $8 == $(jq -r .headRefOid "$file") ]] || exit 1
    clone=$BATS_TEST_TMPDIR/merging
    rm -rf "$clone"
    git clone -q "$ORIGINS/${5#*/}.git" "$clone" 2>/dev/null
    git -C "$clone" checkout -q "$(jq -r .baseRefName "$file")"
    git -C "$clone" merge -q --no-ff -m "Merge pull request #$3 from $(jq -r .headRefName "$file")" "origin/$(jq -r .headRefName "$file")"
    git -C "$clone" push -q origin HEAD
    jq --arg m "$(git -C "$clone" rev-parse HEAD)" '.state = "MERGED" | .mergeCommit = {oid: $m}' "$file" >"$file.next"
    mv "$file.next" "$file"
    echo "✓ Merged pull request $5#$3" >&2 ;;
  "api repos/"*)
    if [[ $2 =~ ^repos/([^/]+/[^/]+)/branches/(.+)$ ]]; then
      jq -n --arg b "${BASH_REMATCH[2]}" '{name: $b, protected: false}'
    elif [[ $2 =~ ^repos/([^/]+/([^/]+))/pulls/([0-9]+)/commits$ ]]; then
      file=$(pr_file "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}")
      git=(git --git-dir "$ORIGINS/${BASH_REMATCH[2]}.git")
      for sha in $("${git[@]}" rev-list --reverse "$(jq -r .baseRefName "$file")..$(jq -r .headRefOid "$file")"); do
        jq -n --arg sha "$sha" --arg message "$("${git[@]}" log -1 --format=%B "$sha")" '{sha: $sha, commit: {message: $message}}'
      done | jq -s .
    else
      exit 1
    fi ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
SH
}

# curl: Discord opens thread 1563 under #coordinator and holds the messages daniel_says posted
# in it; anything else is a 404.
fake_discord() {
  export DISCORD_MESSAGES=$BATS_TEST_TMPDIR/messages
  mkdir -p "$DISCORD_MESSAGES"
  stub_script curl <<'SH'
url=${*: -1}
case $url in
  https://discord.com/api/v10/channels/*/threads) echo '{"id": "1563"}' ;;
  https://discord.com/api/v10/channels/1563/messages/*)
    if [[ -f $DISCORD_MESSAGES/${url##*/} ]]; then cat "$DISCORD_MESSAGES/${url##*/}"; else
      echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
    fi ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
SH
}

# Daniel (757) says <text> in the thread now; sets message to its id, which holds the time sent.
daniel_says() {
  message=$((($(date +%s%3N) - 1420070400000) << 22 | $(find "$DISCORD_MESSAGES" -type f | wc -l)))
  jq -n --arg id "$message" --arg text "$1" '{id: $id, channel_id: "1563", content: $text,
    author: {id: "757", username: "daniel"}}' >"$DISCORD_MESSAGES/$message"
}

# The worker's part: a commit of <file> in <worktree>, pushed to its branch on origin; prints the
# full head.
commit_and_push() {
  echo "$2" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "feat: add $2"
  git -C "$1" push -q origin HEAD
  git -C "$1" rev-parse HEAD
}

# The delivering builder opens PR <n> of <repo> for <worktree>'s branch; CI's test check passes
# on it. Prints the PR's URL.
open_pr() {
  local repo=$1 number=$2 worktree=$3 file
  file=$GH_DIR/${repo//\//_}-$number
  jq -n --arg repo "$repo" --argjson n "$number" --arg branch "$(git -C "$worktree" branch --show-current)" \
    --arg head "$(git -C "$worktree" rev-parse HEAD)" '{number: $n, title: "The work",
      url: "https://github.com/\($repo)/pull/\($n)", state: "OPEN", isDraft: false, mergeable: "MERGEABLE",
      baseRefName: "dev", headRefName: $branch, headRefOid: $head, mergeCommit: null, autoMergeRequest: null}' \
    >"$file.json"
  echo '[{"name": "test", "bucket": "pass", "state": "SUCCESS"}]' >"$GH_DIR/checks/${repo//\//_}-$number.json"
  jq -r .url "$file.json"
}

# The reviewer sets agent-review to success on PR <n> of <repo>'s head.
agent_review_passes() {
  local file=$GH_DIR/checks/${1//\//_}-$2.json
  jq '. + [{name: "agent-review", bucket: "pass", state: "SUCCESS"}]' "$file" >"$file.next"
  mv "$file.next" "$file"
}

# After a step: team-state says <phase>, and team-sweep finds exactly the <kind>:<session>
# findings given (none when only the phase is given).
step() {
  local phase=$1 found
  shift
  run_bin -0 --separate-stderr team-state T1 --json
  assert_equal "$(jq -r .phase <<<"$output")" "$phase"
  run_bin --separate-stderr team-sweep --json
  found=$(jq -r '.[] | "\(.kind):\(.session // "-")"' <<<"$output")
  assert_equal "$found" "$(printf '%s\n' "$@")"
  assert_equal "$status" "$(($# > 0))"
}

# Run a script that must succeed, keeping its stdout as $output and showing its stderr on failure.
ok() {
  run_bin -0 --separate-stderr "$@"
}

# The end of every life: the ledger meets its contract, the task is closed with its archive, its
# slots are free, and the snapshot shows nothing open and no session left.
assert_closed_and_clean() {
  run_bin -0 team-log --check
  step closed
  run_bin -0 --separate-stderr team-snapshot --json
  assert_equal "$(jq -c '[.tasks, .sessions, .strays, .pending_asks]' <<<"$output")" '[[],[],[],[]]'
  assert_equal "$(jq -c '[.prs[] | .prs[]]' <<<"$output")" '[]'
}

@test "one task's life, from team-open to team-close, runs on the scripts alone" {
  # 1. Open.
  ok team-open home feature feat tooling "The tooling"
  local wt plan
  wt=$(jq -r .worktree <<<"$output") plan=$(jq -r .plan <<<"$output")
  assert_equal "$wt" "$HOME/slots/home/1"
  assert_equal "$(jq -r .thread <<<"$output")" "1563"
  # The coordinator has a worker to launch.
  step planning no-worker:-

  # 2. Plan: brief and launch the planner.
  echo "- The idea: \`$TEAM_HOME/tasks/T1/idea.md\`." >"$BATS_TEST_TMPDIR/read"
  ok team-brief T1 planner-feature --set-file read="$BATS_TEST_TMPDIR/read"
  local brief=$output
  assert_contains "$(cat "$brief")" "Worktree: \`~/slots/home/1\`, branch \`feat/T1-tooling\` from \`origin/dev\`."
  step planning no-worker:-
  ok team-worker T1 planner "$wt" -- "Read your brief at $brief"
  local planner=$output
  assert_equal "$planner" 1a2b3c4d
  step planning

  # The planner writes its spec and goes idle without reporting: the coordinator must look.
  mkdir -p "$wt/.scratch/task/tickets"
  echo "# Spec" >"$wt/.scratch/task/spec.md"
  echo "# 01" >"$wt/.scratch/task/tickets/01-thing.md"
  session_is "$planner" idle working
  step planning silent:"$planner"

  # 3. Approve: the planner's DONE, then the approval.
  # Its DONE logged, the next step is the coordinator's until a builder is at work.
  ok team-log T1 "done" role=planner session="$planner"
  step planning no-worker:"$planner"
  ok team-log T1 plan-approved by=Daniel
  step building no-worker:"$planner"

  # 4. Build: one builder for the ticket.
  ok team-brief T1 builder-ticket --set ticket=01 --name build-01
  local builder_brief=$output
  step building no-worker:"$planner"
  ok team-worker T1 builder "$wt" -- "Read your brief at $builder_brief"
  local builder=$output
  step building

  # The builder asks for a permission: the coordinator must answer it.
  session_is "$builder" idle blocked
  step building waiting-input:"$builder"
  session_is "$builder" busy working
  local head
  head=$(commit_and_push "$wt" thing.txt)
  # Pushed and idle, but not reported yet: the coordinator must look.
  session_is "$builder" idle working
  step building silent:"$builder"
  ok team-log T1 ticket-done ticket=01 commits="[\"${head:0:7}\"]"
  step building no-worker:"$builder"

  # The builder delivers: the PR, CI green on it, agent-review not yet there.
  local url
  url=$(open_pr owner/home 7 "$wt")
  ok team-log T1 pr url="$url" head="$head"
  step in-review no-worker:"$builder"
  ok team-state T1
  assert_equal "$output" "T1 home feature in-review | T1-planner idle, T1-builder idle | PR #7 ${head:0:7} checks 1/1 agent-review missing"

  # 5. Review: a fresh reviewer, its pass and the agent-review status on the head.
  echo "- The tests run the real scripts." >"$BATS_TEST_TMPDIR/checks"
  ok team-brief T1 reviewer --name review --set pr="$url" --set head="$head" --set-file checks="$BATS_TEST_TMPDIR/checks"
  local review_brief=$output
  assert_contains "$(cat "$review_brief")" "; review \`origin/dev...$head\`."
  assert_contains "$(cat "$review_brief")" "the comment on PR $url is that file"
  step in-review no-worker:"$builder"
  ok team-worker T1 reviewer "$wt" -- "Read your brief at $review_brief"
  local reviewer=$output
  step in-review
  agent_review_passes owner/home 7
  session_is "$reviewer" idle working
  ok team-log T1 review verdict=pass head="$head"
  step awaiting-merge

  # 6. Merge on Daniel's word in the thread.
  daniel_says "merge it"
  ok team-log T1 merge-approved url="$url" discord_message="$message"
  step awaiting-merge
  ok team-merge T1
  local merge
  merge=$(git --git-dir "$BATS_TEST_TMPDIR/origin/home.git" rev-parse dev)
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg url "$url" --arg merge "$merge" --arg head "$head" \
    '{task: "T1", pr: $url, merge: $merge, head: $head, by: "Discord message \($message) in the task'"'"'s thread 1563, from daniel (757)"}' --arg message "$message")"
  # Merged with its workers idle: the coordinator closes it.
  step merged no-worker:"$reviewer"

  # 7. Close: the idle workers are stopped and removed, the scratch archived, the slot returned.
  ok team-close T1
  assert_equal "$(jq -c '[.stopped, .removed, .archive, .returned, .kept]' <<<"$output")" \
    "$(jq -cn --arg wt "$wt" --arg p "$planner" --arg b "$builder" --arg r "$reviewer" \
      '[[$p, $b, $r], [$p, $b, $r], ["tasks/T1/scratch"], [$wt], []]')"
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/spec.md")" "# Spec"
  [[ -f $TEAM_HOME/tasks/T1/scratch/tickets/01-thing.md ]]
  [[ ! -e $wt ]]
  [[ $(git -C "$home" worktree list) != *"$wt"* ]]
  [[ -f $plan ]]
  assert_closed_and_clean

  # Every line came from a script, in the order the life ran.
  assert_equal "$(jq -r .event "$TEAM_HOME/ledger.jsonl" | paste -sd ' ')" \
    "thread opened launch done plan-approved launch ticket-done pr launch review merge-approved merged worktree-returned closed"
}

@test "a two-project task's life: opened in a git pool, a treehouse worktree added, two PRs merged, both worktrees closed" {
  # 1. Open in home, then add conv's worktree from its treehouse pool.
  ok team-open home feature feat tooling "The tooling"
  local home_wt conv_wt
  home_wt=$(jq -r .worktree <<<"$output")
  ok team-open --task T1 --add conv feat tooling
  conv_wt=$(jq -r .worktree <<<"$output")
  assert_equal "$conv_wt" "${conv_slots[0]}"
  assert_equal "$(git -C "$conv_wt" branch --show-current)" feat/T1-tooling
  step planning no-worker:-

  # 2. Plan in home; a brief needs the project once the task has two.
  echo "- The idea." >"$BATS_TEST_TMPDIR/read"
  run_bin -2 team-brief T1 planner-feature --set-file read="$BATS_TEST_TMPDIR/read"
  ok team-brief T1 planner-feature --project home --set-file read="$BATS_TEST_TMPDIR/read"
  ok team-worker T1 planner "$home_wt" -- "Read your brief at $output"
  local planner=$output
  step planning
  mkdir -p "$home_wt/.scratch/task"
  echo "# Spec" >"$home_wt/.scratch/task/spec.md"
  session_is "$planner" idle working
  step planning silent:"$planner"
  ok team-log T1 "done" role=planner session="$planner"
  step planning no-worker:"$planner"
  ok team-log T1 plan-approved by=Daniel
  step building no-worker:"$planner"

  # 3. One builder per ticket, one ticket in each project.
  ok team-brief T1 builder-ticket --project home --set ticket=01 --name build-01
  step building no-worker:"$planner"
  ok team-worker T1 builder "$home_wt" -- "Read your brief at $output"
  local home_builder=$output home_head
  step building
  home_head=$(commit_and_push "$home_wt" home.txt)
  session_is "$home_builder" idle working
  ok team-log T1 ticket-done ticket=01 commits="[\"${home_head:0:7}\"]"
  step building no-worker:"$home_builder"
  ok team-brief T1 builder-ticket --project conv --set ticket=02 --name build-02
  assert_contains "$(cat "$output")" "Worktree: \`~/.treehouse/conv-abc123/1/conv\`"
  ok team-worker T1 builder "$conv_wt" -- "Read your brief at $output"
  local conv_builder=$output conv_head
  step building
  mkdir -p "$conv_wt/.scratch/task/build-notes"
  echo "# 02" >"$conv_wt/.scratch/task/build-notes/02.md"
  conv_head=$(commit_and_push "$conv_wt" conv.txt)
  session_is "$conv_builder" idle working
  ok team-log T1 ticket-done ticket=02 commits="[\"${conv_head:0:7}\"]"
  step building no-worker:"$conv_builder"

  # 4. A PR in each repo, each reviewed by its own reviewer; conv's review lands first.
  local home_url conv_url
  home_url=$(open_pr owner/home 7 "$home_wt")
  conv_url=$(open_pr owner/conv 3 "$conv_wt")
  ok team-log T1 pr url="$home_url" head="$home_head"
  ok team-log T1 pr url="$conv_url" head="$conv_head"
  step in-review no-worker:"$conv_builder"
  echo "- Both repos." >"$BATS_TEST_TMPDIR/checks"
  ok team-brief T1 reviewer --project home --name review-home --set pr="$home_url" --set head="$home_head" \
    --set-file checks="$BATS_TEST_TMPDIR/checks"
  ok team-worker T1 reviewer "$home_wt" -- "Read your brief at $output"
  local home_reviewer=$output
  # conv is gated: its first review read the local head before the gate ran, so its PR gets the
  # re-review of what the gate added.
  ok team-brief T1 rereview --project conv --name rereview-conv --set pr="$conv_url" --set head="$conv_head" \
    --set reviewed="$conv_head" --set "since=the gate's run"
  ok team-worker T1 reviewer "$conv_wt" -- "Read your brief at $output"
  local conv_reviewer=$output
  step in-review
  agent_review_passes owner/conv 3
  session_is "$conv_reviewer" idle working
  ok team-log T1 review verdict=pass head="$conv_head"
  # home's PR is still under review.
  step in-review
  agent_review_passes owner/home 7
  session_is "$home_reviewer" idle working
  ok team-log T1 review verdict=pass head="$home_head"
  step awaiting-merge

  # 5. Daniel's word for each PR; each merges on its own.
  daniel_says "merge home's"
  ok team-log T1 merge-approved url="$home_url" discord_message="$message"
  daniel_says "merge conv's"
  ok team-log T1 merge-approved url="$conv_url" discord_message="$message"
  ok team-merge T1 --pr "$home_url"
  # conv's PR still waits for its merge.
  step awaiting-merge
  ok team-merge T1 --pr "$conv_url"
  step merged no-worker:"$conv_reviewer"

  # 6. Close: both worktrees archived and returned, each through its own pool.
  ok team-close T1
  assert_equal "$(jq -c '[.archive, .returned, .kept]' <<<"$output")" \
    "$(jq -cn --arg h "$home_wt" --arg c "$conv_wt" '[["tasks/T1/scratch", "tasks/T1/scratch-conv"], [$h, $c], []]')"
  assert_equal "$(jq -c '.stopped | length' <<<"$output")" 5
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch/spec.md")" "# Spec"
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/scratch-conv/build-notes/02.md")" "# 02"
  [[ ! -e $home_wt ]]
  # The treehouse slot is back in its pool, detached and empty of the task.
  assert_equal "$(git -C "$conv_wt" branch --show-current)" ""
  [[ ! -e $conv_wt/.scratch/task/build-notes ]]
  assert_contains "$(cat "$BATS_TEST_TMPDIR/free")" "$conv_wt"
  assert_closed_and_clean
  assert_equal "$(jq -r .event "$TEAM_HOME/ledger.jsonl" | paste -sd ' ')" \
    "thread opened worktree-added launch done plan-approved launch ticket-done launch ticket-done pr pr launch launch review review merge-approved merge-approved merged merged worktree-returned worktree-returned closed"
}
