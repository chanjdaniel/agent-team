#!/usr/bin/env bats
# team-tokens: this machine's usage exported into the team home, one line per reply, no content;
# and the report over every machine's usage, joined to the ledger.

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

# The report's fixture, fixtures/team-tokens/report/: its ledger, and day files from two machines
# (no transcripts, so nothing is read live), every reply's $w chosen to add up by hand (Opus 5.5:
# $8 a million for a one-hour write, $5 a five-minute one, $0.20 a read, $20 an output):
# - home-pc, 2026-10-20: the coordinator c0 in the team home (~/agent-team-records, as this
#   machine's setting names it): 0.34, 0.14, a rebuild (150k of a 200k context written anew,
#   130 minutes on) of 1.23 and a compaction to 40k of 0.34, and its subagent's 0.14 (a five-minute
#   write); T1's planner p1 (0.5, 0.19), builder b1 (0.5, its subagent's 0.3), builder b2 (0.5,
#   0.12; its launch, a relaunch after a stow, names no machine), builder b3 (0.5), reviewer r1 on
#   Sonnet 5.5 (0.25, its launch naming the model sonnet) and reviewer r2 (0.5), whose pass after r1's findings is a re-review; T0's
#   builder t0, a load-check session k0 and an unlaunched worktree's u0 (0.08 each); and Daniel's own
#   d0 on Haiku 5.5, a 200k input at its long-prompt price (0.105);
# - laptop, 2026-10-21: the coordinator c1 (0.34) and T2's builder l1 (0.5, then 0.12 at 15:30,
#   opening a fourth 5-hour block); T2's reviewer l2 was launched and has no replies.
# In all 21 replies, 6.855 $w, in 13 sessions; 17 ledger events from the first reply on.
report_fixture() {
  rm -r "$HOME/.claude/projects"
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-tokens/report/usage" "$TEAM_HOME/usage"
  cp "$BATS_TEST_DIRNAME/fixtures/team-tokens/report/ledger.jsonl" "$TEAM_HOME/ledger.jsonl"
  echo agent-team-records >"$HOME/.config/agent-team/home"
}

# The fixture's report as JSON, its window ending in its last block: report_json [<flag>...]
report_json() {
  run_bin -0 --separate-stderr team-tokens --until 2026-10-21T16:00Z --json "$@"
  assert_equal "$stderr" ""
  json=$output
}

# jq -c <filter> over the last report_json: q <filter>
q() {
  jq -c "$1" <<<"$json"
}

@test "--help prints the header" {
  run_bin -0 team-tokens --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-tokens")"
  assert_contains "$output" "Usage: team-tokens [--since <ISO>] [--until <ISO>] [--task T<n>] [--machine <name>] [--json]"
  assert_contains "$output" "team-tokens export [--through-now]"
  assert_contains "$output" "team-tokens time [--since <ISO>] [--until <ISO>]"
  assert_contains "$output" "time prints where each launched worker session's time went"
  assert_contains "$output" "usage/<machine>/time/"
  assert_contains "$output" "the weekly limit's reset time is in no data"
  assert_contains "$output" "schema team-tokens/1"
  assert_contains "$output" "coordinator turns"
  assert_contains "$output" "Daniel's waits"
}

@test "a malformed command line is exit 2" {
  for args in "export --nope" "export --through-now --through-now" "export now" "report" "--json --nope" "--since" \
    "time --json" "time --since" "time --task T1" "time --until 2026-10-20T00:00Z --until 2026-10-21T00:00Z"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 --separate-stderr team-tokens $args
    assert_equal "$stderr" "team-tokens: usage: team-tokens [--since <ISO>] [--until <ISO>] [--task T<n>] [--machine <name>] [--json] | team-tokens export [--through-now] | team-tokens time [--since <ISO>] [--until <ISO>]"
  done
  run_bin -2 --separate-stderr team-tokens --since 2026-10-20
  assert_equal "$stderr" "team-tokens: --since must be a UTC time like 2026-10-22T01:00Z or 2026-10-22T01:00:00Z"
  run_bin -2 --separate-stderr team-tokens --until 2026-10-20T08:00:00.5Z
  assert_equal "$stderr" "team-tokens: --until must be a UTC time like 2026-10-22T01:00Z or 2026-10-22T01:00:00Z"
  run_bin -2 --separate-stderr team-tokens --task T0
  assert_equal "$stderr" "team-tokens: task must look like T<n>, got 'T0'"
  run_bin -2 --separate-stderr team-tokens --machine Home_PC
  assert_equal "$stderr" "team-tokens: --machine must be a machine's team name like home-pc, got 'Home_PC'"
  run_bin -2 --separate-stderr team-tokens --since 2026-10-21T00:00Z --until 2026-10-21T00:00:00Z
  assert_equal "$stderr" "team-tokens: --since must come before --until"
  run_bin -2 --separate-stderr team-tokens time --since 2026-10-20
  assert_equal "$stderr" "team-tokens: --since must be a UTC time like 2026-10-22T01:00Z or 2026-10-22T01:00:00Z"
  run_bin -2 --separate-stderr team-tokens time --since 2026-10-21T00:00Z --until 2026-10-20T00:00Z
  assert_equal "$stderr" "team-tokens: --since must come before --until"
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

@test "an export into another team home reads every transcript again, and the first home's next export too" {
  run_bin -0 team-tokens export
  local other=$BATS_TEST_TMPDIR/other
  mkdir "$other"
  TEAM_HOME=$other run_bin -0 team-tokens export
  assert_equal "${lines[2]}" "read 3 of 3 transcripts; wrote 2 day files"
  assert_equal "$(cat "$other/usage/home-pc"/*.jsonl)" "$(cat "$usage"/*.jsonl)"
  add_reply req_A4 2026-10-21T12:00:00.000Z 7
  run_bin -0 team-tokens export
  assert_equal "$output" "usage/home-pc/2026-10-21.jsonl: 4 replies, 1 new
read 3 of 3 transcripts; wrote 1 day file"
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
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 --separate-stderr team-tokens time
  assert_equal "$stderr" "team-tokens: this machine has no team name; write one with: echo <name> > ~/.config/agent-team/machine"
  [[ ! -e $TEAM_HOME/usage ]]
}

@test "with neither TEAM_HOME nor ~/.config/agent-team/home it refuses, never writing into its code checkout" {
  local code=$BATS_TEST_TMPDIR/code
  mkdir -p "$code/bin/lib"
  cp "$REPO_ROOT/bin/team-tokens" "$code/bin/"
  cp "$REPO_ROOT/bin/lib/prices.json" "$code/bin/lib/"
  unset TEAM_HOME
  local verb
  for verb in export time ""; do
    run -1 --separate-stderr "$code/bin/team-tokens" ${verb:+"$verb"}
    assert_equal "$stderr" "team-tokens: neither TEAM_HOME nor ~/.config/agent-team/home names the team home; name its checkout there, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  done
  [[ ! -e $code/usage ]]
  run -0 "$code/bin/team-tokens" --help
}

@test "every subcommand refuses Python older than 3.11, naming the fix" {
  local old='' candidate verb
  for candidate in /usr/bin/python3 python3.10 python3.9; do
    candidate=$(command -v "$candidate") || continue
    if "$candidate" -c 'import sys; sys.exit(sys.version_info >= (3, 11))' 2>/dev/null; then
      old=$candidate && break
    fi
  done
  [[ -n $old ]] || skip "no Python older than 3.11 here (macOS has 3.9 at /usr/bin/python3)"
  for verb in export time ""; do
    run -1 --separate-stderr "$old" -I "$REPO_ROOT/bin/team-tokens" ${verb:+"$verb"}
    assert_equal "$output" ""
    assert_contains "$stderr" "team-tokens: needs Python 3.11 or later, but runs under Python "
  done
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

@test "the report weighs every machine's replies by token type, model and machine" {
  report_fixture
  report_json
  assert_equal "$(q '[.schema, .since, .until, .filters, .sources, .live, .ledger_events]')" \
    '["team-tokens/1","2026-10-20T08:00:00Z","2026-10-21T16:00:00Z",{"task":null,"machine":null},{"home-pc":"2026-10-20","laptop":"2026-10-21"},0,17]'
  assert_equal "$(q .totals)" '{"replies":21,"sessions":13,"tokens":1494000,"w":6.855}'
  assert_equal "$(q '.token_types[] | [.type, .tokens, .w]' | paste -sd ' ')" \
    '["input",200000,0.1] ["cache_write_1h",670000,5.16] ["cache_write_5m",60000,0.3] ["cache_read",500000,0.1] ["output",64000,1.195]'
  assert_equal "$(q '.models[] | [.model, .replies, .tokens, .w, .first, .last]' | paste -sd ' ')" \
    '["claude-haiku-5-5",1,202000,0.105,"2026-10-20","2026-10-20"] ["claude-opus-5-5",19,1237000,6.5,"2026-10-20","2026-10-21"] ["claude-sonnet-5-5",1,55000,0.25,"2026-10-20","2026-10-20"]'
  assert_equal "$(q '.machines[] | [.machine, .replies, .tokens, .w]' | paste -sd ' ')" \
    '["home-pc",18,1293000,5.895] ["laptop",3,201000,0.96]'
}

@test "the report classes each session by its launch or its directory, a subagent under its parent" {
  report_fixture
  report_json
  assert_equal "$(q '.roles[] | [.role, .sessions, .replies, .w, .subagent_w]' | paste -sd ' ')" \
    '["coordinator",2,6,2.53,0.14] ["planner",1,2,0.69,0] ["builder",4,7,2.54,0.3] ["reviewer",2,2,0.75,0] ["unlaunched",1,1,0.08,0] ["team-test",2,2,0.16,0] ["daniel",1,1,0.105,0]'
  assert_equal "$(q '.roles[0] | [.cache_write_1h, .cache_write_5m, .cache_read, .output]')" '[280000,20000,250000,7000]'
  assert_equal "$(q '.projects[] | [.project, .w]' | paste -sd ' ')" \
    '["agent-team",3.36] ["(coordinator)",2.53] ["conventioner",0.62] ["(none: team-test)",0.16] ["(none: daniel)",0.105] ["(none: unlaunched)",0.08]'
  assert_equal "$(q '.tasks[]' | paste -sd ' ')" \
    '{"task":"T1","project":"agent-team","tokens":545000,"w":3.36,"plan_w":0.69,"build_w":1.92,"review_w":0.75,"launches":{"home-pc":6},"merged":1,"tickets_done":1,"reviews":2,"closed":true} {"task":"T2","project":"conventioner","tokens":160000,"w":0.62,"plan_w":0,"build_w":0.62,"review_w":0,"launches":{"laptop":2},"merged":0,"tickets_done":1,"reviews":0,"closed":false}'
  assert_equal "$(q '.days[] | [.day, .w, .roles]' | paste -sd ' ')" \
    '["2026-10-20",5.895,{"coordinator":2.19,"planner":0.69,"builder":1.92,"reviewer":0.75,"ops":0}] ["2026-10-21",0.96,{"coordinator":0.34,"planner":0,"builder":0.62,"reviewer":0,"ops":0}]'
}

@test "the report gives each role's sessions, starting context, context buckets and cache rebuilds" {
  report_fixture
  report_json
  assert_equal "$(q '.sessions[]' | paste -sd ' ')" \
    '{"role":"coordinator","sessions":2,"median_replies":2.5,"p90_replies":4,"max_replies":4,"median_w":1.195,"mean_w":1.195,"p90_w":2.05,"started":2,"median_start_context":40000,"median_context":40000,"p90_context":210000,"max_context":210000} {"role":"planner","sessions":1,"median_replies":2,"p90_replies":2,"max_replies":2,"median_w":0.69,"mean_w":0.69,"p90_w":0.69,"started":1,"median_start_context":50000,"median_context":55000,"p90_context":60000,"max_context":60000} {"role":"builder","sessions":4,"median_replies":1.5,"p90_replies":2,"max_replies":2,"median_w":0.56,"mean_w":0.56,"p90_w":0.62,"started":4,"median_start_context":50000,"median_context":50000,"p90_context":100000,"max_context":100000} {"role":"reviewer","sessions":2,"median_replies":1,"p90_replies":1,"max_replies":1,"median_w":0.375,"mean_w":0.375,"p90_w":0.5,"started":2,"median_start_context":50000,"median_context":50000,"p90_context":50000,"max_context":50000}'
  assert_equal "$(q '.context[] | [.from, .to, .replies, .w]' | paste -sd ' ')" \
    '[0,50000,6,1.26] [50000,100000,8,3.44] [100000,200000,2,0.24] [200000,400000,3,1.475]'
  assert_equal "$(q '.rebuilds')" \
    '{"roles":[{"role":"coordinator","rebuilds":1,"extra_w":1.17,"role_w":2.39,"compactions":1},{"role":"planner","rebuilds":0,"extra_w":0,"role_w":0.69,"compactions":0},{"role":"builder","rebuilds":0,"extra_w":0,"role_w":2.24,"compactions":0},{"role":"reviewer","rebuilds":0,"extra_w":0,"role_w":0.75,"compactions":0}],"gap_minutes":{"count":1,"median":130,"over_hour":1,"five_to_sixty":0}}'
}

@test "the report gives cost per outcome, relaunches and re-reviews from the ledger" {
  report_fixture
  report_json
  assert_equal "$(q '.outcomes | del(.reviewer_models)')" \
    '{"sessions":[{"role":"planner","sessions":1,"w":0.69,"median_w":0.69,"mean_w":0.69,"p90_w":0.69},{"role":"builder","sessions":4,"w":2.54,"median_w":0.62,"mean_w":0.635,"p90_w":0.8},{"role":"reviewer","sessions":2,"w":0.75,"median_w":0.375,"mean_w":0.375,"p90_w":0.5}],"counts":{"merged":1,"tickets_done":2,"reviews":2,"pass":1,"findings":1,"launches":9},"complete_tasks":{"count":1,"merged":1,"tickets_done":1,"reviews":2},"measures":{"worker_w_per_merge":3.36,"worker_w_per_ticket":3.36,"builder_w_per_ticket":1.92,"reviewer_w_per_review":0.375,"coordinator_w_per_merge":2.53,"coordinator_w_per_launch":0.281111}}'
  assert_equal "$(q '.relaunches')" \
    '{"reasons":[{"reason":"stow or handoff","count":1,"with_replies":1,"warmup_w":0.62,"median_w":0.62}],"all":1,"warmup_w":0.62}'
  assert_equal "$(q '.rereviews')" '{"count":1,"complete":1,"w":1,"median_w":1,"mean_w":1}'
}

@test "the report gives each reviewer launch model's reviews and \$w per review, a launch with no model on the default" {
  report_fixture
  report_json
  # r1 (sonnet) wrote T1's findings; r2 (no model) its pass; l2 (no model) no reply and no review.
  assert_equal "$(q '.outcomes.reviewer_models[]' | paste -sd ' ')" \
    '{"model":"default","launches":2,"with_replies":1,"reviews":1,"findings":0,"w":0.5,"w_per_review":0.5,"reply_models":{"claude-opus-5-5":0.5}} {"model":"sonnet","launches":1,"with_replies":1,"reviews":1,"findings":1,"w":0.25,"w_per_review":0.25,"reply_models":{"claude-sonnet-5-5":0.25}}'
  # A review after --until is not counted; a launch before --since is not either.
  report_json --since 2026-10-20T12:00Z
  assert_equal "$(q '[.outcomes.reviewer_models[] | [.model, .launches, .reviews]]')" '[["default",2,1]]'
  run_bin -0 team-tokens --until 2026-10-20T11:30Z --json
  assert_equal "$(jq -c '[.outcomes.reviewer_models[] | [.model, .launches, .reviews, .w_per_review]]' <<<"$output")" '[["sonnet",1,0,null]]'
  run_bin -0 team-tokens --until 2026-10-21T16:00Z
  assert_contains "$output" "| Launch model | Reviewer launches | With replies | Reviews | With findings | \$w | \$w per review | Reply models |"
  assert_contains "$output" "| default | 2 | 1 | 1 | 0 | 0.50 | 0.50 | claude-opus-5-5 0.50 |"
  assert_contains "$output" "| sonnet | 1 | 1 | 1 | 1 | 0.25 | 0.25 | claude-sonnet-5-5 0.25 |"
}

@test "the report gives the 5-hour blocks with the current one, and the last seven days per machine" {
  report_fixture
  report_json
  assert_equal "$(q '.blocks[]' | paste -sd ' ')" \
    '{"start":"2026-10-20T08:00:00Z","end":"2026-10-20T13:00:00Z","w":5.79,"replies":17,"machines":{"home-pc":5.79},"current":false} {"start":"2026-10-20T13:00:00Z","end":"2026-10-20T18:00:00Z","w":0.105,"replies":1,"machines":{"home-pc":0.105},"current":false} {"start":"2026-10-21T09:00:00Z","end":"2026-10-21T14:00:00Z","w":0.84,"replies":2,"machines":{"laptop":0.84},"current":false} {"start":"2026-10-21T15:30:00Z","end":"2026-10-21T20:30:00Z","w":0.12,"replies":1,"machines":{"laptop":0.12},"current":true}'
  assert_equal "$(q '.current_block.start')" '"2026-10-21T15:30:00Z"'
  assert_equal "$(q '.seven_days')" \
    '{"from":"2026-10-14T16:00:00Z","to":"2026-10-21T16:00:00Z","machines":[{"machine":"home-pc","replies":18,"tokens":1293000,"w":5.895},{"machine":"laptop","replies":3,"tokens":201000,"w":0.96}],"all":{"replies":21,"tokens":1494000,"w":6.855}}'
  # Between blocks, none is current.
  run_bin -0 team-tokens --until 2026-10-21T15:00Z --json
  assert_equal "$(jq -c '[.current_block, ([.blocks[] | .current] | any)]' <<<"$output")" '[null,false]'
  run_bin -0 team-tokens --until 2026-10-21T15:00Z
  assert_contains "$output" "No block is open at 2026-10-21T15:00:00Z: the next opens at the next reply."
}

@test "--since, --task and --machine narrow the tables, and the limits still count every reply" {
  report_fixture
  report_json --since 2026-10-21T00:00Z
  assert_equal "$(q '[.since, .totals.w, ([.roles[].role] | join(" ")), (.blocks | length), .seven_days.all.w]')" \
    '["2026-10-21T00:00:00Z",0.96,"coordinator builder",4,6.855]'
  # Only replies after --since count, and only events after it: T2's two launches.
  assert_equal "$(q '[.ledger_events, .outcomes.counts.launches]')" '[3,2]'
  report_json --task T1
  assert_equal "$(q '[.filters.task, .totals.w, ([.roles[].role] | join(" ")), ([.tasks[].task] | join(" ")), .outcomes.counts.launches, .seven_days.all.w]')" \
    '["T1",3.36,"planner builder reviewer","T1",6,6.855]'
  report_json --machine laptop
  assert_equal "$(q '[.filters.machine, .totals.w, ([.machines[].machine] | join(" ")), (.blocks | map(.start) | join(" ")), .seven_days.all.w]')" \
    '["laptop",0.96,"laptop","2026-10-21T09:00:00Z 2026-10-21T15:30:00Z",0.96]'
}

@test "the report prints each table as text, its header and the seven days' caveat" {
  report_fixture
  run_bin -0 team-tokens --until 2026-10-21T16:00Z
  assert_equal "${lines[0]}" "# Claude usage, 2026-10-20T08:00:00Z to 2026-10-21T16:00:00Z"
  assert_contains "$output" "21 replies in 13 sessions, 1.5M tokens, 6.9 \$w; 17 ledger events in the window."
  assert_contains "$output" "Day files: home-pc through 2026-10-20, laptop through 2026-10-21; and 0 replies from this machine's transcripts since its last."
  for heading in "Token types" "Models" "Machines" "Roles" "Projects and tasks" "Days (UTC)" "Sessions and context" "Context" \
    "Cache rebuilds" "Cost per outcome" "Relaunches" "5-hour blocks" "The last seven days"; do
    assert_contains "$output" $'\n'"## $heading"$'\n'
  done
  assert_contains "$output" "| cache_write_1h | 0.7 | 44.8% | 5.2 | 75.3% |"
  assert_contains "$output" "| coordinator | 2 | 6 | 0.0 | 0.3 | 0.2 | 0.0 | 0.6 | 2.5 | 36.9% | 5.5% |"
  assert_contains "$output" "| T1 | agent-team | 0.5 | 3.4 | 0.69 | 1.9 | 0.75 | 6 | 0 | 1 | 1 | 2 | yes |"
  assert_contains "$output" "| coordinator | 1 | 1.2 | 49.0% | 1 |"
  assert_contains "$output" "| stow or handoff | 1 | 1 | 0.62 | 0.62 |"
  assert_contains "$output" "| 2026-10-21T15:30:00Z (current) | 2026-10-21T20:30:00Z | 0.12 | 1 | 0.00 | 0.12 |"
  assert_contains "$output" "The current block opened 2026-10-21T15:30:00Z and ends 2026-10-21T20:30:00Z: 0.12 \$w so far."
  assert_contains "$output" "the weekly limit's reset time is in no data (claude.ai shows it), so this is a rolling seven days."
  assert_contains "$output" "| **all** | 21 | 1.5 | **6.9** | 100% |"
}

@test "the report reads this machine's transcripts from its last day file on, a reply in both counted once" {
  run_bin -0 team-tokens export
  add_reply req_L1 2026-10-21T13:00:00.000Z 10
  # The day files hold four replies; the transcripts hold those of 2026-10-21 again, and one more.
  run_bin -0 team-tokens --until 2026-10-21T16:00Z --json
  assert_equal "$(jq -c '[.sources, .live, .totals.replies, ([.models[] | [.model, .replies]])]' <<<"$output")" \
    '[{"home-pc":"2026-10-21"},1,5,[["claude-opus-5-5",4],["claude-sonnet-5-5",1]]]'
  # With no day file, every transcript is read.
  rm -r "$TEAM_HOME/usage"
  run_bin -0 team-tokens --until 2026-10-21T16:00Z --json
  assert_equal "$(jq -c '[.sources, .live, .totals.replies]' <<<"$output")" '[{"home-pc":null},5,5]'
}

@test "a model with no price is weighed as Opus 5.5, with a warning" {
  report_fixture
  sed -i 's/claude-sonnet-5-5/claude-mystery-1/' "$TEAM_HOME/usage/home-pc/2026-10-20.jsonl"
  run_bin -0 --separate-stderr team-tokens --until 2026-10-21T16:00Z --json
  assert_equal "$stderr" "team-tokens: bin/lib/prices.json has no price for the model 'claude-mystery-1'; weighed as claude-opus-5-5"
  assert_equal "$(jq -c '.models[] | select(.model == "claude-mystery-1") | .w' <<<"$output")" 0.5
}

@test "a day file line that is no usage line is refused in one line" {
  report_fixture
  echo 'not json' >>"$TEAM_HOME/usage/laptop/2026-10-21.jsonl"
  run_bin -1 --separate-stderr team-tokens
  assert_equal "$stderr" "team-tokens: cannot read the usage: $TEAM_HOME/usage/laptop/2026-10-21.jsonl holds a line that is no usage line; fix or remove it"
  echo '{"request":"req_x"}' >"$TEAM_HOME/usage/laptop/2026-10-21.jsonl"
  run_bin -1 --separate-stderr team-tokens
  assert_equal "$stderr" "team-tokens: cannot read the usage: the reply req_x has no time, machine, session or project_dir"
}

@test "with no usage and an empty ledger the report says none in each table" {
  rm -r "$HOME/.claude/projects"
  run_bin -0 team-tokens --until 2026-10-21T16:00Z
  assert_contains "$output" "0 replies in 0 sessions, 0.0M tokens, 0.00 \$w; 0 ledger events in the window."
  assert_contains "$output" "## Roles"$'\n\n'"None in the window."
  run_bin -0 team-tokens --until 2026-10-21T16:00Z --json
  assert_equal "$(jq -c '[.since, .totals, .blocks, .current_block]' <<<"$output")" \
    '["2026-10-21T16:00:00Z",{"replies":0,"sessions":0,"tokens":0,"w":0},[],null]'
}

# fixtures/team-tokens/coordinator/ holds a coordinator's transcript, a session claude-coordinator
# named coordinator, in the team home's directory under ~/.claude/projects, every string of message
# content, tool input and output marked CONTENT-; each reply's $w is its output alone, 0.1 for
# 5,000 tokens. Before the window, a worker's PR at 2026-10-21T08:00Z; in it, on 2026-10-22:
# - 10:00 Daniel's D1 in channel A, idle: team-snapshot, a reply to A 20 s after it was sent, text
#   (3 calls, 0.3, 30 s); answered only;
# - 10:10 a worker's DONE: team-log, then a reply to B over two lines of one request (2 calls,
#   0.3, 40 s); Daniel's D2 in B arrives mid-turn (25 s to the reply), and a skill's meta entry
#   inside the turn starts none;
# - 10:20 Daniel's D3 in A, idle: SendMessage, a reply to A 60 s on (2 calls, 0.2, 60 s); acted;
#   then the Stop hook's feedback starts a turn (1 call, 0.1, 10 s);
# - 10:30 Daniel's D4 in C, idle: `grep -c team-log`, a reply to B (2 calls, 0.2, 20 s);
#   answered only, and C never gets a reply;
# - 10:40 a compaction, then the turn after it (1 call, 15,000 output, 0.3, 30 s);
# - 10:50 a watch ends (1 call, 0.1, 5 s); Daniel's D5 in A arrives during it at 10:50:02 and
#   starts its own turn at its end: team-open, a reply to A 58 s after it was sent (2 calls, 0.2,
#   54 s); acted;
# - 11:00 a reminder, a meta entry while idle (1 call, 0.1, 10 s): other;
# - 11:10 Daniel's D6 in A, idle: text only (1 call, 0.1, 5 s); neither, and never replied to;
# and on 2026-10-23, a compaction at 01:00 and its turn (1 call, 0.1, 10 s), then a worker's
# message of no known kind (1 call, 0.1, 4 s).
coordinator_fixture() {
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-tokens/coordinator/." "$HOME/.claude/projects/"
  echo agent-team-records >"$HOME/.config/agent-team/home"
}

@test "the coordinator's turns: by what woke it, with calls, \$w, the median turn, and what Daniel's turns did" {
  coordinator_fixture
  report_json --since 2026-10-22T00:00Z --until 2026-10-23T12:00Z
  assert_equal "$(q '.coordinator | [.machine, .sessions, .unread_replies]')" '["home-pc",1,0]'
  assert_equal "$(q '.coordinator.turns[]' | paste -sd ' ')" \
    '{"trigger":"daniel","turns":5,"calls":10,"calls_per_turn":2,"w":1,"median_s":30} {"trigger":"compaction","turns":2,"calls":2,"calls_per_turn":1,"w":0.4,"median_s":20} {"trigger":"worker:DONE","turns":1,"calls":2,"calls_per_turn":2,"w":0.3,"median_s":40} {"trigger":"other","turns":1,"calls":1,"calls_per_turn":1,"w":0.1,"median_s":10} {"trigger":"stop-hook","turns":1,"calls":1,"calls_per_turn":1,"w":0.1,"median_s":10} {"trigger":"watch","turns":1,"calls":1,"calls_per_turn":1,"w":0.1,"median_s":5} {"trigger":"worker:other","turns":1,"calls":1,"calls_per_turn":1,"w":0.1,"median_s":4}'
  assert_equal "$(q '.coordinator.all')" '{"turns":12,"calls":18,"calls_per_turn":1.5,"w":2.1,"median_s":15}'
  assert_equal "$(q '.coordinator.daniel_turns')" '{"turns":5,"acted":2,"answered":2,"neither":1}'
  # The turn before the window is in the tables once --since takes it in.
  report_json --since 2026-10-21T00:00Z --until 2026-10-23T12:00Z
  assert_equal "$(q '[.coordinator.all.turns, (.coordinator.turns[] | select(.trigger == "worker:PR") | .w)]')" '[13,0.1]'
}

@test "Daniel's waits: from each message's id time to the first reply in its channel, idle or mid-turn, and the compactions per day" {
  coordinator_fixture
  report_json --since 2026-10-22T00:00Z --until 2026-10-23T12:00Z
  assert_equal "$(q '.coordinator.waits')" \
    '{"all":{"messages":6,"replied":4,"median_s":41.5,"p75_s":58,"p90_s":60,"max_s":60},"idle":{"messages":4,"replied":2,"median_s":40,"p75_s":60,"p90_s":60,"max_s":60},"mid_turn":{"messages":2,"replied":2,"median_s":41.5,"p75_s":58,"p90_s":58,"max_s":58}}'
  assert_equal "$(q '.coordinator.compactions')" '[{"day":"2026-10-22","count":1},{"day":"2026-10-23","count":1}]'
  # A message is in the window by its id's time: D1 to D4 only.
  report_json --since 2026-10-22T00:00Z --until 2026-10-22T10:45Z
  assert_equal "$(q '.coordinator.waits.all | [.messages, .replied]')" '[4,3]'
}

@test "the coordinator tables read only sessions named coordinator, and count the coordinator's replies they leave out" {
  coordinator_fixture
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-tokens/report/usage" "$TEAM_HOME/usage"
  cp "$BATS_TEST_DIRNAME/fixtures/team-tokens/report/ledger.jsonl" "$TEAM_HOME/ledger.jsonl"
  # A session of Daniel's own in the team home's directory: the coordinator's by its directory, never named.
  local own=$HOME/.claude/projects/-home-dan-agent-team-records/dddddddd-4444-4444-8444-444444444444.jsonl
  jq -c 'select(.type != "agent-name" and .type != "custom-title") | .sessionId = "dddddddd-4444-4444-8444-444444444444"
    | if .requestId then .requestId += "-own" else . end' \
    "$HOME/.claude/projects/-home-dan-agent-team-records/cccccccc-3333-4333-8333-333333333333.jsonl" >"$own"
  report_json --since 2026-10-20T00:00Z --until 2026-10-23T12:00Z
  # c0's four main replies on home-pc and c1's on laptop come from day files, the own session's 19 from
  # its transcript: none is in a session read.
  assert_equal "$(q '.coordinator | [.sessions, .unread_replies, .all.turns]')" '[1,24,13]'
  run_bin -0 team-tokens --since 2026-10-20T00:00Z --until 2026-10-23T12:00Z
  assert_contains "$output" "24 of the coordinator's replies in the window are in sessions these tables do not read"
}

@test "the coordinator tables print as text, never a message's text, and --task leaves them out" {
  coordinator_fixture
  run_bin -0 team-tokens --since 2026-10-22T00:00Z --until 2026-10-23T12:00Z
  assert_contains "$output" $'\n'"## Coordinator turns"$'\n'
  assert_contains "$output" $'\n'"## Daniel's waits"$'\n'
  assert_contains "$output" "| A message from Daniel | 5 | 10 | 2.0 | 1.0 | 47.6% | 30 s |"
  assert_contains "$output" "| A worker's DONE | 1 | 2 | 2.0 | 0.30 | 14.3% | 40 s |"
  assert_contains "$output" "| A worker's message of another kind | 1 | 1 | 1.0 | 0.10 | 4.8% | 4 s |"
  assert_contains "$output" "| The first turn after a compaction | 2 | 2 | 1.0 | 0.40 | 19.0% | 20 s |"
  assert_contains "$output" "| **all** | 12 | 18 | 1.5 | **2.1** | 100% | 15 s |"
  assert_contains "$output" "Daniel's 5 turns: 2 acted (a team script that writes, or SendMessage), 2 only answered, 1 did neither."
  assert_contains "$output" "| Mid-turn | 2 | 2 | 42 s | 58 s | 58 s | 58 s |"
  assert_contains "$output" "| **all** | 6 | 4 | 42 s | 58 s | 60 s | 60 s |"
  assert_contains "$output" "2 of Daniel's 6 messages had no reply in their channel."
  assert_contains "$output" "| 2026-10-22 | 1 |"
  local printed=$output
  run_bin -0 team-tokens --since 2026-10-22T00:00Z --until 2026-10-23T12:00Z --json
  printed+=$output
  # No fixture string, channel id or user id.
  run grep -c -e CONTENT -e 1300000000000000001 -e 1400000000000000001 <<<"$printed"
  assert_equal "$output" 0
  report_json --task T5
  assert_equal "$(q .coordinator)" null
  run_bin -0 team-tokens --task T5
  assert_contains "$output" "## Coordinator turns"$'\n\n'"Not with --task: the coordinator is no task's."
  run_bin -0 team-tokens --machine laptop
  assert_contains "$output" "## Coordinator turns"$'\n\n'"Not with --machine laptop: these tables read this machine's transcripts."
}

@test "every script the coordinator table counts as only reading is in bin/, and the header names each" {
  local names name
  names=$(sed -n '/^READERS = {/,/^}/p' "$REPO_ROOT/bin/team-tokens" | grep -o 'team-[a-z-]*')
  assert_equal "$(wc -l <<<"$names")" 11
  for name in $names; do
    [[ -x $REPO_ROOT/bin/$name ]]
    assert_contains "$(sed -n '/^#   coordinator turns/,/^#   Daniel/p' "$REPO_ROOT/bin/team-tokens")" "$name"
  done
}

# The time rows' fixture, fixtures/team-tokens/time/: its ledger launches the builder dddddddd (and
# holds a line that is no event, skipped), and its projects/ holds, every content string marked
# CONTENT-:
# - -home-dan-agent-team--claude-worktrees-2/dddddddd-...: the builder's transcript, whose
#   stretches, computed by hand, are:
#   2026-10-20, 10:00:00.000 the brief; tests/run 10 s (10:00:05 to :15); Read 3 s; a parallel
#   batch at 10:00:22 of npx playwright test and Grep, Grep's result at :25 and playwright's at :40
#   (Grep 3 s, playwright the 15 s tail); a background gh pr checks (0.5 s to its result), the turn
#   ending at 10:00:44.100, then 300 s idle on it until its task-notification at 10:05:44.100;
#   npm test from 10:05:50 with no result when its turn ends at 10:06:00 (10 s); idle, an
#   away_summary and a subagent's line between, until a coordinator's <cross-session-message at
#   10:36:00 (wait message, 1800 s); bats 60 s; team-stack up 60 s; a compact_boundary at
#   10:38:42.200 whose durationMs, 25000, comes out of the 30 s model stretch before it; the turn
#   ending at 10:38:50.400, then Daniel's prompt at 23:59:50.000 (wait other, 48059.6 s); the model
#   from 23:59:50 to an api-request line at midnight (10 s, its day's last stretch);
#   so model 53.9 s in 9 replies, its longest run 13.2 s (the 5 s left of the compacted stretch
#   and the 8.2 s after it), and the day 50400 s, 10:00:00 to midnight;
#   2026-10-21, the model on to 00:00:10 (10 s); ./scripts/seed.sh 30 s; a Monitor (0.5 s to its
#   result) idle 120 s to an interim event (no tool-use-id, no status) and 120 s more to its
#   completed notification, two stretches of background monitor tail; SendMessage 1 s; model
#   31.8 s in 6 replies, its longest run 10.1 s; the day 303.3 s, to 00:05:03.300;
# - its subagents/agent-def456.jsonl and eeeeeeee-..., an unlaunched session: no row.
time_fixture() {
  rm -r "$HOME/.claude/projects"
  cp -R "$BATS_TEST_DIRNAME/fixtures/team-tokens/time/projects" "$HOME/.claude/projects"
  cp "$BATS_TEST_DIRNAME/fixtures/team-tokens/time/ledger.jsonl" "$TEAM_HOME/ledger.jsonl"
  dddd=dddddddd-4444-4444-8444-444444444444
}

@test "time prints one row per launched session and UTC day, from this machine's transcripts, and writes nothing" {
  time_fixture
  local before
  before=$(find "$TEAM_HOME" "$HOME" -printf '%p %T@\n' | sort)
  run_bin -0 --separate-stderr team-tokens time
  assert_equal "$stderr" ""
  assert_equal "${#lines[@]}" 2
  assert_equal "$(jq -c '{day, machine, session, first, last, waits}' <<<"${lines[0]}")" \
    '{"day":"2026-10-20","machine":"home-pc","session":"'"$dddd"'","first":"2026-10-20T10:00:00.000Z","last":"2026-10-21T00:00:00.000Z","waits":[{"from":"2026-10-20T10:06:00.000Z","to":"2026-10-20T10:36:00.000Z","key":"wait message"},{"from":"2026-10-20T10:38:50.400Z","to":"2026-10-20T23:59:50.000Z","key":"wait other"}]}'
  assert_equal "$(jq -r '.keys | to_entries[] | "\(.key): \(.value.seconds + 0) \(.value.calls) \(.value.longest + 0)"' <<<"${lines[0]}")" \
    "background bash gh pr checks: 300 1 300
bash bats: 60 1 60
bash gh pr checks: 0.5 1 0.5
bash npm test: 10 1 10
bash npx playwright test: 15 1 15
bash team-stack up: 60 1 60
bash tests/run: 10 1 10
compaction: 25 1 25
model: 53.9 9 13.2
tool Grep: 3 1 3
tool Read: 3 1 3
wait message: 1800 1 1800
wait other: 48059.6 1 48059.6"
  assert_equal "$(jq -c '{day, first, last, waits}' <<<"${lines[1]}")" \
    '{"day":"2026-10-21","first":"2026-10-21T00:00:00.000Z","last":"2026-10-21T00:05:03.300Z","waits":[]}'
  assert_equal "$(jq -r '.keys | to_entries[] | "\(.key): \(.value.seconds + 0) \(.value.calls) \(.value.longest + 0)"' <<<"${lines[1]}")" \
    "background monitor tail: 240 2 120
bash ./scripts/seed.sh: 30 1 30
model: 31.8 6 10.1
monitor tail: 0.5 1 0.5
tool SendMessage: 1 1 1"
  assert_equal "$(find "$TEAM_HOME" "$HOME" -printf '%p %T@\n' | sort)" "$before"
}

@test "time's keys add up to each day's span, parallel calls sharing the wall time" {
  time_fixture
  run_bin -0 team-tokens time
  # 10:00:00 to midnight, and midnight to 00:05:03.300.
  assert_equal "$(jq -c '[.day, ([.keys[].seconds] | add * 1000 | round)]' <<<"$output")" '["2026-10-20",50400000]
["2026-10-21",303300]'
}

@test "no content reaches a time row: every row has only the listed fields, and no fixture string" {
  time_fixture
  run_bin -0 team-tokens time
  if grep CONTENT <<<"$output"; then false; fi
  assert_equal "$(jq -sc 'map(keys_unsorted) | unique' <<<"$output")" '[["day","machine","session","first","last","keys","waits"]]'
  assert_equal "$(jq -sc 'map(.keys[] | keys_unsorted) | unique' <<<"$output")" '[["seconds","calls","longest"]]'
  assert_equal "$(jq -sc 'map(.waits[] | keys_unsorted) | unique' <<<"$output")" '[["from","to","key"]]'
  assert_equal "$(jq -sc '[.[] | .day, .machine, .session, .first, .last, .waits[].from, .waits[].to | type] | unique' <<<"$output")" '["string"]'
  assert_equal "$(jq -sc '[.[].keys[][] | type] | unique' <<<"$output")" '["number"]'
}

@test "time keeps the rows of the days --since and --until name, and with no launch prints none" {
  time_fixture
  run_bin -0 team-tokens time --since 2026-10-20T23:00Z
  assert_equal "$(jq -r .day <<<"$output" | paste -sd ' ')" "2026-10-20 2026-10-21"
  run_bin -0 team-tokens time --since 2026-10-21T00:00Z
  assert_equal "$(jq -r .day <<<"$output")" "2026-10-21"
  run_bin -0 team-tokens time --until 2026-10-20T23:59:59Z
  assert_equal "$(jq -r .day <<<"$output")" "2026-10-20"
  run_bin -0 team-tokens time --since 2026-10-22T00:00Z
  assert_equal "$output" ""
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-tokens time
  assert_equal "$output" ""
}

@test "a call is named by its command's first program that is not plumbing, with its subcommand words" {
  # Each command, then the name it gets.
  local cases=(
    'cd CONTENT-dir && tests/run' 'tests/run'
    'npx playwright test CONTENT-spec | tail -5' 'npx playwright test'
    'until gh pr checks 33; do sleep 30; done' 'gh pr checks'
    $'git commit -F - <<\'EOF\'\nCONTENT-subject; rm -rf CONTENT-dir\nEOF' 'git commit'
    'FOO=CONTENT-x npm test' 'npm test'
    'timeout 600 bats tests/CONTENT-x.bats' 'bats'
    '/home/x/agent-team/bin/team-stack up' 'team-stack up'
    './scripts/seed.sh CONTENT-arg' './scripts/seed.sh'
    'git push no-mistakes' 'git push no-mistakes'
    'no-mistakes axi run --intent "CONTENT-intent"' 'no-mistakes axi run'
    '"CONTENT-quoted prog" --flag' 'other'
    'cat CONTENT-x | grep CONTENT-y' 'cat'
    'echo "CONTENT-a; CONTENT-b | CONTENT-c" && make check' 'make check'
    'npm run test:e2e 2>&1 | tee CONTENT-log' 'npm run test:e2e'
    'for f in CONTENT-a CONTENT-b; do tests/run "$f"; done' 'tests/run'
    '[[ -f CONTENT-x ]] && ~/agent-team/bin/team-checks CONTENT-x' 'team-checks'
    $'# CONTENT-comment; CONTENT-rm\ndocker compose up -d' 'docker compose up'
    'echo $(git rev-parse HEAD)' 'git rev-parse'
    'env -u CONTENT-x' 'other'
    'env -i PATH=/CONTENT-bin stdbuf -o L nice -n 5 make CONTENT-target' 'make'
    '../CONTENT/run.sh' 'other'
    'cd CONTENT-dir' 'cd'
    '' 'other'
  )
  local projects=$HOME/.claude/projects/-home-dan-agent-team--claude-worktrees-1 i session expected=
  rm -r "$HOME/.claude/projects"
  mkdir -p "$projects"
  : >"$TEAM_HOME/ledger.jsonl"
  for ((i = 0; i < ${#cases[@]}; i += 2)); do
    session=$(printf 'c%07d-0000-4000-8000-000000000000' "$i")
    printf '{"ts":"2026-10-20T09:00:00Z","task":"T1","event":"launch","role":"builder","session":"%s","worktree":"/home/dan/agent-team/.claude/worktrees/1","toolkits":[]}\n' "${session:0:8}" >>"$TEAM_HOME/ledger.jsonl"
    jq -nc --arg command "${cases[i]}" --arg session "$session" '
      {type: "user", timestamp: "2026-10-20T10:00:00.000Z", sessionId: $session, message: {content: "go"}},
      {type: "assistant", timestamp: "2026-10-20T10:00:01.000Z", sessionId: $session, requestId: "req",
       message: {stop_reason: "tool_use", content: [{type: "tool_use", id: "toolu_1", name: "Bash", input: {command: $command}}]}},
      {type: "user", timestamp: "2026-10-20T10:00:03.000Z", sessionId: $session,
       message: {content: [{type: "tool_result", tool_use_id: "toolu_1", content: "out"}]}}' >"$projects/$session.jsonl"
    expected+="bash ${cases[i + 1]}"$'\n'
  done
  run_bin -0 team-tokens time
  assert_equal "$(jq -r '.keys | keys[] | select(startswith("bash "))' <<<"$output")" "${expected%$'\n'}"
}

# The time day files: the export writes the time fixture's rows into usage/home-pc/time/, and
# time reads them back with this machine's live rows.
time_day=usage/home-pc/time

# A time row of one model stretch: time_row <machine> <session> <day> <first> <model seconds>
time_row() {
  printf '{"day":"%s","machine":"%s","session":"%s","first":"%s","last":"%s","keys":{"model":{"seconds":%s,"calls":1,"longest":%s}},"waits":[]}\n' \
    "$3" "$1" "$2" "$4" "$4" "$5" "$5"
}

@test "the export writes each launched session's time rows into a day file per complete UTC day" {
  time_fixture
  run_bin -0 team-tokens time
  local live=$output
  run_bin -0 team-tokens export
  assert_equal "$output" "usage/home-pc/2026-10-20.jsonl: 10 replies, 10 new
usage/home-pc/2026-10-21.jsonl: 6 replies, 6 new
usage/home-pc/time/2026-10-20.jsonl: 1 session, 1 new
usage/home-pc/time/2026-10-21.jsonl: 1 session, 1 new
read 3 of 3 transcripts; wrote 2 day files and 2 time files"
  assert_equal "$(ls "$TEAM_HOME/$time_day")" "2026-10-20.jsonl
2026-10-21.jsonl"
  assert_equal "$(cat "$TEAM_HOME/$time_day"/*.jsonl)" "$live"
  if grep -r CONTENT "$TEAM_HOME/usage"; then false; fi
}

@test "the usage day files come out byte for byte as with no launch, and with no ledger there are no time rows" {
  time_fixture
  run_bin -0 team-tokens export
  local other=$BATS_TEST_TMPDIR/other
  mkdir "$other"
  TEAM_HOME=$other run_bin -0 team-tokens export
  assert_equal "$output" "usage/home-pc/2026-10-20.jsonl: 10 replies, 10 new
usage/home-pc/2026-10-21.jsonl: 6 replies, 6 new
read 3 of 3 transcripts; wrote 2 day files"
  [[ ! -e $other/$time_day ]]
  assert_equal "$(cd "$other/usage/home-pc" && md5sum ./*.jsonl)" "$(cd "$TEAM_HOME/usage/home-pc" && md5sum ./*.jsonl)"
}

@test "a time day file keeps the row of a transcript not read again, and changes only when a row does" {
  time_fixture
  run_bin -0 team-tokens export
  local before day20 projects=$HOME/.claude/projects/-home-dan-agent-team--claude-worktrees-2
  before=$(fingerprint "$TEAM_HOME" "$scan")
  run_bin -0 team-tokens export
  assert_equal "$output" "read 0 of 3 transcripts; no day file changed"
  assert_equal "$(fingerprint "$TEAM_HOME" "$scan")" "$before"
  # Read again with its rows unchanged, the transcript rewrites no time file.
  day20=$(fingerprint "$TEAM_HOME/$time_day/2026-10-20.jsonl")
  touch "$projects/$dddd.jsonl"
  run_bin -0 team-tokens export
  assert_equal "$output" "read 1 of 3 transcripts; no day file changed"
  assert_equal "$(fingerprint "$TEAM_HOME/$time_day/2026-10-20.jsonl")" "$day20"
  # Cleaned up, its row stays beside a new launched session's, the copy of its first day's lines.
  local ffff=ffffffff-6666-4666-8666-666666666666
  printf '{"ts":"2026-10-20T09:59:30Z","task":"T2","event":"launch","role":"builder","session":"ffffffff","worktree":"/home/dan/agent-team/.claude/worktrees/3","toolkits":[]}\n' >>"$TEAM_HOME/ledger.jsonl"
  jq -c 'select(.timestamp < "2026-10-20T10:30") | .sessionId = "'"$ffff"'" | del(.requestId)' "$projects/$dddd.jsonl" >"$projects/$ffff.jsonl"
  rm "$projects/$dddd.jsonl"
  run_bin -0 team-tokens export
  assert_equal "$output" "usage/home-pc/time/2026-10-20.jsonl: 2 sessions, 1 new
read 1 of 3 transcripts; wrote 1 time file"
  assert_equal "$(jq -r '"\(.session) \(.first)"' "$TEAM_HOME/$time_day/2026-10-20.jsonl")" "$dddd 2026-10-20T10:00:00.000Z
$ffff 2026-10-20T10:00:00.000Z"
  assert_equal "$(grep -c "$dddd" "$TEAM_HOME/$time_day/2026-10-21.jsonl")" 1
}

@test "today's time rows are written only with --through-now, and the transcript is read again until then" {
  time_fixture
  local today session=cccccccc-3333-4333-8333-333333333333 projects=$HOME/.claude/projects/-home-dan-agent-team--claude-worktrees-2
  today=$(date -u +%F)
  printf '{"ts":"%sT00:00:00Z","task":"T3","event":"launch","role":"reviewer","session":"cccccccc","worktree":"/home/dan/agent-team/.claude/worktrees/2","toolkits":[]}\n' "$today" >>"$TEAM_HOME/ledger.jsonl"
  # A turn of one second with no reply, so only its time row holds the transcript back.
  jq -nc --arg day "$today" --arg session "$session" '
    {type: "user", timestamp: "\($day)T00:00:01.000Z", sessionId: $session, message: {content: "CONTENT-go"}},
    {type: "system", subtype: "turn_duration", timestamp: "\($day)T00:00:02.000Z", sessionId: $session}' >"$projects/$session.jsonl"
  run_bin -0 team-tokens export
  assert_equal "${lines[-1]}" "read 4 of 4 transcripts; wrote 2 day files and 2 time files"
  [[ ! -e $TEAM_HOME/$time_day/$today.jsonl ]]
  run_bin -0 team-tokens export
  assert_equal "$output" "read 1 of 4 transcripts; no day file changed"
  run_bin -0 team-tokens export --through-now
  assert_equal "$output" "usage/home-pc/time/$today.jsonl: 1 session, 1 new
read 1 of 4 transcripts; wrote 1 time file"
  assert_equal "$(jq -c '[.session, .keys.model.seconds + 0]' "$TEAM_HOME/$time_day/$today.jsonl")" "[\"$session\",1]"
  run_bin -0 team-tokens export --through-now
  assert_equal "$output" "read 0 of 4 transcripts; no day file changed"
}

@test "a scan state of the old version leads to a full read, which fills in the time rows and leaves the usage alone" {
  time_fixture
  # The export before the time rows: the usage only, as with no ledger.
  mv "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.jsonl"
  run_bin -0 team-tokens export
  mv "$BATS_TEST_TMPDIR/ledger.jsonl" "$TEAM_HOME/ledger.jsonl"
  local version usage_before
  version=$(jq .version "$scan")
  jq ".version = $((version - 1))" "$scan" >"$BATS_TEST_TMPDIR/scan" && mv "$BATS_TEST_TMPDIR/scan" "$scan"
  usage_before=$(fingerprint "$usage"/*.jsonl)
  run_bin -0 team-tokens export
  assert_equal "$output" "usage/home-pc/time/2026-10-20.jsonl: 1 session, 1 new
usage/home-pc/time/2026-10-21.jsonl: 1 session, 1 new
read 3 of 3 transcripts; wrote 2 time files"
  assert_equal "$(fingerprint "$usage"/*.jsonl)" "$usage_before"
  assert_equal "$(jq .version "$scan")" "$version"
}

@test "time prints every machine's time day files and this machine's live rows from its last one on" {
  time_fixture
  local ffff=ffffffff-6666-4666-8666-666666666666
  mkdir -p "$TEAM_HOME/usage/laptop/time" "$TEAM_HOME/$time_day"
  time_row laptop "$ffff" 2026-10-19 2026-10-19T08:00:00.000Z 7 >"$TEAM_HOME/usage/laptop/time/2026-10-19.jsonl"
  # This machine's files: the 20th's row of dddddddd, before its last file, stands as written; the
  # 21st's is replaced by the live one, and a session with no transcript left keeps its row.
  time_row home-pc "$dddd" 2026-10-20 2026-10-20T10:00:00.000Z 1 >"$TEAM_HOME/$time_day/2026-10-20.jsonl"
  { time_row home-pc "$dddd" 2026-10-21 2026-10-21T00:00:00.000Z 2 && time_row home-pc "$ffff" 2026-10-21 2026-10-21T01:00:00.000Z 3; } >"$TEAM_HOME/$time_day/2026-10-21.jsonl"
  run_bin -0 --separate-stderr team-tokens time
  assert_equal "$stderr" ""
  assert_equal "$(jq -c '[.day, .machine, .session[:8], .keys.model.seconds]' <<<"$output")" '["2026-10-19","laptop","ffffffff",7]
["2026-10-20","home-pc","dddddddd",1]
["2026-10-21","home-pc","dddddddd",31.8]
["2026-10-21","home-pc","ffffffff",3]'
  run_bin -0 team-tokens time --since 2026-10-20T12:00Z --until 2026-10-21T00:00Z
  assert_equal "$(jq -c '[.day, .session[:8]]' <<<"$output")" '["2026-10-20","dddddddd"]
["2026-10-21","dddddddd"]
["2026-10-21","ffffffff"]'
  run_bin -0 team-tokens time --until 2026-10-19T23:59Z
  assert_equal "$(jq -c '[.day, .machine]' <<<"$output")" '["2026-10-19","laptop"]'
  # With no file of its own, this machine's rows are all live.
  rm -r "${TEAM_HOME:?}/$time_day"
  run_bin -0 team-tokens time
  assert_equal "$(jq -c '[.day, .machine, .keys.model.seconds]' <<<"$output")" '["2026-10-19","laptop",7]
["2026-10-20","home-pc",53.9]
["2026-10-21","home-pc",31.8]'
}

@test "a time day file line that is no time row is refused in one line" {
  time_fixture
  mkdir -p "$TEAM_HOME/$time_day"
  echo '{"day":"2026-10-20"}' >"$TEAM_HOME/$time_day/2026-10-20.jsonl"
  run_bin -1 --separate-stderr team-tokens time
  assert_equal "$stderr" "team-tokens: cannot read the time: $TEAM_HOME/$time_day/2026-10-20.jsonl holds a line that is no time row; fix or remove it"
  run_bin -1 --separate-stderr team-tokens export
  assert_equal "$stderr" "team-tokens: cannot export: $TEAM_HOME/$time_day/2026-10-20.jsonl holds a line that is no time row; fix or remove it"
}

@test "the report never reads a time day file" {
  report_fixture
  report_json
  local without=$json
  mkdir -p "$TEAM_HOME/usage/home-pc/time"
  printf '{"day":"2026-10-20","machine":"home-pc","session":"c0","first":"2026-10-20T08:00:00.000Z","last":"2026-10-20T09:00:00.000Z","keys":{},"waits":[]}\n' >"$TEAM_HOME/usage/home-pc/time/2026-10-20.jsonl"
  report_json
  assert_equal "$json" "$without"
}
