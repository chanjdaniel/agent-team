#!/usr/bin/env bats
# team-brief: a worker's brief rendered from templates/briefs/, the task's facts from the ledger
# and the registry, the rest from --set and --set-file. Projects conv (no-mistakes) and home
# (direct-pr); the team home is ~/agent-team, so its paths render as ~/... as in production.

load helpers/common

setup() {
  sandbox
  export TEAM_HOME=$HOME/agent-team
  mkdir -p "$TEAM_HOME/tasks"
  : >"$TEAM_HOME/ledger.jsonl"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[conv]
repo = "chanjdaniel/Conventioner"
path = "Documents/projects/personal/Conventioner"
base = "dev"
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
slots = [".treehouse/Conventioner-d4c77a/3/Conventioner", ".treehouse/Conventioner-d4c77a/4/Conventioner"]

[home]
repo = "chanjdaniel/agent-team"
path = "agent-team"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".work/task"
docs = []
toolkits = []

[home.pool]
provider = "git"
slots = ["agent-team/.claude/worktrees/1", "agent-team/.claude/worktrees/2"]
TOML
}

# event <task> <kind> '<jq object of the other fields>': append one ledger line.
event() {
  jq -cn --arg task "$1" --arg event "$2" "{ts: \"2026-10-22T10:00:00Z\", task: \$task, event: \$event} + $3" \
    >>"$TEAM_HOME/ledger.jsonl"
}

# open_task <task> <project> <path> <branch> <worktree under $HOME> <title>: the events team-open
# writes, with a thread.
open_task() {
  mkdir -p "$TEAM_HOME/tasks/$1"
  event "$1" opened "$(jq -cn --arg p "$2" --arg path "$3" --arg b "$4" --arg wt "$HOME/$5" --arg title "$6" \
    '{project: $p, path: $path, type: ($b | sub("/.*"; "")), title: $title, branch: $b, base: "dev",
      base_sha: "aba9d074", worktree: $wt}')"
  event "$1" thread '{discord_thread: "1563000000000000012"}'
}

# The T12 task of the real ledger: a small fix in Conventioner.
open_t12() {
  open_task T12 conv small fix/T12-applicant-sign-in-rate-limit .treehouse/Conventioner-d4c77a/4/Conventioner \
    "rate-limit the applicant sign-in endpoints"
}

# A task opened in conv with a worktree added in home.
open_two_projects() {
  open_task T5 conv feature chore/T5-move-planning-out .treehouse/Conventioner-d4c77a/3/Conventioner \
    "moving planning out"
  event T5 worktree-added "$(jq -cn --arg wt "$HOME/agent-team/.claude/worktrees/1" \
    '{project: "home", branch: "chore/T5-import-planning", base: "main", base_sha: "644a76b", worktree: $wt}')"
}

# The brief templates of this checkout, one name per line.
templates() {
  find "$REPO_ROOT/templates/briefs" -maxdepth 1 -name '*.md' -printf '%f\n' | sed 's/\.md$//' | sort
}

# A copy of this checkout's bin/ whose templates/briefs/ holds only the test's own templates.
fake_checkout() {
  code=$BATS_TEST_TMPDIR/code
  mkdir -p "$code/templates/briefs/delivery"
  cp -R "$REPO_ROOT/bin" "$code/bin"
}

run_fake() {
  guard_sandbox
  run "$code/bin/team-brief" "$@"
}

# Fail when grep finds a match, showing it.
refute_grep() {
  if grep -n "$@"; then return 1; fi
}

# Everything under the task's directory, for "nothing written".
task_files() {
  (cd "$TEAM_HOME/tasks" && find . -type f -printf '%P %s\n' | sort)
}

@test "the T12 brief is reproduced from builder-fix with three values" {
  open_t12
  run_bin -0 --separate-stderr team-brief T12 builder-fix \
    --set read='- `AGENTS.md` and the code it names.' \
    --set commits='`fix(applicants): ...`' \
    --set goal='rate-limit the applicant sign-in endpoints (per address and per IP, Mongo TTL counters, 429 with Retry-After), so Conventioner cannot be used to flood addresses with sign-in codes or to guess codes.'
  assert_equal "$output" "$TEAM_HOME/tasks/T12/brief.md"
  assert_equal "$stderr" ""
  local expected line=0
  expected=$(
    cat <<'EOF'
# T12 brief (builder): rate-limit the applicant sign-in endpoints

Path: small; you are the builder, then you deliver.
Project: conv (`chanjdaniel/Conventioner`), base `dev`.
Worktree: `~/.treehouse/Conventioner-d4c77a/4/Conventioner`, branch `fix/T12-applicant-sign-in-rate-limit` from `origin/dev`.
Task directory: `.scratch/task/` in the worktree (excluded from git), for your spec, tickets and notes.

## Read first

- The high-level plan: `~/agent-team/tasks/T12/plan.md`.
- `AGENTS.md` and the code it names.

## Do

1. Write the spec and tickets yourself in `.scratch/task/` if the work needs more than one commit; a small fix needs one or two tickets at most.
2. Commit types for this task: `fix(applicants): ...`.

## Deliver through no-mistakes

1. Run `/no-mistakes` with this intent: "T12: rate-limit the applicant sign-in endpoints (per address and per IP, Mongo TTL counters, 429 with Retry-After), so Conventioner cannot be used to flood addresses with sign-in codes or to guess codes."
2. The PR must target `dev`; if the gate opens it against another branch, retarget it to `dev` and close any duplicate.
3. When the gate returns checks-passed, send `T12 PR <full url>` to `coordinator`.

## Rules

Never the em dash in docs; refer to Daniel with they/them.
EOF
  )
  local -a want got
  mapfile -t want <<<"$expected"
  mapfile -t got <"$TEAM_HOME/tasks/T12/brief.md"
  for line in "${!want[@]}"; do
    assert_equal "${got[line]-<missing line $((line + 1))>}" "${want[line]}"
  done
  assert_equal "${#got[@]}" "${#want[@]}"
}

@test "every real template renders for each delivery with no placeholder left and no em dash" {
  assert_equal "$(templates | paste -sd ' ')" \
    "builder-deliver builder-fix builder-ticket planner-feature planner-research rereview retro reviewer"
  open_t12
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local task template keys sets key brief
  for task in T12 T14; do
    while IFS= read -r template; do
      # The refusal names what the template needs beyond the task's facts; a template the
      # facts fill alone (retro) renders at once.
      run_bin team-brief "$task" "$template" --name "$template"
      if ((status == 1)); then
        keys=$(sed -n 's/^team-brief: unfilled placeholders: //p' <<<"$output")
        [[ -n $keys ]]
        sets=()
        for key in ${keys//,/ }; do sets+=(--set "$key=value of $key"); done
        run_bin -0 team-brief "$task" "$template" --name "$template" "${sets[@]}"
      fi
      assert_equal "$status" 0
      brief=$TEAM_HOME/tasks/$task/brief-$template.md
      assert_equal "$output" "$brief"
      refute_grep '{{\|}}' "$brief"
      refute_grep $'—' "$brief"
      assert_contains "$(<"$brief")" "# $task brief ("
    done < <(templates)
  done
  # The delivery partial follows the project's delivery.
  assert_contains "$(<"$TEAM_HOME/tasks/T12/brief-builder-fix.md")" 'Run `/no-mistakes` with this intent: "T12: value of goal"'
  assert_contains "$(<"$TEAM_HOME/tasks/T14/brief-builder-deliver.md")" \
    'gh pr create --repo chanjdaniel/agent-team --base main --head feat/T14-team-tooling'
  refute_grep no-mistakes "$TEAM_HOME/tasks/T14/brief-builder-fix.md"
  refute_grep 'gh pr create' "$TEAM_HOME/tasks/T12/brief-builder-deliver.md"
}

@test "the retro brief renders from the task's facts alone, its digest first and read from team_bin" {
  open_task T31 home retro research/T31-retro-2026-10-25 agent-team/.claude/worktrees/3 "Retro 2026-10-25"
  run_bin -0 team-brief T31 retro
  local brief=$TEAM_HOME/tasks/T31/brief.md
  assert_equal "$output" "$brief"
  # The first item to read is the digest, from the team home's checkout and its live ledger.
  assert_equal "$(grep -m1 '^1\. ' "$brief")" \
    "1. First, the ledger's evidence for this retro's window, in both forms: \`$REPO_ROOT/bin/team-retro digest T31\` and \`$REPO_ROOT/bin/team-retro digest T31 --json\`."
  assert_contains "$(<"$brief")" 'Read `~/agent-team/sops/platform-gotchas.md` before your first command.'
  # What Daniel approved and the team has not built yet is read, so it is not proposed again.
  assert_contains "$(<"$brief")" '`~/agent-team/tasks/queued/`'
  assert_contains "$(<"$brief")" 'Never propose again what Daniel rejected at an earlier retro, or what is already approved and queued, unless there is new evidence, which you name.'
  assert_contains "$(<"$brief")" 'Send `T31 DONE .work/task/report.md` to `coordinator`.'
}

@test "no template repeats a rule from roles/" {
  local file sentence
  # The rules only the role files carry: attribution, denials, the gate's own rules, merging.
  for file in "$REPO_ROOT"/templates/briefs/*.md "$REPO_ROOT"/templates/briefs/delivery/*.md; do
    refute_grep -iE -e '--yes|co-authored|attribution|trailer|denied|hand-fix|/tdd|/implement|never merge|force-push|--force' \
      -e 'progress messages|order that overrides|only inside the task directory|write only there' "$file"
  done
  # And no sentence of a role file appears in a template.
  while IFS= read -r sentence; do
    refute_grep -rF -- "$sentence" "$REPO_ROOT/templates/briefs"
  done < <(sed -E 's/^[-#[:space:]]*//; s/\. /.\n/g' "$REPO_ROOT"/roles/*.md | awk 'length($0) > 30')
}

@test "the task's facts fill their placeholders, paths under HOME as ~/" {
  fake_checkout
  cat >"$code/templates/briefs/facts.md" <<'EOF'
task={{task}}
title={{title}}
path={{path}}
project={{project}}
repo={{repo}}
base={{base}}
branch={{branch}}
worktree={{worktree}}
task_dir={{task_dir}}
plan={{plan}}
thread={{thread}}
team_home={{team_home}}
team_bin={{team_bin}}
EOF
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling & more"
  run_fake T14 facts
  assert_equal "$status" 0
  assert_equal "$(<"$TEAM_HOME/tasks/T14/brief.md")" "task=T14
title=the team's tooling & more
path=feature
project=home
repo=chanjdaniel/agent-team
base=main
branch=feat/T14-team-tooling
worktree=~/agent-team/.claude/worktrees/2
task_dir=.work/task
plan=~/agent-team/tasks/T14/plan.md
thread=1563000000000000012
team_home=~/agent-team
team_bin=$code/bin"
}

@test "team_bin is this checkout's bin/, absolute even under HOME, as the allow rules name it" {
  local checkout=$HOME/agent-team
  mkdir -p "$checkout/templates/briefs/delivery"
  cp -R "$REPO_ROOT/bin" "$checkout/bin"
  echo '{{team_bin}}/team-review-status' >"$checkout/templates/briefs/bin.md"
  open_t12
  guard_sandbox
  run "$checkout/bin/team-brief" T12 bin
  assert_equal "$status" 0
  assert_equal "$(<"$TEAM_HOME/tasks/T12/brief.md")" "$HOME/agent-team/bin/team-review-status"
}

@test "paths outside HOME stay absolute" {
  fake_checkout
  echo '{{plan}} {{team_home}} {{worktree}}' >"$code/templates/briefs/paths.md"
  open_t12
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  HOME=$BATS_TEST_TMPDIR/elsewhere run_fake T12 paths
  assert_equal "$status" 0
  assert_equal "$(<"$TEAM_HOME/tasks/T12/brief.md")" \
    "$TEAM_HOME/tasks/T12/plan.md $TEAM_HOME $HOME/.treehouse/Conventioner-d4c77a/4/Conventioner"
}

@test "values are literal: placeholders, & and backslashes in a value are kept as written" {
  fake_checkout
  echo 'a={{a}} b={{b}}' >"$code/templates/briefs/x.md"
  open_t12
  run_fake T12 x --set a='{{b}} & \1 $HOME' --set b='{{task}}'
  assert_equal "$status" 0
  assert_equal "$(<"$TEAM_HOME/tasks/T12/brief.md")" 'a={{b}} & \1 $HOME b={{task}}'
}

@test "--set-file fills a placeholder with the file's text, without its final newline" {
  fake_checkout
  printf 'before\n{{checks}}\nafter\n' >"$code/templates/briefs/x.md"
  printf -- '- one\n- two\n\n' >"$BATS_TEST_TMPDIR/checks.md"
  open_t12
  run_fake T12 x --set-file checks="$BATS_TEST_TMPDIR/checks.md"
  assert_equal "$status" 0
  assert_equal "$(cat "$TEAM_HOME/tasks/T12/brief.md")" "before
- one
- two
after"
  run_fake T12 x --force --set-file checks="$BATS_TEST_TMPDIR/missing.md"
  assert_equal "$status" 1
  assert_contains "$output" "cannot read $BATS_TEST_TMPDIR/missing.md for checks"
}

@test "an empty value is refused: it would leave a hole" {
  fake_checkout
  echo '{{a}}' >"$code/templates/briefs/x.md"
  : >"$BATS_TEST_TMPDIR/empty.md"
  open_t12
  run_fake T12 x --set a=
  assert_equal "$status" 2
  assert_contains "$output" "--set a= has no value"
  run_fake T12 x --set-file a="$BATS_TEST_TMPDIR/empty.md"
  assert_equal "$status" 2
  assert_contains "$output" "$BATS_TEST_TMPDIR/empty.md is empty"
  assert_equal "$(task_files)" ""
}

@test "a two-project task needs --project, which picks that project's worktree and delivery" {
  open_two_projects
  run_bin -2 team-brief T5 builder-deliver --set goal=g
  assert_contains "$output" "T5 has open worktrees in conv and home; name one with --project"
  assert_equal "$(task_files)" ""

  run_bin -0 team-brief T5 builder-deliver --project home --set goal=g
  local brief
  brief=$(<"$TEAM_HOME/tasks/T5/brief.md")
  assert_contains "$brief" 'Project: home (`chanjdaniel/agent-team`), base `main`.'
  assert_contains "$brief" 'Worktree: `~/agent-team/.claude/worktrees/1`, branch `chore/T5-import-planning`.'
  assert_contains "$brief" 'Task directory: `.work/task/` in the worktree'
  assert_contains "$brief" 'gh pr create --repo chanjdaniel/agent-team --base main --head chore/T5-import-planning'

  run_bin -0 team-brief T5 builder-deliver --project conv --set goal=g --name conv
  brief=$(<"$TEAM_HOME/tasks/T5/brief-conv.md")
  assert_contains "$brief" 'Worktree: `~/.treehouse/Conventioner-d4c77a/3/Conventioner`, branch `chore/T5-move-planning-out`.'
  assert_contains "$brief" 'Run `/no-mistakes` with this intent: "T5: g"'

  run_bin -1 team-brief T5 builder-deliver --project other --set goal=g --name other
  assert_contains "$output" "T5 has no open worktree in other; its open worktrees: conv (~/.treehouse/Conventioner-d4c77a/3/Conventioner), home (~/agent-team/.claude/worktrees/1)"
  [[ ! -e $TEAM_HOME/tasks/T5/brief-other.md ]]
}

@test "a returned worktree no longer counts, so one open worktree needs no --project" {
  open_two_projects
  event T5 worktree-returned "$(jq -cn --arg wt "$HOME/agent-team/.claude/worktrees/1" '{project: "home", worktree: $wt}')"
  run_bin -0 team-brief T5 builder-deliver --set goal=g
  assert_contains "$(<"$TEAM_HOME/tasks/T5/brief.md")" 'branch `chore/T5-move-planning-out`'
  run_bin -0 team-brief T5 builder-deliver --project conv --set goal=g --force
}

@test "a task with no open worktree is refused" {
  open_t12
  event T12 worktree-returned "$(jq -cn --arg wt "$HOME/.treehouse/Conventioner-d4c77a/4/Conventioner" '{project: "conv", worktree: $wt}')"
  run_bin -1 team-brief T12 builder-fix --set read=r --set commits=c --set goal=g
  assert_contains "$output" "T12 has no open worktree"
  assert_equal "$(task_files)" ""
}

@test "every unfilled placeholder is named, and nothing is written" {
  open_t12
  run_bin -1 team-brief T12 builder-fix --set commits=c
  assert_equal "$output" "team-brief: unfilled placeholders: goal, read"
  assert_equal "$(task_files)" ""
}

@test "a --set key no placeholder uses is refused, and nothing is written" {
  open_t12
  echo text >"$BATS_TEST_TMPDIR/text.md"
  run_bin -1 team-brief T12 builder-fix --set read=r --set commits=c --set goal=g --set ticket=03 \
    --set-file zz="$BATS_TEST_TMPDIR/text.md"
  assert_equal "$output" "team-brief: no placeholder in builder-fix uses: ticket, zz"
  assert_equal "$(task_files)" ""
}

@test "a --set of one of the task's facts is refused" {
  open_t12
  run_bin -1 team-brief T12 builder-fix --set read=r --set commits=c --set goal=g --set base=main
  assert_equal "$output" "team-brief: base is one of the task's facts, filled from the ledger and the registry; it cannot be set"
  assert_equal "$(task_files)" ""
}

@test "an unknown template is refused, naming the known ones" {
  open_t12
  local name
  for name in builder plan delivery/no-mistakes ../plan; do
    run_bin -1 team-brief T12 "$name"
    assert_equal "$output" "team-brief: unknown template '$name'; known: $(templates | paste -sd ',' | sed 's/,/, /g')"
  done
  assert_equal "$(task_files)" ""
}

@test "a task that is not open is refused: no opened event, or closed" {
  event T4 thread '{discord_thread: "1"}'
  run_bin -1 team-brief T4 builder-ticket --set ticket=01
  assert_equal "$output" "team-brief: T4 is not open: the ledger has no opened event for it"
  run_bin -1 team-brief T9 builder-ticket --set ticket=01
  assert_equal "$output" "team-brief: T9 is not open: the ledger has no opened event for it"
  open_t12
  event T12 closed '{archive: [], returned: [], kept: []}'
  run_bin -1 team-brief T12 builder-fix --set read=r --set commits=c --set goal=g
  assert_equal "$output" "team-brief: T12 is closed"
  assert_equal "$(task_files)" ""
}

@test "an existing brief is kept unless --force, and the refusal points at --name for another" {
  open_t12
  echo "hand-written" >"$TEAM_HOME/tasks/T12/brief-build.md"
  run_bin -1 team-brief T12 builder-ticket --set ticket=01 --name build
  assert_equal "$output" "team-brief: $TEAM_HOME/tasks/T12/brief-build.md exists; pass --force to replace it, or --name <suffix> to write another brief"
  assert_equal "$(<"$TEAM_HOME/tasks/T12/brief-build.md")" "hand-written"
  run_bin -0 team-brief T12 builder-ticket --force --set ticket=01 --name build
  assert_equal "$output" "$TEAM_HOME/tasks/T12/brief-build.md"
  assert_contains "$(<"$TEAM_HOME/tasks/T12/brief-build.md")" "# T12 brief (builder): ticket 01 of"
  assert_equal "$(find "$TEAM_HOME/tasks/T12" -name '.brief*')" ""
}

@test "--name writes brief-<suffix>.md and must be kebab case" {
  open_t12
  run_bin -0 team-brief --name build-03 T12 builder-ticket --set ticket=03
  assert_equal "$output" "$TEAM_HOME/tasks/T12/brief-build-03.md"
  [[ -f $TEAM_HOME/tasks/T12/brief-build-03.md ]]
  local name
  for name in Build ../x a_b ''; do
    run_bin -2 team-brief T12 builder-ticket --set ticket=03 --name "$name"
    assert_contains "$output" "--name must be lower-case kebab case"
  done
}

@test "a malformed command line is a usage error, with nothing written" {
  open_t12
  run_bin -2 team-brief T12
  assert_contains "$output" "usage: team-brief T<n> <template>"
  run_bin -2 team-brief 12 builder-fix
  assert_contains "$output" "task must look like T<n>, got '12'"
  run_bin -2 team-brief T12 builder-fix extra
  assert_contains "$output" "usage: team-brief T<n> <template>"
  run_bin -2 team-brief T12 builder-fix --bogus
  assert_contains "$output" "unexpected argument '--bogus'"
  run_bin -2 team-brief T12 builder-fix --set read
  assert_contains "$output" "--set needs key=value, got 'read'"
  run_bin -2 team-brief T12 builder-fix --set Read=x
  assert_contains "$output" "--set needs key=value, got 'Read=x'"
  echo text >"$BATS_TEST_TMPDIR/text.md"
  run_bin -2 team-brief T12 builder-fix --set read=a --set-file read="$BATS_TEST_TMPDIR/text.md"
  assert_contains "$output" "read is set twice"
  run_bin -2 team-brief T12 builder-fix --project
  assert_contains "$output" "--project needs a value"
  assert_equal "$(task_files)" ""
}
