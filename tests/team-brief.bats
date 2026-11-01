#!/usr/bin/env bats
# team-brief: a worker's brief rendered from templates/briefs/, the task's facts from the ledger
# and the registry, the rest from --set and --set-file. Projects conv (no-mistakes) and home
# (direct-pr); the team home is ~/agent-team-records, so its paths render as ~/... as in production.
# The code checkout is this one, outside the sandbox HOME, so team_code and team_bin render absolute.

load helpers/common

setup() {
  sandbox
  export TEAM_HOME=$HOME/agent-team-records
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
  copy_bin "$code/bin"
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

# commit <worktree> <file> <subject> [<text>]: commit <file> holding <text> (default its name),
# printing the commit's full sha.
commit() {
  echo "${4:-$2}" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$3"
  git -C "$1" rev-parse HEAD
}

# on_base <worktree> <base> <file> <subject> [<text>]: a commit on <base>, pushed to origin, the
# branch checked out again; prints nothing.
on_base() {
  local branch
  branch=$(git -C "$1" branch --show-current)
  git -C "$1" checkout -q "$2"
  commit "$1" "$3" "$4" "${5:-}" >/dev/null
  git -C "$1" push -q origin "$2"
  git -C "$1" checkout -q "$branch"
}

# reviewed_branch <task> <base> [<sent back, a JSON list>]: the task's worktree (its opened
# event's) as a clone of a bare origin, <base> with one commit, and the task's branch from it with
# two more: reviewed, which a review at the event's time had findings on and sent back the list
# (default [5]), and head. Sets wt to the worktree, and reviewed and head to their full shas.
reviewed_branch() {
  local branch origin
  wt=$(jq -r --arg t "$1" 'select(.task == $t and .event == "opened") | .worktree' "$TEAM_HOME/ledger.jsonl")
  branch=$(jq -r --arg t "$1" 'select(.task == $t and .event == "opened") | .branch' "$TEAM_HOME/ledger.jsonl")
  origin=$BATS_TEST_TMPDIR/origin/$1.git
  mkdir -p "${origin%/*}"
  git init -q --bare -b "$2" "$origin"
  git clone -q "$origin" "$wt" 2>/dev/null
  git -C "$wt" checkout -q -B "$2"
  commit "$wt" base.txt "chore: start" >/dev/null
  git -C "$wt" push -q -u origin "$2"
  git -C "$wt" checkout -q -b "$branch"
  reviewed=$(commit "$wt" work.txt "feat: the first cut")
  event "$1" review "$(jq -cn --arg h "$reviewed" --argjson sent "${3:-[5]}" '{verdict: "findings", head: $h, sent_back: $sent}')"
  head=$(commit "$wt" fix.txt "fix: finding 5")
}

# on_github <url> <head>: gh pr view answers the PR at <url> with <head>; any other PR, with an
# error, as gh does.
on_github() {
  [[ $1 =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]
  echo "$2" >"$STUB_FIXTURES/github-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
  stub_script gh <<'SH'
[[ $1 == pr && $2 == view && $4 == --repo ]] || { echo "unexpected gh $*" >&2; exit 1; }
answer=$STUB_FIXTURES/github-${5/\//-}-$3
[[ -f $answer ]] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2; exit 1; }
jq -cn --arg head "$(<"$answer")" '{headRefOid: $head}'
SH
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

- The high-level plan: `~/agent-team-records/tasks/T12/plan.md`.
- `AGENTS.md` and the code it names.

## Do

1. Write the spec and tickets yourself in `.scratch/task/` if the work needs more than one commit; a small fix needs one or two tickets at most.
2. Commit types for this task: `fix(applicants): ...`.

## Deliver through no-mistakes

1. Bring the branch up to date with the base: `git fetch origin`; if `git merge-base --is-ancestor origin/dev HEAD` fails, merge `origin/dev` with a merge commit (`git merge origin/dev`, never a rebase), resolve any conflict and re-run what the conflicts touched.
   A conflict whose resolution is a judgment call on behaviour goes to `coordinator` as `T12 QUESTION <the conflict> | options: ...`.
2. Find what your branch made false: for each file, command, flag, setting and path it adds, renames or removes (`git diff --stat origin/dev...HEAD`), `git grep` its name in the repository's Markdown, `CLAUDE.md`, `AGENTS.md` and script headers, and fix every line that no longer holds, in the same PR.
3. Push the branch (under a Disclosure section, not before the review passes: the reviewer reads your local head) and send `T12 DONE review-ready <the full sha of HEAD>` to `coordinator`, then wait: the team reviews that head before the gate runs, so the gate runs once.
   Fix each finding the coordinator sends you on the branch and push; once they are fixed, or the coordinator says the review passed, go on.
4. Run `/no-mistakes` with this intent: "T12: rate-limit the applicant sign-in endpoints (per address and per IP, Mongo TTL counters, 429 with Retry-After), so Conventioner cannot be used to flood addresses with sign-in codes or to guess codes." (under a Disclosure section, put in its terms, since the gate drafts the PR's title and body from it)
5. The PR must target `dev`; if the gate opens it against another branch, retarget it to `dev` and close any duplicate.
6. When the gate returns checks-passed, repeat step 1; if it merged anything, push and wait for the PR's checks, noting each file that conflicted: a merge of the base is re-reviewed and checked by CI, never re-gated, so the gate runs again only for a commit of your own, such as the fix to a red check.
   Wait with `@CODE@/bin/team-ci-wait <full url> <the full sha you pushed>`, run with Bash `run_in_background`, and act on how it ended: exit 0, every check passed or the head has none; exit 1, fix each failed check it names, follow a stuck check's message, or, on a head other than the one you pushed, do as its message says; exit 75, run it again, or report as its message says.
   The gate leaves Playwright to CI, so its result arrives with CI's `e2e` checks: treat a red `e2e` as the gate's red.
7. Then send `T12 PR <full url>` to `coordinator`, followed by `merged dev conflicts: <each file that conflicted, or none>` when step 6 merged.

At each gate run's end (it pushed, went red, was aborted, or was stopped once its PR's checks were green), send `T12 DONE gate run=<its id> head=<the full sha it ran on> outcome=<pushed|red|aborted|stopped-green> minutes=<each step's minutes from no-mistakes axi status --run <its id>, as one JSON object>` to `coordinator`, with `cause=<review|notes|gate-finding|load|tooling|base-merge|other>` when the run repeats an earlier one on the same PR.

Never run a command that needs `sudo`; send `T12 BLOCKED <the command> needs sudo` to `coordinator` instead.

## Rules

Read `@CODE@/sops/platform-gotchas.md` before your first command.
Never the em dash in docs; refer to Daniel with they/them.
EOF
  )
  # The code checkout is this one, written whole: it is outside the sandbox HOME.
  expected=${expected//@CODE@/$REPO_ROOT}
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
    "builder-deliver builder-fix builder-merge-base builder-round builder-ticket ops planner-feature planner-interview planner-research rereview resume resume-crash retro reviewer verify"
  open_t12
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  # The interview brief's thread is a task fact, logged as team-thread --interview logs it.
  event T12 interview-thread '{discord_thread: "1565400000000000012"}'
  event T14 interview-thread '{discord_thread: "1565400000000000014"}'
  # The re-review briefs derive the reviewed head, the PR and its head, and since, from the
  # ledger, GitHub and the worktree's git.
  reviewed_branch T12 dev
  event T12 pr "$(jq -cn --arg h "$head" '{url: "https://github.com/chanjdaniel/Conventioner/pull/9", head: $h}')"
  on_github https://github.com/chanjdaniel/Conventioner/pull/9 "$head"
  reviewed_branch T14 main
  event T14 pr "$(jq -cn --arg h "$head" '{url: "https://github.com/chanjdaniel/agent-team/pull/9", head: $h}')"
  on_github https://github.com/chanjdaniel/agent-team/pull/9 "$head"
  local task template keys sets key brief
  for task in T12 T14; do
    while IFS= read -r template; do
      # The refusal names what the template needs beyond the task's facts; a template the
      # facts fill alone (retro) renders at once.
      run_bin team-brief "$task" "$template" --name "$template"
      if ((status == 1)); then
        keys=$(sed -n 's/^team-brief: unfilled placeholders: \([^;]*\).*/\1/p' <<<"$output")
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
      # The gotchas SOP is code, read from the code checkout; the ops session reads nothing
      # outside its worktree and runs no shell, so its brief has no gotchas line.
      if [[ $template == ops ]]; then
        refute_grep platform-gotchas "$brief"
      else
        assert_contains "$(<"$brief")" "Read \`$REPO_ROOT/sops/platform-gotchas.md\` before your first command."
      fi
      refute_grep -F 'agent-team-records/sops/' "$brief"
    done < <(templates)
  done
  # The delivery partial follows the project's delivery.
  assert_contains "$(<"$TEAM_HOME/tasks/T12/brief-builder-fix.md")" 'Run `/no-mistakes` with this intent: "T12: value of goal"'
  assert_contains "$(<"$TEAM_HOME/tasks/T14/brief-builder-deliver.md")" \
    'gh pr create --repo chanjdaniel/agent-team --base main --head feat/T14-team-tooling'
  refute_grep no-mistakes "$TEAM_HOME/tasks/T14/brief-builder-fix.md"
  refute_grep 'gh pr create' "$TEAM_HOME/tasks/T12/brief-builder-deliver.md"
  # So do the review partials: a gated project's first review comes before its PR.
  assert_contains "$(<"$TEAM_HOME/tasks/T14/brief-reviewer.md")" 'team-review-comment https://github.com/chanjdaniel/agent-team/pull/9'
  refute_grep -e team-review -e '/pull/9' "$TEAM_HOME/tasks/T12/brief-reviewer.md"
  assert_contains "$(<"$TEAM_HOME/tasks/T12/brief-rereview.md")" "the gate's own commits"
  refute_grep 'gate' "$TEAM_HOME/tasks/T14/brief-rereview.md"
}

@test "the interview brief needs the task's interview thread, names it and both scripts, and sends the coordinator no question" {
  open_t12
  run_bin -1 team-brief T12 planner-interview --set 'read=- `AGENTS.md`.'
  assert_equal "$output" "team-brief: unfilled placeholders: interview_thread"
  [[ ! -e $TEAM_HOME/tasks/T12/brief.md ]]
  run_bin -1 team-brief T12 planner-interview --set 'read=- `AGENTS.md`.' --set interview_thread=1
  assert_contains "$output" "interview_thread"
  event T12 interview-thread '{discord_thread: "1565400000000000012"}'
  run_bin -0 team-brief T12 planner-interview --set 'read=- `AGENTS.md`.'
  local brief=$TEAM_HOME/tasks/T12/brief.md
  grep -qxF 'Interview thread: Discord thread `1565400000000000012`, under the interview channel, which the coordinator does not read.' "$brief"
  grep -qF "\`$REPO_ROOT/bin/team-post T12 --thread interview --file <file>\`" "$brief"
  grep -qF "\`$REPO_ROOT/bin/team-thread wait T12\`, run with Bash \`run_in_background\`" "$brief"
  grep -qxF 'Send the coordinator only `DONE`, `BLOCKED`, `PAUSED`, `FAILED` or `INJECTION`: your questions go to Daniel in the thread, never to the coordinator.' "$brief"
  grep -qF "\"Please ask in #coordinator: this thread is for T12's interview only.\"" "$brief"
  grep -qxF '6. Send `T12 DONE .scratch/task/spec.md` to `coordinator`.' "$brief"
}

@test "a partial is picked by the project's delivery, from the directory of its name" {
  fake_checkout
  mkdir -p "$code/templates/briefs/extra"
  printf 'one {{> extra}} two {{> extra}}\n' >"$code/templates/briefs/x.md"
  echo 'gated {{task}}' >"$code/templates/briefs/extra/no-mistakes.md"
  open_t12
  run_fake T12 x
  assert_equal "$status" 0
  assert_equal "$(<"$TEAM_HOME/tasks/T12/brief.md")" "one gated T12 two gated T12"
  # A project whose delivery has no such partial is refused, with nothing written.
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  run_fake T14 x
  assert_equal "$status" 1
  assert_equal "$output" "team-brief: no extra partial for home's delivery 'direct-pr'"
  [[ ! -e $TEAM_HOME/tasks/T14/brief.md ]]
}

@test "a gated project's review reads the branch's local head before the gate, and posts nothing" {
  open_t12
  run_bin -0 --separate-stderr team-brief T12 reviewer --name review --set head=abc1234 --set "checks=the checks"
  assert_equal "$output" "$TEAM_HOME/tasks/T12/brief-review.md"
  assert_equal "$stderr" ""
  local expected line=0
  expected=$(
    cat <<'EOF'
# T12 brief (reviewer): review rate-limit the applicant sign-in endpoints

Path: small; you are the reviewer.
Project: conv (`chanjdaniel/Conventioner`), base `dev`.
Worktree: `~/.treehouse/Conventioner-d4c77a/4/Conventioner`, branch `fix/T12-applicant-sign-in-rate-limit`; review `origin/dev...abc1234`.
Task directory: `.scratch/task/` in the worktree: `spec.md`, `tickets/`, `build-notes/`.

## Check, beyond what every review covers

the checks

## Deliver

- Local checks: none.
  Run them on `abc1234` with `@CODE@/bin/team-checks conv abc1234`, which runs them as `team-merge` does, in a fresh detached worktree of that head, and say in `.scratch/task/review.md` whether it passed; a failure is **blocking**, and they set no GitHub status.
- There is no PR yet: the builder stopped before the no-mistakes gate, which runs once this review passes or its findings are fixed, and reviews the code line by line after you.
- Write your findings to `.scratch/task/review.md`, numbered, each with its file and line, one kind, `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`, and one scope, `change` (a line the PR adds or changes) or `before` (code it did not change).
  End it with the count of each kind, the plain notes as `note-change` and `note-before` (0 for none), the numbers of the `before` notes, and the guarded areas the change touches, of `ci`, `dependencies`, `migrations`, `settings`, `permissions` and `secrets`, by the paths `@CODE@/bin/lib/guarded` lists or by what the code does (settings, permission or secrets handling in a file of any name), or none.
  Post nothing to GitHub: the re-review of the gate's PR posts the comment and sets the status.
- Send `T12 DONE pass abc1234 findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:<n> before=<the before notes' numbers, comma-separated, or none> guarded=<areas, comma-separated, or none>` or `T12 DONE findings .scratch/task/review.md findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:<n> before=<the before notes' numbers, comma-separated, or none> guarded=<areas, comma-separated, or none>` to `coordinator`, the counts, numbers and areas as `.scratch/task/review.md` gives them.

## Rules

Read `@CODE@/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
EOF
  )
  expected=${expected//@CODE@/$REPO_ROOT}
  local -a want got
  mapfile -t want <<<"$expected"
  mapfile -t got <"$TEAM_HOME/tasks/T12/brief-review.md"
  for line in "${!want[@]}"; do
    assert_equal "${got[line]-<missing line $((line + 1))>}" "${want[line]}"
  done
  assert_equal "${#got[@]}" "${#want[@]}"
  # A PR is refused: the gate has not opened one when its project's first review runs.
  run_bin -1 team-brief T12 reviewer --name review-pr --set head=abc1234 --set "checks=the checks" \
    --set pr=https://github.com/chanjdaniel/Conventioner/pull/9
  assert_equal "$output" "team-brief: no placeholder in reviewer uses: pr"
}

@test "a direct-PR project's review reads the PR, comments on it and sets its status" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local pr=https://github.com/chanjdaniel/agent-team/pull/9 brief
  run_bin -1 team-brief T14 reviewer --name review --set head=abc1234 --set "checks=the checks"
  assert_equal "$output" "team-brief: unfilled placeholders: pr; nothing to derive them from: pr (T14 has no pr event in chanjdaniel/agent-team; --set pr=)"
  run_bin -0 team-brief T14 reviewer --name review --set pr=$pr --set head=abc1234 --set "checks=the checks"
  brief=$(<"$output")
  assert_contains "$brief" 'branch `feat/T14-team-tooling`; review `origin/main...abc1234`.'
  assert_contains "$brief" "The comment on PR $pr is that file, posted with this exact command, the only comment your settings allow: \`$REPO_ROOT/bin/team-review-comment $pr .work/task/review.md\`."
  assert_contains "$brief" "\`$REPO_ROOT/bin/team-review-status $pr abc1234 <success|failure> \"<one line, at most 140 characters>\"\`."
  assert_contains "$brief" "- Send \`T14 DONE pass $pr findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:<n> before=<the before notes' numbers, comma-separated, or none> guarded=<areas, comma-separated, or none>\` or \`T14 DONE findings .work/task/review.md findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:<n> before=<the before notes' numbers, comma-separated, or none> guarded=<areas, comma-separated, or none>\` to \`coordinator\`, the counts, numbers and areas as \`.work/task/review.md\` gives them."
}

@test "each review brief gives every finding a number, a kind and a scope, so the notes sent back and queued follow it" {
  open_t12
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local each='each with its file and line, one kind, `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`, and one scope, `change` (a line the PR adds or changes) or `before` (code it did not change)'
  local kinds="numbered, $each."
  run_bin -0 team-brief T12 reviewer --name review --set head=abc1234 --set "checks=the checks"
  assert_contains "$(<"$output")" "$kinds"
  run_bin -0 team-brief T14 reviewer --name review --set pr=https://github.com/chanjdaniel/agent-team/pull/9 \
    --set head=abc1234 --set "checks=the checks"
  assert_contains "$(<"$output")" "$kinds"
  local task dir base
  for task in T12:.scratch/task:dev T14:.work/task:main; do
    base=${task##*:} task=${task%:*}
    dir=${task#*:} task=${task%:*}
    reviewed_branch "$task" "$base"
    run_bin -0 team-brief "$task" rereview --name rereview --set pr=https://github.com/chanjdaniel/agent-team/pull/9 \
      --set head="$head" --set "since=the fix"
    assert_contains "$(<"$output")" "its new findings numbered on from the last, $each; then write the same result alone to \`$dir/rereview.md\`."
    assert_contains "$(<"$output")" "(each \`blocking\`, \`note: correctness\`, \`note: security\` and \`note: real-data\`, and each plain \`note\` whose scope is \`change\`) is fixed at \`$head\`"
    assert_contains "$(<"$output")" "a plain \`note\` whose scope is \`before\`, on code the PR did not change, is queued as a follow-up, not for this PR."
    refute_grep -F '**note**' "$output"
  done
}

@test "each review brief asks for each kind's count and the guarded areas in review.md and in the DONE" {
  open_t12
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local pr=https://github.com/chanjdaniel/agent-team/pull/9 brief
  local counts="findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:<n> before=<the before notes' numbers, comma-separated, or none> guarded=<areas, comma-separated, or none>"
  local areas="the guarded areas the change touches, of \`ci\`, \`dependencies\`, \`migrations\`, \`settings\`, \`permissions\` and \`secrets\`, by the paths \`$REPO_ROOT/bin/lib/guarded\` lists or by what the code does (settings, permission or secrets handling in a file of any name), or none"
  run_bin -0 team-brief T12 reviewer --name review --set head=abc1234 --set "checks=the checks"
  brief=$(<"$output")
  assert_contains "$brief" "$areas"
  assert_contains "$brief" "- Send \`T12 DONE pass abc1234 $counts\` or \`T12 DONE findings .scratch/task/review.md $counts\` to \`coordinator\`, the counts, numbers and areas as \`.scratch/task/review.md\` gives them."
  run_bin -0 team-brief T14 reviewer --name review --set pr=$pr --set head=abc1234 --set "checks=the checks"
  brief=$(<"$output")
  assert_contains "$brief" "$areas"
  assert_contains "$brief" "- Send \`T14 DONE pass $pr $counts\` or \`T14 DONE findings .work/task/review.md $counts\` to \`coordinator\`, the counts, numbers and areas as \`.work/task/review.md\` gives them."
  local task dir base
  for task in T12:.scratch/task:dev T14:.work/task:main; do
    base=${task##*:} task=${task%:*}
    dir=${task#*:} task=${task%:*}
    reviewed_branch "$task" "$base"
    run_bin -0 team-brief "$task" rereview --name rereview --set pr=$pr --set head="$head" --set "since=the fix"
    brief=$(<"$output")
    assert_contains "$brief" "$areas"
    assert_contains "$brief" "the findings that stand at \`$head\`, its new ones and any earlier one sent back and not fixed, the plain notes as \`note-change\` and \`note-before\` (0 for none), the numbers of its new \`before\` notes"
    assert_contains "$brief" "- Send \`$task DONE pass $pr $counts\` or \`$task DONE findings $dir/review.md $counts\` to \`coordinator\`, the counts, numbers and areas as \`$dir/rereview.md\` gives them."
  done
}

@test "each planner brief delivers scope.txt beside the spec, one repository path per line, and checks its tickets" {
  open_t12
  event T12 interview-thread '{discord_thread: "1565400000000000012"}'
  local template
  for template in planner-feature planner-interview; do
    run_bin -0 team-brief T12 "$template" --name "$template" --set 'read=- `AGENTS.md`.'
    grep -qxF '3. `scope.txt`, every path the tickets change, one repository path per line: a file, or a directory ending in `/` that covers everything under it, with no leading `/`, no `.` or `..` and no glob; the coordinator puts it to Daniel with the plan, whose approval may let the PR merge with no second ask when it changes nothing outside it.' "$output" ||
      { echo "$template lacks the scope line" >&2; cat "$output" >&2; return 1; }
  done
  grep -qxF "4. Run \`$REPO_ROOT/bin/team-tickets T12 --check\` and fix each line it names." "$TEAM_HOME/tasks/T12/brief-planner-feature.md"
  grep -qxF '5. Send `T12 DONE .scratch/task/spec.md` to `coordinator`.' "$TEAM_HOME/tasks/T12/brief-planner-feature.md"
  grep -qxF "5. Run \`$REPO_ROOT/bin/team-tickets T12 --check\` and fix each line it names." "$TEAM_HOME/tasks/T12/brief-planner-interview.md"
  grep -qxF '6. Send `T12 DONE .scratch/task/spec.md` to `coordinator`.' "$TEAM_HOME/tasks/T12/brief-planner-interview.md"
}

@test "a gated project's builder stops before the gate for the review, then runs the gate once" {
  open_t12
  run_bin -0 team-brief T12 builder-deliver --set "goal=the goal"
  local brief
  brief=$(<"$output")
  assert_contains "$brief" "3. Push the branch (under a Disclosure section, not before the review passes: the reviewer reads your local head) and send \`T12 DONE review-ready <the full sha of HEAD>\` to \`coordinator\`, then wait: the team reviews that head before the gate runs, so the gate runs once."
  assert_contains "$brief" "once they are fixed, or the coordinator says the review passed, go on."
  # The review comes before the gate.
  [[ $(grep -n 'review-ready' <<<"$brief" | cut -d: -f1) -lt $(grep -n '/no-mistakes' <<<"$brief" | cut -d: -f1) ]]
  # A direct-PR project opens its PR first, and is reviewed on it.
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  run_bin -0 team-brief T14 builder-deliver --set "goal=the goal"
  refute_grep review-ready "$output"
}

@test "a gated project's re-review reads the gate's own commits from the reviewed local head" {
  open_t12
  reviewed_branch T12 dev
  run_bin -0 team-brief T12 rereview --name rereview --set pr=https://github.com/chanjdaniel/Conventioner/pull/9 \
    --set head="$head" --set "since=the builder fixed the findings and the gate opened the PR"
  local brief r=$reviewed h=$head
  brief=$(<"$output")
  assert_contains "$brief" "PR: https://github.com/chanjdaniel/Conventioner/pull/9 against \`dev\`, reviewed at \`$r\`, now at head \`$h\`."
  assert_contains "$brief" "2. Review what changed since the last review, \`git diff $r $h\`, and the commit messages of \`origin/dev..$h\`."
  assert_contains "$brief" "   That diff holds the gate's own commits, which no reviewer has read: read them as closely as the builder's, and the PR body the gate wrote; after the gate's first run, \`$r\` is the branch's local head, reviewed before the gate."
  assert_contains "$brief" "   If the gate rebased the branch, so \`$r\` is not an ancestor of \`$h\`, compare with \`git range-diff $r...$h\` instead."
}

@test "the verify brief re-reviews a notes-only fix from its diff alone, waiting on the checks while it reads" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local pr=https://github.com/chanjdaniel/agent-team/pull/9
  # It needs the PR, both heads and the notes sent back.
  run_bin -1 team-brief T14 verify --name verify-2
  assert_contains "$output" "team-brief: unfilled placeholders: "
  local key
  for key in pr reviewed head findings; do assert_contains "$output" "$key"; done
  run_bin -0 --separate-stderr team-brief T14 verify --name verify-2 --set pr=$pr --set head=def5678 \
    --set reviewed=abc1234 --set findings="3 and 5"
  assert_equal "$output" "$TEAM_HOME/tasks/T14/brief-verify-2.md"
  assert_equal "$stderr" ""
  local expected line=0
  expected=$(
    cat <<'BRIEF'
# T14 brief (reviewer): verify the notes fixed on the team's tooling

Path: feature; you are the reviewer of a fix round whose findings were all plain notes on lines the PR adds or changes.
Project: home (`chanjdaniel/agent-team`), base `main`.
Worktree: `~/agent-team/.claude/worktrees/2`, branch `feat/T14-team-tooling`.
PR: https://github.com/chanjdaniel/agent-team/pull/9 against `main`, reviewed at `abc1234`, now at head `def5678`.
Task directory: `.work/task/` in the worktree: `review.md` with the last review's findings.
Sent back: the notes numbered 3 and 5 in `.work/task/review.md`, each a plain `note` whose scope is `change`.

## Check

1. First start the wait for the PR's GitHub checks with `@CODE@/bin/team-ci-wait https://github.com/chanjdaniel/agent-team/pull/9 def5678`, run with Bash `run_in_background`, so the run and your reading overlap, and run the project's local checks (none) on `def5678` with `@CODE@/bin/team-checks home def5678`, which runs them as `team-merge` does, in a fresh detached worktree of that head; every one must pass, and `.work/task/rereview.md` says which local checks passed (they set no GitHub status).
   Act on how the wait ended: exit 0, every check passed or the head has none; exit 1, each failed check it names is a `blocking` finding, while a stuck check or a head other than `def5678` goes to `coordinator` as `T14 BLOCKED <its message>`; exit 75, run it again, or report as its message says.
2. Review what changed since the last review, `git diff abc1234 def5678`, and the commit messages of `origin/main..def5678`.
   Read nothing else: not the rest of the PR, the spec's or the story's acceptance list, or the knowledge graph; run the UI check only when that diff touches a UI file and your session lists `ui-check`, on the states it touched and their siblings.
   A round with no new commit (`abc1234` is `def5678`) edited only the PR body: read the body against the notes.
3. Every note sent back (3 and 5) is fixed at `def5678`, and the diff holds nothing but those fixes, their tests and, on a gated project, the gate's own commits.
   When it changes more than the notes asked, this brief does not fit: send `T14 BLOCKED not a notes-only fix: <what else changed>` to `coordinator`, and write nothing to GitHub.
   Raise a new finding only on a line this diff adds or changes, so each new one's scope is `change`.

## Deliver

- Add the result to `.work/task/review.md` under a heading naming `def5678`, its new findings numbered on from the last, each with its file and line, one kind, `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`, and its scope, `change`; then write the same result alone to `.work/task/rereview.md`.
  Give in it the count of each kind among the findings that stand at `def5678`, its new ones and any note sent back and not fixed, the plain notes as `note-change` and `note-before` (0 for none), and the guarded areas the change touches, of `ci`, `dependencies`, `migrations`, `settings`, `permissions` and `secrets`, by the paths `@CODE@/bin/lib/guarded` lists or by what the code does (settings, permission or secrets handling in a file of any name), or none.
  Post that as one PR comment with this exact command, the only comment your settings allow: `@CODE@/bin/team-review-comment https://github.com/chanjdaniel/agent-team/pull/9 .work/task/rereview.md`.
- The status on the head you reviewed, with this exact command, the only status your settings allow: `@CODE@/bin/team-review-status https://github.com/chanjdaniel/agent-team/pull/9 def5678 <success|failure> "<one line, at most 140 characters>"`.
  It sets the status on `def5678`, the head you reviewed, and refuses when the PR has moved past it: then set nothing and tell the coordinator.
- Send `T14 DONE pass https://github.com/chanjdaniel/agent-team/pull/9 findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:0 before=none guarded=<areas, comma-separated, or none>` or `T14 DONE findings .work/task/review.md findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:0 before=none guarded=<areas, comma-separated, or none>` to `coordinator`, the counts and areas as `.work/task/rereview.md` gives them.

## Rules

Read `@CODE@/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
BRIEF
  )
  expected=${expected//@CODE@/$REPO_ROOT}
  local -a want got
  mapfile -t want <<<"$expected"
  mapfile -t got <"$TEAM_HOME/tasks/T14/brief-verify-2.md"
  for line in "${!want[@]}"; do
    assert_equal "${got[line]-<missing line $((line + 1))>}" "${want[line]}"
  done
  assert_equal "${#got[@]}" "${#want[@]}"
  # A gated project's verify reads the gate's own commits in the fix's diff, as its rereview does.
  open_t12
  run_bin -0 team-brief T12 verify --name verify-2 --set pr=https://github.com/chanjdaniel/Conventioner/pull/9 \
    --set head=def5678 --set reviewed=abc1234 --set findings=4
  assert_contains "$(<"$output")" "   That diff holds the gate's own commits, which no reviewer has read: read them as closely as the builder's"
  assert_contains "$(<"$output")" "Every note sent back (4) is fixed at \`def5678\`"
}

# The section of <brief> from its "## Since the last review" heading to the next heading.
since_section() {
  sed -n '/^## Since the last review$/,/^## Check$/p' "$1"
}

# A commit's short sha and subject, as the derived since lists it.
listed() {
  printf '%s\n' "- \`$(git -C "$wt" rev-parse --short=8 "$1")\` $(git -C "$wt" log -1 --format=%s "$1")"
}

@test "a rereview derives the reviewed head, the PR, its head and since, from the ledger, GitHub and the branch's commits and merges" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local pr=https://github.com/chanjdaniel/agent-team/pull/9 fix5 merge1 fix6 merge2 short
  reviewed_branch T14 main '[5, 6]'
  fix5=$head
  event T14 pr "$(jq -cn --arg h "$reviewed" --arg url "$pr" '{url: $url, head: $h}')"
  # A clean merge of the base, an own commit, then a merge of the base that conflicted on
  # shared.txt and was resolved.
  on_base "$wt" main base-1.txt "feat: the base's first"
  git -C "$wt" fetch -q origin
  git -C "$wt" merge -q --no-edit origin/main
  merge1=$(git -C "$wt" rev-parse HEAD)
  fix6=$(commit "$wt" shared.txt "fix: finding 6" "the branch's line")
  on_base "$wt" main shared.txt "feat: the base's second" "the base's line"
  git -C "$wt" fetch -q origin
  run git -C "$wt" merge -q --no-edit origin/main
  assert_equal "$status" 1
  echo "both lines" >"$wt/shared.txt"
  git -C "$wt" add shared.txt
  git -C "$wt" commit -q --no-edit
  merge2=$(git -C "$wt" rev-parse HEAD)
  on_github "$pr" "$merge2"
  # A build note older than the review, and one written after it.
  mkdir -p "$wt/.work/task/build-notes"
  echo "# 04" >"$wt/.work/task/build-notes/04.md"
  touch -d 2026-10-22T09:00:00Z "$wt/.work/task/build-notes/04.md"
  echo "# 05" >"$wt/.work/task/build-notes/05.md"

  run_bin -0 --separate-stderr team-brief T14 rereview --name rereview-2
  assert_equal "$output" "$TEAM_HOME/tasks/T14/brief-rereview-2.md"
  # GitHub's head wins over the ledger's, said on stderr.
  assert_equal "$stderr" "team-brief: $pr is at $merge2 on GitHub, not at the ledger's $reviewed; the brief names GitHub's"
  grep -qxF "PR: $pr against \`main\`, reviewed at \`$reviewed\`, now at head \`$merge2\`." "$output"
  short=$(git -C "$wt" rev-parse --short=8 "$reviewed")
  local expected
  expected=$(
    cat <<SINCE
## Since the last review

The last review, of \`${reviewed:0:8}\`, had findings, and sent back 5 and 6.

The branch's own commits since \`$short\`, the ones to review:

$(listed "$fix5")
$(listed "$merge1"): a merge of \`origin/main\`, no conflicts
$(listed "$fix6")
$(listed "$merge2"): a merge of \`origin/main\`, conflicts in \`shared.txt\`

The other 2 commits in \`$short..$(git -C "$wt" rev-parse --short=8 "$merge2")\` came from \`origin/main\` and are not to be reviewed.

Build notes changed since the last review: \`.work/task/build-notes/05.md\`.

## Check
SINCE
  )
  assert_equal "$(since_section "$output")" "$expected"
  # The base's commits are named nowhere.
  refute_grep -F "the base's" "$output"
}

@test "a rereview of a branch rewritten past the reviewed head says to compare with git range-diff, and lists no commit" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  reviewed_branch T14 main
  # The reviewed commit rewritten: the new head is built on its parent.
  git -C "$wt" checkout -q --detach "$reviewed^"
  local rewritten
  rewritten=$(commit "$wt" work.txt "feat: the first cut, rewritten" "rewritten")
  run_bin -0 team-brief T14 rereview --name rereview-2 --set pr=https://github.com/chanjdaniel/agent-team/pull/9 \
    --set head="$rewritten"
  local expected
  expected=$(
    cat <<SINCE
## Since the last review

The last review, of \`${reviewed:0:8}\`, had findings, and sent back 5.

The branch was rewritten: \`$(git -C "$wt" rev-parse --short=8 "$reviewed")\` is not an ancestor of \`$(git -C "$wt" rev-parse --short=8 "$rewritten")\`, so compare with \`git range-diff $reviewed...$rewritten\`.

## Check
SINCE
  )
  assert_equal "$(since_section "$output")" "$expected"
}

@test "a rereview with no commit since the reviewed head says so, and one with no review describes none" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  reviewed_branch T14 main
  event T14 review "$(jq -cn --arg h "$head" '{verdict: "pass", head: $h}')"
  run_bin -0 team-brief T14 rereview --name rereview-2 --set pr=https://github.com/chanjdaniel/agent-team/pull/9 \
    --set head="$head"
  local short
  short=$(git -C "$wt" rev-parse --short=8 "$head")
  assert_equal "$(since_section "$output")" "$(printf '%s\n' '## Since the last review' '' \
    "The last review, of \`${head:0:8}\`, passed." '' "No commit since \`$short\`." '' '## Check')"
  # A gated project's first PR, reviewed before the gate at its local head: no review is logged.
  open_t12
  reviewed_branch T12 dev
  sed -i '/"task":"T12","event":"review"/d' "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-brief T12 rereview --name rereview --set pr=https://github.com/chanjdaniel/Conventioner/pull/9 \
    --set head="$head" --set reviewed="$head"
  assert_equal "$(since_section "$output")" "$(printf '%s\n' '## Since the last review' '' \
    "No commit since \`$(git -C "$wt" rev-parse --short=8 "$head")\`." '' '## Check')"
}

@test "GitHub unreadable is refused naming --set head=, an unreachable fetch is exit 75, and neither writes anything" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local pr=https://github.com/chanjdaniel/agent-team/pull/9 before
  reviewed_branch T14 main
  event T14 pr "$(jq -cn --arg h "$reviewed" --arg url "$pr" '{url: $url, head: $h}')"
  # gh answers no PR 9.
  on_github https://github.com/chanjdaniel/agent-team/pull/8 "$head"
  before=$(task_files)
  run_bin -1 team-brief T14 rereview --name rereview-2
  assert_equal "$output" "team-brief: cannot read the head of $pr on GitHub (GraphQL: Could not resolve to a PullRequest with the number of 9.); pass --set head=<full sha>"
  assert_equal "$(task_files)" "$before"
  # The fetch of the base cannot reach origin.
  git -C "$wt" remote set-url origin "$BATS_TEST_TMPDIR/nowhere.git"
  run_bin -75 team-brief T14 rereview --name rereview-2 --set head="$head"
  assert_contains "$output" "team-brief: cannot fetch origin/main into ~/agent-team/.claude/worktrees/2 ("
  assert_contains "$output" "); try again later"
  assert_equal "$(task_files)" "$before"
  # A worktree with no git is refused.
  rm -rf "$wt/.git"
  run_bin -1 team-brief T14 rereview --name rereview-2 --set head="$head"
  assert_equal "$output" "team-brief: cannot read the worktree ~/agent-team/.claude/worktrees/2 to derive since: not a git checkout"
  assert_equal "$(task_files)" "$before"
}

@test "with no review and no pr, each derived fact is refused naming its --set, and a head the worktree lacks is refused" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  run_bin -1 team-brief T14 rereview
  assert_equal "$output" "team-brief: unfilled placeholders: head, pr, reviewed, since; nothing to derive them from: head (no pr to read it from; --set head=), pr (T14 has no pr event in chanjdaniel/agent-team; --set pr=), reviewed (T14 has no review; --set reviewed=), since (derived from reviewed and head)"
  run_bin -1 team-brief T14 rereview --set pr=not-a-url --set reviewed=abc1234
  assert_equal "$output" "team-brief: unfilled placeholders: head, since; nothing to derive them from: head (not-a-url is not a GitHub pull request URL; --set head=), since (derived from reviewed and head)"
  reviewed_branch T14 main
  run_bin -1 team-brief T14 rereview --set pr=https://github.com/chanjdaniel/agent-team/pull/9 \
    --set head=0123456789abcdef0123456789abcdef01234567
  assert_equal "$output" "team-brief: head 0123456789abcdef0123456789abcdef01234567 is in neither ~/agent-team/.claude/worktrees/2 nor its origin; --set head= to a commit it holds"
  assert_equal "$(task_files)" ""
}

@test "a --set of a derived fact wins, and the coordinator's since is added after the derived one" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local first
  reviewed_branch T14 main
  first=$reviewed
  event T14 pr "$(jq -cn --arg h "$reviewed" '{url: "https://github.com/chanjdaniel/agent-team/pull/9", head: $h}')"
  printf '%s\n' 'Read the new test first.' 'It covers finding 5.' >"$BATS_TEST_TMPDIR/since.md"
  # The pr, reviewed and head set by hand: no GitHub call, and since counts from the set head.
  run_bin -0 --separate-stderr team-brief T14 rereview --set pr=https://github.com/chanjdaniel/agent-team/pull/10 \
    --set reviewed="$(git -C "$wt" rev-parse "$first^")" --set head="$head" --set-file since="$BATS_TEST_TMPDIR/since.md"
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls gh)" ""
  grep -qxF "PR: https://github.com/chanjdaniel/agent-team/pull/10 against \`main\`, reviewed at \`$(git -C "$wt" rev-parse "$first^")\`, now at head \`$head\`." "$output"
  local expected
  expected=$(
    cat <<SINCE
## Since the last review

The last review, of \`${first:0:8}\`, had findings, and sent back 5.

The branch's own commits since \`$(git -C "$wt" rev-parse --short=8 "$first^")\`, the ones to review:

$(listed "$first")
$(listed "$head")

The coordinator adds: Read the new test first.
It covers finding 5.

## Check
SINCE
  )
  assert_equal "$(since_section "$output")" "$expected"
  # --set since= is added the same way.
  run_bin -0 team-brief T14 rereview --force --set head="$head" --set "since=the gate's run"
  assert_equal "$(since_section "$output" | tail -n 3 | head -n 1)" "The coordinator adds: the gate's run"
}

@test "--help documents the derived facts and the brief's record" {
  run_bin -0 team-brief --help
  assert_contains "$output" "Derived: a template's reviewed, pr and head the caller does not --set are filled from the ledger"
  assert_contains "$output" "since is always derived, the caller's --set or --set-file since= added after it as \"The"
  assert_contains "$output" "a failed fetch of the base is exit 75, nothing written"
  assert_contains "$output" "builder-round's pr is none"
  assert_contains "$output" "findings the latest review's sent_back, as \"3, 5 and 6\"; findings_file"
  assert_contains "$output" "goal the first sentence of the plan's ## Goal section"
  assert_contains "$output" "tasks/T<n>/brief[-<suffix>].json, replaced with it: {template, project, values}"
}

@test "--help names the review rules file and says it is the coordinator's records" {
  run_bin -0 team-brief --help
  assert_contains "$output" "projects/<project>/review-rules.md"
  assert_contains "$output" "the coordinator's records"
}

@test "every brief leaves its record: template, project and the values of every placeholder but the task's facts" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  run_bin -0 team-brief T14 builder-ticket --name build-01 --set ticket=01
  assert_equal "$(jq -c . "$TEAM_HOME/tasks/T14/brief-build-01.json")" \
    '{"template":"builder-ticket","project":"home","values":{"ticket":"01"}}'
  # --force replaces it with the brief.
  run_bin -0 team-brief T14 builder-ticket --name build-01 --set ticket=02 --force
  assert_equal "$(jq -c .values "$TEAM_HOME/tasks/T14/brief-build-01.json")" '{"ticket":"02"}'
  # A refusal leaves both as they were.
  run_bin -1 team-brief T14 builder-ticket --name build-01 --set ticket=03
  assert_equal "$(jq -c .values "$TEAM_HOME/tasks/T14/brief-build-01.json")" '{"ticket":"02"}'
  grep -qF 'ticket 02' "$TEAM_HOME/tasks/T14/brief-build-01.md"
  # A derived value is recorded as filled: the rereview's pr, heads and since.
  local pr=https://github.com/chanjdaniel/agent-team/pull/9 record
  reviewed_branch T14 main
  event T14 pr "$(jq -cn --arg h "$head" --arg url "$pr" '{url: $url, head: $h}')"
  on_github "$pr" "$head"
  run_bin -0 team-brief T14 rereview
  record=$TEAM_HOME/tasks/T14/brief.json
  assert_equal "$(jq -c '{template, project, keys: (.values | keys)}' "$record")" \
    '{"template":"rereview","project":"home","keys":["head","pr","reviewed","since"]}'
  assert_equal "$(jq -r .values.head "$record") $(jq -r .values.reviewed "$record") $(jq -r .values.pr "$record")" \
    "$head $reviewed $pr"
  assert_contains "$(<"$TEAM_HOME/tasks/T14/brief.md")" "$(jq -r .values.since "$record")"
}

# A project's standing review rules, the coordinator's records in the team home, which every
# review brief includes where its checks are listed.
@test "each review brief holds the project's review rules from the team home, their placeholders filled; with none, the line is left out" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local pr=https://github.com/chanjdaniel/agent-team/pull/9 template plain ruled rules section
  reviewed_branch T14 main
  event T14 pr "$(jq -cn --arg h "$head" --arg url "$pr" '{url: $url, head: $h}')"
  on_github "$pr" "$head"
  # The args each review template needs beyond what it derives.
  review_args() {
    case $1 in
      reviewer) args=(--set checks=c) ;;
      rereview) args=() ;;
      verify) args=(--set findings=5) ;;
    esac
  }
  for template in reviewer rereview verify; do
    review_args "$template"
    run_bin -0 team-brief T14 "$template" --name "plain-$template" "${args[@]}"
  done
  mkdir -p "$TEAM_HOME/projects/home"
  printf '%s\n' '- Run `real_data_check.py` on the tree at `{{head}}` and on the commits of `origin/{{base}}..{{head}}`.' \
    '- Read the PR body as Daniel will.' '' >"$TEAM_HOME/projects/home/review-rules.md"
  rules="- Run \`real_data_check.py\` on the tree at \`$head\` and on the commits of \`origin/main..$head\`."$'\n'"- Read the PR body as Daniel will."
  for template in reviewer rereview verify; do
    review_args "$template"
    run_bin -0 team-brief T14 "$template" --name "rules-$template" "${args[@]}"
    plain=$(<"$TEAM_HOME/tasks/T14/brief-plain-$template.md")
    ruled=$(<"$TEAM_HOME/tasks/T14/brief-rules-$template.md")
    # The rules, as a paragraph of their own, are all that is added.
    assert_contains "$ruled" $'\n\n'"$rules"$'\n\n'
    assert_equal "${ruled/$'\n\n'"$rules"/}" "$plain"
    # They come where the checks are listed, after them and before the delivery.
    section=$(sed -n '/^## Check/,/^## Deliver$/p' "$TEAM_HOME/tasks/T14/brief-rules-$template.md")
    assert_contains "$section" $'\n\n'"$rules"$'\n\n## Deliver'
    # The template's line is never left in the brief, with rules or without.
    refute_grep -F 'review-rules' "$TEAM_HOME/tasks/T14/brief-plain-$template.md"
    refute_grep -F 'review-rules' "$TEAM_HOME/tasks/T14/brief-rules-$template.md"
  done
  # An empty rules file is none.
  : >"$TEAM_HOME/projects/home/review-rules.md"
  run_bin -0 team-brief T14 reviewer --name empty-reviewer --set checks=c
  assert_equal "$(<"$TEAM_HOME/tasks/T14/brief-empty-reviewer.md")" "$(<"$TEAM_HOME/tasks/T14/brief-plain-reviewer.md")"
  # Another project's rules never reach this one's briefs.
  mkdir -p "$TEAM_HOME/projects/conv"
  echo '- the conv rule' >"$TEAM_HOME/projects/conv/review-rules.md"
  run_bin -0 team-brief T14 reviewer --name other-reviewer --set checks=c
  refute_grep -F 'the conv rule' "$TEAM_HOME/tasks/T14/brief-other-reviewer.md"
}

@test "a review rule with an unknown placeholder is refused naming it, and a rules file that cannot be read is refused" {
  open_t12
  mkdir -p "$TEAM_HOME/projects/conv"
  echo '- Check {{bogus}} at `{{head}}`.' >"$TEAM_HOME/projects/conv/review-rules.md"
  run_bin -1 team-brief T12 reviewer --set head=abc1234 --set checks=c
  assert_equal "$output" "team-brief: unfilled placeholders: bogus"
  [[ -z $(task_files) ]]
  # As in a template, a --set fills it.
  run_bin -0 team-brief T12 reviewer --set head=abc1234 --set checks=c --set bogus=the-thing
  grep -qxF -- '- Check the-thing at `abc1234`.' "$TEAM_HOME/tasks/T12/brief.md"
  # A directory where the file belongs is refused, naming the path.
  rm "$TEAM_HOME/projects/conv/review-rules.md"
  mkdir "$TEAM_HOME/projects/conv/review-rules.md"
  run_bin -1 team-brief T12 reviewer --name again --set head=abc1234 --set checks=c
  assert_equal "$output" "team-brief: cannot read the review rules $TEAM_HOME/projects/conv/review-rules.md"
  [[ ! -e $TEAM_HOME/tasks/T12/brief-again.md ]]
}

@test "the review rules come from the team home, never as a delivery partial, which still comes from the template's directory" {
  fake_checkout
  mkdir -p "$code/templates/briefs/review" "$code/templates/briefs/review-rules"
  printf '%s\n' 'one' '{{> review}}' '{{> review-rules}}' '' 'two' >"$code/templates/briefs/x.md"
  echo 'gated {{task}}' >"$code/templates/briefs/review/no-mistakes.md"
  # A directory named like the rules is not read: its name's dash keeps the two forms apart.
  echo 'not the rules' >"$code/templates/briefs/review-rules/no-mistakes.md"
  open_t12
  run_fake T12 x
  assert_equal "$status" 0
  assert_equal "$(<"$TEAM_HOME/tasks/T12/brief.md")" $'one\ngated T12\n\ntwo'
  mkdir -p "$TEAM_HOME/projects/conv"
  echo 'the rules of {{task}}' >"$TEAM_HOME/projects/conv/review-rules.md"
  run_fake T12 x --force
  assert_equal "$status" 0
  assert_equal "$(<"$TEAM_HOME/tasks/T12/brief.md")" $'one\ngated T12\n\nthe rules of T12\n\ntwo'
}

@test "the retro brief renders from the task's facts alone, its digest first and read from team_bin" {
  open_task T31 home retro research/T31-retro-2026-10-25 agent-team/.claude/worktrees/3 "Retro 2026-10-25"
  run_bin -0 team-brief T31 retro
  local brief=$TEAM_HOME/tasks/T31/brief.md
  assert_equal "$output" "$brief"
  # The first item to read is the digest, from the team home's checkout and its live ledger.
  assert_equal "$(grep -m1 '^1\. ' "$brief")" \
    "1. First, the ledger's evidence for this retro's window, in both forms: \`$REPO_ROOT/bin/team-retro digest T31\` and \`$REPO_ROOT/bin/team-retro digest T31 --json\`."
  # Then where the window's time went, measured from the same ledger.
  assert_contains "$(<"$brief")" "Then where the window's time went: \`$REPO_ROOT/bin/team-time --since <the window's since> --until <its until>\`, hours per task and per phase, gate runs, reviews and Daniel's answer latency."
  # The same report holds the workers' lifetimes and where their time went, which the report's first part reasons about.
  assert_contains "$(<"$brief")" "   It is also each worker's lifetime: the averages by role, path, project and model, the longest, and where the workers' time went, with what the task was doing while a worker waited."
  assert_contains "$(<"$brief")" '1. `report.md`, in four parts:'
  assert_equal "$(grep -m1 '^   - \*\*' "$brief")" \
    "   - **Worker time**: the lifetimes by role (median, 90th percentile, longest) against the previous retro's when its report has them; the five longest lifetimes, each with its top sinks and, from the task's records, why; and the top sinks across workers with the hours each cost."
  assert_contains "$(<"$brief")" "the costliest first, a sink's hours from Worker time counting as cost."
  assert_contains "$(<"$brief")" 'and the sink it answers, when it answers one)'
  assert_contains "$(<"$brief")" "Read \`$REPO_ROOT/sops/platform-gotchas.md\` before your first command."
  # What Daniel approved and the team has not built yet is read, so it is not proposed again.
  assert_contains "$(<"$brief")" '`~/agent-team-records/tasks/queued/`'
  assert_contains "$(<"$brief")" 'Never propose again what Daniel rejected at an earlier retro, or what is already approved and queued, unless there is new evidence, which you name.'
  assert_contains "$(<"$brief")" 'Send `T31 DONE .work/task/report.md` to `coordinator`.'
}

@test "the resume brief sends a relaunched worker to its last brief, the handoff note and the branch" {
  open_t12
  run_bin -0 team-brief --help
  assert_contains "$output" "resume (a worker relaunched on"
  run_bin -1 team-brief T12 resume --name resume-builder --set role=builder \
    --set "brief=~/agent-team-records/tasks/T12/brief.md" --set "from=the handoff from home-pc at 2026-10-23T14:05:00Z"
  assert_contains "$output" "snapshot"
  run_bin -0 team-brief T12 resume --name resume-builder --set role=builder \
    --set "brief=~/agent-team-records/tasks/T12/brief.md" --set "from=the handoff from home-pc at 2026-10-23T14:05:00Z" \
    --set "snapshot=applied as uncommitted changes in your worktree"
  local brief
  brief=$(<"$output")
  assert_equal "$(head -n 1 <<<"$brief")" "# T12 brief (builder): resume rate-limit the applicant sign-in endpoints"
  assert_contains "$brief" "you are the builder, resuming the task after the handoff from home-pc at 2026-10-23T14:05:00Z."
  assert_contains "$brief" "Worktree: \`~/.treehouse/Conventioner-d4c77a/4/Conventioner\`, branch \`fix/T12-applicant-sign-in-rate-limit\`"
  assert_contains "$brief" "1. Read your brief \`~/agent-team-records/tasks/T12/brief.md\`"
  assert_contains "$brief" "2. Then \`.scratch/task/handoff.md\` if it exists"
  assert_contains "$brief" "The uncommitted changes the handoff found in the worktree: applied as uncommitted changes in your worktree."
  assert_contains "$brief" "3. Check the branch: \`git status\`, \`git diff\`, and \`git log origin/dev..HEAD\`"
}

@test "the crash resume brief names the checkpoint, what may be missing, and sends the worker to check first" {
  open_t12
  run_bin -0 team-brief --help
  assert_contains "$output" "resume-crash (one relaunched after its machine crashed:"
  run_bin -0 team-brief T12 resume-crash --name resume-builder --set role=builder \
    --set "brief=~/agent-team-records/tasks/T12/brief.md" --set machine=home-pc --set checkpoint=2026-10-23T13:45:00Z \
    --set "snapshot=applied as uncommitted changes in your worktree"
  local brief
  brief=$(<"$output")
  assert_equal "$(head -n 1 <<<"$brief")" "# T12 brief (builder): resume rate-limit the applicant sign-in endpoints after a crash"
  assert_contains "$brief" "you are the builder, resuming the task from the checkpoint of 2026-10-23T13:45:00Z: home-pc stopped without a handoff."
  assert_contains "$brief" "Worktree: \`~/.treehouse/Conventioner-d4c77a/4/Conventioner\`, branch \`fix/T12-applicant-sign-in-rate-limit\`"
  assert_contains "$brief" "Up to 5 minutes of work before home-pc stopped may be missing, and so may any no-mistakes run that was in flight"
  assert_contains "$brief" "The uncommitted changes of that checkpoint: applied as uncommitted changes in your worktree."
  assert_contains "$brief" "Check before you build on any of it."
  assert_contains "$brief" "1. Read your brief \`~/agent-team-records/tasks/T12/brief.md\`"
  assert_contains "$brief" "3. Check what is here against what your brief, the tickets and the build notes say is done: \`git status\`, \`git diff\` and \`git log origin/dev..HEAD\`"
}

@test "each delivery brings the branch up to date with the base before reporting, and never uses sudo" {
  open_t12
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local task base brief
  for task in T12:dev T14:main; do
    base=${task#*:} task=${task%:*}
    run_bin -0 team-brief "$task" builder-deliver --set "goal=the goal"
    brief=$(<"$output")
    assert_contains "$brief" "if \`git merge-base --is-ancestor origin/$base HEAD\` fails, merge \`origin/$base\` with a merge commit (\`git merge origin/$base\`, never a rebase)"
    assert_contains "$brief" "goes to \`coordinator\` as \`$task QUESTION <the conflict> | options: ...\`"
    assert_contains "$brief" "epeat step 1; if it merged anything"
    # A direct PR runs its checks again on the merged head; a gated one's merge is checked by CI,
    # never re-gated.
    if [[ $task == T14 ]]; then
      assert_contains "$brief" "so every required check passes on the new head."
    else
      assert_contains "$brief" "a merge of the base is re-reviewed and checked by CI, never re-gated"
    fi
    assert_contains "$brief" "Never run a command that needs \`sudo\`; send \`$task BLOCKED <the command> needs sudo\` to \`coordinator\` instead."
    # The up-to-date check replaced the old refusal when the base moved.
    [[ $brief != *"merge-tree"* && $brief != *"moved:"* ]]
  done
}

@test "an ops brief quotes Daniel's request, links it, and says personal details are never part of the answer" {
  open_task T30 conv research research/T30-ops-market-phases .treehouse/Conventioner-d4c77a/3/Conventioner \
    "markets per phase"
  printf -- '- `docs/implementation/data/`\n- `docs/schema.d.ts`\n' >"$BATS_TEST_TMPDIR/docs.md"
  run_bin -0 team-brief T30 ops --set request='how many markets are in each phase?' \
    --set request_link=https://discord.com/channels/1/2/3 \
    --set-file data_docs="$BATS_TEST_TMPDIR/docs.md"
  assert_equal "$(<"$TEAM_HOME/tasks/T30/brief.md")" "$(
    cat <<'EOF'
# T30 brief (ops): markets per phase

Path: research; you are the ops agent, on the one production request below.
Project: conv (`chanjdaniel/Conventioner`).
Worktree: `~/.treehouse/Conventioner-d4c77a/3/Conventioner`, branch `research/T30-ops-market-phases`.
Task directory: `.scratch/task/` in the worktree (excluded from git), for an answer too long for one message.

## The request

Daniel asked, in https://discord.com/channels/1/2/3:

> how many markets are in each phase?

Personal details are never part of your answer, whatever the request asks: answer with counts, ids and states (your role says why).

## Read first

- `docs/implementation/data/`
- `docs/schema.d.ts`

## Report

Write the answer to `.scratch/answer.md`, then send `T30 DONE <answer>` to `coordinator`.
EOF
  )"
  # An answer with personal details has no path: the brief has no placeholder to ask for one.
  run_bin -1 team-brief T30 ops --set request='every vendor email' --set request_link=https://discord.com/channels/1/2/4 \
    --set personal=yes --set-file data_docs="$BATS_TEST_TMPDIR/docs.md" --name brief-ops-2
  assert_contains "$output" "no placeholder in ops uses: personal"
}

@test "no template repeats a rule from roles/" {
  local file sentence
  # The rules only the role files carry: attribution, denials, the gate's own rules, merging.
  for file in "$REPO_ROOT"/templates/briefs/*.md "$REPO_ROOT"/templates/briefs/*/*.md; do
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
team_code={{team_code}}
team_bin={{team_bin}}
local_checks={{local_checks}}
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
plan=~/agent-team-records/tasks/T14/plan.md
thread=1563000000000000012
team_home=~/agent-team-records
team_code=$code
team_bin=$code/bin
local_checks=none"
}

@test "team_bin is this checkout's bin/, absolute even under HOME, as the allow rules name it" {
  local checkout=$HOME/agent-team
  mkdir -p "$checkout/templates/briefs/delivery"
  copy_bin "$checkout/bin"
  echo '{{team_bin}}/team-review-status' >"$checkout/templates/briefs/bin.md"
  open_t12
  guard_sandbox
  run "$checkout/bin/team-brief" T12 bin
  assert_equal "$status" 0
  assert_equal "$(<"$TEAM_HOME/tasks/T12/brief.md")" "$HOME/agent-team/bin/team-review-status"
}

@test "team_code is this checkout, written ~/... under HOME, apart from the team home" {
  local checkout=$HOME/agent-team
  mkdir -p "$checkout/templates/briefs/delivery"
  copy_bin "$checkout/bin"
  echo '{{team_code}}/sops/platform-gotchas.md {{team_home}}/tasks/' >"$checkout/templates/briefs/code.md"
  open_t12
  guard_sandbox
  run "$checkout/bin/team-brief" T12 code
  assert_equal "$status" 0
  # shellcheck disable=SC2088 # the literal ~ is the point: the brief is read, not run
  assert_equal "$(<"$TEAM_HOME/tasks/T12/brief.md")" "~/agent-team/sops/platform-gotchas.md ~/agent-team-records/tasks/"
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
  assert_equal "$output" "team-brief: unfilled placeholders: goal, read; nothing to derive them from: goal (~/agent-team-records/tasks/T12/plan.md has no ## Goal sentence; --set goal=)"
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

@test "a project's local checks reach the builder's delivery, the review and the rereview" {
  sed -i '/^\[home\]$/,/^\[home.pool\]$/s|^toolkits = \[\]$|toolkits = []\nlocal_checks = ["tests/run", "make lint"]|' \
    "$TEAM_HOME/projects.toml"
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  open_t12
  local brief
  run_bin -0 team-brief T14 builder-deliver --set "goal=the goal"
  brief=$(<"$output")
  assert_contains "$brief" "3. Run the project's local checks (\`tests/run\`, \`make lint\`) on the head you push with \`$REPO_ROOT/bin/team-checks home <full sha>\`, which runs them as \`team-merge\` does, in a fresh detached worktree of that head; fix"
  assert_contains "$brief" "then a line naming the local checks that passed and the head they passed on."
  run_bin -0 team-brief T14 reviewer --name review --set pr=https://github.com/chanjdaniel/agent-team/pull/9 \
    --set head=abc1234 --set "checks=the checks"
  brief=$(<"$output")
  assert_contains "$brief" "- Local checks: \`tests/run\`, \`make lint\`."
  assert_contains "$brief" "Run them on \`abc1234\` with \`$REPO_ROOT/bin/team-checks home abc1234\`, which runs them as \`team-merge\` does, in a fresh detached worktree of that head, and say in \`.work/task/review.md\` whether it passed"
  reviewed_branch T14 main
  run_bin -0 team-brief T14 rereview --name rereview --set pr=https://github.com/chanjdaniel/agent-team/pull/9 \
    --set head="$head"
  assert_contains "$(<"$output")" "3. Run the project's local checks (\`tests/run\`, \`make lint\`) on \`$head\` with \`$REPO_ROOT/bin/team-checks home $head\`, which runs them as \`team-merge\` does"
  # A project without local checks says so.
  run_bin -0 team-brief T12 reviewer --name review --set head=abc1234 --set "checks=the checks"
  assert_contains "$(<"$output")" "- Local checks: none."
}

@test "the direct-PR delivery and the rereview wait on the PR's GitHub checks with team-ci-wait in the background" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local brief files=()
  run_bin -0 team-brief T14 builder-deliver --set "goal=the goal"
  files+=("$output")
  brief=$(<"$output")
  assert_contains "$brief" "5. Wait for the PR's GitHub checks with \`$REPO_ROOT/bin/team-ci-wait <full url> <the full sha you pushed>\`, run with Bash \`run_in_background\`, and act on how it ended: exit 0, every check passed or the head has none; exit 1, fix each failed check it names on the branch and push again, follow a stuck check's message, or, on a head other than the one you pushed, do as its message says, until every check passes; exit 75, run it again, or report as its message says."
  reviewed_branch T14 main
  run_bin -0 team-brief T14 rereview --name rereview --set pr=https://github.com/chanjdaniel/agent-team/pull/9 \
    --set head="$head"
  files+=("$output")
  brief=$(<"$output")
  assert_contains "$brief" "in a fresh detached worktree of that head, and wait for the PR's GitHub checks with \`$REPO_ROOT/bin/team-ci-wait https://github.com/chanjdaniel/agent-team/pull/9 $head\`, run with Bash \`run_in_background\`; every one must pass"
  assert_contains "$brief" "   Act on how the wait ended: exit 0, every check passed or the head has none; exit 1, each failed check it names is a \`blocking\` finding, while a stuck check or a head other than \`$head\` goes to \`coordinator\` as \`T14 BLOCKED <its message>\`; exit 75, run it again, or report as its message says."
  refute_grep -- '--watch' "${files[@]}"
}

@test "the merge-base brief merges the base, resolves, runs the local checks and names the conflicted files" {
  sed -i '/^\[home\]$/,/^\[home.pool\]$/s|^toolkits = \[\]$|toolkits = []\nlocal_checks = ["tests/run"]|' \
    "$TEAM_HOME/projects.toml"
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  run_bin -0 --separate-stderr team-brief T14 builder-merge-base --name merge-base \
    --set pr=https://github.com/chanjdaniel/agent-team/pull/9
  assert_equal "$output" "$TEAM_HOME/tasks/T14/brief-merge-base.md"
  assert_equal "$stderr" ""
  local expected line=0
  expected=$(
    cat <<'EOF'
# T14 brief (builder): merge main into the team's tooling

Path: feature; you are the builder who brings the task's PR up to date with its base, which moved after the PR was opened.
Project: home (`chanjdaniel/agent-team`), base `main`.
Worktree: `~/agent-team/.claude/worktrees/2`, branch `feat/T14-team-tooling`.
PR: https://github.com/chanjdaniel/agent-team/pull/9, against `main`.
Task directory: `.work/task/` in the worktree (excluded from git): `spec.md`, `tickets/`, `build-notes/`, and `handoff.md` when a builder before you stowed.

## Do

1. Read `.work/task/spec.md`, every note in `.work/task/build-notes/` and `.work/task/handoff.md` when it exists, so you resolve each conflict as the task means it; delete `handoff.md` once the merge is pushed.
2. `git fetch origin`, then merge `origin/main` with a merge commit (`git merge origin/main`, never a rebase), and note each file that conflicted.
   If `git merge-base --is-ancestor origin/main HEAD` already holds, there is nothing to merge: go to step 6 with no conflicts.
3. Resolve each conflict so both sides keep what they meant; a resolution that is a judgment call on behaviour goes to `coordinator` as `T14 QUESTION <the conflict> | options: ...`; then commit the merge.
   Then find what the merge made false, a file, command, flag, setting or path that one side renames or removes and the other still names, and fix it in a commit of its own.
4. Run the project's local checks (`tests/run`) on the merged head with `@CODE@/bin/team-checks home <full sha>`, which runs them as `team-merge` does, in a fresh detached worktree of that head; fix the branch until all pass on one head.
5. Push the branch; if the PR body names the head its local checks passed on, bring that line up to date (`gh pr edit https://github.com/chanjdaniel/agent-team/pull/9 --body-file <file>`).
   Wait for the PR's GitHub checks with `@CODE@/bin/team-ci-wait https://github.com/chanjdaniel/agent-team/pull/9 <the full sha you pushed>`, run with Bash `run_in_background`, and act on how it ended: exit 0, every check passed or the head has none; exit 1, fix each failed check it names and push again, back to step 4, follow a stuck check's message, or, on a head other than the one you pushed, do as its message says; exit 75, run it again, or report as its message says.
   Run no gate: the merge and the fixes of step 3 are re-reviewed, not re-gated.
6. Send `T14 DONE merged main <the full sha of the head> conflicts: <each file that conflicted, or none>` to `coordinator`, which has a fresh reviewer re-check the merge.

Never run a command that needs `sudo`; send `T14 BLOCKED <the command> needs sudo` to `coordinator` instead.

## Rules

Read `@CODE@/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
EOF
  )
  expected=${expected//@CODE@/$REPO_ROOT}
  local -a want got
  mapfile -t want <<<"$expected"
  mapfile -t got <"$TEAM_HOME/tasks/T14/brief-merge-base.md"
  for line in "${!want[@]}"; do
    assert_equal "${got[line]-<missing line $((line + 1))>}" "${want[line]}"
  done
  assert_equal "${#got[@]}" "${#want[@]}"
}

# plan_goal <task> <text of the Goal section>: the task's plan.md with a title, that Goal section
# and a Why after it.
plan_goal() {
  printf '# %s plan\n\n## Goal\n\n%s\n\n## Why\n\nBecause.\n' "$1" "$2" >"$TEAM_HOME/tasks/$1/plan.md"
}

# findings_files <worktree under $HOME> <task_dir> <file>...: each file in the worktree's task
# directory, a minute apart, the last named the newest.
findings_files() {
  local dir=$HOME/$1/$2 minutes=$(($# - 2)) file
  mkdir -p "$dir"
  for file in "${@:3}"; do
    echo "# $file" >"$dir/$file"
    touch -d "-$minutes minutes" "$dir/$file"
    minutes=$((minutes - 1))
  done
}

@test "the round brief hands a fresh builder the findings, the stowed builder's handoff and the delivery" {
  open_t12
  findings_files .treehouse/Conventioner-d4c77a/4/Conventioner .scratch/task review.md
  run_bin -0 --separate-stderr team-brief T12 builder-round --name round-2 \
    --set pr=https://github.com/chanjdaniel/shop/pull/5 --set findings="1 and 3" --set goal="the shop's checkout"
  assert_equal "$output" "$TEAM_HOME/tasks/T12/brief-round-2.md"
  local brief
  brief=$(<"$output")
  assert_contains "$brief" "you are a fresh builder taking over the task for one fix round"
  assert_contains "$brief" "PR: https://github.com/chanjdaniel/shop/pull/5, against"
  assert_contains "$brief" "and findings 1 and 3 in \`.scratch/task/review.md\`."
  assert_contains "$brief" "\`.scratch/task/handoff.md\`"
  assert_contains "$brief" 'Run `/no-mistakes` with this intent: "T12: the shop'"'"'s checkout"'
  assert_contains "$brief" "when the PR exists, push to it where a step opens one"
  # A gated project's first review comes before its gate opens the PR: the round takes none, and
  # the builder checks its branch against what the stowed builder pushed, not a PR's head.
  run_bin -0 team-brief T12 builder-round --name round-1 --set pr=none --set findings=2 --set goal=g
  brief=$(<"$output")
  assert_contains "$brief" "PR: none, against \`dev\` (none on a gated project's first review, before its gate opens the PR)."
  assert_contains "$brief" "\`git merge-base --is-ancestor origin/fix/T12-applicant-sign-in-rate-limit HEAD\`"
  assert_contains "$brief" "when it is none, the delivery opens it as it says."
  assert_contains "$brief" 'Run `/no-mistakes` with this intent: "T12: g"'
}

@test "a round brief takes the findings sent back, the newest findings file, the PR and the plan's goal" {
  open_t12
  local wt=.treehouse/Conventioner-d4c77a/4/Conventioner brief
  event T12 review '{verdict: "findings", head: "abc1234", sent_back: [3, 5]}'
  findings_files "$wt" .scratch/task review.md rereview.md
  plan_goal T12 'Applicants cannot flood addresses with sign-in codes.
Nor guess them.'
  # A gated project before its gate: no pr event, so the PR is none.
  run_bin -0 --separate-stderr team-brief T12 builder-round --name round-1
  assert_equal "$stderr" ""
  brief=$(<"$output")
  assert_contains "$brief" "PR: none, against \`dev\` (none on a gated project's first review, before its gate opens the PR)."
  assert_contains "$brief" "and findings 3 and 5 in \`.scratch/task/rereview.md\`."
  assert_contains "$brief" "When every one of findings 3 and 5 is a plain \`note\`"
  assert_contains "$brief" 'Run `/no-mistakes` with this intent: "T12: Applicants cannot flood addresses with sign-in codes."'
  refute_grep -F 'Nor guess them' "$output"
  assert_equal "$(jq -c .values "$TEAM_HOME/tasks/T12/brief-round-1.json")" \
    '{"findings":"3 and 5","findings_file":".scratch/task/rereview.md","goal":"Applicants cannot flood addresses with sign-in codes.","pr":"none"}'
  # The gate opened the PR, a later review sent back one more, and review.md is now the newest.
  event T12 pr '{url: "https://github.com/chanjdaniel/Conventioner/pull/9", head: "def5678"}'
  event T12 review '{verdict: "findings", head: "def5678", sent_back: [6, 7, 9]}'
  findings_files "$wt" .scratch/task rereview.md review.md
  run_bin -0 team-brief T12 builder-round --name round-2
  brief=$(<"$output")
  assert_contains "$brief" "PR: https://github.com/chanjdaniel/Conventioner/pull/9, against \`dev\`"
  assert_contains "$brief" "and findings 6, 7 and 9 in \`.scratch/task/review.md\`."
  # The verify brief takes the same findings.
  run_bin -0 team-brief T12 verify --name verify-2 --set head=def5678 --set reviewed=abc1234
  assert_contains "$(<"$output")" "Sent back: the notes numbered 6, 7 and 9 in"
}

@test "a direct-PR project's round needs its pr event, and a review that sent nothing back gives no findings" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  run_bin -1 team-brief T14 builder-round
  assert_equal "$output" "team-brief: unfilled placeholders: findings, findings_file, goal, pr; nothing to derive them from: findings (T14 has no review; --set findings=), findings_file (no review.md or rereview*.md in ~/agent-team/.claude/worktrees/2/.work/task; --set findings_file=), goal (~/agent-team-records/tasks/T14/plan.md has no ## Goal sentence; --set goal=), pr (T14 has no pr event in chanjdaniel/agent-team; --set pr=)"
  event T14 review '{verdict: "pass", head: "abc1234"}'
  run_bin -1 team-brief T14 builder-round
  assert_contains "$output" "findings (T14's latest review sent nothing back; --set findings=)"
  event T14 review '{verdict: "findings", head: "abc1234", sent_back: []}'
  run_bin -1 team-brief T14 builder-round
  assert_contains "$output" "findings (T14's latest review sent nothing back; --set findings=)"
  assert_equal "$(task_files)" ""
}

@test "a --set of the PR, the findings, their file or the goal wins over the derived one" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  event T14 review '{verdict: "findings", head: "abc1234", sent_back: [3, 5]}'
  event T14 pr '{url: "https://github.com/chanjdaniel/agent-team/pull/9", head: "abc1234"}'
  findings_files agent-team/.claude/worktrees/2 .work/task review.md
  plan_goal T14 'The team has its tooling.'
  run_bin -0 --separate-stderr team-brief T14 builder-round --set pr=https://github.com/chanjdaniel/agent-team/pull/10 \
    --set findings=4 --set findings_file=.work/task/review-2.md --set goal='the given goal.'
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls gh)" ""
  assert_equal "$(jq -c .values "$TEAM_HOME/tasks/T14/brief.json")" \
    '{"findings":"4","findings_file":".work/task/review-2.md","goal":"the given goal.","pr":"https://github.com/chanjdaniel/agent-team/pull/10"}'
  assert_contains "$(<"$output")" "and findings 4 in \`.work/task/review-2.md\`."
  assert_contains "$(<"$output")" '"T14: the given goal."'
}

@test "a deliver brief takes the goal from the plan's Goal section, its first sentence; a plan with none is refused naming --set goal=" {
  open_task T14 home feature feat/T14-team-tooling agent-team/.claude/worktrees/2 "the team's tooling"
  local plan=$TEAM_HOME/tasks/T14/plan.md
  # No plan at all.
  run_bin -1 team-brief T14 builder-deliver
  assert_equal "$output" "team-brief: unfilled placeholders: goal; nothing to derive them from: goal (~/agent-team-records/tasks/T14/plan.md has no ## Goal sentence; --set goal=)"
  # The plan template's comment alone is no goal, and neither is a Goal section left empty.
  sed 's/{{task}}/T14/g' "$REPO_ROOT/templates/plan.md" >"$plan"
  run_bin -1 team-brief T14 builder-deliver
  assert_contains "$output" "goal (~/agent-team-records/tasks/T14/plan.md has no ## Goal sentence; --set goal=)"
  printf '# T14\n\n## Goal\n\n## Why\n\nBecause.\n' >"$plan"
  run_bin -1 team-brief T14 builder-deliver
  assert_contains "$output" "has no ## Goal sentence"
  # A goal under the template's comment: its first sentence, the next line left out.
  plan_goal T14 '<!-- What is true for Daniel.
     In one or two sentences. -->

The team'"'"'s tooling runs on both machines.
Daniel moves it with one command.'
  run_bin -0 team-brief T14 builder-deliver
  assert_contains "$(<"$output")" "its body opening with the task's goal: \"T14: The team's tooling runs on both machines.\", then"
  assert_equal "$(jq -c .values "$TEAM_HOME/tasks/T14/brief.json")" '{"goal":"The team'"'"'s tooling runs on both machines."}'
  # A goal written as a list: its first item, without the marker.
  plan_goal T14 '- The team home stays packed.
- Stack logs stay out of it.'
  run_bin -0 team-brief T14 builder-deliver --force
  assert_contains "$(<"$output")" '"T14: The team home stays packed."'
  # A --set wins.
  run_bin -0 team-brief T14 builder-deliver --force --set goal='the given goal.'
  assert_contains "$(<"$output")" '"T14: the given goal."'
}

# A UI fix's capture (team-ui) in tasks/T<n>/ui/: every brief of a worker who reads or changes
# the code names it, with the rule that a worker checks its fix on its own stack.
@test "a task with a UI capture names it in each planner, builder and reviewer brief; a task without names none" {
  open_t12
  local template brief ui_line rule
  ui_line='- What Daniel pointed at, captured at intake: `~/agent-team-records/tasks/T12/ui/` (`element.png`, `page.png`, `screenshot-1.png`, `ui-pick.md`); `ui-pick.md` names the element'"'"'s page, its `.vue` source file and line, its HTML and its matched CSS.'
  rule='  Check your fix on your own stack with your own headless browser, never in the Agent Chrome, which is Daniel'"'"'s own window.'
  run_bin -0 team-brief T12 builder-fix --set read='- `AGENTS.md`.' --set commits=fix --set goal=g --name none
  refute_grep -F 'tasks/T12/ui' "$TEAM_HOME/tasks/T12/brief-none.md"
  mkdir -p "$TEAM_HOME/tasks/T12/ui"
  touch "$TEAM_HOME/tasks/T12/ui/"{ui-pick.md,element.png,page.png,screenshot-1.png}
  for template in builder-fix builder-round builder-ticket planner-feature planner-research reviewer; do
    local args=()
    [[ $template == builder-fix ]] && args=(--set 'read=- `AGENTS.md`.' --set commits=fix --set goal=g)
    [[ $template == builder-round ]] && args=(--set pr=none --set findings=1 --set findings_file=.scratch/task/review.md --set goal=g)
    [[ $template == builder-ticket ]] && args=(--set ticket=01)
    [[ $template == planner-* ]] && args=(--set 'read=- `AGENTS.md`.')
    [[ $template == reviewer ]] && args=(--set head=abc --set checks=c)
    run_bin -0 team-brief T12 "$template" --name "$template" "${args[@]}"
    brief=$TEAM_HOME/tasks/T12/brief-$template.md
    grep -qxF -- "$ui_line" "$brief" || { echo "$template lacks the UI line" >&2; cat "$brief" >&2; return 1; }
    grep -qxF -- "$rule" "$brief" || { echo "$template lacks the rule" >&2; return 1; }
  done
  # In a reading list, the line follows the others with no blank line between.
  grep -A2 -F -- '- `AGENTS.md`.' "$TEAM_HOME/tasks/T12/brief-builder-fix.md" | sed -n 2p | grep -qxF -- "$ui_line"
}
