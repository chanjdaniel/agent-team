#!/usr/bin/env bats
# tests/compaction-drill, dry-run against a stub claude: the sandbox it builds from its fixture,
# the three print-mode turns it asks for and the purge after them, and its checks' verdicts on
# canned answers. The real drill starts Claude sessions, which only the coordinator runs.
load helpers/common

setup() {
  sandbox
  fixture=$REPO_ROOT/tests/fixtures/compaction-drill
  # The drill's sandbox lands here, so a test can see it is gone afterwards.
  export TMPDIR=$BATS_TEST_TMPDIR/tmp
  mkdir -p "$TMPDIR"
  export DRILL_CODE=$REPO_ROOT
  # The stub plays the session: each turn records where and how it ran ($STUB_FIXTURES/turn-<n>.*,
  # n counting the calls) and runs the SessionStart hook as Claude Code would; turn 1 writes the
  # new promise into tasks/current.md unless no-write is set; turn 2 reports a compaction unless
  # no-compact is set; turn 3 answers with $STUB_FIXTURES/answer. Every turn prints the stream
  # of a print-mode session: an init line, then its result with usage.
  stub_script claude <<'EOF'
if [[ $1 == purge ]]; then exit 0; fi
n=$(grep -cv '"purge"' "$STUB_CALLS/claude.log")
out=$STUB_FIXTURES/turn-$n
printf '%s\n' "$PWD" >"$out.pwd"
printf '%s\n' "$PATH" >"$out.path"
printf '%s\n' "${TEAM_HOME:-}" >"$out.team-home"
args=("$@")
for i in "${!args[@]}"; do
  if [[ ${args[i]} == --settings ]]; then cp "${args[i + 1]}" "$out.settings"; fi
done
cp ledger.jsonl "$out.ledger"
"$DRILL_CODE/bin/hooks/session-digest" >"$out.digest" 2>&1
if [[ -f $STUB_FIXTURES/fail-$n ]]; then
  echo "API Error: the stub's turn $n failed" >&2
  exit 1
fi
echo '{"type":"system","subtype":"init","session_id":"stub"}'
case $n in
  1)
    [[ -f $STUB_FIXTURES/no-write ]] ||
      echo "- next T92 open a task to pin Node 22 in the drill project's CI once T92 merges, mine | https://discord.com/channels/1100000000000000000/1200000000000000000/1300000000000000042" >>tasks/current.md
    result="Noted the promise in tasks/current.md."
    ;;
  2)
    [[ -f $STUB_FIXTURES/no-compact ]] ||
      echo '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":41000}}'
    result=""
    ;;
  3) result=$(cat "$STUB_FIXTURES/answer") ;;
esac
jq -cn --arg result "$result" --argjson n "$n" '{type: "result", subtype: "success", is_error: false,
  result: $result, total_cost_usd: (0.25 * $n),
  usage: {input_tokens: (10 * $n), cache_creation_input_tokens: (1000 * $n),
    cache_read_input_tokens: (20000 * $n), output_tokens: (100 * $n)}}'
EOF
}

# answer <jq object>: the canned answer turn 3 gives, as the model might write it.
answer() {
  { echo 'Here is what I hold:'; echo '```json'; jq -n "$1"; echo '```'; } >"$STUB_FIXTURES/answer"
}

# A full answer: every task's wait and every item, the new promise included.
full_answer() {
  answer '{tasks: [
      {task: "T91", waits_on: "Daniel'\''s answer to q1, the licence question"},
      {task: "T92", waits_on: "Daniel: rotate the staging database password"},
      {task: "T93", waits_on: "blocked until T92 is on the new database"},
      {task: "T94", waits_on: "nothing: its builder is at work"}],
    items: [
      "owe - the weekly status report | https://discord.com/channels/1100000000000000000/1200000000000000000/1300000000000000001",
      "next T91 open the licence file task once Daniel answers q1 | ledger T91 asked q1",
      "queued - the lint cleanup | tasks/queued/lint-cleanup.md",
      "next T92 open a task to pin Node 22 in CI once T92 merges | https://discord.com/channels/1100000000000000000/1200000000000000000/1300000000000000042"]}'
}

# The drill's calls to claude, one JSON array of arguments per line.
calls() {
  stub_calls claude
}

# The value after <flag> in call <n> (counting from 1).
flag_of() {
  calls | sed -n "${1}p" | jq -r --arg flag "$2" '. as $a | (index($flag)) as $i | $a[$i + 1]'
}

# The drill's sandbox, from the path turn 1 ran in.
drill_sandbox() {
  dirname "$(cat "$STUB_FIXTURES/turn-1.pwd")"
}

@test "a passing run: every check passes, with the answer, the file and the token totals" {
  full_answer
  run -0 "$REPO_ROOT/tests/compaction-drill"
  assert_contains "$output" "PASS the compaction ran (turn 2 reported a compact_boundary)
PASS the answer is one JSON object with tasks and items
PASS T91 waits on its unanswered ask, q1 on the licence
PASS T92 waits on Daniel to rotate the staging database password
PASS T93 is blocked on T92
PASS T94 has its builder at work
PASS the owe item: the weekly status report (message 1300000000000000001)
PASS the next item: the licence file task once q1 is answered
PASS the queued item: the lint cleanup (tasks/queued/lint-cleanup.md)
PASS the new promise: a task to pin Node 22, in the answer
PASS the new promise: a next item to pin Node 22, in tasks/current.md
== tokens"
  # The answer and the file are shown whole, for the PR.
  assert_contains "$output" "== the answer (turn 3)
Here is what I hold:"
  assert_contains "$output" "== tasks/current.md after the drill
# Current items
"
  assert_contains "$output" "- next T92 open a task to pin Node 22"
  assert_contains "$output" "== tokens: input, cache write, cache read, output, cost (USD)
turn 1 (Daniel's message): 10 1000 20000 100 0.25
turn 2 (/compact): 20 2000 40000 200 0.50
turn 3 (the question): 30 3000 60000 300 0.75
total: 60 6000 120000 600 1.50
== 11 of 11 checks passed"
  assert_equal "${lines[-1]}" "== 11 of 11 checks passed"
}

@test "it runs three print-mode turns on one session, coordinator-shaped, then purges it" {
  full_answer
  run -0 "$REPO_ROOT/tests/compaction-drill"
  local sandbox team id
  sandbox=$(drill_sandbox) team=$(drill_sandbox)/team
  assert_equal "$(calls | wc -l)" 4
  id=$(flag_of 1 --session-id)
  [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
  local n shape
  for n in 1 2 3; do
    # Every turn: the variadic --tools first, so it swallows no prompt; the prompt last.
    shape=$(calls | sed -n "${n}p" | jq -c --arg code "$REPO_ROOT" --arg settings "$sandbox/settings.json" '
      [.[0:16], .[16:18], length]
      == [["--tools", "Read,Glob,Grep,Edit,Write", "--print", "--verbose", "--output-format", "stream-json",
           "--append-system-prompt-file", "\($code)/roles/coordinator.md", "--settings", $settings,
           "--strict-mcp-config", "--permission-mode", "acceptEdits", "--no-chrome",
           .[14], .[15]], ["--permission-prompts", "none"], 19]')
    assert_equal "$shape" true
  done
  assert_equal "$(calls | sed -n 1,3p | jq -c '.[14:16]')" "$(jq -cn --arg id "$id" '["--session-id", $id], ["--resume", $id], ["--resume", $id]')"
  assert_contains "$(calls | sed -n 1p | jq -r 'last')" 'message 1300000000000000042'
  assert_contains "$(calls | sed -n 1p | jq -r 'last')" 'Once T92 merges, open a task to pin Node 22'
  assert_equal "$(calls | sed -n 2p | jq -r 'last')" /compact
  assert_contains "$(calls | sed -n 3p | jq -r 'last')" '{"tasks": [{"task": "T<n>", "waits_on":'
  # The session goes with the sandbox.
  assert_equal "$(calls | sed -n 4p)" "$(jq -cn --arg team "$team" '["purge", "-y", $team]')"
  # Each turn ran in the sandbox's team home, with the fixture's stubs first on PATH.
  for n in 1 2 3; do
    assert_equal "$(cat "$STUB_FIXTURES/turn-$n.pwd")" "$team"
    assert_equal "$(cat "$STUB_FIXTURES/turn-$n.team-home")" "$team"
    assert_equal "$(cut -d: -f1 "$STUB_FIXTURES/turn-$n.path")" "$sandbox/stubs"
  done
}

@test "its settings hold only the coordinator's SessionStart hook and TEAM_HOME: no Discord, no Stop hook, no lease fence" {
  full_answer
  run -0 "$REPO_ROOT/tests/compaction-drill"
  assert_equal "$(jq -c . "$STUB_FIXTURES/turn-1.settings")" "$(jq -cn --arg code "$REPO_ROOT" --arg team "$(drill_sandbox)/team" '
    {enabledPlugins: {"discord@claude-plugins-official": false},
     env: {TEAM_HOME: $team},
     hooks: {SessionStart: [{hooks: [{type: "command", command: "\"\($code)/bin/hooks/session-digest\"", timeout: 120}]}]}}')"
}

@test "its sandbox is the fixture, so the session's digest shows the fixture's tasks, sessions and items, and no GitHub" {
  full_answer
  run -0 "$REPO_ROOT/tests/compaction-drill"
  diff "$STUB_FIXTURES/turn-1.ledger" "$fixture/team/ledger.jsonl"
  local digest
  digest=$(cat "$STUB_FIXTURES/turn-1.digest")
  assert_contains "$digest" "Open tasks (4):
  T91 drill feature planning | no live worker
  T92 drill feature planning | no live worker | waiting on Daniel: rotate the staging database password
  T93 drill feature blocked | no live worker
  T94 drill feature planning | T94-builder busy
this machine: 4 of 6 task slots held, none kept, since no registered project's primary checkout is the code checkout ...
Standing merge word: none
Live team sessions (1):
  T94-builder c3d4e5f6 busy
Stray sessions: none
Open PRs:
  drill (example/drill): none
Pending asks (1):
  T91 q1: Which licence should the drill project ship under, MIT or Apache 2.0?
Current items (3):
  - owe - the weekly status report Daniel asked for, mine to send | https://discord.com/channels/1100000000000000000/1200000000000000000/1300000000000000001
  - next T91 open the licence file task once Daniel answers q1, mine | ledger T91 asked q1
  - queued - the drill project's lint cleanup, approved by Daniel, mine to open | tasks/queued/lint-cleanup.md
"
  # Turn 3's digest has the promise turn 1 wrote.
  assert_contains "$(cat "$STUB_FIXTURES/turn-3.digest")" "Current items (4):"
}

@test "a claude and gh in the machine's tool directories, which the library puts first on PATH, never reach the session's hooks" {
  full_answer
  # ~/.local/bin is one of tools.lock's directories under HOME, which every script's library puts
  # ahead of the PATH it was given; there the machine's own claude would list its own sessions.
  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\necho %s\n' \
    "'[{\"pid\": 1, \"cwd\": \"/elsewhere\", \"kind\": \"background\", \"sessionId\": \"edd90326-0000-4000-8000-000000000000\", \"name\": \"T31-builder\", \"status\": \"busy\", \"id\": \"edd90326\"}]'" \
    >"$HOME/.local/bin/claude"
  printf '#!/usr/bin/env bash\necho "the machine'"'"'s gh, not the drill'"'"'s" >&2; exit 1\n' >"$HOME/.local/bin/gh"
  chmod +x "$HOME/.local/bin/claude" "$HOME/.local/bin/gh"
  run -0 "$REPO_ROOT/tests/compaction-drill"
  local digest
  digest=$(cat "$STUB_FIXTURES/turn-1.digest")
  assert_contains "$digest" "  T94 drill feature planning | T94-builder busy
this machine: 4 of 6 task slots held, none kept, since no registered project's primary checkout is the code checkout ...
Standing merge word: none
Live team sessions (1):
  T94-builder c3d4e5f6 busy
Stray sessions: none
Open PRs:
  drill (example/drill): none
"
}

@test "it removes the sandbox and never touches the team home or HOME it was run with" {
  full_answer
  run -0 "$REPO_ROOT/tests/compaction-drill"
  [[ ! -e $(drill_sandbox) ]]
  assert_equal "$(find "$TMPDIR" -mindepth 1)" ""
  assert_equal "$(find "$TEAM_HOME" -mindepth 1)" "$TEAM_HOME/ledger.jsonl"
  [[ ! -s $TEAM_HOME/ledger.jsonl ]]
}

@test "a TMPDIR inside a .claude directory puts the sandbox under /tmp instead, where the session's writes do not prompt" {
  full_answer
  export TMPDIR=$BATS_TEST_TMPDIR/home/.claude/jobs/1/tmp
  mkdir -p "$TMPDIR"
  run -0 "$REPO_ROOT/tests/compaction-drill"
  [[ $(drill_sandbox) == "$(realpath /tmp)"/compaction-drill.* ]]
  [[ ! -e $(drill_sandbox) ]]
}

@test "an answer missing a wait and the new promise, and no promise written, fails those checks, exit 1" {
  answer '{tasks: [
      {task: "T91", waits_on: "the licence question"},
      {task: "T92", waits_on: "Daniel: the staging database password"},
      {task: "T93", waits_on: "blocked"},
      {task: "T94", waits_on: "its builder, at work"}],
    items: ["owe - report | 1300000000000000001", "next T91 the licence file task", "queued - lint cleanup"]}'
  touch "$STUB_FIXTURES/no-write"
  run -1 "$REPO_ROOT/tests/compaction-drill"
  assert_contains "$output" "PASS T92 waits on Daniel to rotate the staging database password
FAIL T93 is blocked on T92
PASS T94 has its builder at work"
  assert_contains "$output" "PASS the queued item: the lint cleanup (tasks/queued/lint-cleanup.md)
FAIL the new promise: a task to pin Node 22, in the answer
FAIL the new promise: a next item to pin Node 22, in tasks/current.md
== tokens"
  assert_equal "${lines[-1]}" "== 8 of 11 checks passed"
  [[ ! -e $(drill_sandbox) ]]
  assert_equal "$(calls | sed -n 4p | jq -r '.[0]')" purge
}

@test "an answer that gives T94's builder as no longer live fails its check, though it names the builder" {
  answer '{tasks: [
      {task: "T91", waits_on: "Daniel'\''s answer to q1, the licence question"},
      {task: "T92", waits_on: "Daniel: rotate the staging database password"},
      {task: "T93", waits_on: "blocked until T92 is on the new database"},
      {task: "T94", waits_on: "nothing recorded; its builder c3d4e5f6 is no longer live, so it is unattended"}],
    items: [
      "owe - the weekly status report | 1300000000000000001",
      "next T91 open the licence file task once Daniel answers q1",
      "queued - the lint cleanup | tasks/queued/lint-cleanup.md",
      "next T92 open a task to pin Node 22 in CI once T92 merges"]}'
  run -1 "$REPO_ROOT/tests/compaction-drill"
  assert_contains "$output" "FAIL T94 has its builder at work"
  assert_equal "${lines[-1]}" "== 10 of 11 checks passed"
}

@test "a turn 2 that reports no compaction fails that check" {
  full_answer
  touch "$STUB_FIXTURES/no-compact"
  run -1 "$REPO_ROOT/tests/compaction-drill"
  assert_contains "$output" "FAIL the compaction ran (turn 2 reported a compact_boundary)"
  assert_equal "${lines[-1]}" "== 10 of 11 checks passed"
}

@test "an answer with no JSON object fails every check of the answer" {
  echo "I cannot say." >"$STUB_FIXTURES/answer"
  run -1 "$REPO_ROOT/tests/compaction-drill"
  assert_contains "$output" "FAIL the answer is one JSON object with tasks and items
FAIL T91 waits on its unanswered ask, q1 on the licence"
  assert_contains "$output" "PASS the new promise: a next item to pin Node 22, in tasks/current.md
== tokens"
  assert_equal "${lines[-1]}" "== 2 of 11 checks passed"
}

@test "a turn that fails stops the drill with its error, exit 1, and still cleans up" {
  full_answer
  touch "$STUB_FIXTURES/fail-2"
  run -1 "$REPO_ROOT/tests/compaction-drill"
  assert_contains "$output" "FAIL turn 2 (/compact) failed (exit 1):
API Error: the stub's turn 2 failed"
  assert_equal "$(calls | wc -l)" 3
  assert_equal "$(calls | sed -n 3p | jq -r '.[0]')" purge
  [[ ! -e $(drill_sandbox) ]]
}

@test "--help prints its header, which says it spends allowance and never runs in tests/run; arguments are exit 2" {
  run -0 "$REPO_ROOT/tests/compaction-drill" --help
  assert_contains "$output" "spends allowance"
  assert_contains "$output" "never runs in tests/run"
  assert_contains "$output" "Usage: tests/compaction-drill"
  run -2 "$REPO_ROOT/tests/compaction-drill" extra
  assert_equal "$output" "usage: tests/compaction-drill"
  assert_equal "$(calls)" ""
}
