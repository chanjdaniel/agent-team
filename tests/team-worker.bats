#!/usr/bin/env bats
# team-worker: starting a worker as a background session, only on the lease holder and in one of
# its task's open worktrees, with its role's settings, and logging the launch.

load helpers/common
load helpers/ops-request

setup() {
  sandbox
  # This machine, home-pc, holds the lease; make_machine laptop builds the other one.
  hold_lease home-pc >/dev/null
  primary=$(make_repo proj)
  wt1=$HOME/slots/proj/1 wt2=$HOME/slots/proj/2
  git -C "$primary" worktree add -q -b feat/T7-one "$wt1"
  git -C "$primary" worktree add -q -b feat/T8-two "$wt2"
  registry proj other
  # The session list holds the session just launched, its process alive, so team-capacity place
  # (on Linux) places it and says nothing.
  stub_script claude <<'EOF'
if [[ $* == "agents --json" ]]; then
  jq -cn --arg name "$(cat "$STUB_FIXTURES/launched" 2>/dev/null)" '[{id: "4f2a9c1e", name: $name, pid: 4242}]'
  exit 0
fi
printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.cwd"
printf '%s\n' "$PATH" >>"$STUB_CALLS/claude.path"
echo "${*: -2:1}" >"$STUB_FIXTURES/launched"
echo "Started background session 4f2a9c1e (${*: -2:1}). Attach with: claude attach 4f2a9c1e"
EOF
  fake_process 4242 1 - claude --bg
  # A reading of the machine with room for every launch, so team-capacity admit takes none.
  capacity_room $((16 * 1073741824))
}

# The claude calls that started a session, one JSON array each.
bg_calls() {
  stub_calls claude | jq -c 'select(.[0] == "--bg")'
}

# The first word of each claude call, space-separated, but the session list team-capacity place
# reads right after a launch, which it reads on Linux only.
claude_verbs() {
  stub_calls claude | jq -r '.[0]' | awk 'last == "--bg" && $0 == "agents" { last = ""; next } { print; last = $0 }' | tr '\n' ' '
}

# ledger_line [jq options...] <filter>: append the line jq builds, standing in for the script
# that writes it.
ledger_line() {
  jq -cn "$@" >>"$TEAM_HOME/ledger.jsonl"
}

thread() {
  ledger_line --arg t "$1" '{ts: (now | todate), task: $t, event: "thread", discord_thread: "1563"}'
}

# opened <task> <project> <branch> <worktree>
opened() {
  ledger_line --arg t "$1" --arg p "$2" --arg b "$3" --arg wt "$4" '{ts: (now | todate), task: $t,
    event: "opened", project: $p, path: "feature", type: "feat", title: "A task", branch: $b,
    base: "main", base_sha: "0123456", worktree: $wt}'
}

# registry [--first <TOML line>] <project>...: a registry holding each project, a git pool of
# slots/<project>/1 and 2, listing every toolkit the tests give, with the TOML line, if any, in the
# first project's table.
registry() {
  local extra='' name
  if [[ $1 == --first ]]; then extra=$2 && shift 2; fi
  : >"$TEAM_HOME/projects.toml"
  for name in "$@"; do
    cat >>"$TEAM_HOME/projects.toml" <<TOML
[$name]
repo = "owner/$name"
path = "projects/$name"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = ["prod-read", "prod-write", "vercel-read", "browser", "codegraph", "effect", "spec-review", "kit-a", "kit-b", "kit-c"]
$extra
pool = { provider = "git", slots = ["slots/$name/1", "slots/$name/2"] }

TOML
    extra=
  done
}

launches() {
  jq -c 'select(.event == "launch") | del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

# ops_refused <message> <argument>...: the launcher run with those arguments exits 1 with
# <message> and nothing else on stderr, starts no session, reads no session list and logs nothing.
ops_refused() {
  run_bin team-worker "${@:2}"
  assert_equal "$status" 1
  assert_equal "$output" "team-worker: $1"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

# A copy of bin/ in a checkout with roles, settings and toolkits written by the test, so the
# merge of settings and toolkits is checked against known inputs. Sets $code.
fake_checkout() {
  code=$BATS_TEST_TMPDIR/code
  mkdir -p "$code/roles" "$code/settings" "$code/toolkits/kit-a" "$code/toolkits/kit-b" "$code/toolkits/kit-c"
  copy_bin "$code/bin"
  echo "You plan." >"$code/roles/planner.md"
  cat >"$code/settings/worker.json" <<'JSON'
{"disableClaudeAiConnectors": true, "env": {"A": "worker", "B": "worker"},
 "permissions": {"deny": ["Bash(git clean*)", "Bash(gh pr merge*)"], "allow": ["Read"]},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "@TEAM_CODE@/bin/hooks/w"}]}],
   "Stop": [{"hooks": [{"type": "command", "command": "s"}]}]}}
JSON
  cat >"$code/settings/planner.json" <<'JSON'
{"env": {"B": "planner"}, "permissions": {"deny": ["Bash(git push*)"], "allow": ["Edit"]},
 "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "@TEAM_CODE@/bin/hooks/x @TEAM_CODE@"}]}]}}
JSON
  echo '{"mcpServers": {"alpha": {"command": "a"}}}' >"$code/toolkits/kit-a/.mcp.json"
  echo '{"mcpServers": {"beta": {"command": "b"}, "gamma": {"command": "c"}}}' >"$code/toolkits/kit-c/.mcp.json"
}

run_fake() {
  guard_sandbox
  run "$code/bin/team-worker" "$@"
}

@test "a malformed command line is a usage error, with nothing started or logged" {
  thread T7
  run_bin -2 team-worker T7 builder
  assert_contains "$output" "usage: team-worker <task> <role> <worktree> [--toolkit <name>]... [--model <alias>] [--request <link>] -- <first prompt>"
  run_bin -2 team-worker 7 builder "$wt1" -- go
  assert_contains "$output" "task must look like T<n>, got '7'"
  run_bin -2 team-worker T7 builder "$wt1" go
  assert_contains "$output" "unexpected argument 'go'"
  run_bin -2 team-worker T7 builder "$wt1" --toolkit
  assert_contains "$output" "--toolkit needs a name"
  run_bin -2 team-worker T7 builder "$wt1"
  assert_contains "$output" "missing '--' before the first prompt"
  run_bin -2 team-worker T7 builder "$wt1" --
  assert_contains "$output" "missing first prompt"
  run_bin -2 team-worker T7 coordinator "$wt1" -- go
  assert_contains "$output" "unknown role 'coordinator'"
  run_bin -2 team-worker T7 builder "$wt1" --toolkit nope -- go
  assert_contains "$output" "unknown toolkit 'nope'"
  run_bin -2 team-worker T7 builder "$wt1" --toolkit coordinator -- go
  assert_contains "$output" "toolkit 'coordinator' is the coordinator's own"
  local bad
  for bad in "" "-x" "a b"; do
    run_bin -2 team-worker T7 reviewer "$wt1" --model "$bad" -- go
    assert_contains "$output" "--model needs a model alias or name"
  done
  run_bin -2 team-worker T7 reviewer "$wt1" --model
  assert_contains "$output" "--model needs a model alias or name"
  run_bin -2 team-worker T7 ops "$wt1" --toolkit prod-read --model sonnet --request https://discord.com/channels/1/2/3 -- go
  assert_contains "$output" "--model is not for the ops role, which runs on the default model"

  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "the frontend toolkit, Daniel's own, is refused for every role and for the load check, with nothing started or logged" {
  thread T7
  local role
  for role in planner builder reviewer ops; do
    run_bin -2 team-worker T7 "$role" "$wt1" --toolkit frontend -- go
    assert_contains "$output" "toolkit 'frontend' is Daniel's own"
  done
  run_bin -2 team-worker T0 planner "$wt1" --toolkit browser --toolkit frontend -- go
  assert_contains "$output" "toolkit 'frontend' is Daniel's own"
  run_bin -2 team-load-check --toolkit frontend
  assert_contains "$output" "toolkit 'frontend' is Daniel's own"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "a task with no Discord thread is refused" {
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "T7 has no Discord thread; open one first with team-thread"
  thread T8
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "T7 has no Discord thread"
  assert_equal "$(stub_calls claude)" ""
}

@test "a primary checkout or a directory outside git is refused" {
  thread T7
  # From another directory, so git's relative answers would be read against the wrong one.
  cd "$HOME"
  run_bin -1 team-worker T7 builder "$primary" -- go
  assert_contains "$output" "$primary is a primary checkout, not a linked worktree"
  mkdir "$HOME/plain"
  run_bin -1 team-worker T7 builder "$HOME/plain" -- go
  assert_contains "$output" "$HOME/plain is not a git checkout"
  run_bin -1 team-worker T7 builder "$HOME/missing" -- go
  assert_contains "$output" "$HOME/missing does not exist"
  # A primary checkout however it is spelled (report F6).
  run_bin -1 team-worker T7 builder "$(other_spelling "$primary")" -- go
  assert_contains "$output" "is a primary checkout, not a linked worktree"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "the session starts in the worktree with the role's settings, an empty MCP config and the prompt last" {
  thread T7
  mkdir -p "$TEAM_HOME/tasks/T7"
  echo "the brief" >"$TEAM_HOME/tasks/T7/brief.md"
  run_bin -0 --separate-stderr team-worker T7 builder "$wt1" -- Read your brief "at $TEAM_HOME/tasks/T7/brief.md"
  assert_equal "$output" "4f2a9c1e"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$wt1"

  local t=$TEAM_HOME/tasks/T7
  assert_equal "$(bg_calls)" "$(jq -cn --arg t "$t" --arg roles "$REPO_ROOT/roles" '["--bg",
    "--strict-mcp-config", "--mcp-config", "\($t)/mcp.builder.json",
    "--settings", "\($t)/settings.builder.json",
    "--append-system-prompt-file", "\($roles)/builder.md",
    "--permission-mode", "auto", "--name", "T7-builder", "Read your brief at \($t)/brief.md"]')"
  assert_equal "$(jq -c . "$t/mcp.builder.json")" '{"mcpServers":{}}'
}

@test "a prompt naming a brief that is missing or unreadable, or saying 'your brief' with none, is refused: nothing started or logged" {
  thread T7
  # The empty path a failed pipe into the prompt leaves.
  run_bin -1 team-worker T7 builder "$wt1" -- "Read your brief at "
  assert_contains "$output" "the prompt says 'your brief' but names no brief*.md file"
  run_bin -1 team-worker T7 builder "$wt1" -- "Read YOUR BRIEF and go"
  assert_contains "$output" "names no brief*.md file"
  run_bin -1 team-worker T7 builder "$wt1" -- "Read your brief at ~/x/tasks/T1/brief-nope.md."
  assert_contains "$output" "the prompt's brief $HOME/x/tasks/T1/brief-nope.md does not exist or cannot be read"
  # A relative path is the worktree's, where the session reads it.
  run_bin -1 team-worker T7 builder "$wt1" -- "Read your brief at brief.md"
  assert_contains "$output" "the prompt's brief $wt1/brief.md does not exist or cannot be read"
  # An ops prompt, the brief's text, is checked the same way.
  run_bin -1 team-worker T7 builder "$wt1" -- "$(printf '# T7 brief (ops)\nSee `%s` first.\n' "$TEAM_HOME/tasks/T7/brief-gone.md")"
  assert_contains "$output" "$TEAM_HOME/tasks/T7/brief-gone.md does not exist or cannot be read"
  mkdir -p "$TEAM_HOME/tasks/T7"
  echo "the brief" >"$TEAM_HOME/tasks/T7/brief.md"
  chmod 000 "$TEAM_HOME/tasks/T7/brief.md"
  run_bin -1 team-worker T7 builder "$wt1" -- "Read your brief at $TEAM_HOME/tasks/T7/brief.md"
  assert_contains "$output" "$TEAM_HOME/tasks/T7/brief.md does not exist or cannot be read"
  # A directory named like a brief is no brief either.
  mkdir "$TEAM_HOME/tasks/T7/brief-dir.md"
  run_bin -1 team-worker T7 builder "$wt1" -- "Read your brief at $TEAM_HOME/tasks/T7/brief-dir.md"
  assert_contains "$output" "brief-dir.md does not exist or cannot be read"
  chmod 644 "$TEAM_HOME/tasks/T7/brief.md"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
  [[ ! -e $TEAM_HOME/tasks/T7/settings.builder.json ]]
}

@test "a launch logs the brief its prompt names under the task's directory, and none for a prompt naming none" {
  thread T7
  mkdir -p "$TEAM_HOME/tasks/T7"
  echo "the brief" >"$TEAM_HOME/tasks/T7/brief-rereview-3.md"
  run_bin -0 team-worker T7 reviewer "$wt1" -- "Read your brief at $TEAM_HOME/tasks/T7/brief-rereview-3.md"
  assert_equal "$output" "4f2a9c1e"
  assert_equal "$(bg_calls | jq -r last)" "Read your brief at $TEAM_HOME/tasks/T7/brief-rereview-3.md"
  assert_equal "$(launches)" "$(jq -cn --arg wt "$wt1" '{task: "T7", event: "launch", role: "reviewer",
    session: "4f2a9c1e", worktree: $wt, toolkits: [], machine: "home-pc", brief: "brief-rereview-3"}')"
  : >"$TEAM_HOME/ledger.jsonl"
  thread T7
  # An ops-shaped prompt, the brief's own text, names no brief.
  run_bin -0 team-worker T7 builder "$wt1" -- "$(printf '# T7 brief (ops): a request\nAnswer the request, then stop.\n')"
  assert_equal "$(launches | jq -c 'has("brief")')" "false"
}

@test "a brief named with ~/, \$HOME or trailing punctuation is found; another task's brief launches with no brief logged" {
  thread T7
  mkdir -p "$TEAM_HOME/tasks/T7" "$TEAM_HOME/tasks/T8"
  echo "seven" >"$TEAM_HOME/tasks/T7/brief-build-02.md"
  echo "eight" >"$TEAM_HOME/tasks/T8/brief.md"
  # The team home as a path from HOME (the sandbox's is beside it: ../team).
  local rel
  rel=$(realpath --relative-to="$HOME" "$TEAM_HOME")
  run_bin -0 team-worker T7 builder "$wt1" -- "Read your brief at ~/$rel/tasks/T7/brief-build-02.md."
  assert_equal "$(launches | jq -r .brief)" "brief-build-02"
  : >"$TEAM_HOME/ledger.jsonl"
  thread T7
  # shellcheck disable=SC2016 # the prompt names $HOME as written
  run_bin -0 team-worker T7 builder "$wt1" -- 'Read your brief ($HOME/'"$rel"'/tasks/T7/brief-build-02.md),'
  assert_equal "$(launches | jq -r .brief)" "brief-build-02"
  : >"$TEAM_HOME/ledger.jsonl"
  thread T7
  run_bin -0 team-worker T7 builder "$wt1" -- "Read your brief \`\${HOME}/$rel/tasks/T7/brief-build-02.md\`;"
  assert_equal "$(launches | jq -r .brief)" "brief-build-02"
  : >"$TEAM_HOME/ledger.jsonl"
  thread T7
  run_bin -0 team-worker T7 builder "$wt1" -- "Read your brief at \"$TEAM_HOME/tasks/T8/brief.md\"."
  assert_equal "$(launches | jq -c 'has("brief")')" "false"
  run_bin -0 team-log --check
}

@test "team-log --check accepts a launch's brief, and --help says what team-worker checks and logs" {
  thread T7
  mkdir -p "$TEAM_HOME/tasks/T7"
  echo "the brief" >"$TEAM_HOME/tasks/T7/brief.md"
  run_bin -0 team-worker T7 builder "$wt1" -- "Read your brief at $TEAM_HOME/tasks/T7/brief.md"
  assert_equal "$(launches | jq -r .brief)" "brief"
  run_bin -0 team-log --check
  # A brief that is not a string is refused.
  local bad
  bad=$(jq -c 'select(.event == "launch") | .brief = 3' "$TEAM_HOME/ledger.jsonl")
  echo "$bad" >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-log --check
  assert_contains "$output" "brief"
  run_bin -0 team-worker --help
  assert_contains "$output" "your brief"
  assert_contains "$output" "brief*.md"
  assert_contains "$output" "logs it as brief"
}

@test "role settings are layered on the worker settings, permission and hook lists concatenated" {
  fake_checkout
  thread T7
  run_fake T7 planner "$wt1" -- go
  assert_equal "$status" "0"
  assert_equal "$(jq -cS . "$TEAM_HOME/tasks/T7/settings.planner.json")" "$(jq -cnS --arg code "$code" '{
    disableClaudeAiConnectors: true, env: {A: "worker", B: "planner"},
    permissions: {deny: ["Bash(git clean*)", "Bash(gh pr merge*)", "Bash(git push*)"], allow: ["Read", "Edit"]},
    hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "\($code)/bin/hooks/w"}]},
        {hooks: [{type: "command", command: "\($code)/bin/hooks/x \($code)"}]}],
      Stop: [{hooks: [{type: "command", command: "s"}]}]}}')"
}

@test "role autoMode lists are concatenated on the worker settings' own, \"\$defaults\" kept once where it first stands" {
  fake_checkout
  jq '.autoMode = {environment: ["$defaults", "shared fact"], soft_deny: ["$defaults"]}' "$code/settings/worker.json" >"$code/w.json"
  mv "$code/w.json" "$code/settings/worker.json"
  jq '.autoMode = {environment: ["$defaults", "planner fact at @TEAM_CODE@"], allow: ["$defaults", "planner allow"]}' \
    "$code/settings/planner.json" >"$code/p.json"
  mv "$code/p.json" "$code/settings/planner.json"
  thread T7
  run_fake T7 planner "$wt1" -- go
  assert_equal "$status" 0
  assert_equal "$(jq -cS .autoMode "$TEAM_HOME/tasks/T7/settings.planner.json")" "$(jq -cnS --arg code "$code" '{
    environment: ["$defaults", "shared fact", "planner fact at \($code)"],
    soft_deny: ["$defaults"], allow: ["$defaults", "planner allow"]}')"

  # With no autoMode in either file, the settings have none.
  fake_checkout
  run_fake T7 planner "$wt1" -- go
  assert_equal "$(jq -c 'has("autoMode")' "$TEAM_HOME/tasks/T7/settings.planner.json")" false
}

@test "every role's generated settings hold the worker settings' autoMode lines, \"\$defaults\" once per list" {
  thread T7
  ops_stub
  local role settings
  for role in planner builder reviewer ops; do
    if [[ $role == ops ]]; then
      run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
    else
      run_bin -0 team-worker T7 "$role" "$wt1" -- go
    fi
    settings=$TEAM_HOME/tasks/T7/settings.$role.json
    # Each line as the worker settings have it, a line with a registry fact rendered.
    assert_equal "$(jq -c --slurpfile w "$REPO_ROOT/settings/worker.json" '
      [.autoMode.environment, $w[0].autoMode.environment] | transpose
      | all(.[]; (.[1] | test("@PROJECT_[A-Z]+@")) or .[0] == .[1])' "$settings")" true
    assert_equal "$(jq -c '[.autoMode[] | map(select(. == "$defaults")) | length] | unique' "$settings")" '[1]'
    assert_equal "$(jq -c '[.autoMode.environment[] | select(test("@[A-Z_]+@"))]' "$settings")" '[]'
    assert_equal "$(jq '.autoMode.environment | length' "$settings")" \
      "$(jq '.autoMode.environment | length' "$REPO_ROOT/settings/worker.json")"
  done
}

@test "the autoMode lines state the registry's projects: repositories, visibility and base branches" {
  registry --first 'visibility = "private"' proj other
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'
[third]
repo = "someone/Third"
path = "elsewhere/third"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["slots/third/1"] }
TOML
  thread T7
  run_bin -0 team-worker T7 builder "$wt1" -- go
  local settings=$TEAM_HOME/tasks/T7/settings.builder.json
  assert_equal "$(jq -r '.autoMode.environment[] | select(startswith("**Source control**"))' "$settings")" \
    "**Source control**: the team's repositories are on GitHub: its team home, chanjdaniel/agent-team-records (~/agent-team-records: the ledger, plans, briefs and memory), and the projects it works on, owner/proj (primary checkout ~/projects/proj), owner/other (primary checkout ~/projects/other) and someone/Third (primary checkout ~/elsewhere/third). agent-team is the team's own code, and no-mistakes is Daniel's fork of the gate, whose pull requests from the team go to the fork itself, never upstream."
  assert_equal "$(jq -r '.autoMode.environment[] | select(startswith("**Repository visibility**"))' "$settings")" \
    "**Repository visibility**: other and Third are public, so whatever reaches them is published; proj is private; agent-team-records, the team home, is private."
  assert_equal "$(jq -r '.autoMode.environment[] | select(startswith("**Default / protected branches**")) | split(";")[0]' "$settings")" \
    "**Default / protected branches**: the base branch is main for proj and other, and dev for Third"
  # Each repository's own origin, its owner from the registry, another owner's too.
  assert_equal "$(jq -r '.autoMode.environment[] | select(startswith("**Trusted repo**"))' "$settings")" \
    "**Trusted repo**: a worker's working directory is a linked git worktree of one of those repositories, on its task's branch, with origin at that repository on GitHub: github.com/owner/proj, github.com/owner/other or github.com/someone/Third; the task's work leaves it as pushes of that branch and one pull request to the project's base branch."

  # One project: one public repository, one base branch.
  registry proj
  run_bin -0 team-worker T7 builder "$wt1" -- go
  assert_equal "$(jq -r '.autoMode.environment[] | select(startswith("**Repository visibility**"))' "$settings")" \
    "**Repository visibility**: proj is public, so whatever reaches it is published; agent-team-records, the team home, is private."
  assert_equal "$(jq -r '.autoMode.environment[] | select(startswith("**Default / protected branches**")) | split(";")[0]' "$settings")" \
    "**Default / protected branches**: the base branch is main for proj"
  assert_equal "$(jq -r '.autoMode.environment[] | select(startswith("**Trusted repo**")) | split(";")[0]' "$settings")" \
    "**Trusted repo**: a worker's working directory is a linked git worktree of one of those repositories, on its task's branch, with origin at that repository on GitHub: github.com/owner/proj"
}

@test "every role's settings run the fence and command guard hooks on Bash; the planner's and reviewer's add the edit hook" {
  thread T7
  local role settings
  for role in planner builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    settings=$TEAM_HOME/tasks/T7/settings.$role.json
    assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$settings")" \
      "$REPO_ROOT/bin/hooks/lease-fence
$REPO_ROOT/bin/hooks/command-guard"
    if [[ $role == builder ]]; then
      assert_equal "$(jq '.hooks.PreToolUse | length' "$settings")" 1
    else
      assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit|NotebookEdit|Bash") | .hooks[].command' "$settings")" \
        "$REPO_ROOT/bin/hooks/scratch-only-edits"
      assert_equal "$(jq '.hooks.PreToolUse | length' "$settings")" 2
    fi
    assert_equal "$(jq -r '.permissions.deny | index("Bash(gh pr merge*)") != null' "$settings")" true
  done
  [[ -x $REPO_ROOT/bin/hooks/scratch-only-edits && -x $REPO_ROOT/bin/hooks/lease-fence && -x $REPO_ROOT/bin/hooks/command-guard ]]
}

@test "every role's generated settings keep onFailure block and the timeout on each PreToolUse hook" {
  thread T7
  ops_stub
  local role settings expected
  for role in planner builder reviewer ops; do
    if [[ $role == ops ]]; then
      run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
    else
      run_bin -0 team-worker T7 "$role" "$wt1" -- go
    fi
    settings=$TEAM_HOME/tasks/T7/settings.$role.json
    expected="lease-fence block 60
command-guard block 10"
    case $role in
      planner | reviewer) expected+=$'\nscratch-only-edits block 30' ;;
      ops) expected+=$'\nscratch-only-edits block 30\nops-log block 30' ;;
    esac
    assert_equal "$(jq -r '.hooks.PreToolUse[].hooks[] | "\(.command | ltrimstr("'"$REPO_ROOT"'/bin/hooks/")) \(.onFailure) \(.timeout)"' "$settings" | sort)" \
      "$(sort <<<"$expected")"
    # The write hook holds ops to its one file, and planners and reviewers to .scratch/.
    case $role in
      planner | reviewer) expected=null ;;
      ops) expected='[".scratch/answer.md"]' ;;
      *) expected='' ;;
    esac
    assert_equal "$(jq -c '.hooks.PreToolUse[].hooks[] | select(.command | endswith("/scratch-only-edits")) | .args' "$settings")" "$expected"
  done
}

@test "toolkits add their plugin directories and only their MCP servers" {
  fake_checkout
  thread T7
  run_fake T7 planner "$wt1" --toolkit kit-a --toolkit kit-b --toolkit kit-c -- go
  assert_equal "$status" "0"
  assert_equal "$(jq -cS . "$TEAM_HOME/tasks/T7/mcp.planner.json")" \
    '{"mcpServers":{"alpha":{"command":"a"},"beta":{"command":"b"},"gamma":{"command":"c"}}}'
  assert_equal "$(bg_calls | jq -c '[index("--plugin-dir") as $i | .[$i:$i + 6]]')" \
    "$(jq -cn --arg k "$code/toolkits" '[["--plugin-dir", "\($k)/kit-a", "--plugin-dir", "\($k)/kit-b", "--plugin-dir", "\($k)/kit-c"]]')"
  assert_equal "$(launches | jq -c .toolkits)" '["kit-a","kit-b","kit-c"]'
}

@test "a session that started without its prompt, or printed no id, is refused and not logged" {
  thread T7
  rm "$STUB_FIXTURES/claude.sh"
  stub_reply claude "Started background session 4f2a9c1e. It is waiting: send a prompt to start."
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "the session started without its prompt"
  stub_reply claude "Something went wrong"
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "could not read the session id from: Something went wrong"
  assert_equal "$(launches)" ""
}

@test "on Linux a launch places its new session in its task's slice, and one it cannot place is a warning while the launch stands" {
  stub_command uname
  stub_reply uname Linux
  fake_placement
  thread T7
  run_bin -0 --separate-stderr team-worker T7 builder "$wt1" -- go
  assert_equal "$output" "4f2a9c1e"
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls busctl | jq -r '.[7]')" "agent-team-T7-4f2a9c1e.scope"
  assert_equal "$(cgroup_of 4242)" "$(user_cgroup agent-team-T7-4f2a9c1e.scope agent-team-T7.slice)"

  # The user manager refuses: the session runs on, unheld, and its launch is logged all the same.
  fake_process 4242 1 - claude --bg
  echo 4242 >"$STUB_FIXTURES/busctl-refuse"
  : >"$TEAM_HOME/ledger.jsonl"
  thread T7
  run_bin -0 --separate-stderr team-worker T7 reviewer "$wt1" -- go
  assert_equal "$output" "4f2a9c1e"
  assert_equal "$stderr" "team-worker: warning: could not place T7-reviewer 4f2a9c1e (pid 4242) in agent-team-T7.slice: Call failed: Access denied; the launch stands"
  assert_equal "$(launches | jq -r .role)" reviewer
}

@test "T0, the load check, needs no thread and no lease, and is not logged" {
  # No lease anywhere: no origin to read one from, and no team name to hold one under.
  git -C "$TEAM_HOME" remote remove origin
  rm "$HOME/.config/agent-team/machine"
  run_bin -0 team-worker T0 planner "$wt1" -- go
  assert_equal "$output" "4f2a9c1e"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "the session gets the library's PATH: the tool directories from tools.lock first" {
  # Arch, where uname says Linux; Bun installed under HOME, which the caller's PATH lacks.
  export TEAM_OS_RELEASE=$BATS_TEST_TMPDIR/os-release
  echo ID=arch >"$TEAM_OS_RELEASE"
  mkdir -p "$HOME/.bun/bin"
  run_bin -0 team-worker T0 planner "$wt1" -- go
  [[ :$(cat "$STUB_CALLS/claude.path"): == *":$HOME/.bun/bin:"*"$BATS_TEST_TMPDIR/stubs:"* ]] ||
    { echo "claude's PATH: $(cat "$STUB_CALLS/claude.path")" >&2; return 1; }
}

@test "a legacy task with no opened event launches in any linked worktree, without project or branch" {
  thread T7
  run_bin -0 team-worker T7 builder "$wt2" -- go
  assert_equal "$(launches)" \
    "$(jq -cn --arg wt "$wt2" '{task: "T7", event: "launch", role: "builder", session: "4f2a9c1e", worktree: $wt, toolkits: [], machine: "home-pc"}')"
  run_bin -0 team-log --check
}

@test "an opened task launches in its own worktree, logging the project and branch" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  # A relative path through a symlink still names the same worktree.
  ln -s "$HOME/slots" "$HOME/link"
  cd "$HOME"
  run_bin -0 team-worker T7 builder link/proj/1 -- go
  assert_equal "$(launches)" "$(jq -cn --arg wt "$wt1" '{task: "T7", event: "launch", role: "builder",
    session: "4f2a9c1e", worktree: $wt, toolkits: [], project: "proj", branch: "feat/T7-one", machine: "home-pc"}')"
  run_bin -0 team-log --check
}

@test "an opened task launches in a worktree added from a second project" {
  local other
  other=$(make_repo other)
  git -C "$other" worktree add -q -b chore/T7-two "$HOME/slots/other/1"
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ledger_line --arg wt "$HOME/slots/other/1" '{ts: (now | todate), task: "T7", event: "worktree-added",
    project: "other", branch: "chore/T7-two", base: "main", base_sha: "0123456", worktree: $wt}'
  run_bin -0 team-worker T7 builder "$HOME/slots/other/1" -- go
  assert_equal "$(launches | jq -c '[.project, .branch, .worktree]')" \
    "$(jq -cn --arg wt "$HOME/slots/other/1" '["other", "chore/T7-two", $wt]')"
}

@test "a project's model for the role is passed to claude and logged on the launch" {
  registry --first 'models = { reviewer = "sonnet", builder = "claude-sonnet-5-5" }' proj other
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  run_bin -0 team-worker T7 reviewer "$wt1" -- Review it
  local t=$TEAM_HOME/tasks/T7
  assert_equal "$(bg_calls)" "$(jq -cn --arg t "$t" --arg roles "$REPO_ROOT/roles" '["--bg",
    "--strict-mcp-config", "--mcp-config", "\($t)/mcp.reviewer.json",
    "--settings", "\($t)/settings.reviewer.json",
    "--append-system-prompt-file", "\($roles)/reviewer.md",
    "--permission-mode", "auto", "--model", "sonnet", "--name", "T7-reviewer", "Review it"]')"
  assert_equal "$(launches)" "$(jq -cn --arg wt "$wt1" '{task: "T7", event: "launch", role: "reviewer",
    session: "4f2a9c1e", worktree: $wt, toolkits: [], project: "proj", branch: "feat/T7-one", machine: "home-pc",
    model: "sonnet"}')"
  run_bin -0 team-log --check

  # Each role takes its own line; one the table does not name takes none.
  : >"$STUB_CALLS/claude.log"
  run_bin -0 team-worker T7 builder "$wt1" -- go
  run_bin -0 team-worker T7 planner "$wt1" -- go
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "--bg") | [(index("--model") // empty) as $i | .[$i + 1]]')" $'["claude-sonnet-5-5"]\n[]'
  assert_equal "$(launches | jq -c '[.role, .model]')" $'["reviewer","sonnet"]\n["builder","claude-sonnet-5-5"]\n["planner",null]'
  run_bin -0 team-log --check
}

@test "the model is the launch worktree's project's: a worktree added from a second project takes that one's" {
  registry --first 'models = { builder = "sonnet" }' other proj
  local other
  other=$(make_repo other)
  git -C "$other" worktree add -q -b chore/T7-two "$HOME/slots/other/1"
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ledger_line --arg wt "$HOME/slots/other/1" '{ts: (now | todate), task: "T7", event: "worktree-added",
    project: "other", branch: "chore/T7-two", base: "main", base_sha: "0123456", worktree: $wt}'
  run_bin -0 team-worker T7 builder "$wt1" -- go
  run_bin -0 team-worker T7 builder "$HOME/slots/other/1" -- go
  assert_equal "$(launches | jq -c '[.project, .model]')" $'["proj",null]\n["other","sonnet"]'
}

@test "--model launches on the model it names instead of the registry's, and logs it, for a legacy task or T0 too" {
  registry --first 'models = { reviewer = "sonnet" }' proj other
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  run_bin -0 team-worker T7 reviewer "$wt1" --model opus -- Review it
  thread T8
  run_bin -0 team-worker T8 builder "$wt2" --model 'sonnet[1m]' -- go
  run_bin -0 team-worker T0 planner "$wt1" --model haiku -- go
  assert_equal "$(bg_calls | jq -c '[(index("--model") // empty) as $i | .[$i + 1], .[-2], .[-1]]')" \
    $'["opus","T7-reviewer","Review it"]\n["sonnet[1m]","T8-builder","go"]\n["haiku","T0-planner","go"]'
  assert_equal "$(launches | jq -c '[.task, .model]')" $'["T7","opus"]\n["T8","sonnet[1m]"]'
  run_bin -0 team-log --check
}

@test "with no models key, a legacy task or T0, no model is passed or logged" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  run_bin -0 team-worker T7 reviewer "$wt1" -- go
  # A legacy task has no project to read a model from, whatever the registry says.
  registry --first 'models = { reviewer = "sonnet" }' proj other
  thread T8
  run_bin -0 team-worker T8 reviewer "$wt2" -- go
  run_bin -0 team-worker T0 reviewer "$wt1" -- go
  assert_equal "$(bg_calls | jq -c 'index("--model")')" $'null\nnull\nnull'
  assert_equal "$(launches | jq -c '[.task, has("model")]')" $'["T7",false]\n["T8",false]'
  run_bin -0 team-log --check
}

@test "a project missing from the registry, or a broken registry, refuses the launch: nothing started or logged" {
  registry other
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  run_bin -1 --separate-stderr team-worker T7 reviewer "$wt1" -- go
  assert_contains "$stderr" "unknown project 'proj'"
  registry --first 'models = { reviewer = 5 }' proj
  run_bin -1 --separate-stderr team-worker T7 reviewer "$wt1" -- go
  assert_contains "$stderr" "proj.models.reviewer: must be a string"
  [[ ! -s $STUB_CALLS/claude.log ]]
  assert_equal "$(launches)" ""
}

@test "an opened task refuses a worktree that is not one of its open worktrees" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  run_bin -1 team-worker T7 builder "$wt2" -- go
  assert_contains "$output" "$wt2 is not one of T7's open worktrees:"
  assert_contains "$output" "  $wt1 (proj, feat/T7-one)"

  ledger_line --arg wt "$wt1" '{ts: (now | todate), task: "T7", event: "worktree-returned", project: "proj", worktree: $wt}'
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "$wt1 is not one of T7's open worktrees: it has none"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "a worktree the ledger spells otherwise is that open worktree (report F6)" {
  thread T7
  opened T7 proj feat/T7-one "$(other_spelling "$(dirname "$wt1")")/${wt1##*/}"
  run_bin -0 team-worker T7 builder "$wt1" -- go
  assert_equal "$(launches | jq -c '[.project, .branch]')" '["proj","feat/T7-one"]'
}

@test "a worktree recorded under another home launches as the same path under this HOME" {
  thread T7
  opened T7 proj feat/T7-one /home/someone/slots/proj/1
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
  run_bin -0 team-worker T7 builder "$wt1" -- go
  assert_equal "$(launches | jq -c '[.project, .branch, .worktree]')" \
    "$(jq -cn --arg wt "$wt1" '["proj", "feat/T7-one", $wt]')"
  # Returned on the other machine, under its own home: no longer open here either.
  ledger_line '{ts: (now | todate), task: "T7", event: "worktree-returned", project: "proj",
    worktree: "/Users/someone/slots/proj/1"}'
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "$wt1 is not one of T7's open worktrees: it has none"
  # The recorded events stay as they were written.
  assert_equal "$(head -n 2 "$TEAM_HOME/ledger.jsonl")" "$(cat "$BATS_TEST_TMPDIR/before")"
}

@test "after a worktree-moved the task launches in the new worktree, not the recorded one" {
  thread T7
  opened T7 proj feat/T7-one /home/someone/slots/proj/1
  git -C "$primary" worktree remove "$wt2"
  git -C "$primary" worktree move "$wt1" "$wt2"
  ledger_line --arg wt "$wt2" '{ts: (now | todate), task: "T7", event: "worktree-moved", project: "proj",
    branch: "feat/T7-one", from: "/home/someone/slots/proj/1", worktree: $wt, machine: "home-pc"}'
  run_bin -0 team-worker T7 builder "$wt2" -- go
  assert_equal "$(launches | jq -c '[.project, .branch, .worktree]')" \
    "$(jq -cn --arg wt "$wt2" '["proj", "feat/T7-one", $wt]')"
  git -C "$primary" worktree add -q -b feat/T9-other "$wt1"
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "$wt1 is not one of T7's open worktrees:"$'\n'"  $wt2 (proj, feat/T7-one)"
  run_bin -0 team-log --check
}

@test "the launch names this machine" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  run_bin -0 team-worker T7 builder "$wt1" -- go
  assert_equal "$(launches | jq -r .machine)" "home-pc"
  run_bin -0 team-log --check
}

@test "with the lease held by the other machine it refuses, naming the holder: no session, no ledger line" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
  make_machine laptop
  run_bin -0 team-lease release
  on_machine laptop run_bin -0 team-lease take
  run_bin -1 --separate-stderr team-worker T7 builder "$wt1" -- go
  assert_equal "$output" ""
  assert_contains "$stderr" "team-lease: home-pc no longer holds the lease: laptop holds it (epoch 2"
  assert_contains "$stderr" "team-worker: laptop holds the lease: run team-resume --wait here, then hand off there once it says this machine is ready"
  assert_equal "$(stub_calls claude)" ""
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
  [[ ! -e $TEAM_HOME/tasks/T7/settings.builder.json ]]
}

@test "with GitHub unreachable it refuses: a worker never starts offline" {
  thread T7
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 --separate-stderr team-worker T7 planner "$wt1" -- go
  assert_equal "$output" ""
  assert_contains "$stderr" "team-lease: GitHub is unreachable"
  assert_contains "$stderr" "team-worker: GitHub unreachable; a worker never starts offline"
  assert_equal "$(stub_calls claude)" ""
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/before"
}

@test "with the lease released, or no team name for this machine, it refuses" {
  thread T7
  run_bin -0 team-lease release
  run_bin -1 --separate-stderr team-worker T7 builder "$wt1" -- go
  assert_contains "$stderr" "team-lease: the lease is released (last held by home-pc, epoch 1)"
  assert_contains "$stderr" "team-worker: a worker starts only on the machine that holds the lease"

  run_bin -0 team-lease take
  echo Home-PC >"$HOME/.config/agent-team/machine"
  run_bin -1 --separate-stderr team-worker T7 builder "$wt1" -- go
  assert_contains "$stderr" "not a lower-case kebab-case name like home-pc"
  assert_contains "$stderr" "team-worker: a worker starts only on the machine that holds the lease"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

# The role prompt and every brief template written for <role>, by the role its first line names
# (or {{role}}, a brief for any role), with the partials each includes: role_texts <role>
role_texts() {
  local brief partial
  echo "$REPO_ROOT/roles/$1.md"
  for brief in "$REPO_ROOT"/templates/briefs/*.md; do
    head -n 1 "$brief" | grep -qE "\((\{\{role\}\}|$1)\)" || continue
    echo "$brief"
    while IFS= read -r partial; do
      printf '%s\n' "$REPO_ROOT/templates/briefs/$partial"/*.md
    done < <(grep -oE '\{\{> [a-z-]+\}\}' "$brief" | sed -E 's/^\{\{> //; s/\}\}$//')
  done
}

@test "each role's settings parse, layer on the worker settings, and keep every tool and skill its prompt and briefs name" {
  thread T7
  ops_stub
  local role settings worker=$REPO_ROOT/settings/worker.json texts
  for role in planner builder reviewer ops; do
    if [[ $role == ops ]]; then
      run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
    else
      run_bin -0 team-worker T7 "$role" "$wt1" -- go
    fi
    settings=$TEAM_HOME/tasks/T7/settings.$role.json
    jq -e . "$settings" >/dev/null
    # The worker settings' rules come first, and its skill overrides hold unless the role's own
    # file overrides the same skill.
    assert_equal "$(jq -c --slurpfile w "$worker" '.permissions.deny[:($w[0].permissions.deny | length)]' "$settings")" \
      "$(jq -c .permissions.deny "$worker")"
    assert_equal "$(jq -c --slurpfile w "$worker" --slurpfile r "$REPO_ROOT/settings/$role.json" \
      '.skillOverrides == ($w[0].skillOverrides * ($r[0].skillOverrides // {}))' "$settings")" true
    assert_equal "$(jq -c '[.syncClaudeAiPlugins, .syncClaudeAiSkills, .enabledPlugins["cc-plugin-plugin-authoring@builtin"]]' "$settings")" \
      '[false,false,false]'
    mapfile -t texts < <(role_texts "$role")
    ((${#texts[@]} > 1)) || { echo "no brief template found for $role" >&2; return 1; }
    keeps_named "$settings" "${texts[@]}" || { echo "in $role's settings" >&2; return 1; }
  done
}

@test "every role's settings name its role in AGENT_TEAM_ROLE, print the gh-axi banner at session start and log each denial" {
  thread T7
  ops_stub
  local role settings
  for role in planner builder reviewer ops; do
    if [[ $role == ops ]]; then
      run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
    else
      run_bin -0 team-worker T7 "$role" "$wt1" -- go
    fi
    settings=$TEAM_HOME/tasks/T7/settings.$role.json
    assert_equal "$(jq -r .env.AGENT_TEAM_ROLE "$settings")" "$role"
    assert_equal "$(jq -c '[.hooks.SessionStart[].hooks[] | [.command, .timeout]]' "$settings")" \
      "$(jq -cn --arg code "$REPO_ROOT" '[["\"\($code)/bin/hooks/axi-banner\" gh-axi", 10]]')"
    assert_equal "$(jq -c '[.hooks.PermissionDenied[] | [.matcher, (.hooks[] | .command, .timeout)]]' "$settings")" \
      "$(jq -cn --arg code "$REPO_ROOT" '[[null, "\($code)/bin/hooks/denial-log", 10]]')"
  done
  [[ -x $REPO_ROOT/bin/hooks/axi-banner && -x $REPO_ROOT/bin/hooks/denial-log ]]
}

@test "a launched worker's chrome-devtools-axi session is named for its task and role" {
  thread T7
  local role
  for role in builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" --toolkit browser -- go
    assert_equal "$(jq -r .env.CHROME_DEVTOOLS_AXI_SESSION "$TEAM_HOME/tasks/T7/settings.$role.json")" "T7-$role"
  done
}

@test "the browser toolkit adds its plugin directory and no MCP server" {
  thread T7
  run_bin -0 team-worker T7 builder "$wt1" --toolkit browser -- go
  assert_equal "$(bg_calls | tail -n 1 | jq -c '[index("--plugin-dir") as $i | .[$i + 1]]')" \
    "$(jq -cn --arg code "$REPO_ROOT" '["\($code)/toolkits/browser"]')"
  assert_equal "$(jq -c . "$TEAM_HOME/tasks/T7/mcp.builder.json")" '{"mcpServers":{}}'
  assert_equal "$(launches | jq -c .toolkits)" '["browser"]'
}

@test "the effect toolkit adds its plugin directory and no MCP server" {
  thread T7
  run_bin -0 team-worker T7 builder "$wt1" --toolkit effect -- go
  assert_equal "$(bg_calls | tail -n 1 | jq -c '[index("--plugin-dir") as $i | .[$i + 1]]')" \
    "$(jq -cn --arg code "$REPO_ROOT" '["\($code)/toolkits/effect"]')"
  assert_equal "$(jq -c . "$TEAM_HOME/tasks/T7/mcp.builder.json")" '{"mcpServers":{}}'
  assert_equal "$(launches | jq -c .toolkits)" '["effect"]'
}

@test "the codegraph toolkit adds its plugin directory and no MCP server" {
  thread T7
  run_bin -0 team-worker T7 builder "$wt1" --toolkit codegraph -- go
  assert_equal "$(bg_calls | tail -n 1 | jq -c '[index("--plugin-dir") as $i | .[$i + 1]]')" \
    "$(jq -cn --arg code "$REPO_ROOT" '["\($code)/toolkits/codegraph"]')"
  assert_equal "$(jq -c . "$TEAM_HOME/tasks/T7/mcp.builder.json")" '{"mcpServers":{}}'
  assert_equal "$(launches | jq -c .toolkits)" '["codegraph"]'
}

@test "the spec-review toolkit adds its plugin directory and no MCP server" {
  thread T7
  run_bin -0 team-worker T7 builder "$wt1" --toolkit spec-review -- go
  assert_equal "$(bg_calls | tail -n 1 | jq -c '[index("--plugin-dir") as $i | .[$i + 1]]')" \
    "$(jq -cn --arg code "$REPO_ROOT" '["\($code)/toolkits/spec-review"]')"
  assert_equal "$(jq -c . "$TEAM_HOME/tasks/T7/mcp.builder.json")" '{"mcpServers":{}}'
  assert_equal "$(launches | jq -c .toolkits)" '["spec-review"]'
}

# fixture_projects: the registry fixture (tests/fixtures/projects.toml), in which conventioner lists
# prod-read and prod-write and agent-team none, with a git checkout at both primary checkouts and
# linked worktrees of them: $conv_wt and $conv_wt2 of conventioner's, $at_wt of agent-team's.
fixture_projects() {
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  conv=$HOME/Documents/projects/personal/Conventioner at=$HOME/agent-team
  conv_wt=$HOME/wt/conventioner-1 conv_wt2=$HOME/wt/conventioner-2 at_wt=$HOME/wt/agent-team-1
  local repo
  for repo in "$conv" "$at"; do
    git init -q -b main "$repo"
    git -C "$repo" commit -q --allow-empty -m "chore: start"
  done
  git -C "$conv" worktree add -q -b feat/T8-conv "$conv_wt"
  git -C "$conv" worktree add -q -b feat/T9-conv "$conv_wt2"
  git -C "$at" worktree add -q -b feat/T7-team "$at_wt"
}

# The tail of every refusal of a toolkit its project does not list.
UNLISTED="a new toolkit for a project takes Daniel's yes, then its name in that project's toolkits line in projects.toml"

@test "a toolkit the worktree's project does not list is refused, naming the project, its list and Daniel's yes, with nothing started or logged" {
  fixture_projects
  ops_stub
  thread T7
  opened T7 agent-team feat/T7-team "$at_wt"
  ops_refused "toolkit 'browser' is not one of agent-team's toolkits in projects.toml (it lists none): $UNLISTED" \
    T7 builder "$at_wt" --toolkit browser -- go
  thread T8
  opened T8 conventioner feat/T8-conv "$conv_wt"
  ops_refused "toolkit 'effect' is not one of conventioner's toolkits in projects.toml (prod-read, prod-write): $UNLISTED" \
    T8 reviewer "$conv_wt" --toolkit effect -- go
  # One toolkit listed and one not: the launch is refused, before Discord is read.
  ops_refused "toolkit 'vercel-read' is not one of conventioner's toolkits in projects.toml (prod-read, prod-write): $UNLISTED" \
    T8 ops "$conv_wt" --toolkit prod-read --toolkit vercel-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$(stub_calls curl)" ""
  # The project is the one the ledger's open worktree names, whichever checkout the worktree is of.
  thread T9
  opened T9 agent-team feat/T9-conv "$conv_wt2"
  ops_refused "toolkit 'prod-read' is not one of agent-team's toolkits in projects.toml (it lists none): $UNLISTED" \
    T9 ops "$conv_wt2" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  run_bin -0 team-worker --help
  assert_contains "$output" "A worker gets only the toolkits its worktree's project lists in the registry (team-project's"
  run_bin -0 team-project --help
  assert_contains "$output" "an allow list"$'\n'"                   team-worker enforces"
}

@test "a toolkit the worktree's project lists launches as today, and so does a launch with no toolkit" {
  fixture_projects
  ops_stub
  thread T8
  opened T8 conventioner feat/T8-conv "$conv_wt"
  run_bin -0 team-worker T8 ops "$conv_wt" --toolkit prod-read --toolkit prod-write --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$(launches | jq -c '{task, role, project, toolkits}')" \
    '{"task":"T8","role":"ops","project":"conventioner","toolkits":["prod-read","prod-write"]}'
  thread T7
  opened T7 agent-team feat/T7-team "$at_wt"
  run_bin -0 team-worker T7 builder "$at_wt" -- go
  assert_equal "$(launches | tail -n 1 | jq -c '{task, role, project, toolkits}')" \
    '{"task":"T7","role":"builder","project":"agent-team","toolkits":[]}'
  assert_equal "$(bg_calls | wc -l)" 2
  run_bin -0 team-log --check
}

@test "T0 and a task with no opened event take the registered project at the worktree's main checkout; a worktree of no registered project gets no toolkit" {
  fixture_projects
  ops_stub
  thread T8
  # proj, the setup's repository, is no project of the fixture's.
  local task
  for task in T8 T0; do
    ops_refused "$(realpath "$wt1") is a worktree of $(realpath "$primary"), which is no registered project's primary checkout in projects.toml, so a worker there gets no toolkit (asked for: browser effect)" \
      "$task" builder "$wt1" --toolkit browser --toolkit effect -- go
  done
  ops_refused "toolkit 'browser' is not one of conventioner's toolkits in projects.toml (prod-read, prod-write): $UNLISTED" \
    T8 builder "$conv_wt" --toolkit browser -- go

  run_bin -0 team-worker T8 ops "$conv_wt" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$(launches | jq -c '{task, role, toolkits}')" '{"task":"T8","role":"ops","toolkits":["prod-read"]}'
  run_bin -0 team-worker T8 builder "$wt1" -- go
  run_bin -0 team-worker T0 ops "$conv_wt" --toolkit prod-read --toolkit prod-write --request "$(ops_request "$OPS_COORDINATOR")" -- go
}

@test "T0 takes any toolkit but a production one whatever its worktree's project lists; a production one needs the project to list it" {
  fixture_projects
  ops_stub
  run_bin -0 team-worker T0 builder "$at_wt" --toolkit browser --toolkit effect -- go
  assert_equal "$(bg_calls | jq -c '[.[index("--plugin-dir") + 1], .[index("--plugin-dir") + 3]]')" \
    "$(jq -cn --arg k "$REPO_ROOT/toolkits" '["\($k)/browser", "\($k)/effect"]')"
  : >"$STUB_CALLS/claude.log"
  ops_refused "toolkit 'vercel-read' is not one of agent-team's toolkits in projects.toml (it lists none): $UNLISTED" \
    T0 ops "$at_wt" --toolkit vercel-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  ops_refused "toolkit 'prod-read' is not one of agent-team's toolkits in projects.toml (it lists none): $UNLISTED" \
    T0 ops "$at_wt" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  ops_refused "toolkit 'vercel-read' is not one of agent-team's toolkits in projects.toml (it lists none): $UNLISTED" \
    T0 ops "$at_wt" --toolkit vercel-read --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
}

@test "the existing toolkit refusals come first and unchanged, on a project that lists none" {
  fixture_projects
  ops_stub
  thread T7
  opened T7 agent-team feat/T7-team "$at_wt"
  run_bin -2 team-worker T7 builder "$at_wt" --toolkit coordinator -- go
  assert_contains "$output" "toolkit 'coordinator' is the coordinator's own (claude-coordinator loads it)"
  run_bin -2 team-worker T7 builder "$at_wt" --toolkit frontend -- go
  assert_contains "$output" "toolkit 'frontend' is Daniel's own"
  run_bin -1 team-worker T7 builder "$at_wt" --toolkit prod-read -- go
  assert_equal "$output" "team-worker: toolkit 'prod-read' is for the ops role only"
  run_bin -1 team-worker T7 ops "$at_wt" --toolkit prod-write --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$output" "team-worker: prod-write needs --toolkit prod-read beside it"
  run_bin -1 team-worker T7 ops "$at_wt" --toolkit prod-read -- go
  assert_equal "$output" "team-worker: the ops role needs --request <the link to Daniel's Discord message>"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "the worker settings take away the tools and skills no worker uses, and the check notices a named one" {
  thread T7
  run_bin -0 team-worker T7 reviewer "$wt1" -- go
  local settings=$TEAM_HOME/tasks/T7/settings.reviewer.json tool
  for tool in Artifact DesignSync ScheduleWakeup CronCreate RemoteTrigger SendFeedback AskUserQuestion EnterWorktree; do
    jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null ||
      { echo "no deny rule for $tool" >&2; return 1; }
  done
  for tool in Bash Read Edit Write Agent Skill ToolSearch SendMessage ListAgents Monitor WebFetch WebSearch; do
    if jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null; then
      echo "denies $tool, which workers use" >&2 && return 1
    fi
  done
  assert_equal "$(jq -c '.skillOverrides | [.lavish, .loop, .implement, .["code-review"]]' "$settings")" '["off","off","off",null]'
  # A brief that names a skill or tool the settings take away fails the check.
  echo 'Run `/implement` on it.' >"$BATS_TEST_TMPDIR/brief.md"
  run keeps_named "$settings" "$BATS_TEST_TMPDIR/brief.md"
  assert_equal "$status" 1
  echo 'Then post it with ScheduleWakeup.' >"$BATS_TEST_TMPDIR/brief.md"
  run keeps_named "$settings" "$BATS_TEST_TMPDIR/brief.md"
  assert_equal "$status" 1
  echo 'Read `skills/code-review/SKILL.md` and use the `tdd` skill.' >"$BATS_TEST_TMPDIR/brief.md"
  run keeps_named "$settings" "$BATS_TEST_TMPDIR/brief.md"
  assert_equal "$status" 0
}

@test "every role's generated settings isolate peer machines" {
  thread T7
  local role
  for role in planner builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    assert_equal "$(jq .isolatePeerMachines "$TEAM_HOME/tasks/T7/settings.$role.json")" true
  done
}

# The deny matrices (sudo and Claude sessions, Docker's prune commands, the 1Password CLI, another
# process's environment and the git hooks setting, team-run-approved, Discord) run on the source
# files in tests/repo.bats; here each role's generated deny list is proved to be those files', and
# one command of each rule family checks that the generated file is the one read.
@test "every role's generated deny list is settings/worker.json's then its role file's, placeholders filled, and denies one command of each rule family" {
  thread T7
  local role settings command bin=$REPO_ROOT/bin
  for role in planner builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    settings=$TEAM_HOME/tasks/T7/settings.$role.json
    assert_equal "$(jq -c .permissions.deny "$settings")" "$(jq -cs --arg code "$REPO_ROOT" --arg dir "$TEAM_HOME/tasks/T7" \
      --arg role "$role" '.[0].permissions.deny + (.[1].permissions.deny // [])
        | map(gsub("@TEAM_CODE@"; $code) | gsub("@TASK_DIR@"; $dir) | gsub("@TASK@"; "T7") | gsub("@ROLE@"; $role))' \
      "$REPO_ROOT/settings/worker.json" "$REPO_ROOT/settings/$role.json")"
    # shellcheck disable=SC2088 # ~ is part of the command as an agent types it
    for command in "sudo -n true" "claude --bg --name x go" "$HOME/.local/bin/claude agents" \
      "docker --context default volume prune" "op read op://agent-team/discord-bot-env/.env" "cat /proc/1234/environ" \
      "git config --unset core.hooksPath" "git -c core.hooksPath=/dev/null commit -m x" "$bin/team-run-approved T7 fix" \
      "$bin/team-ask T7 sign-in --file q.md" "cat ~/.claude/channels/discord/.env" "$bin/team-post --coordinator --file q.md"; do
      denied_in "$settings" "$command" || { echo "$role allows: $command" >&2; return 1; }
    done
  done
}

# Whether an allow rule of <settings> matches <command> and no deny rule does, a rule's * matching
# any text as Claude Code's does, untraced: allowed_in <settings> <command>
allowed_in() {
  [[ -n ${UNTRACED_DEBUG+set} ]] || { untraced allowed_in "$@"; return; }
  local rule
  denied_in "$1" "$2" && return 1
  while IFS= read -r rule; do
    # shellcheck disable=SC2053 # the rule is a glob
    [[ $2 == $rule ]] && return 0
  done < <(jq -r '.permissions.allow[]? | select(startswith("Bash(")) | .[5:-1]' "$1")
  return 1
}

@test "a planner runs only its own task's interview post and wait, by its generated allow rules, and every role's settings name its task" {
  thread T7
  local role settings command bin=$REPO_ROOT/bin
  for role in planner builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    assert_equal "$(jq -r .env.AGENT_TEAM_TASK "$TEAM_HOME/tasks/T7/settings.$role.json")" T7
  done
  settings=$TEAM_HOME/tasks/T7/settings.planner.json
  # --attach after --file needs no rule of its own; team-post holds what it may send.
  for command in "$bin/team-post T7 --thread interview --file $HOME/w/.scratch/task/q1.md" \
    "$bin/team-post T7 --thread interview --file $HOME/w/.scratch/task/q1.md --attach $HOME/w/.scratch/task/shots/1.png --attach $HOME/w/.scratch/task/shots/2.png" \
    "$bin/team-post T7 --thread interview --retract 1564000000000000001" \
    "$bin/team-thread wait T7" "$bin/team-thread wait T7 --after 1564000000000000001"; do
    allowed_in "$settings" "$command" || { echo "planner may not: $command" >&2; return 1; }
  done
  for command in "$bin/team-post T17 --thread interview --file q.md" "$bin/team-post T7 --file q.md" \
    "$bin/team-post T17 --thread interview --retract 1" "$bin/team-post T7 --retract 1" \
    "$bin/team-post T7 --thread task --retract 1" "$bin/team-post T17 --thread interview --file q.md --attach a.png" \
    "$bin/team-post T7 --file q.md --attach a.png" "$bin/team-post --coordinator --file q.md --attach a.png" \
    "$bin/team-thread wait T17" "$bin/team-thread wait T7; $bin/team-post --coordinator --file q.md"; do
    if allowed_in "$settings" "$command"; then echo "planner may: $command" >&2; return 1; fi
  done
}

# T177's builder was refused gh pr ready on its own draft PR, which no rule allowed.
@test "a builder may mark a PR ready for review, never back to a draft, and no other role may" {
  thread T7
  local role settings command
  run_bin -0 team-worker T7 builder "$wt1" -- go
  settings=$TEAM_HOME/tasks/T7/settings.builder.json
  for command in "gh pr ready https://github.com/me/shop/pull/5" "gh pr ready 5 --repo me/shop" \
    "gh-axi pr ready 5"; do
    allowed_in "$settings" "$command" || { echo "builder may not: $command" >&2; return 1; }
  done
  for command in "gh pr ready https://github.com/me/shop/pull/5 --undo" "gh pr ready --undo 5" \
    "gh-axi pr ready 5 --undo"; do
    denied_in "$settings" "$command" || { echo "builder may: $command" >&2; return 1; }
  done
  for role in planner reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    settings=$TEAM_HOME/tasks/T7/settings.$role.json
    for command in "gh pr ready https://github.com/me/shop/pull/5" "gh-axi pr ready 5"; do
      if allowed_in "$settings" "$command"; then echo "$role may: $command" >&2; return 1; fi
    done
  done
}

@test "a closed task is refused, opened or legacy" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ledger_line '{ts: (now | todate), task: "T7", event: "closed", archive: [], returned: [], kept: []}'
  run_bin -1 team-worker T7 builder "$wt1" -- go
  assert_contains "$output" "T7 is closed"
  thread T8
  ledger_line '{ts: "2026-10-01T00:00:00Z", task: "T8", event: "closed"}'
  run_bin -1 team-worker T8 builder "$wt2" -- go
  assert_contains "$output" "T8 is closed"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

# The claude stub for an ops launch: claude agents --json lists $STUB_FIXTURES/agents.json (no
# session by default), and claude --bg starts a session.
ops_stub() {
  echo "${1:-[]}" >"$STUB_FIXTURES/agents.json"
  stub_script claude <<'SH'
if [[ $1 == agents ]]; then cat "$STUB_FIXTURES/agents.json"; exit 0; fi
printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.cwd"
echo "Started background session 5b3c0d2f (${*: -2:1}). Attach with: claude attach 5b3c0d2f"
SH
}

# The claude --bg calls made, without claude agents.
bg_calls() {
  stub_calls claude | jq -c 'select(.[0] == "--bg")'
}

# prod-write's tools in both naming forms: the --mcp-config form and the plugin form.
PROD_WRITE_TOOLS=(insert-many update-many delete-many create-index drop-index)
prod_write_names() {
  local tool
  for tool in "${PROD_WRITE_TOOLS[@]}"; do
    echo "mcp__prod-write__$tool"
    echo "mcp__plugin_prod-write_prod-write__$tool"
  done
}

# assert_prod_write_gated <settings>: an ask rule names every prod-write tool in both forms, the
# glob proven live (T16 ticket 02) covers them all, and no allow rule matches any of them, read
# as a glob the way Claude Code reads a rule's *.
assert_prod_write_gated() {
  local name rule
  while IFS= read -r name; do
    jq -e --arg n "$name" '.permissions.ask | index($n) != null' "$1" >/dev/null ||
      { echo "no ask rule names $name" >&2; return 1; }
    # shellcheck disable=SC2053 # the rules are globs
    [[ $name == mcp__*prod-write* ]] || { echo "the ask glob misses $name" >&2; return 1; }
    while IFS= read -r rule; do
      # shellcheck disable=SC2053
      [[ $name != $rule ]] || { echo "allow rule $rule matches $name" >&2; return 1; }
    done < <(jq -r '.permissions.allow[]?' "$1")
  done < <(prod_write_names)
  jq -e '.permissions.ask | index("mcp__*prod-write*") != null' "$1" >/dev/null
}

@test "an ops launch is restricted to the allowlisted tools and logs Daniel's request, its link and its message" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ops_stub
  local request
  request=$(ops_request "$OPS_COORDINATOR")
  run_bin -0 --separate-stderr team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- Answer the request
  assert_equal "$output" "5b3c0d2f"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$wt1"

  local t=$TEAM_HOME/tasks/T7
  assert_equal "$(stub_calls claude | head -n 1)" '["agents","--json"]'
  assert_equal "$(bg_calls)" "$(jq -cn --arg t "$t" --arg code "$REPO_ROOT" '["--bg",
    "--restricted", "--tools", "Read,Glob,Grep,Edit,Write,ToolSearch,SendMessage,ListAgents,Skill",
    "--strict-mcp-config", "--mcp-config", "\($t)/mcp.ops.json",
    "--plugin-dir", "\($code)/toolkits/prod-read",
    "--settings", "\($t)/settings.ops.json",
    "--append-system-prompt-file", "\($code)/roles/ops.md",
    "--permission-mode", "auto", "--name", "T7-ops", "Answer the request"]')"
  # The message is read back from #coordinator, the one place its link names.
  assert_equal "$(stub_calls curl | jq -r '.[-1]')" "https://discord.com/api/v10/channels/$OPS_COORDINATOR/messages/${request##*/}"
  assert_equal "$(launches)" "$(jq -cn --arg wt "$wt1" --arg r "$request" '{task: "T7", event: "launch",
    role: "ops", session: "5b3c0d2f", worktree: $wt, toolkits: ["prod-read"], project: "proj",
    branch: "feat/T7-one", machine: "home-pc", request: $r, discord_message: ($r | split("/") | last)}')"
  run_bin -0 team-log --check
}

@test "an ops launch on Daniel's message in the task's latest thread passes and logs it, one sent just inside the hour too" {
  thread T7
  ops_stub
  local request
  request=$(ops_request 1563)
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$(stub_calls curl | jq -r '.[-1]')" "https://discord.com/api/v10/channels/1563/messages/${request##*/}"
  assert_equal "$(launches | jq -c '[.request, .discord_message]')" "$(jq -cn --arg r "$request" '[$r, ($r | split("/") | last)]')"
  request=$(ops_request --ago 3540 1563)
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  run_bin -0 team-log --check
}

@test "an ops --request that is not a Discord message link is a malformed command line" {
  thread T7
  ops_stub
  local bad
  for bad in load-check 3 https://discord.com/channels/1/2 https://discord.com/channels/1/2/3/4 \
    https://discord.com/channels/1/2/x http://discord.com/channels/1/2/3 https://example.com/channels/1/2/3 \
    'https://discord.com/channels/1/2/3?x' ' https://discord.com/channels/1/2/3' https://discord.com/channels/@me/2/3 \
    https://discord.com/channels/1/2/0123; do
    run_bin -2 team-worker T7 ops "$wt1" --toolkit prod-read --request "$bad" -- go
    assert_equal "$output" "team-worker: --request must link Daniel's Discord message, https://discord.com/channels/<guild>/<channel>/<message>, got '$bad'"
  done
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(launches)" ""
}

@test "an ops request outside #coordinator and the task's latest thread is refused naming both; T0's outside #coordinator" {
  thread T7
  ledger_line '{ts: (now | todate), task: "T7", event: "thread", discord_thread: "1564"}'
  ops_stub
  local request
  request=$(ops_request 1565)
  ops_refused "the request links a message in channel 1565, which is neither #coordinator ($OPS_COORDINATOR) nor T7's thread (1564): an ops launch needs Daniel's message in one of them" T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  # The task's earlier thread is not its thread now.
  request=$(ops_request 1563)
  ops_refused "the request links a message in channel 1563, which is neither #coordinator ($OPS_COORDINATOR) nor T7's thread (1564): an ops launch needs Daniel's message in one of them" T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  ops_refused "the request links a message in channel 1563, not #coordinator ($OPS_COORDINATOR): T0, the load check, has no thread, so its ops launch needs Daniel's message there" T0 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$(stub_calls curl)" ""
}

@test "an ops request Discord cannot show, or by an author not in allowFrom, is refused with its reason" {
  thread T7
  ops_stub
  local request id
  request=$(ops_request "$OPS_COORDINATOR")
  id=${request##*/}
  rm "$BATS_TEST_TMPDIR/ops-request/$OPS_COORDINATOR-$id.json"
  ops_refused "Discord message $id cannot be fetched from #coordinator $OPS_COORDINATOR: curl: (22) The requested URL returned error: 404" T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  request=$(ops_request --author 999 1563)
  id=${request##*/}
  ops_refused "Discord message $id is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json" T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  echo '{"allowFrom": "757"}' >"$HOME/.claude/channels/discord/access.json"
  request=$(ops_request 1563)
  ops_refused "cannot read allowFrom from ~/.claude/channels/discord/access.json, so the ops request cannot be checked" T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
}

@test "an ops request sent more than an hour before the launch is refused naming when, before Discord is read" {
  thread T7
  ops_stub
  local request id sent
  grep -qx 'OPS_REQUEST_MAX_AGE=3600' "$REPO_ROOT/bin/lib/team.sh"
  request=$(ops_request --ago 3660 "$OPS_COORDINATOR")
  id=${request##*/}
  sent=$(date -ud "@$(((id >> 22) / 1000 + 1420070400))" +%FT%TZ)
  ops_refused "Discord message $id was sent at $sent, more than 60 minutes before this launch, the limit for an ops request: ask Daniel for a new message" T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  ops_refused "Discord message $id was sent at $sent, more than 60 minutes before this launch, the limit for an ops request: ask Daniel for a new message" T0 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$(stub_calls curl)" ""
}

@test "an ops request another ops launch used is refused naming that launch: in the ledger, an older launch's request, or T0's record" {
  thread T7
  thread T5
  ops_stub
  local request id at used
  request=$(ops_request "$OPS_COORDINATOR")
  id=${request##*/}
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  at=$(jq -r 'select(.event == "launch") | .ts' "$TEAM_HOME/ledger.jsonl")
  : >"$STUB_CALLS/claude.log"
  # A relaunch, of this task, another or T0, needs a new message.
  used="Discord message $id asked for T7's ops launch 5b3c0d2f at $at already: each ops launch needs a new message of Daniel's"
  run_bin team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$status" 1
  assert_equal "$output" "team-worker: $used"
  run_bin team-worker T5 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$output" "team-worker: $used"
  run_bin team-worker T0 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$output" "team-worker: $used"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(jq -c 'select(.event == "launch") | .session' "$TEAM_HOME/ledger.jsonl")" '"5b3c0d2f"'

  # A launch from before discord_message was logged names the id at the end of its request; a
  # builder's launch, or a request whose id only ends in the same digits, used none.
  request=$(ops_request "$OPS_COORDINATOR")
  id=${request##*/}
  ledger_line --arg r "$request" '{ts: "2026-11-01T10:00:00Z", task: "T5", event: "launch", role: "ops", session: "0d0d0d0d", worktree: "/w", toolkits: ["prod-read"], request: $r}'
  run_bin team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$output" "team-worker: Discord message $id asked for T5's ops launch 0d0d0d0d at 2026-11-01T10:00:00Z already: each ops launch needs a new message of Daniel's"
  request=$(ops_request "$OPS_COORDINATOR")
  id=${request##*/}
  ledger_line --arg r "https://discord.com/channels/1/2/9$id" '{ts: "2026-11-01T10:00:00Z", task: "T5", event: "launch", role: "ops", session: "0e0e0e0e", worktree: "/w", toolkits: ["prod-read"], request: $r}'
  ledger_line --arg r "$request" '{ts: "2026-11-01T10:00:00Z", task: "T5", event: "launch", role: "builder", session: "0f0f0f0f", worktree: "/w", toolkits: [], request: $r}'
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go

  # T0 logs nothing, so its launch records its message in the machine's state, which counts too.
  local record=$HOME/.local/state/agent-team/ops-requests
  request=$(ops_request "$OPS_COORDINATOR")
  id=${request##*/}
  run_bin -0 team-worker T0 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$(wc -l <"$record")" 1
  [[ $(cat "$record") =~ ^$id\ ([0-9T:-]+Z)\ 5b3c0d2f$ ]]
  at=${BASH_REMATCH[1]}
  : >"$STUB_CALLS/claude.log"
  used="Discord message $id asked for T0's ops launch 5b3c0d2f at $at (~/.local/state/agent-team/ops-requests) already: each ops launch needs a new message of Daniel's"
  run_bin team-worker T0 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$status" 1
  assert_equal "$output" "team-worker: $used"
  run_bin team-worker T7 ops "$wt1" --toolkit prod-read --request "$request" -- go
  assert_equal "$output" "team-worker: $used"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(wc -l <"$record")" 1

  run_bin -0 team-worker --help
  assert_contains "$output" "https://discord.com/channels/<guild>/<channel>/<message>"
  assert_contains "$output" "OPS_REQUEST_MAX_AGE seconds (an hour, bin/lib/team.sh)"
  assert_contains "$output" "a line of ~/.local/state/agent-team/ops-requests"
  assert_contains "$output" "so a relaunch"
}

@test "the generated ops MCP config starts the real prod-read launcher and holds no secret" {
  thread T7
  ops_stub
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  local mcp=$TEAM_HOME/tasks/T7/mcp.ops.json
  assert_equal "$(jq -c . "$mcp")" "$(jq -cn --arg code "$REPO_ROOT" '{mcpServers: {"prod-read": {command: "node",
    args: ["\($code)/toolkits/prod-read/scripts/start-server.mjs"]}}}')"
  run -1 grep -Eq '@TEAM_CODE@|@TASK@|mongodb(\+srv)?://|MDB_MCP|op://|password' "$mcp"
  # The worker settings' deny rules name mongodb+srv:// themselves.
  run -1 grep -Eq 'mongodb(\+srv)?://|MDB_MCP_CONNECTION|op://|password' \
    <(jq 'del(.permissions.deny)' "$TEAM_HOME/tasks/T7/settings.ops.json")
}

@test "the generated ops settings allow only prod-read, vercel-read and the answer file's edits, ask for every prod-write tool, and deny every outbound tool" {
  thread T7
  ops_stub
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  local s=$TEAM_HOME/tasks/T7/settings.ops.json rule
  assert_equal "$(jq -c .permissions.allow "$s")" '["mcp__prod-read__*","mcp__vercel-read__*","Edit(./.scratch/answer.md)"]'
  # The write hook holds the session to that one file, and blocks when it fails.
  assert_equal "$(jq -c '[.hooks.PreToolUse[].hooks[] | select(.command | endswith("/scratch-only-edits"))
    | [.command, .args, .onFailure, .timeout]]' "$s")" \
    "$(jq -cn --arg c "$REPO_ROOT/bin/hooks/scratch-only-edits" '[[$c, [".scratch/answer.md"], "block", 30]]')"
  # The write rules hold even in a read session, where prod-write is not loaded.
  assert_prod_write_gated "$s"
  assert_equal "$(jq '.permissions.ask | length' "$s")" 11
  for rule in Bash WebFetch WebSearch Agent NotebookEdit Artifact ArtifactComments ArtifactData SendUserFile \
    PushNotification SendFeedback DesignSync EnterWorktree CronCreate RemoteTrigger ScheduleWakeup \
    'Read(//proc/**)' 'Bash(op *)' 'Bash(gh pr merge*)'; do
    jq -e --arg r "$rule" '.permissions.deny | index($r) != null' "$s" >/dev/null ||
      { echo "missing deny rule $rule" >&2; return 1; }
  done
  # A worktree's .env files (Conventioner's back-end/.env among them) at any depth. Claude Code
  # applies Read rules to Grep and Glob too, and never matches a Grep(path) or Glob(path) rule.
  jq -e '.permissions.deny | index("Read(**/.env*)") != null' "$s" >/dev/null
  assert_equal "$(jq -r '.permissions.deny[] | select(test("^(Grep|Glob)\\("))' "$s")" ""
  assert_equal "$(jq -c .env.MCP_TIMEOUT "$s")" '"120000"'
  # --restricted ignores the user settings, and without this the coordinator's replies (the
  # write protocol's answers) never reach the session (T16 ticket 04's live check).
  assert_equal "$(jq -r .crossSessionInbound "$s")" accept
  # The same for the push of a permission prompt to Daniel's phone: without these no write
  # prompt reached it (T16 ticket 08's first live run).
  assert_equal "$(jq -c '[.remoteControlAtStartup, .inputNeededNotifEnabled]' "$s")" '[true,true]'
  # The Skill tool is there for the toolkits' skills only: without this the bundled skills and the
  # built-in commands the Skill tool reaches (/init, /security-review) came too (T16 ticket 09's
  # live check).
  assert_equal "$(jq -r .disableBundledSkills "$s")" true
  # A skill's inline shell would run a command in a role that has no shell.
  assert_equal "$(jq -r .disableSkillShellExecution "$s")" true
  # disableBundledSkills leaves the built-in plugin that carries the plugin-authoring skill (T16
  # ticket 09's second live check), which the worker settings turn off for every worker.
  assert_equal "$(jq -c .enabledPlugins "$s")" \
    '{"discord@claude-plugins-official":false,"mongodb-atlas@claude-plugins-official":false,"cc-plugin-plugin-authoring@builtin":false}'
  # The shared hooks come first (lease-fence on Bash, a tool ops lacks), then the role's own.
  assert_equal "$(jq -r '.hooks.PreToolUse[] | "\(.matcher) \(.hooks[0].command)"' "$s" | sed -n 1,2p)" \
    "Bash $REPO_ROOT/bin/hooks/lease-fence
Edit|Write|MultiEdit|NotebookEdit $REPO_ROOT/bin/hooks/scratch-only-edits"
  # The ops log goes to the team home's task directory, which is not this checkout's in a test.
  local event
  for event in PreToolUse PostToolUse PostToolUseFailure; do
    assert_equal "$(jq -c --arg e "$event" '[.hooks[$e][].hooks[0] | select(.command | endswith("/ops-log"))
      | [.command, .args]]' "$s")" \
      "$(jq -cn --arg c "$REPO_ROOT/bin/hooks/ops-log" --arg t "$TEAM_HOME/tasks/T7" '[[$c, [$t]]]')"
  done
}

@test "a write launch adds prod-write's plugin and server beside prod-read's, every write tool behind an ask rule" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ops_stub
  local request
  request=$(ops_request "$OPS_COORDINATOR")
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --toolkit prod-write --request "$request" -- Make the change
  local t=$TEAM_HOME/tasks/T7
  assert_equal "$(bg_calls)" "$(jq -cn --arg t "$t" --arg code "$REPO_ROOT" '["--bg",
    "--restricted", "--tools", "Read,Glob,Grep,Edit,Write,ToolSearch,SendMessage,ListAgents,Skill",
    "--strict-mcp-config", "--mcp-config", "\($t)/mcp.ops.json",
    "--plugin-dir", "\($code)/toolkits/prod-read", "--plugin-dir", "\($code)/toolkits/prod-write",
    "--settings", "\($t)/settings.ops.json",
    "--append-system-prompt-file", "\($code)/roles/ops.md",
    "--permission-mode", "auto", "--name", "T7-ops", "Make the change"]')"

  local mcp=$t/mcp.ops.json
  assert_equal "$(jq -c . "$mcp")" "$(jq -cn --arg code "$REPO_ROOT" '{mcpServers: {
    "prod-read": {command: "node", args: ["\($code)/toolkits/prod-read/scripts/start-server.mjs"]},
    "prod-write": {command: "node", args: ["\($code)/toolkits/prod-write/scripts/start-server.mjs"]}}}')"
  run -1 grep -Eq '@TEAM_CODE@|@TASK@|mongodb(\+srv)?://|MDB_MCP|op://|password' "$mcp"

  local s=$t/settings.ops.json
  assert_prod_write_gated "$s"
  assert_equal "$(jq -c .permissions.allow "$s")" '["mcp__prod-read__*","mcp__vercel-read__*","Edit(./.scratch/answer.md)"]'
  # The ops log's hooks cover both toolkits' tools, and block a write whose line is lost.
  assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | endswith("/ops-log"))
    | "\(.matcher) \(.hooks[0].onFailure)"' "$s")" '^mcp__.*(prod-(read|write)|vercel-read).*__ block'
  run -1 grep -Eq 'mongodb(\+srv)?://|MDB_MCP_CONNECTION|op://|password' <(jq 'del(.permissions.deny)' "$s")

  assert_equal "$(launches | jq -c '[.toolkits, .request]')" "$(jq -cn --arg r "$request" '[["prod-read", "prod-write"], $r]')"
  run_bin -0 team-log --check
}

# The ops log hook's matcher, read from <settings>, matches each <name>: matcher_matches <settings> <name>...
matcher_matches() {
  local matcher name
  matcher=$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | endswith("/ops-log")) | .matcher' "$1")
  for name in "${@:2}"; do
    grep -Eq "$matcher" <<<"$name" || { echo "the ops log matcher $matcher misses $name" >&2; return 1; }
  done
}

@test "a Vercel launch adds vercel-read's plugin and server, alone or beside prod-read's, its tools allowed and logged in both naming forms" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ops_stub
  local t=$TEAM_HOME/tasks/T7 set
  for set in vercel-read 'prod-read vercel-read'; do
    : >"$STUB_CALLS/claude.log"
    local kits args=() plugins=() kit
    read -ra kits <<<"$set"
    for kit in "${kits[@]}"; do args+=(--toolkit "$kit"); plugins+=(--plugin-dir "$REPO_ROOT/toolkits/$kit"); done
    run_bin -0 team-worker T7 ops "$wt1" "${args[@]}" --request "$(ops_request "$OPS_COORDINATOR")" -- Answer the request
    assert_equal "$(bg_calls)" "$(jq -cn --arg t "$t" --arg code "$REPO_ROOT" \
      --argjson plugins "$(printf '%s\n' "${plugins[@]}" | jq -R . | jq -sc .)" '["--bg",
      "--restricted", "--tools", "Read,Glob,Grep,Edit,Write,ToolSearch,SendMessage,ListAgents,Skill",
      "--strict-mcp-config", "--mcp-config", "\($t)/mcp.ops.json"] + $plugins + [
      "--settings", "\($t)/settings.ops.json",
      "--append-system-prompt-file", "\($code)/roles/ops.md",
      "--permission-mode", "auto", "--name", "T7-ops", "Answer the request"]')"

    # The real launcher, which reads its tokens itself: the config holds no secret.
    local mcp=$t/mcp.ops.json
    assert_equal "$(jq -c '.mcpServers["vercel-read"]' "$mcp")" \
      "$(jq -cn --arg code "$REPO_ROOT" '{command: "node", args: ["\($code)/toolkits/vercel-read/scripts/start-server.mjs"]}')"
    assert_equal "$(jq -c '.mcpServers | keys' "$mcp")" "$(jq -cn --args '$ARGS.positional' "${kits[@]}")"
    run -1 grep -Eq '@TEAM_CODE@|@TASK@|vcp_|VERCEL|op://|token|mongodb(\+srv)?://|password' "$mcp"

    local s=$t/settings.ops.json
    assert_equal "$(jq -c .permissions.allow "$s")" '["mcp__prod-read__*","mcp__vercel-read__*","Edit(./.scratch/answer.md)"]'
    assert_prod_write_gated "$s"
    matcher_matches "$s" mcp__vercel-read__list-deployments mcp__plugin_vercel-read_vercel-read__runtime-logs \
      mcp__prod-read__find mcp__plugin_prod-write_prod-write__delete-many
    run -1 grep -Eq 'vcp_|op://|password' <(jq 'del(.permissions.deny)' "$s")
    assert_equal "$(launches | tail -n 1 | jq -c .toolkits)" "$(jq -cn --args '$ARGS.positional' "${kits[@]}")"
  done
  run_bin -0 team-log --check
}

@test "an ops launch takes no model, whatever its project's models table names" {
  registry --first 'models = { planner = "sonnet", builder = "sonnet", reviewer = "sonnet" }' proj other
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  ops_stub
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- Answer the request
  assert_equal "$(bg_calls | jq -c 'index("--model")')" "null"
  assert_equal "$(launches | jq -c 'has("model")')" "false"
}

@test "only the ops role is restricted" {
  thread T7
  local role
  for role in planner builder reviewer; do
    : >"$STUB_CALLS/claude.log"
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "--bg") | map(select(. == "--restricted" or . == "--tools"))')" '[]'
  done
}

@test "production toolkits, vercel-read among them, are refused for every role but ops, with nothing started or logged" {
  thread T7
  ops_stub
  local role
  for role in planner builder reviewer; do
    run_bin -1 team-worker T7 "$role" "$wt1" --toolkit prod-read -- go
    assert_contains "$output" "toolkit 'prod-read' is for the ops role only"
    run_bin -1 team-worker T7 "$role" "$wt1" --toolkit prod-write -- go
    assert_contains "$output" "toolkit 'prod-write' is for the ops role only"
    run_bin -1 team-worker T7 "$role" "$wt1" --toolkit vercel-read -- go
    assert_contains "$output" "toolkit 'vercel-read' is for the ops role only"
  done
  run_bin -2 team-worker T7 builder "$wt1" --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_contains "$output" "--request is for the ops role only"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "an ops launch without prod-read or vercel-read, prod-write without prod-read or beside vercel-read, or a launch without Daniel's request is refused" {
  fake_checkout
  mkdir -p "$code/toolkits/prod-read" "$code/toolkits/prod-write" "$code/toolkits/vercel-read"
  cp "$REPO_ROOT/roles/ops.md" "$code/roles/" && cp "$REPO_ROOT/settings/ops.json" "$code/settings/"
  thread T7
  ops_stub
  run_fake T7 ops "$wt1" --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$status" 1
  assert_contains "$output" "the ops role needs --toolkit prod-read or --toolkit vercel-read"
  run_fake T7 ops "$wt1" --toolkit kit-a --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$status" 1
  assert_contains "$output" "the ops role needs --toolkit prod-read or --toolkit vercel-read"
  run_fake T7 ops "$wt1" --toolkit prod-write --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$status" 1
  assert_contains "$output" "prod-write needs --toolkit prod-read beside it"
  run_fake T7 ops "$wt1" --toolkit vercel-read --toolkit prod-write --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$status" 1
  assert_contains "$output" "prod-write needs --toolkit prod-read beside it"
  # The ops load check proves no write session with vercel-read, so none launches.
  run_fake T7 ops "$wt1" --toolkit prod-read --toolkit prod-write --toolkit vercel-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$status" 1
  assert_contains "$output" "prod-write takes no --toolkit vercel-read beside it"
  run_fake T7 ops "$wt1" --toolkit vercel-read -- go
  assert_equal "$status" 1
  assert_contains "$output" "the ops role needs --request <the link to Daniel's Discord message>"
  run_fake T7 ops "$wt1" --toolkit prod-read -- go
  assert_equal "$status" 1
  assert_contains "$output" "the ops role needs --request <the link to Daniel's Discord message>"
  run_fake T7 ops "$wt1" --toolkit prod-read --request "" -- go
  assert_equal "$status" 2
  assert_contains "$output" "--request needs Daniel's Discord message link"
  assert_equal "$(stub_calls claude)" ""
  assert_equal "$(launches)" ""
}

@test "an ops launch is refused while any task's ops session is listed" {
  thread T7
  ops_stub '[{"id": "11111111", "name": "T7-builder"}, {"id": "22222222", "name": "T5-ops", "state": "done"}]'
  run_bin -1 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_contains "$output" "an ops session is already listed: T5-ops (22222222); end it with team-ops-end first"
  assert_equal "$(bg_calls)" ""
  assert_equal "$(launches)" ""

  stub_reply claude "not json"
  rm "$STUB_FIXTURES/claude.sh"
  run_bin -1 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_contains "$output" "cannot read the live session list"
  assert_equal "$(bg_calls)" ""
}

@test "no placeholder is left in any role's generated settings and MCP config from this checkout" {
  thread T7
  local role
  for role in planner builder reviewer; do
    run_bin -0 team-worker T7 "$role" "$wt1" -- go
    run -1 grep -Eq '@[A-Z_]+@' "$TEAM_HOME/tasks/T7/settings.$role.json" "$TEAM_HOME/tasks/T7/mcp.$role.json"
  done
  ops_stub
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --toolkit prod-write --request "$(ops_request "$OPS_COORDINATOR")" -- go
  grep -q "$REPO_ROOT/bin/hooks/ops-log" "$TEAM_HOME/tasks/T7/settings.ops.json"
  grep -q "$REPO_ROOT/toolkits/prod-write/" "$TEAM_HOME/tasks/T7/mcp.ops.json"
  run -1 grep -Eq '@[A-Z_]+@' "$TEAM_HOME/tasks/T7/settings.ops.json" "$TEAM_HOME/tasks/T7/mcp.ops.json"
}

@test "@TEAM_CODE@, @TASK@, @TASK_DIR@ and @ROLE@ are substituted in the settings and the MCP config" {
  fake_checkout
  echo '{"env": {"WHO": "@ROLE@"}, "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "@TEAM_CODE@/bin/hooks/x @TASK@", "args": ["@TASK_DIR@"]}]}]}}' \
    >"$code/settings/planner.json"
  echo '{"mcpServers": {"alpha": {"command": "@TEAM_CODE@/a", "args": ["--task", "@TASK@", "@TASK_DIR@", "@ROLE@"]}}}' >"$code/toolkits/kit-a/.mcp.json"
  thread T7
  run_fake T7 planner "$wt1" --toolkit kit-a -- go
  assert_equal "$status" 0
  # The role's hook comes after the shared settings' own.
  assert_equal "$(jq -c '.hooks.PreToolUse[-1].hooks[0] | [.command, .args[0]]' "$TEAM_HOME/tasks/T7/settings.planner.json")" \
    "$(jq -cn --arg code "$code" --arg t "$TEAM_HOME/tasks/T7" '["\($code)/bin/hooks/x T7", $t]')"
  assert_equal "$(jq -r .env.WHO "$TEAM_HOME/tasks/T7/settings.planner.json")" planner
  assert_equal "$(jq -c . "$TEAM_HOME/tasks/T7/mcp.planner.json")" \
    "$(jq -cn --arg code "$code" --arg t "$TEAM_HOME/tasks/T7" '{mcpServers: {alpha: {command: "\($code)/a", args: ["--task", "T7", $t, "planner"]}}}')"
}

# The ledger lines given on stdin, one per line, each "launch <task> <role> <session> <worktree>"
# or "<task> <jq object of the event's other fields>", logged in order.
log_lines() {
  local kind task role session wt more
  while read -r kind more; do
    if [[ $kind == launch ]]; then
      read -r task role session wt <<<"$more"
      ledger_line --arg t "$task" --arg r "$role" --arg s "$session" --arg wt "$wt" '{ts: (now | todate), task: $t,
        event: "launch", role: $r, session: $s, worktree: $wt, toolkits: [], machine: "home-pc"}'
    else
      ledger_line --arg t "$kind" "{ts: (now | todate), task: \$t} + ($more)"
    fi
  done
}

# The claude stub for launches beside a task's earlier workers: claude agents --json lists
# $STUB_FIXTURES/agents.json; claude stop succeeds unless the id is in $STUB_FIXTURES/stop-fails;
# claude --bg starts a session.
stop_stub() {
  : >"$STUB_FIXTURES/stop-fails"
  stub_script claude <<'SH'
if [[ $1 == agents ]]; then cat "$STUB_FIXTURES/agents.json"; exit 0; fi
if [[ $1 == stop ]]; then
  if grep -qx "$2" "$STUB_FIXTURES/stop-fails"; then echo "no such session $2" >&2; exit 1; fi
  echo "Stopped $2"; exit 0
fi
echo "Started background session 9a8b7c6d (${*: -2:1}). Attach with: claude attach 9a8b7c6d"
SH
}

# T9's earlier workers, each listed live by claude agents --json: an idle planner, builder and
# reviewer, a busy second builder, an idle reviewer waiting for input, an idle ops session, an
# idle builder of the second worktree (its launch recorded under another machine's home, as the
# first worktree's builders are), a reviewer with no status and one starting, all handed on by
# the planner's done, a ticket-done and each reviewer's done beside the review; then a reviewer
# and a planner launched after them, idle with no event of their own since (the planner's done
# names another session); and T8's idle reviewer, handed on by its done beside T8's review, with
# a session T9 never launched.
finished_workers() {
  thread T8
  thread T9
  log_lines <<LINES
launch T9 planner 11111111 $wt1
launch T9 builder 22222222 /Users/someone/slots/proj/1
launch T9 reviewer 33333333 $wt1
launch T9 builder 44444444 $wt1
launch T9 reviewer 55555555 $wt1
launch T9 ops 66666666 $wt1
launch T9 builder 99999999 /Users/someone/slots/proj/2
launch T8 reviewer 77777777 $wt1
launch T9 reviewer 3a3a3a3a $wt1
launch T9 reviewer 3b3b3b3b $wt1
T9 {event: "done", role: "planner", session: "11111111"}
T9 {event: "ticket-done", ticket: "01", commits: ["abc1234"]}
T9 {event: "review", verdict: "findings", head: "abc1234"}
T9 {event: "done", role: "reviewer", session: "33333333"}
T9 {event: "done", role: "reviewer", session: "55555555"}
T9 {event: "done", role: "reviewer", session: "3a3a3a3a"}
T9 {event: "done", role: "reviewer", session: "3b3b3b3b"}
T8 {event: "review", verdict: "pass", head: "abc1234"}
T8 {event: "done", role: "reviewer", session: "77777777"}
launch T9 reviewer 5c5c5c5c $wt1
launch T9 planner 1e1e1e1e $wt1
T9 {event: "done", role: "planner", session: "0e0e0e0e"}
LINES
  cat >"$STUB_FIXTURES/agents.json" <<'JSON'
[{"id": "11111111", "name": "T9-planner", "status": "idle"},
 {"id": "22222222", "name": "T9-builder", "status": "idle"},
 {"id": "33333333", "name": "T9-reviewer", "status": "idle"},
 {"id": "44444444", "name": "T9-builder", "status": "busy"},
 {"id": "55555555", "name": "T9-reviewer", "status": "idle", "state": "blocked"},
 {"id": "66666666", "name": "T9-ops", "status": "idle"},
 {"id": "77777777", "name": "T8-reviewer", "status": "idle"},
 {"id": "88888888", "name": "T9-builder", "status": "idle"},
 {"id": "99999999", "name": "T9-builder", "status": "idle"},
 {"id": "3a3a3a3a", "name": "T9-reviewer"},
 {"id": "3b3b3b3b", "name": "T9-reviewer", "status": "starting"},
 {"id": "5c5c5c5c", "name": "T9-reviewer", "status": "idle"},
 {"id": "1e1e1e1e", "name": "T9-planner", "status": "idle"}]
JSON
  stop_stub
}

# The ids claude stop was called with, one per line.
stops() {
  stub_calls claude | jq -r 'select(.[0] == "stop") | .[1]'
}

@test "a builder's launch stops the task's idle, handed-on planners, reviewers and builders of its worktree, and leaves the rest" {
  finished_workers
  run_bin -0 --separate-stderr team-worker T9 builder "$wt1" -- go
  assert_equal "$output" "9a8b7c6d"
  assert_equal "$(stops)" $'11111111\n22222222\n33333333'
  assert_contains "$stderr" "team-worker: stopped T9-planner 11111111: its work is handed on"
  assert_contains "$stderr" "team-worker: stopped T9-builder 22222222: its work is handed on"
  assert_contains "$stderr" "team-worker: stopped T9-reviewer 33333333: its work is handed on"
  assert_contains "$stderr" "team-worker: left T9-builder 44444444: busy"
  assert_contains "$stderr" "team-worker: left T9-reviewer 55555555: waiting for input"
  assert_contains "$stderr" "team-worker: left T9-reviewer 3a3a3a3a: no status"
  assert_contains "$stderr" "team-worker: left T9-reviewer 3b3b3b3b: status starting"
  assert_contains "$stderr" "team-worker: left T9-reviewer 5c5c5c5c: idle with no event of its own since its launch"
  assert_contains "$stderr" "team-worker: left T9-planner 1e1e1e1e: idle with no event of its own since its launch"
  # An ops session, another task's, one T9 never launched and another worktree's builder go unnamed.
  [[ $stderr != *66666666* && $stderr != *77777777* && $stderr != *88888888* && $stderr != *99999999* ]]
  # The stops come before the launch, which is logged.
  assert_equal "$(claude_verbs)" "agents stop stop stop --bg "
  assert_equal "$(launches | jq -r 'select(.task == "T9" and .session == "9a8b7c6d") | .role')" builder
}

@test "a builder is handed on by a stow, and left while nothing of its own follows its launch" {
  thread T9
  log_lines <<LINES
launch T9 builder 2f2f2f2f $wt1
LINES
  echo '[{"id": "2f2f2f2f", "name": "T9-builder", "status": "idle"}]' >"$STUB_FIXTURES/agents.json"
  stop_stub
  run_bin -0 --separate-stderr team-worker T9 reviewer "$wt1" -- go
  run_bin -0 --separate-stderr team-worker T9 builder "$wt1" -- go
  assert_equal "$(stops)" ""
  assert_contains "$stderr" "team-worker: left T9-builder 2f2f2f2f: idle with no event of its own since its launch"
  log_lines <<<'T9 {event: "paused", reason: "stowed"}'
  run_bin -0 --separate-stderr team-worker T9 builder "$wt1" -- go
  assert_equal "$(stops)" 2f2f2f2f
}

@test "a paused for any reason but stowed leaves an idle reviewer, a resumed after it too" {
  thread T9
  log_lines <<LINES
launch T9 reviewer 6a6a6a6a $wt1
T9 {event: "paused", reason: "offline"}
LINES
  echo '[{"id": "6a6a6a6a", "name": "T9-reviewer", "status": "idle"}]' >"$STUB_FIXTURES/agents.json"
  stop_stub
  run_bin -0 --separate-stderr team-worker T9 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$(stops)" ""
  assert_contains "$stderr" "team-worker: left T9-reviewer 6a6a6a6a: idle with no event of its own since its launch"
  log_lines <<<'T9 {event: "resumed"}'
  run_bin -0 --separate-stderr team-worker T9 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$(stops)" ""
  assert_contains "$stderr" "team-worker: left T9-reviewer 6a6a6a6a: idle with no event of its own since its launch"
}

@test "a reviewer is handed on only by a done of its own session, never by another reviewer's review" {
  thread T9
  log_lines <<LINES
launch T9 reviewer 6b6b6b6b $wt1
launch T9 reviewer 6c6c6c6c $wt2
T9 {event: "review", verdict: "findings", head: "abc1234"}
T9 {event: "done", role: "reviewer", session: "6c6c6c6c"}
LINES
  echo '[{"id": "6b6b6b6b", "name": "T9-reviewer", "status": "idle"}, {"id": "6c6c6c6c", "name": "T9-reviewer", "status": "idle"}]' \
    >"$STUB_FIXTURES/agents.json"
  stop_stub
  run_bin -0 --separate-stderr team-worker T9 builder "$wt2" -- go
  assert_equal "$(stops)" 6c6c6c6c
  assert_contains "$stderr" "team-worker: left T9-reviewer 6b6b6b6b: idle with no event of its own since its launch"
}

@test "a stow hands a planner on once a later planner launch of its worktree follows it, a resumed between them or not" {
  thread T9
  log_lines <<LINES
launch T9 planner 6d6d6d6d $wt1
T9 {event: "paused", reason: "stowed"}
T9 {event: "resumed"}
launch T9 planner 6e6e6e6e $wt1
LINES
  echo '[{"id": "6d6d6d6d", "name": "T9-planner", "status": "idle"}, {"id": "6e6e6e6e", "name": "T9-planner", "status": "idle"}]' \
    >"$STUB_FIXTURES/agents.json"
  stop_stub
  run_bin -0 --separate-stderr team-worker T9 reviewer "$wt1" -- go
  assert_equal "$(stops)" 6d6d6d6d
  assert_contains "$stderr" "team-worker: left T9-planner 6e6e6e6e: idle with no event of its own since its launch"
}

@test "a stow hands on only the launches of the fresh worker's role and worktree, never another worktree's reviewer" {
  thread T9
  log_lines <<LINES
launch T9 reviewer 7a7a7a7a $wt1
launch T9 builder 7b7b7b7b $wt2
T9 {event: "paused", reason: "stowed"}
LINES
  echo '[{"id": "7a7a7a7a", "name": "T9-reviewer", "status": "idle"}, {"id": "7b7b7b7b", "name": "T9-builder", "status": "idle"}]' \
    >"$STUB_FIXTURES/agents.json"
  stop_stub
  run_bin -0 --separate-stderr team-worker T9 builder "$wt2" -- go
  assert_equal "$(stops)" 7b7b7b7b
  assert_contains "$stderr" "team-worker: left T9-reviewer 7a7a7a7a: idle with no event of its own since its launch"
  # A later reviewer launch in another worktree does not resume 7a7a7a7a's work; one in its own does.
  echo '[{"id": "7a7a7a7a", "name": "T9-reviewer", "status": "idle"}]' >"$STUB_FIXTURES/agents.json"
  log_lines <<<"launch T9 reviewer 7c7c7c7c $wt2"
  run_bin -0 --separate-stderr team-worker T9 builder "$wt2" -- go
  assert_equal "$(stops)" 7b7b7b7b
  log_lines <<<"launch T9 reviewer 7d7d7d7d $wt1"
  run_bin -0 --separate-stderr team-worker T9 builder "$wt2" -- go
  assert_equal "$(stops)" $'7b7b7b7b\n7a7a7a7a'
}

@test "a reviewer's launch stops the idle reviewers and planner and leaves the idle builder, which holds the task" {
  finished_workers
  run_bin -0 --separate-stderr team-worker T9 reviewer "$wt1" -- go
  assert_equal "$(stops)" $'11111111\n33333333'
  [[ $stderr != *22222222* ]]
}

@test "a stop that fails warns, naming the session, and the launch goes on and is logged" {
  finished_workers
  echo 22222222 >"$STUB_FIXTURES/stop-fails"
  run_bin -0 --separate-stderr team-worker T9 builder "$wt1" -- go
  assert_equal "$output" "9a8b7c6d"
  assert_equal "$(stops)" $'11111111\n22222222\n33333333'
  assert_contains "$stderr" "team-worker: warning: could not stop T9-builder 22222222 (no such session 22222222); the launch goes on"
  assert_equal "$(launches | jq -r 'select(.session == "9a8b7c6d") | .task')" T9
}

@test "an unreadable session list warns and the launch goes on, stopping nothing" {
  finished_workers
  echo "not json" >"$STUB_FIXTURES/agents.json"
  run_bin -0 --separate-stderr team-worker T9 builder "$wt1" -- go
  assert_equal "$(stops)" ""
  assert_contains "$stderr" "team-worker: warning: cannot read the live session list (claude agents --json), so no finished session was stopped"
  assert_equal "$(launches | jq -r 'select(.session == "9a8b7c6d") | .task')" T9
}

@test "an ops launch stops the idle, handed-on planners and reviewers, and no builder" {
  finished_workers
  # The ops session of the fixture has ended.
  jq 'map(select(.id != "66666666"))' "$STUB_FIXTURES/agents.json" >"$STUB_FIXTURES/agents.next"
  mv "$STUB_FIXTURES/agents.next" "$STUB_FIXTURES/agents.json"
  run_bin -0 --separate-stderr team-worker T9 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$output" "9a8b7c6d"
  assert_equal "$(stops)" $'11111111\n33333333'
  [[ $stderr != *22222222* && $stderr != *44444444* ]]
}

@test "a launch with no earlier worker to stop, and a T0 launch, do not read the session list before the launch" {
  finished_workers
  thread T7
  run_bin -0 team-worker T0 builder "$wt1" -- go
  run_bin -0 team-worker T7 builder "$wt1" -- go
  assert_equal "$(claude_verbs)" "--bg --bg "
}

@test "a launch with no room at the level exits 75 with the reason and launches nothing, and T0 and ops are never asked" {
  thread T7
  opened T7 proj feat/T7-one "$wt1"
  : >"$HOME/.local/state/agent-team/capacity/readings.jsonl"
  capacity_room $((256 * 1048576))
  run_bin -75 --separate-stderr team-worker T7 reviewer "$wt1" -- go
  assert_equal "$output" ""
  assert_equal "$stderr" "team-worker: no room for session:reviewer at full (90%): 0.0 GiB of 0.3 GiB reserved, a reviewer needs 0.5 GiB; room comes when the team's work shrinks or the level rises"
  assert_equal "$(bg_calls)" ""
  assert_equal "$(launches)" ""
  [[ ! -e $TEAM_HOME/tasks/T7/settings.reviewer.json ]]

  # At none, nothing starts but the load check and an ops session.
  capacity_room $((16 * 1073741824)) none
  run_bin -75 --separate-stderr team-worker T7 builder "$wt1" -- go
  assert_equal "$stderr" "team-worker: no room for session:builder: the team is at level none: nothing starts; room comes when Daniel raises the level"
  assert_equal "$(bg_calls)" ""
  run_bin -0 team-worker T0 planner "$wt1" -- go
  ops_stub
  run_bin -0 team-worker T7 ops "$wt1" --toolkit prod-read --request "$(ops_request "$OPS_COORDINATOR")" -- go
  assert_equal "$(launches | jq -r .role)" ops
  [[ ! -e $HOME/.local/state/agent-team/capacity/admitted.json ]]

  # Room again: the launch is admitted and kept as reserved.
  capacity_room $((16 * 1073741824)) full
  run_bin -0 team-worker T7 builder "$wt1" -- go
  assert_equal "$(jq -c 'map([.kind, .task])' "$HOME/.local/state/agent-team/capacity/admitted.json")" '[["session:builder","T7"]]'
}

@test "the task's finished sessions are stopped before the launch asks for room, and their use leaves the reservations" {
  thread T9
  log_lines <<LINES
launch T9 reviewer 6c6c6c6c $wt1
T9 {event: "review", verdict: "findings", head: "abc1234"}
T9 {event: "done", role: "reviewer", session: "6c6c6c6c"}
LINES
  echo '[{"id": "6c6c6c6c", "name": "T9-reviewer", "status": "idle"}]' >"$STUB_FIXTURES/agents.json"
  stop_stub
  # The finished reviewer uses 0.4 GiB, reserved with a 0.1 GiB spike allowance; the budget, 0.8
  # GiB, leaves 0.3 GiB beside them, and a reviewer needs 0.5 GiB.
  : >"$HOME/.local/state/agent-team/capacity/readings.jsonl"
  capacity_room $((819 * 1048576))
  jq -c '.tasks = [{task: "T9", memory: 429496730, cpu: null, cpu_nsec: null, stacks: [],
                    sessions: [{id: "6c6c6c6c", role: "reviewer", memory: 429496730, cpu_seconds: 1}]}]' \
    "$HOME/.local/state/agent-team/capacity/readings.jsonl" >"$BATS_TEST_TMPDIR/reading"
  mv "$BATS_TEST_TMPDIR/reading" "$HOME/.local/state/agent-team/capacity/readings.jsonl"
  run_bin -0 --separate-stderr team-worker T9 reviewer "$wt1" -- go
  assert_equal "$(stops)" 6c6c6c6c
  assert_contains "$stderr" "team-worker: stopped T9-reviewer 6c6c6c6c: its work is handed on"
  assert_equal "$(jq -c 'map([.kind, .task])' "$HOME/.local/state/agent-team/capacity/admitted.json")" '[["session:reviewer","T9"]]'
  # A stop that fails leaves the session's use reserved, so the launch has no room.
  rm "$HOME/.local/state/agent-team/capacity/admitted.json"
  echo 6c6c6c6c >"$STUB_FIXTURES/stop-fails"
  run_bin -75 --separate-stderr team-worker T9 reviewer "$wt1" -- go
  assert_contains "$stderr" "team-worker: no room for session:reviewer at full (90%)"
}

@test "an admission that fails for another reason stops the launch with it" {
  thread T7
  mkdir -p "$HOME/.config/agent-team"
  echo '{"session_gib": 0}' >"$HOME/.config/agent-team/capacity.json"
  run_bin -1 --separate-stderr team-worker T7 builder "$wt1" -- go
  assert_equal "$stderr" "team-worker: team-capacity admit failed for T7-builder (exit 1): team-capacity: $HOME/.config/agent-team/capacity.json: session_gib must be a number above 0, not 0"
  assert_equal "$(bg_calls)" ""
  assert_equal "$(launches)" ""
}

@test "refused in a worker session, whatever its role, before any read; --help and the coordinator are not" {
  thread T7
  worker_refused team-worker "launches no session" T7 builder "$wt1" -- go
  worker_refused team-worker "launches no session" T7 ops "$wt1" --toolkit prod-read --request x -- go
  AGENT_TEAM_ROLE=builder run_bin -0 team-worker --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-worker")"
  AGENT_TEAM_ROLE=coordinator run_bin -2 team-worker T7 builder
  assert_contains "$output" "usage: team-worker <task> <role> <worktree>"
}
