#!/usr/bin/env bats
# team-tokens: this machine's usage exported into the team home, one line per reply, no content.

load helpers/common

# fixtures/team-tokens/projects/ is a ~/.claude/projects holding, with every string of message
# content, thinking, tool input and output, working directory and branch marked CONTENT-:
# - -home-dan-agent-team/aaaaaaaa-...: req_A1 (two lines, a thinking and a text block, across
#   midnight UTC, with cache_creation and thinking tokens), req_A2 (an older version's line, no
#   cache_creation, no thinking), a tool result, a <synthetic> error with no request id, and a
#   last line cut short;
# - its subagents/agent-abc123.jsonl: req_S1, two lines whose output grows from 5 to 120, no
#   cache_creation;
# - -home-dan-agent-team--claude-worktrees-1/bbbbbbbb-...: a copy of req_A1's second line (as a
#   fork carries it) and req_B1 on Sonnet 5.5, its cache write split between the lifetimes.
setup() {
  sandbox
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-tokens/projects" "$HOME/.claude/projects"
  usage=$TEAM_HOME/usage/home-pc
  scan=$HOME/.local/state/agent-team/usage-scan.json
  aaaa=aaaaaaaa-1111-4111-8111-111111111111
  bbbb=bbbbbbbb-2222-4222-8222-222222222222
}

# Each file under <dir> with its modification time and checksum, one per line, for a before and
# after: fingerprint <dir>...
fingerprint() {
  find "$@" -type f -printf '%p %T@ ' -exec md5sum {} \; | sort
}

# Append to the main fixture transcript an assistant reply, request <id>, at <ts>, with <output>
# tokens: add_reply <id> <ts> <output>
add_reply() {
  printf '{"type":"assistant","isSidechain":false,"message":{"id":"msg_%s","model":"claude-opus-5-5","content":[{"type":"text","text":"CONTENT-LATER"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":500,"output_tokens":%s}},"requestId":"%s","timestamp":"%s","sessionId":"%s"}\n' \
    "$1" "$3" "$1" "$2" "$aaaa" >>"$HOME/.claude/projects/-home-dan-agent-team/$aaaa.jsonl"
}

@test "--help prints the header" {
  run_bin -0 team-tokens --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-tokens")"
  assert_contains "$output" "Usage: team-tokens export [--through-now]"
}

@test "the report is not built yet, said in one line" {
  run_bin -1 --separate-stderr team-tokens
  assert_equal "$output" ""
  assert_equal "$stderr" "team-tokens: the report is not built yet; team-tokens export writes this machine's usage into the team home"
}

@test "a malformed command line is exit 2" {
  for args in "export --nope" "export --through-now --through-now" "export now" "report"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 --separate-stderr team-tokens $args
    assert_contains "$stderr" "usage: team-tokens"
  done
}

@test "the export writes one line per reply, deduplicated by request id, in a file per UTC day" {
  run_bin -0 team-tokens export
  assert_equal "$output" "usage/home-pc/2026-10-20.jsonl: 1 reply, 1 new
usage/home-pc/2026-10-21.jsonl: 3 replies, 3 new
read 3 of 3 transcripts; wrote 2 day files"
  assert_equal "$(ls "$usage")" "2026-10-20.jsonl
2026-10-21.jsonl"
  assert_equal "$(cat "$usage/2026-10-20.jsonl")" \
    '{"ts":"2026-10-20T23:59:59.500Z","machine":"home-pc","session":"'"$aaaa"'","project_dir":"-home-dan-agent-team","model":"claude-opus-5-5","request":"req_A1","input":3,"cache_write_1h":1000,"cache_write_5m":0,"cache_read":20000,"output":50,"thinking":7}'
  assert_equal "$(cat "$usage/2026-10-21.jsonl")" \
    '{"ts":"2026-10-21T00:00:10.000Z","machine":"home-pc","session":"'"$aaaa"'","project_dir":"-home-dan-agent-team","model":"claude-opus-5-5","request":"req_A2","input":1,"cache_write_1h":300,"cache_write_5m":0,"cache_read":21000,"output":40}
{"ts":"2026-10-21T01:00:00.000Z","machine":"home-pc","session":"'"$aaaa"'","agent":"abc123","project_dir":"-home-dan-agent-team","model":"claude-opus-5-5","request":"req_S1","input":2,"cache_write_1h":0,"cache_write_5m":2000,"cache_read":0,"output":120}
{"ts":"2026-10-21T10:00:00.000Z","machine":"home-pc","session":"'"$bbbb"'","project_dir":"-home-dan-agent-team--claude-worktrees-1","model":"claude-sonnet-5-5","request":"req_B1","input":5,"cache_write_1h":3000,"cache_write_5m":1000,"cache_read":8000,"output":90,"thinking":0}'
}

@test "no content reaches the export: every line has only the listed fields, and no fixture string" {
  run_bin -0 team-tokens export
  run grep -r CONTENT "$TEAM_HOME/usage" "$scan"
  assert_equal "$status" 1
  assert_equal "$(cat "$usage"/*.jsonl | jq -r 'keys_unsorted[]' | sort -u | paste -sd ' ')" \
    "agent cache_read cache_write_1h cache_write_5m input machine model output project_dir request session thinking ts"
  assert_equal "$(jq -s 'all(.[]; (to_entries | map(.value | type) | unique) - ["number", "string"] == [])' "$usage"/*.jsonl)" true
}

@test "a rerun with nothing new changes no file, the scan state included" {
  run_bin -0 team-tokens export
  local before
  before=$(fingerprint "$TEAM_HOME" "$scan")
  run_bin -0 team-tokens export
  assert_equal "$output" "read 0 of 3 transcripts; no day file changed"
  assert_equal "$(fingerprint "$TEAM_HOME" "$scan")" "$before"
}

@test "it rereads only the transcripts whose size or modification time changed" {
  run_bin -0 team-tokens export
  local worker=$HOME/.claude/projects/-home-dan-agent-team--claude-worktrees-1/$bbbb.jsonl day20
  day20=$(fingerprint "$usage/2026-10-20.jsonl")
  # The worker's transcript, its output count changed in place with its size and time kept, is not
  # read again; the main one, which gained a reply, is.
  touch -r "$worker" "$BATS_TEST_TMPDIR/stamp"
  sed -i 's/"output_tokens":90/"output_tokens":99/' "$worker"
  touch -r "$BATS_TEST_TMPDIR/stamp" "$worker"
  add_reply req_A4 2026-10-21T12:00:00.000Z 7
  run_bin -0 team-tokens export
  assert_equal "$output" "usage/home-pc/2026-10-21.jsonl: 4 replies, 1 new
read 1 of 3 transcripts; wrote 1 day file"
  assert_equal "$(jq -r '"\(.request) \(.output)"' "$usage/2026-10-21.jsonl")" "req_A2 40
req_S1 120
req_B1 90
req_A4 7"
  assert_equal "$(fingerprint "$usage/2026-10-20.jsonl")" "$day20"
}

@test "today is written only with --through-now, and a later export still finds its replies" {
  local today
  today=$(date -u +%F)
  add_reply req_T1 "${today}T00:00:01.000Z" 11
  run_bin -0 team-tokens export
  assert_equal "${lines[2]}" "read 3 of 3 transcripts; wrote 2 day files; 1 reply of today left for a later export"
  [[ ! -e $usage/$today.jsonl ]]
  # The transcript holding today's reply is read again until today is written.
  run_bin -0 team-tokens export
  assert_equal "$output" "read 1 of 3 transcripts; no day file changed; 1 reply of today left for a later export"
  run_bin -0 team-tokens export --through-now
  assert_equal "$output" "usage/home-pc/$today.jsonl: 1 reply, 1 new
read 1 of 3 transcripts; wrote 1 day file"
  assert_equal "$(jq -r .request "$usage/$today.jsonl")" req_T1
  # Today's file gains the replies made since.
  add_reply req_T2 "${today}T00:00:02.000Z" 12
  run_bin -0 team-tokens export --through-now
  assert_equal "$(jq -r .request "$usage/$today.jsonl" | paste -sd ' ')" "req_T1 req_T2"
  run_bin -0 team-tokens export --through-now
  assert_equal "$output" "read 0 of 3 transcripts; no day file changed"
}

@test "a reply already in a day file keeps its line, and gains only what grew" {
  run_bin -0 team-tokens export
  # req_A2 copied, its output grown, into a new session's transcript under another directory.
  mkdir -p "$HOME/.claude/projects/-home-dan-other"
  grep req_A2 "$HOME/.claude/projects/-home-dan-agent-team/$aaaa.jsonl" |
    jq -c '.sessionId = "cccccccc" | .message.usage.output_tokens = 41' >"$HOME/.claude/projects/-home-dan-other/cccccccc.jsonl"
  run_bin -0 team-tokens export
  assert_equal "$output" "usage/home-pc/2026-10-21.jsonl: 3 replies, 0 new
read 1 of 4 transcripts; wrote 1 day file"
  assert_equal "$(jq -c 'select(.request == "req_A2") | [.session, .project_dir, .output]' "$usage/2026-10-21.jsonl")" \
    "[\"$aaaa\",\"-home-dan-agent-team\",41]"
}

@test "a transcript Claude Code cleaned up leaves the scan state, and its days stay" {
  run_bin -0 team-tokens export
  rm "$HOME/.claude/projects/-home-dan-agent-team--claude-worktrees-1/$bbbb.jsonl"
  run_bin -0 team-tokens export
  assert_equal "$output" "read 0 of 2 transcripts; no day file changed"
  assert_equal "$(jq -r '.files | keys[]' "$scan" | grep -c bbbbbbbb)" 0
  assert_equal "$(grep -c req_B1 "$usage/2026-10-21.jsonl")" 1
}

@test "with no transcripts it writes nothing" {
  rm -r "$HOME/.claude/projects"
  run_bin -0 team-tokens export
  assert_equal "$output" "read 0 of 0 transcripts; no day file changed"
  [[ ! -e $TEAM_HOME/usage ]]
}

@test "a machine with no team name is refused" {
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 --separate-stderr team-tokens export
  assert_equal "$stderr" "team-tokens: this machine has no team name; write one with: echo <name> > ~/.config/agent-team/machine"
  echo Home_PC >"$HOME/.config/agent-team/machine"
  run_bin -1 --separate-stderr team-tokens export
  assert_contains "$stderr" "names 'Home_PC', not a lower-case kebab-case name like home-pc"
  [[ ! -e $TEAM_HOME/usage ]]
}

@test "the prices file holds each model's five prices, the date read and the source" {
  local prices=$REPO_ROOT/bin/lib/prices.json
  assert_equal "$(jq -r '.source' "$prices")" "https://platform.claude.com/docs/en/about-claude/pricing"
  [[ $(jq -r '.read' "$prices") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  assert_equal "$(jq -r '.models | keys[]' "$prices" | paste -sd ' ')" \
    "<synthetic> claude-fable-5-1 claude-haiku-5-5 claude-opus-5 claude-opus-5-5 claude-sonnet-5-5"
  assert_equal "$(jq '[.models[] | ., (.above // empty) | del(.tokens, .above) | keys == ["cache_read", "cache_write_1h", "cache_write_5m", "input", "output"] and all(.[]; type == "number")] | all' "$prices")" true
  assert_equal "$(jq -c '.models["<synthetic>"] | [.[]] | unique' "$prices")" "[0]"
}
