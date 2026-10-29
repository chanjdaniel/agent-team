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

teardown() {
  # Let a slot lock holder a test left go, so bats does not wait on it.
  touch "$BATS_TEST_TMPDIR/release"
  wait 2>/dev/null || true
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
  assert_equal "$(grep '^## ' "$plan")" "$(printf '%s\n' '## Goal' '## Why' '## Scope' '## Acceptance criteria' '## Not in scope' '## Disclosure')"
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

@test "a primary checkout on the base, clean and behind, is fast-forwarded to origin's, untracked files aside" {
  local ahead
  ahead=$(advance_origin "moved on")
  touch "$primary/notes.txt"
  run_bin -0 --separate-stderr team-open proj feature feat late "Late"
  assert_contains "$stderr" "team-open: the primary checkout $primary: main fast-forwarded to ${ahead:0:7}"
  assert_equal "$(grep -c 'primary checkout' <<<"$stderr")" 1
  assert_equal "$(git -C "$primary" rev-parse main)" "$ahead"
  assert_equal "$(git -C "$primary" status --porcelain)" "?? notes.txt"
  # Level with origin's, there is nothing to say.
  run_bin -0 --separate-stderr team-open proj feature feat later "Later"
  assert_equal "$(grep -c 'primary checkout' <<<"$stderr")" 0
}

@test "a primary checkout off the base, with local changes or ahead of origin's is left as it is, with the reason" {
  local ahead before
  sed -i 's|^slots = .*|slots = ["slots/proj/1", "slots/proj/2", "slots/proj/3"]|' "$TEAM_HOME/projects.toml"
  ahead=$(advance_origin "moved on")
  before=$(git -C "$primary" rev-parse main)
  git -C "$primary" switch -q -c elsewhere
  run_bin -0 --separate-stderr team-open proj feature feat one "One"
  assert_contains "$stderr" "team-open: the primary checkout $primary is left as it is: it is on elsewhere, not main"
  git -C "$primary" switch -q main
  echo changed >"$primary/README.md"
  run_bin -0 --separate-stderr team-open proj feature feat two "Two"
  assert_contains "$stderr" "team-open: the primary checkout $primary is left as it is: it has local changes to README.md"
  assert_equal "$(git -C "$primary" rev-parse main)" "$before"
  git -C "$primary" checkout -q README.md
  git -C "$primary" merge -q --ff-only origin/main
  git -C "$primary" commit -q --allow-empty -m "feat: only here"
  before=$(git -C "$primary" rev-parse main)
  run_bin -0 --separate-stderr team-open proj feature feat three "Three"
  assert_contains "$stderr" "team-open: the primary checkout $primary is left as it is: main has 1 commit origin's lacks"
  assert_equal "$(git -C "$primary" rev-parse main)" "$before"
  [[ $ahead == "$(git -C "$primary" rev-parse origin/main)" ]]
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

@test "slots the registry spells otherwise than git lists them are the same slots (report F6)" {
  mkdir -p "$slots"
  local other
  other=$(other_spelling "$HOME/slots")
  sed -i "s#\"slots/proj/#\"${other##*/}/proj/#g" "$TEAM_HOME/projects.toml"
  # git lists slot 1 as it was added, by the other spelling.
  git -C "$primary" worktree add -q "$slots/1" -b feat/T3-busy origin/main
  run_bin -0 --separate-stderr team-open proj feature feat next "Next"
  assert_equal "$(jq -r .worktree <<<"$output")" "$other/proj/2"
  run_bin -75 --separate-stderr team-open proj feature feat late "Late"
  assert_equal "$stderr" "$(printf '%s\n' "team-open: every slot of proj is taken:" \
    "  $other/proj/1: T3 (feat/T3-busy)" "  $other/proj/2: T1 (feat/T1-next)")"

  # A half-open task is finished in the slot holding its branch.
  git -C "$primary" worktree remove "$slots/1"
  stub_reply curl '{"message":"Missing Access"}'
  run_bin -1 --separate-stderr team-open proj feature feat flaky "Flaky"
  stub_reply curl '{"id":"1563000000000000009"}'
  run_bin -0 --separate-stderr team-open --task T2 proj feature feat flaky "Flaky"
  assert_equal "$(jq -r .worktree <<<"$output")" "$other/proj/1"
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
    "  T2 fix/T2-going in $HOME/w/2: Still going" "    no branch yet" \
    "  T4 chore/T4-y in /w/5: Elsewhere" "    no branch yet")"
}

@test "under each other open task, stderr lists the files its branch changes against the base" {
  # T2 pushed its branch, then made a commit it has not pushed; T3 has only a local branch;
  # T4 has no branch; T5's branch changes nothing yet. The base then moves on.
  git -C "$primary" branch -q --no-track fix/T3-local origin/main
  git -C "$primary" branch -q --no-track fix/T5-same origin/main
  local clone=$BATS_TEST_TMPDIR/work
  git clone -q "$BATS_TEST_TMPDIR/origin/proj.git" "$clone" 2>/dev/null
  git -C "$clone" switch -q -c fix/T2-pushed
  mkdir -p "$clone/bin" "$clone/docs"
  echo a >"$clone/bin/a" && echo b >"$clone/docs/b"
  git -C "$clone" add bin/a docs/b && git -C "$clone" commit -q -m "fix: a and b"
  git -C "$clone" push -q origin fix/T2-pushed
  git -C "$clone" push -q origin origin/main:refs/heads/fix/T5-same
  git -C "$primary" fetch -q origin "+refs/heads/fix/T2-pushed:refs/heads/fix/T2-pushed"
  git -C "$primary" worktree add -q "$BATS_TEST_TMPDIR/t2" fix/T2-pushed
  echo c >"$BATS_TEST_TMPDIR/t2/unpushed"
  git -C "$BATS_TEST_TMPDIR/t2" add unpushed && git -C "$BATS_TEST_TMPDIR/t2" commit -q -m "fix: unpushed"
  git -C "$primary" worktree add -q "$BATS_TEST_TMPDIR/t3" fix/T3-local
  echo d >"$BATS_TEST_TMPDIR/t3/local"
  git -C "$BATS_TEST_TMPDIR/t3" add local && git -C "$BATS_TEST_TMPDIR/t3" commit -q -m "fix: local"
  git -C "$clone" switch -q main
  echo e >"$clone/base-only" && git -C "$clone" add base-only && git -C "$clone" commit -q -m "feat: base"
  git -C "$clone" push -q origin main
  local base
  base=$(git -C "$clone" rev-parse HEAD)
  cat >"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-22T02:00:00Z","task":"T2","event":"opened","project":"proj","path":"small","type":"fix","title":"Pushed","branch":"fix/T2-pushed","base":"main","base_sha":"abc1234","worktree":"/w/2"}
{"ts":"2026-10-22T02:00:01Z","task":"T3","event":"opened","project":"proj","path":"small","type":"fix","title":"Local","branch":"fix/T3-local","base":"main","base_sha":"abc1234","worktree":"/w/3"}
{"ts":"2026-10-22T02:00:02Z","task":"T4","event":"opened","project":"proj","path":"small","type":"fix","title":"Not yet","branch":"fix/T4-none","base":"main","base_sha":"abc1234","worktree":"/w/4"}
{"ts":"2026-10-22T02:00:03Z","task":"T5","event":"opened","project":"proj","path":"small","type":"fix","title":"Same","branch":"fix/T5-same","base":"main","base_sha":"abc1234","worktree":"/w/5"}
LEDGER
  run_bin -0 --separate-stderr team-open proj feature feat new "New"
  # The primary checkout follows the moved base before the listing.
  assert_equal "$stderr" "$(printf '%s\n' "team-open: the primary checkout $primary: main fast-forwarded to ${base:0:7}" \
    "team-open: other open tasks in proj:" \
    "  T2 fix/T2-pushed in /w/2: Pushed" "    changes against main (origin's branch):" "      bin/a" "      docs/b" \
    "  T3 fix/T3-local in /w/3: Local" "    changes against main (the local branch, not pushed):" "      local" \
    "  T4 fix/T4-none in /w/4: Not yet" "    no branch yet" \
    "  T5 fix/T5-same in /w/5: Same" "    no changes against main yet")"
}

@test "the other tasks' local branches are listed when origin cannot be read after the open" {
  git -C "$primary" branch -q --no-track fix/T2-local origin/main
  git -C "$primary" worktree add -q "$BATS_TEST_TMPDIR/t2" fix/T2-local
  echo a >"$BATS_TEST_TMPDIR/t2/a"
  git -C "$BATS_TEST_TMPDIR/t2" add a && git -C "$BATS_TEST_TMPDIR/t2" commit -q -m "fix: a"
  cat >"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-22T02:00:00Z","task":"T2","event":"opened","project":"proj","path":"small","type":"fix","title":"Local","branch":"fix/T2-local","base":"main","base_sha":"abc1234","worktree":"/w/2"}
LEDGER
  # Origin goes away while the thread is made, after the base was fetched.
  cat >"$STUB_FIXTURES/curl.sh" <<FIXTURE
mv "$BATS_TEST_TMPDIR/origin/proj.git" "$BATS_TEST_TMPDIR/origin/gone.git" 2>/dev/null || true
cat "\$STUB_FIXTURES/curl.out"
FIXTURE
  run_bin -0 --separate-stderr team-open proj feature feat new "New"
  assert_equal "$(jq -r .task <<<"$output")" "T3"
  assert_contains "$stderr" "team-open: cannot read the other tasks' branches from origin; their local branches are shown"
  assert_contains "$stderr" "$(printf '%s\n' "  T2 fix/T2-local in /w/2: Local" \
    "    changes against main (the local branch, not pushed):" "      a")"
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

# Make agent-team the reserved project, as on Daniel's machines: the code checkout is its primary
# checkout, registered beside proj with a git pool of one slot; and name the machine home-pc.
reserve_agent_team() {
  local code
  code=$(make_repo agent-team dev)
  echo ".scratch/" >"$code/.gitignore"
  git -C "$code" add .gitignore
  git -C "$code" commit -q -m "chore: ignore scratch"
  git -C "$code" push -q origin dev
  code_checkout "$code"
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'

[agent-team]
repo = "owner/agent-team"
path = "projects/agent-team"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[agent-team.pool]
provider = "git"
slots = ["slots/agent-team/1"]
TOML
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
}

# holding <project> <first> <last>: the open tasks T<first> to T<last> of <project>, each holding
# a slot in the ledger at ~/elsewhere/<project>/<n>.
holding() {
  local n
  for ((n = $2; n <= $3; n++)); do
    jq -cn --arg task "T$n" --arg p "$1" --arg wt "$HOME/elsewhere/$1/$n" \
      '{ts: "2026-10-29T10:00:00Z", task: $task, event: "opened", project: $p, path: "feature", type: "feat",
        title: "Held", branch: "feat/\($task)-held", base: "main", base_sha: "abc1234", worktree: $wt}' \
      >>"$TEAM_HOME/ledger.jsonl"
  done
}

@test "with cap 10 and 9 slots held by other projects, a task is refused naming the reserved slot and every holder, and agent-team's opens" {
  reserve_agent_team
  echo '{"cap": 10}' >"$HOME/.config/agent-team/slots.json"
  holding proj 1 9
  run_bin -75 --separate-stderr team-open proj feature feat late "Late"
  assert_equal "$output" ""
  local expected n
  expected="team-open: no task slot for proj on home-pc: 9 of 10 held, and the last one is kept for agent-team (reserved 1)
team-open: the cap is 10 (cap in ~/.config/agent-team/slots.json), effective 10: no reading of the machine's load yet
team-open: the slots:"
  for n in 1 2 3 4 5 6 7 8 9; do expected+=$'\n'"  T$n proj in ~/elsewhere/proj/$n"; done
  assert_equal "$stderr" "$expected"
  [[ ! -e $slots/1 && ! -e $TEAM_HOME/tasks/T10 ]]
  assert_equal "$(git -C "$primary" branch --list 'feat/T10-*')" ""
  assert_equal "$(events opened | wc -l)" "9"
  assert_equal "$(stub_calls curl)" ""

  run_bin -0 --separate-stderr team-open agent-team feature feat self "Self"
  assert_equal "$(jq -r '"\(.task) \(.worktree)"' <<<"$output")" "T10 $HOME/slots/agent-team/1"
}

@test "with agent-team holding 3 and others 6 at cap 10, another project opens the tenth, then every project is refused for the cap" {
  reserve_agent_team
  echo '{"cap": 10}' >"$HOME/.config/agent-team/slots.json"
  holding agent-team 1 3
  holding proj 4 9
  run_bin -0 --separate-stderr team-open proj feature feat tenth "Tenth"
  assert_equal "$(jq -r '"\(.task) \(.worktree)"' <<<"$output")" "T10 $slots/1"
  run_bin -75 --separate-stderr team-open proj feature feat late "Late"
  assert_equal "${stderr%%$'\n'*}" "team-open: no task slot for proj on home-pc: 10 of 10 held"
  [[ ! -e $slots/2 ]]
  # agent-team's pool has a free slot, but the cap is met first.
  run_bin -75 --separate-stderr team-open agent-team feature feat self "Self"
  assert_equal "${stderr%%$'\n'*}" "team-open: no task slot for agent-team on home-pc: 10 of 10 held"
  [[ ! -e $HOME/slots/agent-team/1 ]]
}

@test "a full pool is refused with its own message while the cap has room" {
  mkdir -p "$HOME/.config/agent-team"
  echo '{"cap": 10}' >"$HOME/.config/agent-team/slots.json"
  git -C "$primary" worktree add -q "$slots/1" -b feat/T3-busy origin/main
  git -C "$primary" worktree add -q "$slots/2" -b feat/T4-busy origin/main
  run_bin -75 --separate-stderr team-open proj feature feat late "Late"
  assert_equal "$stderr" "$(printf '%s\n' "team-open: every slot of proj is taken:" \
    "  $slots/1: T3 (feat/T3-busy)" "  $slots/2: T4 (feat/T4-busy)")"
}

@test "a half-open re-run whose slot holds its branch is never refused by the cap; a new task is" {
  mkdir -p "$HOME/.config/agent-team"
  echo '{"cap": 1, "reserved": 0}' >"$HOME/.config/agent-team/slots.json"
  stub_reply curl '{"message":"Missing Access"}'
  run_bin -1 --separate-stderr team-open proj feature feat flaky "Flaky"
  assert_contains "$stderr" "T1 is half open in $slots/1"
  stub_reply curl '{"id":"1563000000000000009"}'
  run_bin -75 --separate-stderr team-open proj feature feat late "Late"
  assert_equal "$stderr" "team-open: no task slot for proj on this machine: 1 of 1 held
team-open: the cap is 1 (cap in ~/.config/agent-team/slots.json), effective 1: no reading of the machine's load yet
team-open: the slots:
  T1 proj in ~/slots/proj/1 (half open)"
  run_bin -0 --separate-stderr team-open --task T1 proj feature feat flaky "Flaky"
  assert_equal "$(jq -r .worktree <<<"$output")" "$slots/1"
}

@test "a malformed slots.json refuses a new slot with the reason, taking none" {
  mkdir -p "$HOME/.config/agent-team"
  echo '{"cap": 0}' >"$HOME/.config/agent-team/slots.json"
  run_bin -1 --separate-stderr team-open proj feature feat late "Late"
  assert_equal "$stderr" "team-open: $HOME/.config/agent-team/slots.json: cap must be a whole number of 1 or more, not 0"
  [[ ! -e $slots/1 && ! -e $TEAM_HOME/tasks/T1 ]]
}

# hold_slot_lock <line>: hold the machine's slot lock in the background, its holder's line <line>,
# until $BATS_TEST_TMPDIR/release exists; returns once it is held.
hold_slot_lock() {
  local lock=$HOME/.local/state/agent-team/slots.lock
  mkdir -p "${lock%/*}"
  echo "$1" >"$lock"
  (
    exec {fd}<>"$lock"
    flock -x "$fd"
    touch "$BATS_TEST_TMPDIR/held"
    until [[ -e $BATS_TEST_TMPDIR/release ]]; do sleep 0.1; done
  ) 3>&- &
  until [[ -e $BATS_TEST_TMPDIR/held ]]; do sleep 0.1; done
}

@test "a slot lock held past wait_minutes exits 75 naming its holder, taking no slot" {
  local lock=$HOME/.local/state/agent-team/slots.lock
  mkdir -p "${lock%/*}" "$HOME/.config/agent-team"
  echo '{"wait_minutes": 0.02}' >"$HOME/.config/agent-team/slots.json"
  hold_slot_lock "team-open T7 conv (pid 7) since 2026-10-29 10:00:00 +0000"
  run_bin -75 --separate-stderr team-open proj feature feat late "Late"
  touch "$BATS_TEST_TMPDIR/release"
  assert_equal "$stderr" "team-open: waiting up to 0.02 minutes for the machine's slot lock, held by team-open T7 conv (pid 7) since 2026-10-29 10:00:00 +0000
team-open: the machine's slot lock is still held after 0.02 minutes, by team-open T7 conv (pid 7) since 2026-10-29 10:00:00 +0000"
  [[ ! -e $slots/1 && ! -e $TEAM_HOME/tasks/T1 ]]

  # Once it is free, a run takes it, writes its own line and lets it go when it ends.
  wait
  run_bin -0 --separate-stderr team-open proj feature feat late "Late"
  [[ $(cat "$lock") =~ ^team-open\ T1\ proj\ \(pid\ [0-9]+\)\ since\  ]]
  run -0 flock -n "$lock" true
}

@test "--help documents the machine's cap and its refusal" {
  run_bin -0 team-open --help
  assert_contains "$output" "The machine's cap on task slots, across every project, holds too"
  assert_contains "$output" "team-slots check under the machine's slot lock"
  assert_contains "$output" "Never refused by the cap"
}
