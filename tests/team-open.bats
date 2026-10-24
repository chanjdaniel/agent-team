#!/usr/bin/env bats
# team-open: opening a task for a project with a git worktree pool.

load helpers/common

setup() {
  sandbox
  primary=$(make_repo proj)
  echo ".scratch/" >"$primary/.gitignore"
  git -C "$primary" add .gitignore
  git -C "$primary" commit -q -m "chore: ignore scratch"
  git -C "$primary" push -q origin main
  slots=$HOME/slots/proj
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1", "slots/proj/2"]
TOML
  stub_reply curl '{"id":"1563000000000000001"}'
}

# The events of one kind in the sandbox ledger, one compact object per line.
events() {
  jq -c --arg e "$1" 'select(.event == $e)' "$TEAM_HOME/ledger.jsonl"
}

# Push a commit to origin's main from a second clone, so the primary checkout falls behind.
advance_origin() {
  local other=$BATS_TEST_TMPDIR/other
  [[ -d $other ]] || git clone -q "$BATS_TEST_TMPDIR/origin/proj.git" "$other" 2>/dev/null
  git -C "$other" pull -q
  git -C "$other" commit -q --allow-empty -m "feat: $1"
  git -C "$other" push -q origin main
  git -C "$other" rev-parse HEAD
}

@test "a task opens in the first slot, on a new branch from the fetched base" {
  run_bin -0 --separate-stderr team-open proj feature feat team-tooling "The team's own tooling"
  local worktree=$slots/1 base_sha
  base_sha=$(git -C "$primary" rev-parse origin/main)

  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg wt "$worktree" --arg sha "$base_sha" --arg home "$TEAM_HOME" '{
    task: "T1", project: "proj", path: "feature", title: "The team'"'"'s own tooling",
    branch: "feat/T1-team-tooling", base: "main", base_sha: $sha, worktree: $wt,
    task_dir: "\($wt)/.scratch/task", thread: "1563000000000000001", plan: "\($home)/tasks/T1/plan.md"}')"

  assert_equal "$(git -C "$worktree" rev-parse --abbrev-ref HEAD)" "feat/T1-team-tooling"
  assert_equal "$(git -C "$worktree" rev-parse HEAD)" "$base_sha"
  run -128 git -C "$worktree" rev-parse --abbrev-ref '@{upstream}'
  [[ -d $worktree/.scratch/task ]]
  assert_equal "$(git -C "$worktree" status --porcelain)" ""

  assert_equal "$(stub_calls curl | wc -l)" "1"
  assert_equal "$(stub_calls curl | jq -r 'index("-d") as $i | .[$i + 1] | fromjson | .name')" \
    "T1 · proj · The team's own tooling"
  assert_equal "$(events thread | jq -r .discord_thread)" "1563000000000000001"
  assert_equal "$(events opened | jq -c 'del(.ts)')" "$(jq -cn --arg wt "$worktree" --arg sha "$base_sha" '{
    task: "T1", event: "opened", project: "proj", path: "feature", type: "feat",
    title: "The team'"'"'s own tooling", branch: "feat/T1-team-tooling", base: "main",
    base_sha: $sha, worktree: $wt}')"
  run_bin -0 team-log --check
}

@test "the plan is written from the template with the task's facts" {
  run_bin -0 team-open proj bug fix sign-in-limit "Rate-limit sign-in & codes"
  local plan=$TEAM_HOME/tasks/T1/plan.md
  assert_equal "$(sed -n 1p "$plan")" "# T1: Rate-limit sign-in & codes"
  assert_equal "$(sed -n 3p "$plan")" "High-level plan, by the coordinator, $(date +%F)."
  assert_equal "$(sed -n 4p "$plan")" 'Project: proj, base `main`, branch `fix/T1-sign-in-limit`.'
  assert_equal "$(sed -n 5p "$plan")" 'Path: bug.'
  assert_equal "$(grep '^## ' "$plan")" "$(printf '%s\n' '## Goal' '## Why' '## Scope' '## Acceptance criteria' '## Not in scope')"
  run grep -c '{{' "$plan"
  assert_equal "$output" "0"
}

@test "a retro opens with the retro path on a research branch" {
  run_bin -0 --separate-stderr team-open proj retro research retro-2026-10-25 "Retro 2026-10-25"
  assert_equal "$(jq -r '[.path, .branch] | join(" ")' <<<"$output")" "retro research/T1-retro-2026-10-25"
  assert_equal "$(events opened | jq -r '[.path, .type, .title] | join(" ")')" "retro research Retro 2026-10-25"
  assert_equal "$(sed -n 5p "$TEAM_HOME/tasks/T1/plan.md")" 'Path: retro.'
  run_bin -0 team-log --check
}

@test "the plan is filled in one pass, so a title is never read for placeholders itself" {
  run_bin -0 team-open proj small chore q-and-a 'Q&A {{date}} and {{task}}'
  assert_equal "$(sed -n 1p "$TEAM_HOME/tasks/T1/plan.md")" '# T1: Q&A {{date}} and {{task}}'
}

@test "two runs in a row take the next two numbers and the next two slots" {
  printf '%s\n' '{"ts":"2026-10-01T00:00:00Z","task":"T7","event":"done","role":"builder","session":"s"}' >"$TEAM_HOME/ledger.jsonl"
  mkdir -p "$TEAM_HOME/tasks/T9" "$TEAM_HOME/tasks/T0"
  run_bin -0 --separate-stderr team-open proj feature feat first "First"
  assert_equal "$(jq -r '"\(.task) \(.branch) \(.worktree)"' <<<"$output")" "T10 feat/T10-first $slots/1"
  stub_reply curl '{"id":"1563000000000000002"}'
  run_bin -0 --separate-stderr team-open proj small chore second "Second"
  assert_equal "$(jq -r '"\(.task) \(.branch) \(.worktree) \(.thread)"' <<<"$output")" \
    "T11 chore/T11-second $slots/2 1563000000000000002"
  [[ -d $TEAM_HOME/tasks/T10 && -d $TEAM_HOME/tasks/T11 ]]
  assert_equal "$(events opened | jq -r .task | paste -sd ' ')" "T10 T11"
}

@test "--task opens that number and keeps its existing plan" {
  mkdir -p "$TEAM_HOME/tasks/T13"
  echo "# T13: written by hand" >"$TEAM_HOME/tasks/T13/plan.md"
  run_bin -0 --separate-stderr team-open --task T13 proj feature feat fixes "Fixes from T4"
  assert_equal "$(jq -r '"\(.task) \(.branch) \(.plan)"' <<<"$output")" \
    "T13 feat/T13-fixes $TEAM_HOME/tasks/T13/plan.md"
  assert_equal "$(cat "$TEAM_HOME/tasks/T13/plan.md")" "# T13: written by hand"
  assert_equal "$(events opened | jq -r .task)" "T13"
}

@test "--task refuses a task that is already open" {
  run_bin -0 team-open --task T5 proj feature feat one "One"
  run_bin -1 team-open --task T5 proj feature feat one "One"
  assert_contains "$output" "T5 is already open"
  assert_equal "$(events opened | wc -l)" "1"
  assert_equal "$(stub_calls curl | wc -l)" "1"
  assert_equal "$(git -C "$primary" worktree list | wc -l)" "2"
}

@test "malformed arguments are usage errors that change nothing" {
  run_bin -2 team-open proj feature feat slug
  assert_contains "$output" "usage: team-open [--task T<n>] <project> <path> <type> <slug> <title...>"
  run_bin -2 team-open proj feature feat slug "  "
  run_bin -2 team-open --task
  run_bin -2 team-open --task 13 proj feature feat slug "Title"
  assert_contains "$output" "task must look like T<n>, got '13'"
  run_bin -2 team-open proj hotfix feat slug "Title"
  assert_contains "$output" "path must be feature, bug, small, research or retro, got 'hotfix'"
  run_bin -2 team-open proj feature feature slug "Title"
  assert_contains "$output" "type must be feat, fix, docs, chore, build, ci, test, refactor, perf or research, got 'feature'"
  local slug
  for slug in Upper under_score -lead trail- double--dash "with space" "$(printf 'a%.0s' {1..41})"; do
    run_bin -2 team-open proj feature feat "$slug" "Title"
    assert_contains "$output" "slug must be lower-case kebab case of at most 40 characters"
  done
  run_bin -0 team-open proj feature feat "$(printf 'a%.0s' {1..40})" "Title"
  run_bin -2 team-open nope feature feat slug "Title"
  assert_contains "$output" "unknown project 'nope'; known: proj"
  assert_equal "$(events opened | wc -l)" "1"
  assert_equal "$(find "$TEAM_HOME/tasks" -mindepth 1 -printf '%P\n' | sort | paste -sd ' ')" "T1 T1/plan.md"
}

@test "a broken registry is refused" {
  echo 'junk = [' >>"$TEAM_HOME/projects.toml"
  run_bin -1 team-open proj feature feat slug "Title"
  assert_equal "$(stub_calls curl)" ""
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
}

@test "the branch starts at the fetched origin base even when the local base is behind" {
  local ahead
  ahead=$(advance_origin "moved on")
  [[ $(git -C "$primary" rev-parse main) != "$ahead" ]]
  run_bin -0 --separate-stderr team-open proj feature feat late "Late"
  assert_equal "$(jq -r .base_sha <<<"$output")" "$ahead"
  assert_equal "$(git -C "$slots/1" rev-parse HEAD)" "$ahead"
  assert_equal "$(git -C "$primary" rev-parse origin/main)" "$ahead"
  run -128 git -C "$slots/1" rev-parse --abbrev-ref '@{upstream}'
}

@test "with branch.autoSetupMerge=always the branch still has no upstream" {
  git config --global branch.autoSetupMerge always
  run_bin -0 team-open proj feature feat track "Track"
  run -128 git -C "$slots/1" rev-parse --abbrev-ref '@{upstream}'
}

@test "a slot that is already a registered worktree is skipped" {
  git -C "$primary" worktree add -q "$slots/1" -b someone-else origin/main
  run_bin -0 --separate-stderr team-open proj feature feat next "Next"
  assert_equal "$(jq -r .worktree <<<"$output")" "$slots/2"
  assert_equal "$(git -C "$slots/1" rev-parse --abbrev-ref HEAD)" "someone-else"
}

@test "with every slot taken it exits 75 naming the holders, and gives the number back" {
  git -C "$primary" worktree add -q "$slots/1" -b feat/T3-busy origin/main
  git -C "$primary" worktree add -q --detach "$slots/2" origin/main
  git -C "$primary" worktree add -q "$HOME/elsewhere" -b spare origin/main
  run_bin -75 --separate-stderr team-open proj feature feat late "Late"
  assert_equal "$output" ""
  assert_equal "$stderr" "$(printf '%s\n' "team-open: every slot of proj is taken:" \
    "  $slots/1: T3 (feat/T3-busy)" "  $slots/2: no task (detached HEAD)")"
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
  assert_equal "$(git -C "$HOME/elsewhere" rev-parse --abbrev-ref HEAD)" "spare"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "the task's branch checked out outside the slots is refused" {
  git -C "$primary" worktree add -q "$HOME/elsewhere" -b feat/T4-x origin/main
  run_bin -1 team-open --task T4 proj feature feat x "X"
  assert_contains "$output" "feat/T4-x is checked out in $HOME/elsewhere, which is not one of proj's slots"
  assert_equal "$(git -C "$primary" worktree list | wc -l)" "2"
}

@test "a task directory git does not ignore is refused and the slot removed again" {
  git -C "$primary" rm -q .gitignore
  git -C "$primary" commit -q -m "chore: stop ignoring scratch"
  git -C "$primary" push -q origin main
  run_bin -1 team-open proj feature feat leak "Leak"
  assert_contains "$output" "git does not ignore .scratch/task in proj"
  [[ ! -e $slots/1 ]]
  assert_equal "$(git -C "$primary" worktree list | wc -l)" "1"
  run git -C "$primary" branch --list 'feat/T1-leak'
  assert_equal "$output" ""
  [[ ! -e $TEAM_HOME/tasks/T1 ]]
  assert_equal "$(stub_calls curl)" ""
}

@test "re-running with --task after the thread failed finishes the task in the same slot" {
  stub_reply curl '{"message":"Missing Access"}'
  run_bin -1 --separate-stderr team-open proj feature feat flaky "Flaky Discord"
  assert_contains "$stderr" "Discord did not return a thread id"
  assert_contains "$stderr" "T1 is half open in $slots/1; finish it with: team-open --task T1 proj feature feat flaky Flaky\\ Discord"
  assert_equal "$(git -C "$slots/1" rev-parse --abbrev-ref HEAD)" "feat/T1-flaky"
  echo "# T1: edited before the retry" >"$TEAM_HOME/tasks/T1/plan.md"
  advance_origin "moved on" >/dev/null
  local start
  start=$(git -C "$slots/1" rev-parse HEAD)

  stub_reply curl '{"id":"1563000000000000009"}'
  run_bin -0 --separate-stderr team-open --task T1 proj feature feat flaky "Flaky Discord"
  assert_equal "$(jq -r '"\(.worktree) \(.thread) \(.base_sha)"' <<<"$output")" "$slots/1 1563000000000000009 $start"
  assert_equal "$(git -C "$primary" worktree list | wc -l)" "2"
  [[ ! -e $slots/2 ]]
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/plan.md")" "# T1: edited before the retry"
  assert_equal "$(stub_calls curl | wc -l)" "2"
  assert_equal "$(events thread | wc -l)" "1"
  assert_equal "$(events opened | jq -r '"\(.worktree) \(.base_sha)"')" "$slots/1 $start"
}

@test "stderr lists the other open tasks in the same project only, with paths on this machine" {
  cat >"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-22T02:00:00Z","task":"T2","event":"opened","project":"proj","path":"small","type":"fix","title":"Still going","branch":"fix/T2-going","base":"main","base_sha":"abc1234","worktree":"/Users/someone/w/2"}
{"ts":"2026-10-22T02:00:01Z","task":"T3","event":"opened","project":"proj","path":"small","type":"fix","title":"Done now","branch":"fix/T3-done","base":"main","base_sha":"abc1234","worktree":"/w/3"}
{"ts":"2026-10-22T02:00:02Z","task":"T4","event":"opened","project":"other","path":"small","type":"fix","title":"Elsewhere","branch":"fix/T4-x","base":"main","base_sha":"abc1234","worktree":"/w/4"}
{"ts":"2026-10-22T02:00:03Z","task":"T4","event":"worktree-added","project":"proj","branch":"chore/T4-y","base":"main","base_sha":"abc1234","worktree":"/w/5"}
{"ts":"2026-10-22T02:00:04Z","task":"T3","event":"closed","archive":[],"returned":[],"kept":[]}
LEDGER
  run_bin -0 --separate-stderr team-open proj feature feat new "New"
  assert_equal "$(jq -r .task <<<"$output")" "T5"
  assert_equal "$stderr" "$(printf '%s\n' "team-open: other open tasks in proj:" \
    "  T2 fix/T2-going in $HOME/w/2: Still going" "  T4 chore/T4-y in /w/5: Elsewhere")"
}

@test "the Discord token never reaches the output" {
  run_bin -0 team-open proj feature feat secret "Secret"
  [[ $output != *"$FAKE_DISCORD_TOKEN"* ]]
  stub_reply curl '' 22
  run_bin -1 team-open proj feature feat secret-two "Secret"
  [[ $output != *"$FAKE_DISCORD_TOKEN"* ]]
}

@test "the task's branch existing with no worktree is refused" {
  git -C "$primary" branch feat/T6-x origin/main
  run_bin -1 team-open --task T6 proj feature feat x "X"
  assert_contains "$output" "branch feat/T6-x already exists in $primary but no slot holds it"
  [[ ! -e $slots/1 ]]
}
