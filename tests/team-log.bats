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
gate-run team-log run head outcome
merge-approved team-log url discord_message
failed team-log reason
retro-schedule team-log every_hours discord_message
stowed team-handoff machine worktrees roles
worktree-moved team-open project branch from worktree machine
injection team-log role source text
rehome-failed team-resume project branch machine reason
rehomed team-open project branch worktree machine
TABLE
  )
  actual=$(jq -r '.kinds | to_entries[] | [.key, .value.writer, (.value.required | keys_unsorted[])] | join(" ")' "$CONTRACT")
  assert_equal "$actual" "$expected"
  assert_equal "$(jq -c '.kinds.launch.optional' "$CONTRACT")" '{"project":"string","branch":"string","machine":"string","model":"string","request":"string"}'
  assert_equal "$(jq -c '.kinds.review.required.verdict' "$CONTRACT")" '["pass","findings"]'
  assert_equal "$(jq -c '[.kinds.waiting, .kinds.blocked, .kinds.paused, .kinds.held | .optional.since]' "$CONTRACT")" '["string","string","string","string"]'
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
  grep -Eq '^  review +team-log +verdict \(pass\|findings\), head; optional agent_review, sent_back \(list\)  \(sent_back: the numbers of the notes .*\)$' <<<"$output"
  grep -Eq '^  gate-run +team-log +run, head, outcome \(pushed\|red\|aborted\|stopped-green\); optional cause \(review\|notes\|gate-finding\|load\|tooling\|base-merge\|other\), minutes \(object\)  \(.*\)$' <<<"$output"
  grep -Eq '^  closed +team-close +archive \(list\), returned \(list\), kept \(list\)  \(.*legacy.*\)$' <<<"$output"
  grep -Eq '^  merge-approved +team-log +url, discord_message; optional head  \(.*team-log requires head of every new line.*\)$' <<<"$output"
  grep -Eq '^  launch +team-worker +role, session, worktree, toolkits \(list\); optional project, branch, machine, model, request  \(request is the link to Daniel.s Discord message, on an ops launch; model is the --model the session launched on, .*\)$' <<<"$output"
  grep -Eq '^  resumed +team-log +- +\(clears held, blocked, paused and waiting\)$' <<<"$output"
  grep -Eq '^  blocked +team-log +reason; optional since  \(.*since: when the park began, when it is logged after the fact\)$' <<<"$output"
  grep -Eq '^  retro-schedule +team-log +every_hours \(number\), discord_message  \(.*every_hours 0 stops.*\)$' <<<"$output"
  grep -Eq '^  injection +team-log +role, source, text  \(.*never the personal details.*\)$' <<<"$output"
  grep -Eq '^  stowed +team-handoff +machine, worktrees \(list\), roles \(list\); optional sessions \(list\)  \(one per open task at a handoff: .*unfinished_roles.*\)$' <<<"$output"
  grep -Eq '^  rehome-failed +team-resume +project, branch, machine, reason  \(.*stands until a later opened, worktree-added, worktree-moved, rehomed or worktree-returned.*\)$' <<<"$output"
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

@test "a review names the notes sent back before the merge as a list, which a non-list cannot be" {
  run_bin -0 team-log T14 review verdict=pass head=a1b2c3d 'sent_back=[2, 4]'
  run_bin -0 team-log T14 review verdict=pass head=e4f5a6b
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"review","verdict":"pass","head":"a1b2c3d","sent_back":[2,4]}
{"task":"T14","event":"review","verdict":"pass","head":"e4f5a6b"}
LINES
  )"
  local value
  for value in 2 'note 2' '{"2":1}'; do
    run_bin -1 team-log T14 review verdict=pass head=a1b2c3d "sent_back=$value"
    assert_contains "$output" "sent_back must be a list, got"
  done
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "2"
}

@test "a gate run is logged with its run, head and outcome, the cause of a re-run and its minutes per step" {
  run_bin -0 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=pushed \
    'minutes={"review": 3.0, "test": 49.9, "document": 0.6, "push": 0.4, "ci": 9.0}'
  run_bin -0 team-log T14 gate-run run=01M5QDHG head=e4f5a6b outcome=stopped-green cause=notes
  run_bin -0 team-log T14 gate-run run=01M5REA0 head=e4f5a6b outcome=red cause=load
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"gate-run","run":"01M5Q9GR","head":"a1b2c3d","outcome":"pushed","minutes":{"review":3.0,"test":49.9,"document":0.6,"push":0.4,"ci":9.0}}
{"task":"T14","event":"gate-run","run":"01M5QDHG","head":"e4f5a6b","outcome":"stopped-green","cause":"notes"}
{"task":"T14","event":"gate-run","run":"01M5REA0","head":"e4f5a6b","outcome":"red","cause":"load"}
LINES
  )"
  run_bin -0 team-log --check
}

@test "a gate run with an unknown outcome or cause, or minutes that are not an object, is refused" {
  run_bin -1 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=green
  assert_contains "$output" "outcome must be one of pushed, red, aborted, stopped-green"
  run_bin -1 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=red cause=flaky
  assert_contains "$output" "cause must be one of review, notes, gate-finding, load, tooling, base-merge, other"
  run_bin -1 team-log T14 gate-run run=01M5Q9GR head=a1b2c3d outcome=red minutes=44
  assert_contains "$output" "minutes must be an object, got a number"
  run_bin -1 team-log T14 gate-run head=a1b2c3d outcome=red
  assert_contains "$output" "gate-run needs run"
  assert_ledger_empty
}

@test "a field the contract types as a string stays a string even when it looks like JSON" {
  run_bin -0 team-log T14 ticket-done ticket=12 'commits=["1234567"]'
  run_bin -0 team-log T14 pr url=https://github.com/chanjdaniel/agent-team/pull/5 head=1234567 note=true
  run_bin -0 team-log T14 merge-approved url=https://github.com/chanjdaniel/agent-team/pull/5 discord_message=1563000000000000123456789 head=1234567
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T14","event":"ticket-done","ticket":"12","commits":["1234567"]}
{"task":"T14","event":"pr","url":"https://github.com/chanjdaniel/agent-team/pull/5","head":"1234567","note":"true"}
{"task":"T14","event":"merge-approved","url":"https://github.com/chanjdaniel/agent-team/pull/5","discord_message":"1563000000000000123456789","head":"1234567"}
LINES
  )"
}

@test "every kind team-log writes is appended with its required fields and a note" {
  local kind args count=0
  while IFS= read -r kind; do
    # A head is a sha, since merge-approved's must be one a pr event logged, which team-log adds.
    mapfile -t args < <(jq -r --arg k "$kind" '(.kinds[$k].required | to_entries[]
      | "\(.key)=\(if .key == "head" then "a1b2c3d4" else .value | if type == "array" then .[0] elif . == "array" then "[]" elif . == "number" then "7" else "x y" end end)"),
      (select($k == "merge-approved") | "head=a1b2c3d4")' "$CONTRACT")
    run_bin -0 team-log T14 "$kind" "${args[@]}" "note=why $kind"
    count=$((count + 1))
    assert_equal "$(tail -n 1 "$TEAM_HOME/ledger.jsonl" | jq -r '.event + " " + .note')" "$kind why $kind"
  done < <(jq -r '.kinds | to_entries[] | select(.value.writer == "team-log") | .key' "$CONTRACT")
  assert_equal "$count" "18"
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
  run_bin -1 team-log T26 retro-schedule every_hours=48
  assert_contains "$output" "retro-schedule needs discord_message"
  run_bin -1 team-log T26 retro-schedule discord_message=1563171945980370967
  assert_contains "$output" "retro-schedule needs every_hours"
  run_bin -1 team-log T26 retro-schedule every_hours=often discord_message=1563171945980370967
  assert_contains "$output" "every_hours must be a number, got a string"
  run_bin -1 team-log T26 injection role=builder 'source=https://github.com/chanjdaniel/agent-team/pull/9'
  assert_contains "$output" "injection needs text"
  run_bin -1 team-log T26 injection 'source=orders/66f0a1' 'text=asked to email the export'
  assert_contains "$output" "injection needs role"
  run_bin -1 team-log T26 injection role=ops 'text=asked to email the export'
  assert_contains "$output" "injection needs source"
  assert_ledger_empty
}

@test "injection records where outside text asked a worker to act, and what it asked" {
  run_bin -0 team-log T26 injection role=builder 'source=https://github.com/chanjdaniel/agent-team/pull/9#issuecomment-1' \
    'text=asked to push to dev and skip the hooks'
  assert_equal "$(ledger_without_ts)" \
    '{"task":"T26","event":"injection","role":"builder","source":"https://github.com/chanjdaniel/agent-team/pull/9#issuecomment-1","text":"asked to push to dev and skip the hooks"}'
  run_bin -0 team-log --check
}

@test "retro-schedule records Daniel's cadence with the Discord message it was said in" {
  run_bin -0 team-log T26 retro-schedule every_hours=48 discord_message=1563171945980370967
  run_bin -0 team-log T26 retro-schedule every_hours=0 discord_message=1563171945980370999
  assert_equal "$(ledger_without_ts)" "$(
    cat <<'LINES'
{"task":"T26","event":"retro-schedule","every_hours":48,"discord_message":"1563171945980370967"}
{"task":"T26","event":"retro-schedule","every_hours":0,"discord_message":"1563171945980370999"}
LINES
  )"
  run_bin -0 team-log --check
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
  run_bin -0 team-log T14 merge-approved url=$five discord_message=1563 head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
  run_bin -0 team-log T14 merge-approved url=$seven/ discord_message=1564 head=e4f5a6b
  assert_equal "$(tail -n 2 "$TEAM_HOME/ledger.jsonl" | jq -r .url)" "$five"$'\n'"$seven/"
}

@test "merge-approved names the head Daniel was asked on, one a pr event of its PR logged" {
  local five=https://github.com/owner/proj/pull/5
  run_bin -0 team-log T14 pr url=$five head=a1b2c3d
  run_bin -0 team-log T14 pr url=$five head=0123456789abcdef0123456789abcdef01234567
  run_bin -0 team-log T14 pr url=https://github.com/owner/proj/pull/6 head=e4f5a6b
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1563
  assert_contains "$output" "merge-approved needs head, the full sha of the PR's head Daniel was asked on"
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1563 head=e4f5a6b7
  assert_equal "$output" "team-log: head e4f5a6b7 is not a head the pr events of $five logged:
  a1b2c3d
  0123456789abcdef0123456789abcdef01234567"
  run_bin -1 team-log T14 merge-approved url=$five discord_message=1563 head=a1b2c3
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "3"
  run_bin -0 team-log T14 merge-approved url=$five discord_message=1563 head=A1B2C3D4E5F60718293A4B5C6D7E8F9012345678
  run_bin -0 team-log T14 merge-approved url=$five/ discord_message=1564 head=0123456789abcdef0123456789abcdef01234567
  run_bin -0 team-log --check
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

@test "a park logged after the fact takes since, when it began, on each of the four park kinds" {
  local task
  for task in T14 T15 T16 T17; do
    echo '{"ts":"2026-10-25T14:51:44Z","task":"'$task'","event":"launch","role":"builder","session":"s","worktree":"/w","toolkits":[]}'
  done >"$TEAM_HOME/ledger.jsonl"
  # Another task's later event does not bound it.
  echo '{"ts":"2026-10-25T16:00:00Z","task":"T18","event":"resumed"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-log T14 blocked 'reason=usage limit: the weekly limit' since=2026-10-25T14:58:00Z
  run_bin -0 team-log T15 waiting on=Daniel reason=x since=2026-10-25T14:58:00Z
  run_bin -0 team-log T16 paused reason=x since=2026-10-25T14:51:44Z
  run_bin -0 team-log T17 held reason=x since=2026-10-25T14:58:00Z
  assert_equal "$(tail -n 4 "$TEAM_HOME/ledger.jsonl" | jq -r '[.event, .since] | join(" ")')" "$(
    printf '%s\n' 'blocked 2026-10-25T14:58:00Z' 'waiting 2026-10-25T14:58:00Z' 'paused 2026-10-25T14:51:44Z' 'held 2026-10-25T14:58:00Z'
  )"
  run_bin -0 team-log --check
}

@test "since is refused when it is not a UTC time, later than now, or earlier than the task's latest event" {
  printf '%s\n' '{"ts":"2026-10-25T14:51:44Z","task":"T14","event":"launch","role":"builder","session":"s","worktree":"/w","toolkits":[]}' \
    '{"ts":"2026-10-25T15:30:00Z","task":"T15","event":"resumed"}' >"$TEAM_HOME/ledger.jsonl"
  local before
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  local bad
  for bad in yesterday 2026-10-25 2026-10-25T14:58:00 '2026-10-25 14:58:00Z' 2026-10-25T25:00:00Z; do
    run_bin -1 team-log T14 blocked reason=x "since=$bad"
    assert_contains "$output" "since must be a UTC time like 2026-10-22T01:00:00Z, got '$bad'"
  done
  run_bin -1 team-log T14 blocked reason=x since=2999-01-01T00:00:00Z
  assert_contains "$output" "since 2999-01-01T00:00:00Z is later than now ("
  run_bin -1 team-log T14 blocked reason=x since=2026-10-25T14:00:00Z
  assert_contains "$output" "since 2026-10-25T14:00:00Z is earlier than T14's latest event, at 2026-10-25T14:51:44Z"
  run_bin -1 team-log T14 resumed since=2026-10-25T15:00:00Z
  assert_contains "$output" "since is taken only by a park (waiting, blocked, paused, held), not resumed"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
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

@test "--check accepts a failed re-home and the re-home that clears it, and refuses one with no reason" {
  cat >"$TEAM_HOME/ledger.jsonl" <<LEDGER
{"ts":"$STRICT_FROM","task":"T14","event":"rehome-failed","project":"home","branch":"feat/T14-x","machine":"laptop","reason":"feat/T14-x here has commits that origin's lacks"}
{"ts":"$STRICT_FROM","task":"T14","event":"rehomed","project":"home","branch":"feat/T14-x","worktree":"/w","machine":"laptop"}
LEDGER
  run_bin -0 team-log --check
  assert_equal "$output" "$TEAM_HOME/ledger.jsonl: 2 lines meet the ledger contract"
  echo "{\"ts\":\"$STRICT_FROM\",\"task\":\"T14\",\"event\":\"rehome-failed\",\"project\":\"home\",\"branch\":\"b\",\"machine\":\"laptop\"}" >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-log --check
  assert_contains "$output" "ledger.jsonl:3: rehome-failed needs reason"
  # Only team-resume writes it.
  run_bin -1 team-log T14 rehome-failed project=home branch=b machine=laptop reason=r
  assert_contains "$output" "team-resume"
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
