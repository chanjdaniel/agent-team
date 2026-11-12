#!/usr/bin/env bats
# team-ops-end: stopping and removing a task's ops session, and deleting its transcript, its MCP
# logs and its session directory by the session's full uuid only, and the answer file in its
# worktree.

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
  # The ops session's worktree and the builder's, each with an answer file.
  ops_wt="$HOME/slots/proj 1" builder_wt=$HOME/slots/proj-2
  mkdir -p "$ops_wt/.scratch" "$builder_wt/.scratch"
  echo answer >"$ops_wt/.scratch/answer.md"
  echo answer >"$builder_wt/.scratch/answer.md"
  # The session's directory under the config directory, and another session's.
  mkdir -p "$HOME/.claude/session-env/$uuid" "$HOME/.claude/session-env/aaaaaaaa-1111-4222-8333-944455556666"
  echo env >"$HOME/.claude/session-env/$uuid/hook-1.sh"
}

# native_cache: Claude Code's cache root on the OS the tests run on, XDG_CACHE_HOME unset, as the
# library reads it: Library/Caches on macOS, ~/.cache elsewhere.
native_cache() {
  if [[ $(uname -s) == Darwin ]]; then
    echo "$HOME/Library/Caches/claude-cli-nodejs"
  else
    echo "$HOME/.cache/claude-cli-nodejs"
  fi
}

# mcp_logs <cache root>: the MCP logs a stub session left under Claude Code's cache, and their
# neighbours. Sets own (the files that are the session's) and kept (the ones that are not).
mcp_logs() {
  local root=$1 dir
  local line='{"debug":"Starting connection","timestamp":"2026-11-09T10:00:00.000Z","sessionId":"%s","cwd":"/x"}\n'
  local result='{"debug":"Tool returned 42 documents","timestamp":"2026-11-09T10:00:01.000Z","sessionId":"%s","cwd":"/x"}\n'
  for dir in -home-x-slots-proj-1/mcp-logs-prod-read -home-x-slots-proj-1/mcp-logs-prod-write \
    -home-x-slots-proj-1/mcp-logs-vercel-read -home-x-slots-proj-1/mcp-logs-plugin-prod-read-prod-read \
    -other/mcp-logs-prod-read -home-x-slots-proj-1/not-mcp-logs; do
    mkdir -p "$root/$dir"
  done
  own=("$root/-home-x-slots-proj-1/mcp-logs-prod-read/2026-11-09T10-00-00-000Z.jsonl"
    "$root/-home-x-slots-proj-1/mcp-logs-prod-write/2026-11-09T10-00-02-000Z.jsonl"
    "$root/-home-x-slots-proj-1/mcp-logs-vercel-read/2026-11-09T10-00-03-000Z.jsonl"
    "$root/-home-x-slots-proj-1/mcp-logs-plugin-prod-read-prod-read/2026-11-09T10-00-04-000Z.jsonl"
    "$root/-other/mcp-logs-prod-read/2026-11-09T10-00-05-000Z.jsonl")
  local file
  for file in "${own[@]}"; do
    # shellcheck disable=SC2059 # the line formats are this function's own
    printf "$line$result" "$uuid" "$uuid" >"$file"
  done
  # Kept: another session's log, one naming the session's short id or its uuid only inside a
  # message, a file named by the uuid whose lines name another session, and a file outside an
  # mcp-logs- directory.
  kept=("$root/-home-x-slots-proj-1/mcp-logs-prod-read/2026-11-09T09-00-00-000Z.jsonl"
    "$root/-home-x-slots-proj-1/mcp-logs-prod-read/2026-11-09T09-00-01-000Z.jsonl"
    "$root/-home-x-slots-proj-1/mcp-logs-prod-write/$uuid.jsonl"
    "$root/-home-x-slots-proj-1/not-mcp-logs/2026-11-09T10-00-06-000Z.jsonl")
  # shellcheck disable=SC2059
  printf "$line" aaaaaaaa-1111-4222-8333-944455556666 >"${kept[0]}"
  local other=bbbbbbbb-1111-4222-8333-944455556666
  # shellcheck disable=SC2059
  printf "$line" "$other" >"${kept[1]}"
  printf '%s\n' "{\"debug\":\"asked about 4f2a9c1e, $uuid and \\\"sessionId\\\":\\\"$uuid\\\"\",\"sessionId\":\"$other\"}" \
    "{\"debug\":\"sessionId $uuid\",\"sessionId\":\"4f2a9c1e\"}" 'not json' >>"${kept[1]}"
  # shellcheck disable=SC2059
  printf "$line" aaaaaaaa-1111-4222-8333-944455556666 >"${kept[2]}"
  # shellcheck disable=SC2059
  printf "$line" "$uuid" >"${kept[3]}"
}

# assert_logs_ended: each of own is deleted and printed, each of kept is there.
assert_logs_ended() {
  local file
  for file in "${own[@]}"; do
    [[ ! -e $file ]] || { echo "still there: $file" >&2; return 1; }
    assert_contains "$output" "deleted $file"$'\n'
  done
  for file in "${kept[@]}"; do
    [[ -f $file ]] || { echo "deleted: $file" >&2; return 1; }
  done
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
  jq -cn --arg uuid "$uuid" --arg ops "$ops_wt" --arg builder "$builder_wt" '[
    {id: "4f2a9c1e", sessionId: $uuid, name: "T5-ops", state: "done", cwd: $ops},
    {id: "aaaaaaaa", sessionId: "aaaaaaaa-1111-4222-8333-944455556666", name: "T5-builder", state: "working", cwd: $builder}]'
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
  # The answer file, which holds the answer, goes with it.
  assert_contains "$output" "deleted $ops_wt/.scratch/answer.md"
  [[ ! -e $ops_wt/.scratch/answer.md && -d $ops_wt/.scratch && -f $builder_wt/.scratch/answer.md ]]
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

@test "a session with no answer file, or no worktree listed, deletes its transcript alone" {
  rm "$ops_wt/.scratch/answer.md"
  agents "$(ops_session)"
  run_bin -0 team-ops-end T5
  [[ ! -e $slug/$uuid.jsonl ]]
  run -1 grep -q answer.md <<<"$output"
  echo '{}' >"$slug/$uuid.jsonl"
  echo answer >"$ops_wt/.scratch/answer.md"
  : >"$STUB_CALLS/claude.log"
  agents "$(ops_session | jq -c 'map(del(.cwd))')"
  run_bin -0 team-ops-end T5
  [[ ! -e $slug/$uuid.jsonl && -f $ops_wt/.scratch/answer.md ]]
}

@test "no ops session for the task is refused, nothing stopped or deleted" {
  mcp_logs "$(native_cache)"
  agents '[{"id": "aaaaaaaa", "sessionId": "aaaaaaaa-1111-4222-8333-944455556666", "name": "T6-ops"}]'
  run_bin -1 team-ops-end T5
  assert_contains "$output" "no session named T5-ops is listed"
  assert_equal "$(stub_calls claude)" '["agents","--json","--all"]'
  [[ -f $slug/$uuid.jsonl && -d $slug/$uuid && -d $HOME/.claude/session-env/$uuid && -f ${own[0]} ]]
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
  mcp_logs "$(native_cache)"
  run_bin -1 team-ops-end T5
  assert_contains "$output" "claude rm 4f2a9c1e failed; its transcript is kept"
  [[ -f $slug/$uuid.jsonl && -d $slug/$uuid && -f $ops_wt/.scratch/answer.md && -d $HOME/.claude/session-env/$uuid ]]
  local file
  for file in "${own[@]}"; do [[ -f $file ]]; done
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

@test "the session's MCP logs, found by its uuid, its session directory and its file checkpoints are deleted, nothing else" {
  mcp_logs "$(native_cache)"
  # Claude Code's checkpoints of the files a session edited: an earlier text of its answer.
  local history=$HOME/.claude/file-history
  mkdir -p "$history/$uuid" "$history/aaaaaaaa-1111-4222-8333-944455556666"
  echo "42 orders" >"$history/$uuid/3f1c2a9b8e7d6c5a@v1"
  echo "another session's" >"$history/aaaaaaaa-1111-4222-8333-944455556666/3f1c2a9b8e7d6c5a@v1"
  agents "$(ops_session)"
  run_bin -0 team-ops-end T5
  assert_logs_ended
  assert_contains "$output" "deleted $HOME/.claude/session-env/$uuid"$'\n'
  assert_contains "$output" "deleted $history/$uuid"$'\n'
  [[ ! -e $HOME/.claude/session-env/$uuid && -d $HOME/.claude/session-env/aaaaaaaa-1111-4222-8333-944455556666 ]]
  [[ ! -e $history/$uuid && -f $history/aaaaaaaa-1111-4222-8333-944455556666/3f1c2a9b8e7d6c5a@v1 ]]
  # Everything is deleted before the session is reported ended.
  assert_equal "${output##*$'\n'}" "ended T5-ops (4f2a9c1e)"
  # A second end of a session already gone deletes nothing more and still ends.
  run_bin -0 team-ops-end T5
  run -1 grep -q '^deleted ' <<<"$output"
}

@test "the cache directory is XDG_CACHE_HOME's on Linux, Library/Caches on macOS, and the config directory CLAUDE_CONFIG_DIR's" {
  agents "$(ops_session)"
  mcp_logs "$HOME/xdg/claude-cli-nodejs"
  local xdg_own=("${own[@]}") xdg_kept=("${kept[@]}")
  if [[ $(uname -s) == Darwin ]]; then
    # macOS: Library/Caches, whatever XDG_CACHE_HOME says.
    mcp_logs "$HOME/Library/Caches/claude-cli-nodejs"
    XDG_CACHE_HOME=$HOME/xdg run_bin -0 team-ops-end T5
    kept+=("${xdg_own[@]}" "${xdg_kept[@]}")
    assert_logs_ended
  else
    # Linux with XDG_CACHE_HOME: ~/.cache is not Claude Code's then.
    mcp_logs "$HOME/.cache/claude-cli-nodejs"
    local home_own=("${own[@]}")
    XDG_CACHE_HOME=$HOME/xdg run_bin -0 team-ops-end T5
    own=("${xdg_own[@]}") kept=("${xdg_kept[@]}" "${home_own[@]}")
    assert_logs_ended
    # The library's macOS branch on Linux too, driven by a stub uname and a fake Homebrew.
    local dir
    for dir in coreutils/libexec/gnubin findutils/libexec/gnubin gnu-sed/libexec/gnubin grep/libexec/gnubin flock/bin; do
      mkdir -p "$BATS_TEST_TMPDIR/brew/opt/$dir"
    done
    stub_command uname
    stub_reply uname Darwin
    mcp_logs "$HOME/Library/Caches/claude-cli-nodejs"
    HOMEBREW_PREFIX=$BATS_TEST_TMPDIR/brew run_bin -0 team-ops-end T5
    kept+=("${home_own[@]}")
    assert_logs_ended
    stub_reply uname Linux
  fi
  # CLAUDE_CONFIG_DIR holds the session directory and the transcripts when set.
  mkdir -p "$HOME/config/session-env/$uuid" "$HOME/config/projects/-p" "$HOME/config/file-history/$uuid"
  echo '{}' >"$HOME/config/projects/-p/$uuid.jsonl"
  mkdir -p "$HOME/.claude/session-env/$uuid"
  CLAUDE_CONFIG_DIR=$HOME/config run_bin -0 team-ops-end T5
  assert_contains "$output" "deleted $HOME/config/session-env/$uuid"$'\n'
  assert_contains "$output" "deleted $HOME/config/file-history/$uuid"$'\n'
  assert_contains "$output" "deleted $HOME/config/projects/-p/$uuid.jsonl"$'\n'
  [[ ! -e $HOME/config/session-env/$uuid && -d $HOME/.claude/session-env/$uuid ]]
}

@test "an MCP log it cannot read is named and kept, the rest deleted, and the end fails" {
  [[ $EUID -ne 0 ]] || skip "root reads every file"
  mcp_logs "$(native_cache)"
  local locked; locked=$(native_cache)/-home-x-slots-proj-1/mcp-logs-prod-read/locked.jsonl
  printf '{"sessionId":"%s"}\n' "$uuid" >"$locked"
  chmod 000 "$locked"
  agents "$(ops_session)"
  run_bin -1 --separate-stderr team-ops-end T5
  chmod 600 "$locked"
  assert_logs_ended
  [[ -f $locked && ! -e $HOME/.claude/session-env/$uuid && ! -e $slug/$uuid.jsonl ]]
  assert_contains "$output" "ended T5-ops (4f2a9c1e)"
  assert_contains "$stderr" "$locked"
  assert_contains "$stderr" "team-ops-end: an MCP log above could not be read and is kept; delete it by hand if it is the session's"
}
