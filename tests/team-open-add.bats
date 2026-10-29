#!/usr/bin/env bats
# team-open --add: a second project's worktree for an open task, across a git-pool project
# (home) and a treehouse-pool project (conv, through the fake commands of helpers/treehouse).

load helpers/common
load helpers/treehouse

setup() {
  sandbox
  home=$(make_repo home)
  conv=$(make_repo conv)
  ignore_scratch "$home"
  ignore_scratch "$conv"
  home_slots=("$HOME/slots/home/1" "$HOME/slots/home/2")
  conv_slots=("$HOME/.treehouse/conv-abc123/1/conv" "$HOME/.treehouse/conv-abc123/2/conv")
  local slot
  for slot in "${conv_slots[@]}"; do git -C "$conv" worktree add -q --detach "$slot" origin/main; done
  printf '%s\n' "${conv_slots[@]}" >"$BATS_TEST_TMPDIR/free"
  fake_pool_commands "$conv"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[home]
repo = "owner/home"
path = "projects/home"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[home.pool]
provider = "git"
slots = ["slots/home/1", "slots/home/2"]

[conv]
repo = "owner/conv"
path = "projects/conv"
base = "main"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[conv.pool]
provider = "treehouse"
lease = "scripts/th-lease.sh"
return = "scripts/th-return.sh"
slots = [".treehouse/conv-abc123/1/conv", ".treehouse/conv-abc123/2/conv"]
TOML
  stub_reply curl '{"id":"1563000000000000001"}'
}

# Commit and push a .gitignore with .scratch/ in the primary checkout <path>.
ignore_scratch() {
  echo ".scratch/" >"$1/.gitignore"
  git -C "$1" add .gitignore
  git -C "$1" commit -q -m "chore: ignore scratch"
  git -C "$1" push -q origin main
}

# Push a commit to <project>'s origin main from a second clone; prints the new head.
advance_origin() {
  local other=$BATS_TEST_TMPDIR/other-$1
  [[ -d $other ]] || git clone -q "$BATS_TEST_TMPDIR/origin/$1.git" "$other" 2>/dev/null
  git -C "$other" pull -q
  git -C "$other" commit -q --allow-empty -m "feat: $2"
  git -C "$other" push -q origin main
  git -C "$other" rev-parse HEAD
}

events() {
  jq -c --arg e "$1" 'select(.event == $e)' "$TEAM_HOME/ledger.jsonl"
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for the scripts
# (team-close) that will write it.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

@test "--add leases a treehouse worktree for a task opened in a git pool" {
  git config --global branch.autoSetupMerge always
  run_bin -0 team-open home feature chore import-planning "Move planning out"
  local plan
  plan=$(cat "$TEAM_HOME/tasks/T1/plan.md")
  local ahead
  ahead=$(advance_origin conv "moved on")

  run_bin -0 --separate-stderr team-open --task T1 --add conv chore move-planning-out
  local worktree=${conv_slots[0]}
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg wt "$worktree" --arg sha "$ahead" '{
    task: "T1", project: "conv", branch: "chore/T1-move-planning-out", base: "main",
    base_sha: $sha, worktree: $wt, task_dir: "\($wt)/.scratch/task"}')"
  # The lease command runs from conv's primary checkout, brought level with origin's first.
  assert_equal "$stderr" "team-open: the primary checkout $conv: main fast-forwarded to ${ahead:0:7}"

  assert_equal "$(stub_calls th-lease.sh)" "$(jq -cn --arg cwd "$conv" '{cwd: $cwd, args: ["T1"]}')"
  assert_equal "$(git -C "$worktree" rev-parse --abbrev-ref HEAD)" "chore/T1-move-planning-out"
  assert_equal "$(git -C "$worktree" rev-parse HEAD)" "$ahead"
  run -128 git -C "$worktree" rev-parse --abbrev-ref '@{upstream}'
  [[ -d $worktree/.scratch/task ]]

  assert_equal "$(events worktree-added | jq -c 'del(.ts)')" "$(jq -cn --arg wt "$worktree" --arg sha "$ahead" '{
    task: "T1", event: "worktree-added", project: "conv", branch: "chore/T1-move-planning-out",
    base: "main", base_sha: $sha, worktree: $wt}')"
  assert_equal "$(events opened | wc -l)" "1"
  assert_equal "$(events thread | wc -l)" "1"
  assert_equal "$(stub_calls curl | wc -l)" "1"
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/plan.md")" "$plan"
  assert_equal "$(git -C "${home_slots[0]}" rev-parse --abbrev-ref HEAD)" "chore/T1-import-planning"
  run_bin -0 team-log --check
}

@test "--add takes a git-pool worktree for a task opened in a treehouse pool" {
  run_bin -0 team-open conv feature chore move-planning-out "Move planning out"
  local ahead
  ahead=$(advance_origin home "moved on")

  run_bin -0 --separate-stderr team-open --task T1 --add home chore import-planning
  local worktree=${home_slots[0]}
  assert_equal "$(jq -r '"\(.project) \(.branch) \(.worktree) \(.base_sha)"' <<<"$output")" \
    "home chore/T1-import-planning $worktree $ahead"
  assert_equal "$(git -C "$worktree" rev-parse --abbrev-ref HEAD)" "chore/T1-import-planning"
  assert_equal "$(git -C "$worktree" rev-parse HEAD)" "$ahead"
  run -128 git -C "$worktree" rev-parse --abbrev-ref '@{upstream}'
  assert_equal "$(events worktree-added | jq -r '"\(.task) \(.project) \(.worktree)"')" "T1 home $worktree"
  assert_equal "$(stub_calls th-lease.sh | wc -l)" "1"
  assert_equal "$(events opened | wc -l)" "1"
  assert_equal "$(stub_calls curl | wc -l)" "1"
  run_bin -0 team-log --check
}

@test "--add needs --task and exactly a project, a type and a slug" {
  run_bin -0 team-open home feature feat one "One"
  run_bin -2 team-open --add conv chore slug
  assert_contains "$output" "--add needs --task T<n>"
  run_bin -2 team-open --task T1 --add conv chore
  assert_contains "$output" "usage: team-open --task T<n> --add <project> <type> <slug>"
  run_bin -2 team-open --task T1 --add conv chore slug "Title"
  run_bin -2 team-open --task T1 --add conv feature slug
  assert_contains "$output" "type must be feat, fix, docs, chore, build, ci, test, refactor, perf or research, got 'feature'"
  run_bin -2 team-open --task T1 --add conv chore Bad_Slug
  assert_contains "$output" "slug must be lower-case kebab case of at most 40 characters"
  run_bin -2 team-open --task T1 --add nope chore slug
  assert_contains "$output" "unknown project 'nope'; known: home, conv"
  assert_equal "$(events worktree-added)" ""
  assert_equal "$(stub_calls th-lease.sh)" ""
}

@test "--add refuses a task that is unknown, legacy or closed" {
  run_bin -1 team-open --task T7 --add conv chore slug
  assert_contains "$output" "T7 is not open: the ledger has no opened event for it"
  ledger_line '{ts: "2026-10-01T00:00:00Z", task: "T8", event: "done", role: "builder", session: "s"}'
  run_bin -1 team-open --task T8 --add conv chore slug
  assert_contains "$output" "T8 is not open: the ledger has no opened event for it"

  run_bin -0 team-open home feature feat one "One"
  ledger_line '{ts: (now | todate), task: "T1", event: "closed", archive: [], returned: [], kept: []}'
  run_bin -1 team-open --task T1 --add conv chore slug
  assert_contains "$output" "T1 is closed"

  assert_equal "$(events worktree-added)" ""
  assert_equal "$(stub_calls th-lease.sh)" ""
  [[ ! -e $TEAM_HOME/tasks/T7 && ! -e $TEAM_HOME/tasks/T8 ]]
}

@test "--add refuses a project where the task already has an open worktree, until it is returned" {
  run_bin -0 team-open home feature feat one "One"
  run_bin -1 team-open --task T1 --add home chore two
  assert_contains "$output" "T1 already has an open worktree in home: ${home_slots[0]} (feat/T1-one)"
  [[ ! -e ${home_slots[1]} ]]

  run_bin -0 team-open --task T1 --add conv chore two
  run_bin -1 team-open --task T1 --add conv chore three
  assert_contains "$output" "T1 already has an open worktree in conv: ${conv_slots[0]} (chore/T1-two)"
  assert_equal "$(stub_calls th-lease.sh | wc -l)" "1"
  assert_equal "$(events worktree-added | wc -l)" "1"

  ledger_line --arg wt "${conv_slots[1]}" '{ts: (now | todate), task: "T1", event: "worktree-returned", project: "conv", worktree: $wt}'
  run_bin -1 team-open --task T1 --add conv chore three
  assert_contains "$output" "T1 already has an open worktree in conv: ${conv_slots[0]} (chore/T1-two)"
  ledger_line --arg wt "${conv_slots[0]}" '{ts: (now | todate), task: "T1", event: "worktree-returned", project: "conv", worktree: $wt}'
  run_bin -0 --separate-stderr team-open --task T1 --add conv chore three
  assert_equal "$(jq -r .worktree <<<"$output")" "${conv_slots[1]}"
  assert_equal "$(events worktree-added | jq -r .branch | paste -sd ' ')" "chore/T1-two chore/T1-three"
}

@test "with every git slot taken --add exits 75 naming the holders" {
  run_bin -0 team-open conv feature feat one "One"
  git -C "$home" worktree add -q "${home_slots[0]}" -b feat/T3-busy origin/main
  git -C "$home" worktree add -q --detach "${home_slots[1]}" origin/main
  run_bin -75 --separate-stderr team-open --task T1 --add home chore two
  assert_equal "$output" ""
  assert_equal "$stderr" "$(printf '%s\n' "team-open: every slot of home is taken:" \
    "  ${home_slots[0]}: T3 (feat/T3-busy)" "  ${home_slots[1]}: no task (detached HEAD)")"
  assert_equal "$(events worktree-added)" ""
}

@test "--add is held to the machine's cap: with no task slot it leases nothing, and a re-run once one frees adds it" {
  mkdir -p "$HOME/.config/agent-team"
  echo '{"cap": 1, "reserved": 0}' >"$HOME/.config/agent-team/slots.json"
  run_bin -0 team-open home feature feat one "One"
  run_bin -75 --separate-stderr team-open --task T1 --add conv chore two
  assert_equal "$output" ""
  assert_equal "$stderr" "team-open: no task slot for conv on this machine: 1 of 1 held
team-open: the cap is 1 (cap in ~/.config/agent-team/slots.json), effective 1: $(sampled_reason)
team-open: the slots:
  T1 home in ~/slots/home/1"
  assert_equal "$(stub_calls th-lease.sh)" ""
  assert_equal "$(events worktree-added)" ""
  echo '{"cap": 2, "reserved": 0}' >"$HOME/.config/agent-team/slots.json"
  run_bin -0 --separate-stderr team-open --task T1 --add conv chore two
  assert_equal "$(jq -r .worktree <<<"$output")" "${conv_slots[0]}"
}

@test "with the treehouse pool full --add exits 75 with the lease's message" {
  run_bin -0 team-open home feature feat one "One"
  : >"$BATS_TEST_TMPDIR/free"
  run_bin -75 --separate-stderr team-open --task T1 --add conv chore two
  assert_equal "$output" ""
  assert_contains "$stderr" "team-open: conv's lease command found no free slot:"
  assert_contains "$stderr" "all 2 worktrees are in use or dirty"
  assert_contains "$stderr" "  ${conv_slots[0]}: no task (detached HEAD)"
  assert_equal "$(events worktree-added)" ""
}

@test "--add returns and refuses a leased slot that is not clean" {
  run_bin -0 team-open home feature feat one "One"
  echo 'echo junk >stray.txt' >"$BATS_TEST_TMPDIR/prewarm"
  run_bin -1 --separate-stderr team-open --task T1 --add conv chore two
  assert_contains "$stderr" "the leased slot ${conv_slots[0]} is not clean: untracked files: stray.txt"
  assert_contains "$stderr" "handed ${conv_slots[0]} back to $conv/scripts/th-return.sh, discarding what its lease changed"
  assert_equal "$(pool_calls th-return.sh)" "${conv_slots[0]} --force --if-lease-holder T1"
  assert_equal "$(pool_leases)" ""
  run git -C "$conv" branch --list 'chore/T1-two'
  assert_equal "$output" ""
  assert_equal "$(events worktree-added)" ""
}

@test "--add refuses a project whose git does not ignore the task directory, removing the slot" {
  run_bin -0 team-open conv feature feat one "One"
  git -C "$home" rm -q .gitignore
  git -C "$home" commit -q -m "chore: stop ignoring scratch"
  git -C "$home" push -q origin main
  run_bin -1 team-open --task T1 --add home chore two
  assert_contains "$output" "git does not ignore .scratch/task in home"
  [[ ! -e ${home_slots[0]} ]]
  run git -C "$home" branch --list 'chore/T1-two'
  assert_equal "$output" ""
  assert_equal "$(events worktree-added)" ""
  [[ -d $TEAM_HOME/tasks/T1 ]]
}

@test "after a failure once the slot holds the branch, re-running --add finishes in that slot" {
  [[ $EUID -ne 0 ]] || skip "root ignores the lock file's permissions"
  run_bin -0 team-open conv feature feat one "One"
  chmod 000 "$TEAM_HOME/ledger.jsonl.lock"
  run_bin -1 --separate-stderr team-open --task T1 --add home chore two
  assert_contains "$stderr" "T1 is half open in ${home_slots[0]}; finish it with: team-open --task T1 --add home chore two"
  assert_equal "$(git -C "${home_slots[0]}" rev-parse --abbrev-ref HEAD)" "chore/T1-two"
  chmod 644 "$TEAM_HOME/ledger.jsonl.lock"

  run_bin -0 --separate-stderr team-open --task T1 --add home chore two
  assert_equal "$(jq -r .worktree <<<"$output")" "${home_slots[0]}"
  [[ ! -e ${home_slots[1]} ]]
  assert_equal "$(events worktree-added | jq -r .worktree)" "${home_slots[0]}"
}

@test "--add lists the other open tasks in the added project, with their titles" {
  run_bin -0 team-open home feature feat one "One"
  ledger_line '{ts: (now | todate), task: "T2", event: "opened", project: "conv", path: "small", type: "fix",
    title: "Still going", branch: "fix/T2-going", base: "main", base_sha: "abc1234", worktree: "/w/2"}'
  ledger_line '{ts: (now | todate), task: "T3", event: "opened", project: "home", path: "small", type: "fix",
    title: "From home", branch: "fix/T3-x", base: "main", base_sha: "abc1234", worktree: "/w/3"}'
  ledger_line '{ts: (now | todate), task: "T3", event: "worktree-added", project: "conv", branch: "chore/T3-y",
    base: "main", base_sha: "abc1234", worktree: "/w/4"}'
  ledger_line '{ts: (now | todate), task: "T4", event: "opened", project: "conv", path: "small", type: "fix",
    title: "Gone back", branch: "fix/T4-z", base: "main", base_sha: "abc1234", worktree: "/w/5"}'
  ledger_line '{ts: (now | todate), task: "T4", event: "worktree-returned", project: "conv", worktree: "/w/5"}'
  run_bin -0 --separate-stderr team-open --task T1 --add conv chore two
  assert_equal "$stderr" "$(printf '%s\n' "team-open: other open tasks in conv:" \
    "  T2 fix/T2-going in /w/2: Still going" "    no branch yet" "  T3 chore/T3-y in /w/4: From home" "    no branch yet")"
}
