# shellcheck shell=bash
# The load check's sandbox, shared by tests/team-load-check.bats and tests/team-load-check-probe.bats:
# load it with `load helpers/load-check` after `load helpers/common`, and call load_check_sandbox
# in setup.
#
#   load_check_sandbox       sandbox, then the code checkout, code (a sandbox repo ignoring .scratch/
#                            and .claude/worktrees/, with a CLAUDE.md, pushed to origin/main), which
#                            TEAM_LOAD_CHECK_CHECKOUT names; wt, the load check's worktree in it,
#                            its first numbered worktree, .claude/worktrees/1;
#                            TEAM_DOCTOR, a stub doctor answering --json with the results
#                            doctor_results last wrote (a PASS of machine until a test calls it), and
#                            failing when they hold a FAIL, as team-doctor does; the registry; and
#                            the machine's name, home-pc, which team-drill records a run on
#   registry [<proj's pool>] projects.toml with the code checkout's own project, code, and a git
#                            pool project, site, and, when given, proj, with that pool, listing
#                            prod-read, prod-write and vercel-read (T0 takes no production toolkit
#                            its project does not list); code is registered, as the real code
#                            checkout is, since team-worker gives a toolkit, the project's
#                            instructions and its memory directory only in a registered project's
#                            worktree
#   project <name> [<toolkits, a TOML list>]
#                            the project's table, its toolkits none by default
#   doctor_results [<verdict> <check>]...
#                            the stub doctor's results: a PASS of machine, then each given one, its
#                            reason "broken" and its fix "repair it"
#   going_on <check>         the line the load check names a FAIL it goes on past with
#   stopped                  the line a doctor FAIL stops the load check with
#   left_nothing             the load check's worktree is gone, and the code checkout is as it was
#   drill_lines              the team home's drill record, each line's fields but at
#   drill_line <drill> <verdict> [<detail>]
#                            the one line a run of <drill> from this checkout should have recorded,
#                            but at
#   recorded <drill> <verdict>
#                            team-drill's line for this checkout's run of <drill>

load_check_sandbox() {
  sandbox
  code=$(make_repo code)
  printf '%s\n' .scratch/ .claude/worktrees/ >"$code/.gitignore"
  # The project's instructions, which team-worker gives each session from origin/main.
  echo "# code" >"$code/CLAUDE.md"
  git -C "$code" add .gitignore CLAUDE.md
  git -C "$code" commit -q -m "chore: ignore scratch and worktrees"
  git -C "$code" push -q origin main
  code=$(realpath "$code") wt=$code/.claude/worktrees/1
  export TEAM_LOAD_CHECK_CHECKOUT=$code
  # The doctor's own lines are tests/team-doctor*.bats'.
  export TEAM_DOCTOR=$BATS_TEST_TMPDIR/doctor
  printf '%s\n' '#!/usr/bin/env bash' '[[ $* == --json ]] || exit 64' 'cat "$BATS_TEST_TMPDIR/doctor.json"' \
    'jq -e "all(.[]; .verdict != \"FAIL\")" "$BATS_TEST_TMPDIR/doctor.json" >/dev/null 2>&1' >"$TEAM_DOCTOR"
  chmod +x "$TEAM_DOCTOR"
  # shellcheck disable=SC2119 # the default results and registry, which a test may rewrite
  doctor_results
  # shellcheck disable=SC2119
  registry
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
}

# shellcheck disable=SC2120 # the tests pass a pool
registry() {
  {
    project code
    printf '%s\n' '[code.pool]' 'provider = "git"' 'slots = []'
    project site
    printf '%s\n' '[site.pool]' 'provider = "git"' 'slots = []'
    if [[ -n ${1:-} ]]; then project proj '["prod-read", "prod-write", "vercel-read"]' && echo "$1"; fi
  } >"$TEAM_HOME/projects.toml"
}

project() {
  printf '%s\n' "[$1]" "repo = \"owner/$1\"" "path = \"projects/$1\"" 'base = "main"' 'delivery = "no-mistakes"' \
    'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' "toolkits = ${2:-[]}"
}

# shellcheck disable=SC2120 # the tests pass results
doctor_results() {
  local results='{"check": "machine", "verdict": "PASS", "reason": "named", "fix": ""}'
  while [[ $# -gt 0 ]]; do
    results+=$(jq -cn --arg verdict "$1" --arg check "$2" '{$check, $verdict, reason: "broken", fix: "repair it"}')
    shift 2
  done
  jq -s . <<<"$results" >"$BATS_TEST_TMPDIR/doctor.json"
}

going_on() {
  echo "load check: going on past FAIL $1: it bears on no session this check starts"
}

# shellcheck disable=SC2034 # read by the tests that load this file
stopped="load check: team-doctor reports a FAIL above; fix it, then run the load check again"

left_nothing() {
  [[ ! -e $wt ]]
  assert_equal "$(git -C "$code" worktree list --porcelain | sed -n 's/^worktree //p')" "$code"
  assert_equal "$(git -C "$code" status --porcelain --ignored)" ""
}

drill_lines() {
  if [[ -e $TEAM_HOME/drills.jsonl ]]; then jq -c 'del(.at)' "$TEAM_HOME/drills.jsonl"; fi
}

drill_line() {
  jq -cn --arg drill "$1" --arg commit "$(git -C "$REPO_ROOT" rev-parse HEAD)" --argjson dirty \
    "$([[ -z $(git -C "$REPO_ROOT" status --porcelain --untracked-files=no) ]] && echo false || echo true)" \
    --arg verdict "$2" --arg detail "${3:-}" \
    '{drill: $drill, machine: "home-pc", commit: $commit, dirty: $dirty, claude: "2.1.321",
      verdict: $verdict, detail: $detail}'
}

recorded() {
  echo "team-drill: recorded $1 $2 on home-pc at $(git -C "$REPO_ROOT" rev-parse --short=7 HEAD)"
}
