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
  assert_contains "$output" "the weekly limit's reset time is in no data"
  assert_contains "$output" "schema team-tokens/1"
}

@test "a malformed command line is exit 2" {
  for args in "export --nope" "export --through-now --through-now" "export now" "report" "--json --nope" "--since"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 --separate-stderr team-tokens $args
    assert_equal "$stderr" "team-tokens: usage: team-tokens [--since <ISO>] [--until <ISO>] [--task T<n>] [--machine <name>] [--json] | team-tokens export [--through-now]"
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
