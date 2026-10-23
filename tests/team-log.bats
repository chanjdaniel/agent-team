#!/usr/bin/env bats
# team-log: recording a hand-written event against the ledger contract, and checking a ledger.

load helpers/common

setup() {
  sandbox
  CONTRACT=$REPO_ROOT/bin/lib/ledger-contract.json
  STRICT_FROM=$(jq -r .strict_from "$CONTRACT")
}

# The ledger's lines without their ts, one per line.
ledger_without_ts() {
  jq -c 'del(.ts)' "$TEAM_HOME/ledger.jsonl"
}

assert_ledger_empty() {
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" ""
}

@test "the contract lists every kind of the spec's table with its writer and required fields" {
  local expected actual
  expected=$(
    cat <<'TABLE'
opened team-open project path type title branch base base_sha worktree
worktree-added team-open project branch base base_sha worktree
thread team-thread discord_thread
launch team-worker role session worktree toolkits
worktree-returned team-close project worktree
closed team-close archive returned kept
merged team-merge pr merge head by
history-rewritten team-clean-messages branch old_head head
done team-log role session
ticket-done team-log ticket commits
question team-log role text
asked team-log id text
answered team-log id answer
plan-approved team-log by
paused team-log reason
blocked team-log reason
held team-log reason
waiting team-log on reason
resumed team-log
pr team-log url head
review team-log verdict head
merge-approved team-log url discord_message
failed team-log reason
stowed team-handoff machine worktrees roles
TABLE
  )
  actual=$(jq -r '.kinds | to_entries[] | [.key, .value.writer, (.value.required | keys_unsorted[])] | join(" ")' "$CONTRACT")
  assert_equal "$actual" "$expected"
  assert_equal "$(jq -c '.kinds.launch.optional' "$CONTRACT")" '{"project":"string","branch":"string","machine":"string"}'
  assert_equal "$(jq -c '.kinds.review.required.verdict' "$CONTRACT")" '["pass","findings"]'
  assert_equal "$(jq -c '[.kinds.closed.required[]]' "$CONTRACT")" '["array","array","array"]'
  [[ $STRICT_FROM =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "--help prints the header and the contract as a table" {
  run_bin -0 team-log --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-log")"
  assert_contains "$output" "Ledger contract, strict from $STRICT_FROM"
  local kind
  for kind in $(jq -r '.kinds | keys_unsorted[]' "$CONTRACT"); do
    grep -Eq "^  $kind +[a-z-]+ " <<<"$output" || {
      echo "no row for $kind" >&2
      return 1
    }
  done
  grep -Eq '^  opened +team-open +project, path, type, title, branch, base, base_sha, worktree$' <<<"$output"
  grep -Eq '^  review +team-log +verdict \(pass\|findings\), head; optional agent_review$' <<<"$output"
  grep -Eq '^  closed +team-close +archive \(list\), returned \(list\), kept \(list\)  \(.*legacy.*\)$' <<<"$output"
  grep -Eq '^  merge-approved +team-log +url, discord_message  \(.*\)$' <<<"$output"
  grep -Eq '^  launch +team-worker +role, session, worktree, toolkits \(list\); optional project, branch, machine$' <<<"$output"
  grep -Eq '^  resumed +team-log +- +\(clears held, blocked, paused and waiting\)$' <<<"$output"
  grep -Eq '^  stowed +team-handoff +machine, worktrees \(list\), roles \(list\)  \(one per open task at a handoff: .*\)$' <<<"$output"
  assert_equal "$(stub_calls curl)$(stub_calls gh)" ""
}

@test "an event is appended as one line with ts now, task and event" {
  local before after
  before=$(date -u +%FT%TZ)
  run_bin -0 team-log T14 pr url=https://github.com/chanjdaniel/agent-team/pull/5 head=a1b2c3d
  after=$(date -u +%FT%TZ)
  assert_equal "$output" ""
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "1"
  assert_equal "$(ledger_without_ts)" \
    '{"task":"T14","event":"pr","url":"https://github.com/chanjdaniel/agent-team/pull/5","head":"a1b2c3d"}'
  local ts
  ts=$(jq -r .ts "$TEAM_HOME/ledger.jsonl")
  [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ ! $ts < $before && ! $ts > $after ]]

  run_bin -0 team-log T14 resumed
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "2"
  assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)')" '{"task":"T14","event":"resumed"}'
}

@test "values that parse as JSON are stored as JSON, others as strings" {
  run_bin -0 team-log T14 ticket-done ticket=03 'commits=["a1b2c3d", "e4f5a6b"]' count=3 ok=true \
    'extra={"a":1}' 'quoted="7"' 'note=two words, [not a list' nan=nan nothing=null
  assert_equal "$(ledger_without_ts)" \
    '{"task":"T14","event":"ticket-done","ticket":"03","commits":["a1b2c3d","e4f5a6b"],"count":3,"ok":true,"extra":{"a":1},"quoted":"7","note":"two words, [not a list","nan":"nan","nothing":"null"}'
}

@test "a field the contract types as a string stays a string even when it looks like JSON" {
  run_bin -0 team-log T14 ticket-done ticket=12 'commits=["1234567"]'
  run_bin -0 team-log T14 pr url=https://github.com/chanjdaniel/agent-team/pull/5 head=1234567 note=true
  run_bin -0 team-log T14 merge-approved url=https://github.com/chanjdaniel/agent-team/pull/5 discord_message=1563000000000000123456789
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"ticket-done","ticket":"12","commits":["1234567"]}
{"task":"T14","event":"pr","url":"https://github.com/chanjdaniel/agent-team/pull/5","head":"1234567","note":"true"}
{"task":"T14","event":"merge-approved","url":"https://github.com/chanjdaniel/agent-team/pull/5","discord_message":"1563000000000000123456789"}
LINES
  )"
}

@test "every kind team-log writes is appended with its required fields and a note" {
  local kind args count=0
  while IFS= read -r kind; do
    mapfile -t args < <(jq -r --arg k "$kind" '.kinds[$k].required | to_entries[]
      | "\(.key)=\(.value | if type == "array" then .[0] elif . == "array" then "[]" elif . == "number" then "7" else "x y" end)"' "$CONTRACT")
    run_bin -0 team-log T14 "$kind" "${args[@]}" "note=why $kind"
    count=$((count + 1))
    assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r '.event + " " + .note')" "$kind why $kind"
  done < <(jq -r '.kinds | to_entries[] | select(.value.writer == "team-log") | .key' "$CONTRACT")
  assert_equal "$count" "15"
  run_bin -0 team-log --check
}

@test "a malformed task id is a usage error with nothing appended" {
  local task
  for task in 14 T0 t14 T14a T-1 ''; do
    run_bin -2 team-log "$task" resumed
    assert_contains "$output" "task must look like T<n>, got '$task'"
  done
  assert_ledger_empty
}

@test "an unknown kind is refused with nothing appended" {
  run_bin -1 team-log T14 ticket-don ticket=03 'commits=["a1b2c3d"]'
  assert_contains "$output" "unknown event kind 'ticket-don'"
  assert_contains "$output" "team-log --help"
  assert_ledger_empty
}

@test "a missing required field is refused with nothing appended" {
  run_bin -1 team-log T14 pr url=https://github.com/chanjdaniel/agent-team/pull/5
  assert_contains "$output" "pr needs head"
  run_bin -1 team-log T14 review 'note=looks fine'
  assert_contains "$output" "review needs verdict"
  assert_contains "$output" "review needs head"
  assert_ledger_empty
}

@test "a value of the wrong type or outside its choices is refused with nothing appended" {
  run_bin -1 team-log T14 ticket-done ticket=03 commits=a1b2c3d
  assert_contains "$output" "commits must be a list, got a string"
  run_bin -1 team-log T14 review verdict=ok head=a1b2c3d
  assert_contains "$output" "verdict must be one of pass, findings"
  run_bin -1 team-log T14 ticket-done ticket=03 'commits={"a":1}'
  assert_contains "$output" "commits must be a list, got an object"
  assert_ledger_empty
}

@test "a malformed key=value is a usage error with nothing appended" {
  local pair
  for pair in reason '=x' 'Reason=x' 'two words=x' 'reason=' '1st=x'; do
    run_bin -2 team-log T14 blocked "$pair"
    assert_contains "$output" "not a key=value: '$pair'"
  done
  run_bin -2 team-log T14 blocked reason=a reason=b
  assert_contains "$output" "reason is given twice"
  local key
  for key in ts task event; do
    run_bin -2 team-log T14 blocked reason=a "$key=x"
    assert_contains "$output" "$key is set by team-log"
  done
  assert_ledger_empty
}

@test "merge-approved names a PR of the task's pr events, by its URL" {
  local five=https://github.com/owner/proj/pull/5 seven=https://github.com/other/repo/pull/7
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1563
  assert_contains "$output" "$five is not a PR of T14's pr events; it has none"
  assert_ledger_empty
  run_bin -0 team-log T14 pr url=$five/ head=a1b2c3d
  run_bin -0 team-log T14 pr url=$seven head=e4f5a6b
  run_bin -0 team-log T13 pr url=https://github.com/owner/proj/pull/9 head=0a1b2c3
  run_bin -1 team-log T14 merge-approved url=https://github.com/owner/proj/pull/9 discord_message=1563
  assert_contains "$output" "https://github.com/owner/proj/pull/9 is not a PR of T14's pr events:"
  assert_contains "$output" "  $five/"
  assert_contains "$output" "  $seven"
  run_bin -1 team-log T14 merge-approved pr=5 discord_message=1563
  assert_contains "$output" "merge-approved needs url"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "3"
  run_bin -0 team-log T14 merge-approved url=$five discord_message=1563
  run_bin -0 team-log T14 merge-approved url=$seven/ discord_message=1564
  assert_equal "$(tail -n 2 "$TEAM_HOME/ledger.jsonl" | jq -r .url)" "$five"$'\n'"$seven/"
}

@test "a kind another script writes is refused with nothing appended" {
  run_bin -1 team-log T14 opened project=agent-team path=feature type=feat title=x branch=b base=dev base_sha=abc1234 worktree=/w
  assert_contains "$output" "opened events are written by team-open, not team-log"
  run_bin -1 team-log T14 launch role=builder session=abc worktree=/w 'toolkits=[]'
  assert_contains "$output" "launch events are written by team-worker, not team-log"
  run_bin -1 team-log T14 merged pr=5 merge=abc1234 head=def5678 by=coordinator
  assert_contains "$output" "merged events are written by team-merge, not team-log"
  run_bin -1 team-log T14 closed 'archive=[]' 'returned=[]' 'kept=[]'
  assert_contains "$output" "closed events are written by team-close, not team-log"
  run_bin -1 team-log T14 thread discord_thread=1563
  assert_contains "$output" "thread events are written by team-thread, not team-log"
  assert_ledger_empty
}

@test "too few arguments is a usage error" {
  run_bin -2 team-log
  assert_contains "$output" "usage: team-log T<n> <event> [key=value]..."
  run_bin -2 team-log T14
  run_bin -2 team-log --check a b
  assert_ledger_empty
}

@test "--check passes a ledger whose legacy lines are loose and whose later lines meet the contract" {
  [[ 2026-10-01T00:00:00Z < $STRICT_FROM ]]
  cat >"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"2026-10-01T00:00:00Z","task":"T1","event":"closed"}
{"ts":"2026-10-01T00:00:01Z","task":"T5","event":"ticket-partial","ticket":"09"}
{"ts":"2026-10-01T00:00:02Z","task":"T4","event":"review","verdict":"pass","agent_review":"success","head":"e1e8cdb6"}
{"ts":"2026-10-01T00:00:03Z","task":"T7","event":"closed","note":"a legacy close by hand: no lists"}
{"ts":"2026-10-01T00:00:04Z","task":"T16","event":"plan-ready","note":"a kind that is not in the contract"}
{"ts":"$STRICT_FROM","task":"T14","event":"closed","archive":["tasks/T14/scratch"],"returned":[],"kept":[]}
{"ts":"$STRICT_FROM","task":"T14","event":"launch","role":"builder","session":"c79f0205","worktree":"/w","toolkits":[]}
{"ts":"$STRICT_FROM","task":"T14","event":"resumed","note":"anything extra is allowed","by":"coordinator"}
LEDGER
  run_bin -0 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 8 lines meet the ledger contract"
}

@test "--check lists every bad line by number and exits 1" {
  cat >"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"2026-10-01T00:00:00Z","task":"T1","event":"closed"}
not json
{"task":"T1","event":"closed"}
{"ts":"2026-10-01 00:00:00","task":"T1","event":"closed"}
{"ts":"2026-10-01T00:00:00Z","task":"7","event":"closed"}

{"ts":"2026-10-01T00:00:00Z","task":"T1"}
["ts","task","event"]
{"ts":"$STRICT_FROM","task":"T14","event":"closed"}
{"ts":"$STRICT_FROM","task":"T14","event":"ticket-partial","ticket":"09"}
{"ts":"$STRICT_FROM","task":"T14","event":"review","verdict":"fine","head":"a1b2c3d","note":7}
{"ts":"$STRICT_FROM","task":"T14","event":"pr","url":"","head":"a1b2c3d"}
{"ts":"$STRICT_FROM","task":"T14","event":"thread","discord_thread":"1563"}
LEDGER
  run_bin -1 team-log --check
  assert_equal "$output" "$(
    cat <<EXPECTED
$TEAM_HOME/ledger.jsonl:2: not JSON
$TEAM_HOME/ledger.jsonl:3: missing ts
$TEAM_HOME/ledger.jsonl:4: ts must be a UTC time like 2026-10-22T01:00:00Z
$TEAM_HOME/ledger.jsonl:5: task must look like T<n>
$TEAM_HOME/ledger.jsonl:6: not JSON
$TEAM_HOME/ledger.jsonl:7: missing event
$TEAM_HOME/ledger.jsonl:8: not a JSON object
$TEAM_HOME/ledger.jsonl:9: closed needs archive; closed needs returned; closed needs kept
$TEAM_HOME/ledger.jsonl:10: unknown event kind 'ticket-partial'
$TEAM_HOME/ledger.jsonl:11: verdict must be one of pass, findings; note must be a string, got a number
$TEAM_HOME/ledger.jsonl:12: pr needs url
$TEAM_HOME/ledger.jsonl: 11 of 13 lines break the ledger contract
EXPECTED
  )"
}

@test "--check reads the file it is given, and a missing ledger is refused" {
  printf '%s\n' '{"ts":"2026-10-01T00:00:00Z","task":"T1","event":"closed"}' >"$BATS_TEST_TMPDIR/other.jsonl"
  echo 'not json' >"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log --check "$BATS_TEST_TMPDIR/other.jsonl"
  assert_equal "$output" "$BATS_TEST_TMPDIR/other.jsonl: 1 line meets the ledger contract"
  run_bin -1 team-log --check "$BATS_TEST_TMPDIR/missing.jsonl"
  assert_contains "$output" "no ledger at $BATS_TEST_TMPDIR/missing.jsonl"
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-log --check
  assert_contains "$output" "no ledger at $TEAM_HOME/ledger.jsonl"
}

@test "--check passes the real ledger" {
  run_bin -0 team-log --check "$REPO_ROOT/ledger.jsonl"
  assert_contains "$output" "lines meet the ledger contract"
}
