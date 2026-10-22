#!/usr/bin/env bats
# team-ops-end: stopping and removing a task's ops session, and deleting its transcript by the
# session's full uuid only.

load helpers/common

setup() {
  sandbox
  uuid=4f2a9c1e-1111-4222-8333-944455556666
  projects=$HOME/.claude/projects
  slug=$projects/-home-x-slots-proj-1
  mkdir -p "$slug/$uuid/tool-results" "$projects/-other"
  echo '{}' >"$slug/$uuid.jsonl"
  echo big >"$slug/$uuid/tool-results/r.txt"
  # Neighbours: another session's transcript, in the same and in another project directory, and
  # one whose name only starts with the uuid.
  echo '{}' >"$slug/4f2a9c1e-0000-4000-8000-000000000000.jsonl"
  echo '{}' >"$projects/-other/aaaaaaaa-1111-4222-8333-944455556666.jsonl"
  echo '{}' >"$slug/$uuid.jsonl.bak"
}

# agents <json>: what claude agents --json --all lists; stop and rm succeed.
agents() {
  printf '%s\n' "$1" >"$STUB_FIXTURES/agents.json"
  stub_script claude <<'SH'
case $1 in
  agents) cat "$STUB_FIXTURES/agents.json" ;;
  stop|rm) echo "$1 $2" ;;
  *) exit 64 ;;
esac
SH
}

ops_session() {
  jq -cn --arg uuid "$uuid" '[{id: "4f2a9c1e", sessionId: $uuid, name: "T5-ops", state: "done"},
    {id: "aaaaaaaa", sessionId: "aaaaaaaa-1111-4222-8333-944455556666", name: "T5-builder", state: "working"}]'
}

@test "the ops session is stopped, removed and its transcript and results deleted, nothing else" {
  agents "$(ops_session)"
  run_bin -0 team-ops-end T5
  assert_contains "$output" "deleted $slug/$uuid.jsonl"
  assert_contains "$output" "deleted $slug/$uuid"$'\n'
  assert_contains "$output" "ended T5-ops (4f2a9c1e)"
  [[ ! -e $slug/$uuid.jsonl && ! -e $slug/$uuid ]]
  [[ -f $slug/4f2a9c1e-0000-4000-8000-000000000000.jsonl ]]
  [[ -f $projects/-other/aaaaaaaa-1111-4222-8333-944455556666.jsonl ]]
  [[ -f $slug/$uuid.jsonl.bak ]]
  assert_equal "$(stub_calls claude)" "$(printf '%s\n' '["agents","--json","--all"]' '["stop","4f2a9c1e"]' '["rm","4f2a9c1e"]')"
}

@test "a session that finished and cannot be stopped is still removed and deleted" {
  agents "$(ops_session)"
  stub_script claude <<'SH'
case $1 in
  agents) cat "$STUB_FIXTURES/agents.json" ;;
  stop) exit 1 ;;
  rm) echo "removed $2" ;;
esac
SH
  run_bin -0 team-ops-end T5
  [[ ! -e $slug/$uuid.jsonl ]]
}

@test "no ops session for the task is refused, nothing stopped or deleted" {
  agents '[{"id": "aaaaaaaa", "sessionId": "aaaaaaaa-1111-4222-8333-944455556666", "name": "T6-ops"}]'
  run_bin -1 team-ops-end T5
  assert_contains "$output" "no session named T5-ops is listed"
  assert_equal "$(stub_calls claude)" '["agents","--json","--all"]'
  [[ -f $slug/$uuid.jsonl && -d $slug/$uuid ]]
}

@test "a session whose full uuid cannot be resolved is refused, nothing stopped or deleted" {
  local listing
  for listing in '[{"id": "4f2a9c1e", "name": "T5-ops"}]' \
    '[{"id": "4f2a9c1e", "sessionId": "4f2a9c1e", "name": "T5-ops"}]' \
    '[{"id": "4f2a9c1e", "sessionId": "*", "name": "T5-ops"}]' \
    '[{"id": "4f2a9c1e", "sessionId": "aaaaaaaa-1111-4222-8333-944455556666", "name": "T5-ops"}]'; do
    : >"$STUB_CALLS/claude.log"
    agents "$listing"
    run_bin -1 team-ops-end T5
    assert_contains "$output" "cannot resolve the full session uuid of T5-ops (4f2a9c1e); nothing deleted"
    assert_equal "$(stub_calls claude)" '["agents","--json","--all"]'
  done
  [[ -f $slug/$uuid.jsonl && -d $slug/$uuid && -f $projects/-other/aaaaaaaa-1111-4222-8333-944455556666.jsonl ]]
}

@test "a failed claude rm keeps the transcript" {
  agents "$(ops_session)"
  stub_script claude <<'SH'
case $1 in
  agents) cat "$STUB_FIXTURES/agents.json" ;;
  stop) ;;
  rm) exit 1 ;;
esac
SH
  run_bin -1 team-ops-end T5
  assert_contains "$output" "claude rm 4f2a9c1e failed; its transcript is kept"
  [[ -f $slug/$uuid.jsonl && -d $slug/$uuid ]]
}

@test "an unreadable session list and a malformed command line are refused" {
  stub_reply claude "not json"
  run_bin -1 team-ops-end T5
  assert_contains "$output" "cannot read the session list"
  run_bin -2 team-ops-end
  assert_contains "$output" "usage: team-ops-end <task>"
  run_bin -2 team-ops-end 5
  assert_contains "$output" "task must look like T<n>, got '5'"
  [[ -f $slug/$uuid.jsonl ]]
}
