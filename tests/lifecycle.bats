#!/usr/bin/env bats
# The task lifecycle: bin/lib/lifecycle.json's table and the fold in bin/lib/ledger.jq that reads
# a task's events into its status, phase, PRs, parks, asks and stow, over synthetic events.

load helpers/common

setup() {
  sandbox
  events=()
}

# on <kind> [<jq object of more fields>]: add an event of T1 to the events, a minute after the one
# before it, from 2026-11-01T00:00:00Z.
on() {
  events+=("$(jq -cn --arg e "$1" --argjson n "${#events[@]}" --arg from "${ON_FROM:-2026-11-01T00:00:00Z}" \
    '{ts: ($from | fromdate + $n * 60 | todate), task: "T1", event: $e} + ('"${2:-{\}}"')')")
}

# fold_read <filter>: the filter's output over the events so far, with ledger.jq's definitions (from
# FOLD_LIB when a test set it to a library of its own, else this checkout's), the contract as
# $contract and the sandbox's HOME as $home, compact, strings raw.
fold_read() {
  printf '%s\n' "${events[@]}" | jq -L "${FOLD_LIB:-$REPO_ROOT/bin/lib}" -scr --slurpfile contract "$REPO_ROOT/bin/lib/ledger-contract.json" \
    --arg home "$HOME" "include \"ledger\"; \$contract[0] as \$contract | $1"
}

# opened <path>: T1 opened on <path>.
opened() {
  on opened "{project: \"proj\", path: \"$1\", type: \"feat\", title: \"The tooling\", branch: \"feat/T1-tooling\",
    base: \"dev\", base_sha: \"0123456\", worktree: \"/w/1\"}"
}

builder_launch() {
  on launch "{role: \"builder\", session: \"${1:-b1}\", worktree: \"/w/1\", toolkits: []}"
}

@test "the table names only contract kinds, implemented effects, and known statuses and phases" {
  # Each kind the table lists is a contract kind, so a kind the contract drops cannot linger here.
  run fold_read 'lifecycle_table as $t
    | [($t.kinds | keys[] | select(in($contract.kinds) | not) | "kind \(.) is no contract kind"),
       ($t.kinds | to_entries[] | select(.value.effect != null and (.value.effect | IN(lifecycle_effects[]) | not))
         | "kind \(.key) has effect \(.value.effect), which the fold does not implement"),
       (($t.kinds[] , $t.default) | .status // [] | .[] | select(IN(lifecycle_statuses[]) | not) | "status \(.) is unknown"),
       (($t.kinds[], $t.default) | .phases // [] | .[] | select(IN($t.phases[]) | not) | "phase \(.) is unknown"),
       ($t.start[] | select(IN($t.phases[]) | not) | "start phase \(.) is unknown"),
       ($t.refusing_writers[] | select(IN($contract.kinds[] | .writer | if type == "array" then .[] else . end) | not)
         | "refusing writer \(.) writes no kind")]'
  assert_equal "$status" 0
  assert_equal "$output" "[]"
}

@test "the table's causes name park kinds, known ends and team-time classes, and the contract types each kind's causes" {
  # Each cause is logged on park kinds only, ends by the rules the fold reads, and has a class of
  # team-time's phases; each park kind's cause choices in the contract are the table's causes of it.
  run jq -L "$REPO_ROOT/bin/lib" -nc --slurpfile contract "$REPO_ROOT/bin/lib/ledger-contract.json" \
    'include "time"; include "ledger"; $contract[0] as $contract
    | lifecycle_table as $t
    | [$t.kinds | to_entries[] | select(.value.effect == "park") | .key] as $parks
    | [($t.causes | to_entries[] | .key as $cause | .value
         | ((.kinds // [] | if . == [] then "cause \($cause) names no kind" else empty end),
            (.kinds // [] | .[] | select(IN($parks[]) | not) | "cause \($cause) names \(.), no park kind"),
            (select(IN(.launch; "any", "role", "never") | not) | "cause \($cause) has launch \(.launch)"),
            (select(IN(.resume; "id", "daniel", "never") | not) | "cause \($cause) has resume \(.resume)"),
            (select(.all | type != "boolean") | "cause \($cause) has all \(.all)"),
            (select(IN(.class; time_phases[][0]) | not) | "cause \($cause) has class \(.class), no team-time phase"))),
       ($parks[] as $kind
         | [$t.causes | to_entries[] | select(.value.kinds | index([$kind])) | .key] | sort as $causes
         | ($contract.kinds[$kind].optional.cause // [] | sort) as $typed
         | select($causes != $typed) | "\($kind): the table gives causes \($causes), the contract \($typed)")]'
  assert_equal "$status" 0
  assert_equal "$output" "[]"
  # Every park kind has a cause, and the spec's table is the one written.
  assert_equal "$(fold_read 'lifecycle_table.causes | to_entries | map("\(.key) \(.value.kinds | join(",")) \(.value.launch) \(.value.resume) \(.value.all) \(.value.class)") | join("\n")')" \
    "$(printf '%s\n' "daniel-hold held never daniel false wait:daniel" "ask waiting never never false wait:daniel" \
      "daniel waiting any id true wait:daniel" "outside waiting any id true wait:external" "task blocked any id true wait:task" \
      "worker blocked,paused role id true wait:other" "denial blocked any id true wait:denial" "room paused role id true wait:machine" \
      "stow paused role id true wait:off" "coordinator-hold paused role id true wait:off" "offline paused role id true wait:external" \
      "limit paused any id true wait:limit" "machine paused any id true wait:machine" "shutdown paused any id true wait:off")"
}

@test "a feature task plans, builds on its plan, is in review on its PR and awaits merge once every open PR's head passed" {
  assert_equal "$(fold_read 'task_status + " " + phase')" "unknown planning"
  on thread '{discord_thread: "1563"}'
  assert_equal "$(fold_read 'task_status + " " + phase')" "legacy planning"
  opened feature
  assert_equal "$(fold_read 'task_status + " " + phase')" "open planning"
  on plan-approved '{by: "Daniel"}'
  assert_equal "$(fold_read phase)" building
  assert_equal "$(fold_read 'lifecycle.since')" "2026-11-01T00:02:00Z"
  on pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  assert_equal "$(fold_read phase)" in-review
  on pr '{url: "https://github.com/owner/conv/pull/3", head: "2222222"}'
  on review '{verdict: "pass", head: "1111111"}'
  assert_equal "$(fold_read phase)" in-review
  on review '{verdict: "pass", head: "2222222aaaa"}'
  assert_equal "$(fold_read phase)" awaiting-merge
  assert_equal "$(fold_read 'lifecycle.prs | map([.number, .verdict, .merged])')" '[[5,"pass",false],[3,"pass",false]]'
  # A rewrite moves the PR's head, and the pass on the old head no longer counts.
  on history-rewritten '{project: "proj", branch: "feat/T1-tooling", old_head: "1111111", head: "3333333"}'
  assert_equal "$(fold_read phase)" in-review
  assert_equal "$(fold_read 'lifecycle.prs | map([.head, .verdict])')" '[["3333333",null],["2222222","pass"]]'
  on review '{verdict: "pass", head: "3333333"}'
  assert_equal "$(fold_read phase)" awaiting-merge
  # A new pr in a repo replaces its PR, at a head no review has passed.
  on pr '{url: "https://github.com/owner/proj/pull/6", head: "4444444"}'
  assert_equal "$(fold_read phase)" in-review
  assert_equal "$(fold_read 'task_prs')" \
    '[{"url":"https://github.com/owner/conv/pull/3","head":"2222222","number":3},{"url":"https://github.com/owner/proj/pull/6","head":"4444444","number":6}]'
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(fold_read 'task_status + " " + phase')" "closed closed"
}

@test "a pass on a fix's head counts for the pr logged at that head after it, as for a rewrite to it" {
  opened feature
  on pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  on review '{verdict: "findings", head: "1111111"}'
  # The fix was reviewed at its head before the delivering builder logged the PR there.
  on review '{verdict: "pass", head: "2222222"}'
  assert_equal "$(fold_read phase)" in-review
  on pr '{url: "https://github.com/owner/proj/pull/5", head: "2222222"}'
  assert_equal "$(fold_read phase)" awaiting-merge
  on history-rewritten '{project: "proj", branch: "feat/T1-tooling", old_head: "2222222", head: "1111111"}'
  assert_equal "$(fold_read 'phase + " " + (lifecycle.prs[0].verdict)')" "in-review findings"
}

@test "a rewrite with no PR logged moves no phase, while a review puts a building task in review" {
  opened small
  on history-rewritten '{project: "proj", branch: "feat/T1-tooling", old_head: "1111111", head: "2222222"}'
  assert_equal "$(fold_read phase)" building
  on review '{verdict: "findings", head: "2222222"}'
  assert_equal "$(fold_read phase)" in-review
}

@test "a small or bug task builds from its open, a research or retro task plans, and a path the table lacks plans" {
  local path want
  for path in small:building bug:building research:planning retro:planning feature:planning other:planning; do
    events=()
    opened "${path%%:*}"
    want=${path#*:}
    assert_equal "$path $(fold_read 'phase + " " + lifecycle.path + " " + lifecycle.since')" \
      "$path $want ${path%%:*} 2026-11-01T00:00:00Z"
  done
}

@test "a builder's report of review-ready or merged puts the task in review, and no other done does" {
  opened small
  on "done" '{role: "builder", session: "b1", report: "05"}'
  on "done" '{role: "reviewer", session: "r1", report: "review-ready https://x"}'
  assert_equal "$(fold_read phase)" building
  on "done" '{role: "builder", session: "b1", report: "review-ready https://github.com/owner/proj/pull/5"}'
  assert_equal "$(fold_read phase)" in-review
}

@test "a merged naming phases left is a merged part, and one naming none, or [], is merged" {
  local left want
  for left in '[2]:merged-part' '[]:merged' 'null:merged'; do
    events=()
    opened feature
    on plan-approved '{by: "Daniel"}'
    on pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
    on review '{verdict: "pass", head: "1111111"}'
    on merged "{pr: 5, merge: \"fedcba9\", head: \"1111111\", by: \"Daniel\", url: \"https://github.com/owner/proj/pull/5\"}
      + if ${left%%:*} == null then {} else {phases_left: ${left%%:*}} end"
    want=${left#*:}
    assert_equal "$left $(fold_read phase)" "$left $want"
  done
  # The contract takes phases_left as a list of whole numbers, and only that.
  assert_equal "$(fold_read '[.[-1] | append_problems($contract; "team-merge")]')" '[]'
  on merged '{pr: 5, merge: "fedcba9", head: "1111111", by: "Daniel", phases_left: ["2"]}'
  assert_contains "$(fold_read '[.[-1] | append_problems($contract; "team-merge")] | join("; ")')" "phases_left must be"
}

@test "after a merge, a builder launch or a ticket-done builds again and a pr is in review" {
  local after want
  for after in launch:building ticket-done:building pr:in-review review:merged-part other-launch:merged-part; do
    events=()
    opened feature
    on plan-approved '{by: "Daniel"}'
    on pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
    on merged '{pr: 5, merge: "fedcba9", head: "1111111", by: "Daniel", phases_left: [2]}'
    case ${after%%:*} in
      launch) builder_launch b2 ;;
      other-launch) on launch '{role: "reviewer", session: "r2", worktree: "/w/1", toolkits: []}' ;;
      ticket-done) on ticket-done '{ticket: "05", commits: ["bbbbbbb"]}' ;;
      pr) on pr '{url: "https://github.com/owner/proj/pull/6", head: "2222222"}' ;;
      review) on review '{verdict: "pass", head: "1111111"}' ;;
    esac
    # A reviewer's launch or a review of the merged head moves nothing: the part stays merged.
    want=${after#*:}
    assert_equal "$after $(fold_read phase)" "$after $want"
  done
}

@test "T278's A1: a part merged, then a builder's ticket, reads building and the sweep does not say to close it" {
  opened feature
  on thread '{discord_thread: "1"}'
  on plan-approved '{by: "coordinator"}'
  on pr '{url: "https://github.com/o/r/pull/1", head: "aaaaaaa1"}'
  on review '{verdict: "pass", head: "aaaaaaa1"}'
  on merged '{pr: 1, merge: "fedcba9", url: "https://github.com/o/r/pull/1", head: "aaaaaaa1", by: "Daniel"}'
  assert_equal "$(fold_read phase)" merged
  builder_launch b2
  on ticket-done '{ticket: "05", commits: ["bbbbbbb2"]}'
  on "done" '{role: "builder", session: "b2", report: "05"}'
  assert_equal "$(fold_read phase)" building
  run fold_read '[task_findings([{id: "b2", status: "idle", name: "T1-builder"}]; {sessions: {}})][0].text'
  assert_equal "$output" "T1 no-worker: every live worker is idle with a ledger event since its launch (latest T1-builder b2); next: send it its next step or launch the next worker with team-worker, or log why the task waits with team-log"
}

@test "a held or a blocked shows over the work phase while it stands, wherever it was logged, and closed over every one" {
  opened feature
  on held '{reason: "OS update"}'
  on merged '{pr: 5, merge: "fedcba9", head: "a1b2c3d", by: "1563"}'
  assert_equal "$(fold_read phase)" held
  on blocked '{reason: "a denied push"}'
  assert_equal "$(fold_read phase)" held
  # A launch ends the block, never the hold; a resumed ends both.
  builder_launch b2
  assert_equal "$(fold_read 'phase + " " + (lifecycle.parks | map(.id) | join(","))')" "held held-1"
  on resumed
  assert_equal "$(fold_read phase)" building
  on blocked '{reason: "the second half waits on T31"}'
  assert_equal "$(fold_read 'phase + " " + (lifecycle.parks | map(.id) | join(","))')" "blocked blocked-2"
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(fold_read phase)" closed
}

@test "the fold keeps each standing park with its id, the asks no event settles, and the stow until a launch" {
  opened feature
  on waiting '{on: "Daniel", reason: "an interview", since: "2026-10-31T00:00:00Z"}'
  on asked '{id: "door-data", text: "Which door data?"}'
  on asked '{id: "merge", text: "merge https://github.com/owner/proj/pull/5 at 1111111?"}'
  on paused '{reason: "stowed, handoff written"}'
  on stowed '{machine: "m1", worktrees: [], roles: ["builder"], cause: "handoff"}'
  # An old line's cause is legacy_cause's, and typed false; an asked before asked_parks_from parks
  # nothing by itself.
  assert_equal "$(fold_read 'lifecycle | [.parks[] | [.id, .kind, .cause, .typed, .on, .since, .i, .passed]]')" \
    '[["waiting-1","waiting","daniel",false,"Daniel","2026-10-31T00:00:00Z",1,false],["paused-1","paused","stow",false,null,"2026-11-01T00:04:00Z",4,false]]'
  assert_equal "$(fold_read 'lifecycle | .asks | map(.id)')" '["door-data","merge"]'
  assert_equal "$(fold_read 'lifecycle.stow')" '{"state":"stowed","cause":"handoff","roles":["builder"],"since":"2026-11-01T00:05:00Z","i":5}'
  on answered '{id: "door-data", text: "the old data"}'
  on merge-approved '{url: "https://github.com/owner/proj/pull/5", head: "1111111", discord_message: "1"}'
  assert_equal "$(fold_read 'lifecycle | .asks')" '[]'
  # The merge-approved also ended the old wait on Daniel (ticket 03's rule); a resumed naming only a
  # merge-base round's brief ends no park; a launch ends the pause and the stow, and the next
  # park's id counts on.
  assert_equal "$(fold_read 'lifecycle | .parks | map(.id)')" '["paused-1"]'
  on resumed '{brief: "brief-merge-base"}'
  assert_equal "$(fold_read 'lifecycle | .parks | map(.id)')" '["paused-1"]'
  builder_launch b2
  on waiting '{on: "T31", reason: "its PR"}'
  assert_equal "$(fold_read 'lifecycle | [(.parks | map(.id)), .stow, .counts]')" '[["waiting-2"],null,{"waiting":2,"paused":1}]'
}

@test "T278's A4: a room refusal and a resumed after it agree in parked and refused_launches, which both clear" {
  opened feature
  on plan-approved '{by: "Daniel"}'
  on launch '{role: "planner", session: "p1", worktree: "/w/1", toolkits: []}'
  on paused '{reason: "no room for session:builder at full (90%)"}'
  # The refusal is a standing park of cause room, its role read once from its reason.
  assert_equal "$(fold_read 'lifecycle.parks | map([.id, .cause, .role])')" '[["paused-1","room","builder"]]'
  assert_equal "$(fold_read '[parked, refused_launches]')" \
    '[true,{"at":"2026-11-01T00:03:00Z","roles":["builder"],"hold":null}]'
  on resumed
  assert_equal "$(fold_read '[parked, refused_launches]')" '[false,null]'
  # A room refusal whose words name no role parks the task, and refused_launches, which relaunches
  # roles, has none to name.
  on paused '{reason: "no room at full (90%): 17.9 GiB of 17.2"}'
  assert_equal "$(fold_read '[parked, refused_launches, (lifecycle.parks | map([.cause, .role]))]')" '[true,null,[["room",null]]]'
}

@test "T278's A5 and D6: a PAUSED stowed with detail hands the stowed builder on, and launch_states calls it handed-on" {
  local reason
  for reason in "stowed" "stowed, handoff written" "stowed ad6520fc for shutdown; next: re-run the gate"; do
    events=()
    opened feature
    builder_launch b1
    on paused "{reason: \"$reason\"}"
    builder_launch b2
    assert_equal "$(fold_read 'handed_on_launches("builder"; "/home/x") | map([.session, .stowed, .handed_on])')" \
      '[["b1",true,true],["b2",false,false]]'
    assert_equal "$(fold_read 'handed_on_launches(""; "/home/x") | launch_states([{id: "b1", status: "idle"}]) | map([.session, .state])')" \
      '[["b1","handed-on"]]'
  done
  # A paused that is no stow (its cause worker) is a wait the builder comes back from.
  events=()
  opened feature
  builder_launch b1
  on paused '{reason: "holding gate runs for the sudo fix"}'
  builder_launch b2
  assert_equal "$(fold_read 'handed_on_launches(""; "/home/x") | launch_states([{id: "b1", status: "idle"}]) | map([.session, .state])')" \
    '[["b1","idle with no event of its own since its launch"]]'
}

@test "a merge-approved ends an old wait on Daniel, and no other park" {
  opened feature
  on waiting '{on: "Daniel", reason: "the merge of PR 5"}'
  on waiting '{on: "daniel", reason: "ask merge"}'
  on waiting '{reason: "a word on the plan"}'
  on waiting '{on: "restart", reason: "machine shutdown; resume from the handoff"}'
  on blocked '{reason: "Daniel to apply the settings change"}'
  on paused '{reason: "machine load"}'
  on held '{reason: "on hold by Daniel"}'
  on merge-approved '{url: "https://github.com/owner/proj/pull/5", head: "1111111", discord_message: "1"}'
  assert_equal "$(fold_read 'lifecycle.parks | map(.id)')" '["waiting-4","blocked-1","paused-1","held-1"]'
  assert_equal "$(fold_read 'waiting')" '{"on":"restart","reason":"machine shutdown; resume from the handoff","since":"2026-11-01T00:04:00Z"}'
  # A wait whose line carries its own cause is not an old one, whatever it says.
  on waiting '{on: "Daniel", cause: "daniel", reason: "an interview"}'
  on merge-approved '{url: "https://github.com/owner/proj/pull/5", head: "1111111", discord_message: "2"}'
  assert_equal "$(fold_read 'lifecycle.parks | map([.id, .typed])')" \
    '[["waiting-4",false],["blocked-1",false],["paused-1",false],["held-1",false],["waiting-5",true]]'
}

@test "legacy_cause gives every park line of an old ledger a cause, first match winning" {
  run jq -L "$REPO_ROOT/bin/lib" -sc 'include "ledger";
    map(select(.event | IN("held", "blocked", "waiting", "paused")) | legacy_cause)
    | [length, (group_by(.) | map([.[0], length]))]' "$REPO_ROOT/tests/fixtures/ledger-2026-10-23.jsonl"
  assert_equal "$status" 0
  assert_equal "$output" '[30,[["daniel",8],["denial",9],["shutdown",6],["stow",3],["worker",4]]]'
  # One line of each rule, in the order the rules are tried.
  run jq -L "$REPO_ROOT/bin/lib" -nrc 'include "ledger";
    {event: "paused", reason: "Stowed ad6520fc for shutdown"},
    {event: "paused", reason: "team-worker: no room for session:reviewer at minor (30%)"},
    {event: "waiting", on: "the weekly limit", reason: "until Monday"},
    {event: "paused", reason: "the usage limit, stowed after it"},
    {event: "waiting", on: "restart", reason: "machine shutdown 2026-10-22"},
    {event: "held", reason: "OS update"},
    {event: "held", reason: "on hold by Daniel"},
    {event: "waiting", on: "Daniel", reason: "ask door-data"},
    {event: "waiting", on: "daniel", reason: "walkthrough section B"},
    {event: "waiting", reason: "a word on the plan"},
    {event: "waiting", on: "GitHub Support", reason: "ticket 4412"},
    {event: "blocked", on: "T31", reason: "its PR"},
    {event: "blocked", reason: "auto mode denied git rm"},
    {event: "blocked", reason: "the fixture server is down"},
    {event: "paused", reason: "docker daemons need a restart"},
    {event: "paused", reason: "holding gate runs for the sudo fix"},
    {event: "paused", cause: "limit", reason: "stowed"}
    | park_cause'
  assert_equal "$status" 0
  assert_equal "$(tr '\n' ' ' <<<"$output")" \
    "stow room limit limit shutdown shutdown daniel-hold ask daniel daniel outside task denial worker machine worker limit "
}

# problems <kind> [<jq object of more fields>]: the problems transition_problems finds for a T1
# event of <kind> a minute after the last event, over the events so far, one per line.
problems() {
  fold_read '(last.ts // "2026-11-01T00:00:00Z" | fromdate + 60 | todate) as $ts
    | transition_problems({ts: $ts, task: "T1", event: "'"$1"'"} + ('"${2:-{\}}"'))'
}

@test "the table test: every contract kind, in every status and phase, is refused exactly where lifecycle.json does not take it" {
  # Generated from lifecycle.json, so a new row is tested by being written: each case a state of
  # that status and phase, and a T1 event of the kind, whose retro is T1 for closed-own-retro and
  # T2 otherwise, a park carrying its kind's first cause, a stowed or stow-failed meeting a stowing
  # that stands; taken when the kind's status (or default's) names the status, a closed task's
  # own retro taken where it names closed too, and its phases (or default's) are null or name it.
  run fold_read 'lifecycle_table as $t
    | [$contract.kinds | keys[] as $kind | lifecycle_statuses[] as $status | $t.phases[] as $phase
       | ($t.kinds[$kind] // {}) as $row
       | ($row.status // $t.default.status) as $statuses
       | ($row.phases // $t.default.phases) as $phases
       | ((($statuses | index([$status])) or ($status == "closed-own-retro" and ($statuses | index(["closed"]))))
          and ($phases == null or ($phases | index([$phase])))) as $taken
       | (lifecycle_start | .status = (if $status == "closed-own-retro" then "closed" else $status end)
          | .phase = $phase | .since = "2026-11-01T00:00:00Z" | .opened_at = "2026-11-01T00:00:00Z"
          | .stow = (if IN($kind; "stowed", "stow-failed")
                     then {state: "stowing", cause: "level", roles: [], since: "2026-11-01T00:00:00Z", i: 0} else null end)) as $state
       | ({ts: "2026-11-01T00:01:00Z", task: "T1", event: $kind, retro: (if $status == "closed-own-retro" then "T1" else "T2" end)}
          + (first($t.causes | to_entries[] | select(.value.kinds | index([$kind])) | {cause: .key}) // {})) as $e
       | [$state | lifecycle_problems($e)] as $problems
       | {kind: $kind, status: $status, phase: $phase, taken: $taken, problems: $problems}] as $cases
    | [$cases[] | select(.taken == (.problems != [])) | "\(.kind) \(.status) \(.phase): taken \(.taken), problems \(.problems)"],
      ([$cases[] | select(.taken)] | length > 0), ([$cases[] | select(.taken | not)] | length > 0),
      (($cases | length) == ($contract.kinds | length) * (lifecycle_statuses | length) * ($t.phases | length))'
  assert_equal "$status" 0
  assert_equal "$output" "$(printf '[]\ntrue\ntrue\ntrue')"
}

@test "a closed task takes no event but a team-wide word and a closed retro's own retro-change" {
  opened retro
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(problems retro-change '{retro: "T1", proposals: "1, 2"}')" ""
  assert_equal "$(problems retro-change '{retro: "T5", proposals: "1"}')" "T1 is closed, and a closed task takes no retro-change"
  assert_equal "$(problems merge-standing '{project: "proj", discord_message: "1", discord_channel: "2"}')" ""
  assert_equal "$(problems merge-default-withdrawn '{scope: "all", discord_message: "1", discord_channel: "2"}')" ""
  assert_equal "$(problems merge-default-restored '{scope: "proj", discord_message: "1", discord_channel: "2"}')" ""
  assert_equal "$(problems asked '{id: "a1", text: "which?"}')" "T1 is closed, and a closed task takes no asked"
  # A closed task of another path takes no retro-change, even one naming it.
  events=()
  opened small
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(problems retro-change '{retro: "T7", proposals: "3"}')" "T1 is closed, and a closed task takes no retro-change"
}

@test "a new task takes a thread and then its opened, and an opened task no second opened" {
  assert_equal "$(problems thread '{discord_thread: "1563"}')" ""
  on thread '{discord_thread: "1563"}'
  assert_equal "$(problems opened '{path: "feature"}')" ""
  opened feature
  assert_equal "$(problems opened '{path: "feature"}')" "T1 is opened already, at 2026-11-01T00:01:00Z"
  assert_equal "$(problems thread '{discord_thread: "1564"}')" ""
}

@test "an event of a task not opened is refused, naming what its status takes, and review as T99's first event is refused" {
  run fold_read 'transition_problems({ts: "2026-11-01T00:00:00Z", task: "T99", event: "review", verdict: "pass", head: "a1b2c3d"})'
  assert_equal "$output" "T99 is not opened (no opened event), and it takes only thread and opened before its opened, not review"
  # A legacy task (events, no opened) takes its closed too, as team-close of a half-opened task.
  on launch '{role: "builder", session: "b1"}'
  assert_equal "$(problems review '{verdict: "pass", head: "a1b2c3d"}')" \
    "T1 is not opened (no opened event), and it takes only thread, opened and closed before its opened, not review"
  assert_equal "$(problems closed)" ""
  # A kind the table does not list takes default: an open task only.
  assert_equal "$(problems image-posted)" \
    "T1 is not opened (no opened event), and it takes only thread, opened and closed before its opened, not image-posted"
}

@test "a kind the table takes only in some phases is refused in the others, naming them" {
  # The table gives no kind phases now, so a table of the test's own gives plan-approved those it
  # had before T276, when a re-approval of a changed plan was no step.
  opened feature
  on pr '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d"}'
  assert_equal "$(problems plan-approved)" ""
  FOLD_LIB=$BATS_TEST_TMPDIR/lib
  mkdir -p "$FOLD_LIB"
  cp "$REPO_ROOT/bin/lib/ledger.jq" "$FOLD_LIB/"
  jq '.kinds["plan-approved"].phases = ["planning", "building", "merged-part", "merged"]' "$REPO_ROOT/bin/lib/lifecycle.json" \
    >"$FOLD_LIB/lifecycle.json"
  assert_equal "$(problems plan-approved)" \
    "T1 is in-review since 2026-11-01T00:01:00Z, and plan-approved is taken only while it is planning, building, merged-part or merged"
  on review '{verdict: "pass", head: "a1b2c3d"}'
  assert_equal "$(problems plan-approved)" \
    "T1 is awaiting-merge since 2026-11-01T00:02:00Z, and plan-approved is taken only while it is planning, building, merged-part or merged"
  on merged '{url: "https://github.com/owner/proj/pull/5", head: "a1b2c3d", phases_left: [2]}'
  assert_equal "$(problems plan-approved)" ""
  # A held shows over the work phase, but the table reads the work phase.
  on held '{reason: "on hold by Daniel"}'
  assert_equal "$(problems plan-approved)" ""
}

@test "a park with no cause breaks the table, naming its kind's causes, and a typed one does not" {
  opened feature
  assert_equal "$(problems paused '{reason: "the usage limit"}')" \
    "a paused needs a cause, one of coordinator-hold, limit, machine, offline, room, shutdown, stow, worker"
  assert_equal "$(problems held '{reason: "Daniel holds it"}')" "a held needs a cause, one of daniel-hold"
  assert_equal "$(problems waiting '{on: "Daniel", reason: "an interview"}')" "a waiting needs a cause, one of ask, daniel, outside"
  assert_equal "$(problems blocked '{reason: "a denial"}')" "a blocked needs a cause, one of denial, task, worker"
  assert_equal "$(problems paused '{reason: "the usage limit", cause: "limit"}')" ""
  # A closed task's park gets only the status text.
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(problems paused '{reason: "the usage limit"}')" "T1 is closed, and a closed task takes no paused"
}

@test "check_lifecycle replays raw lines in one pass, each task's event against the state before it" {
  run jq -L "$REPO_ROOT/bin/lib" -nRc --slurpfile contract "$REPO_ROOT/bin/lib/ledger-contract.json" \
    'include "ledger"; $contract[0] as $contract | check_lifecycle' <<'LEDGER'
{"ts":"2026-11-01T00:00:00Z","task":"T2","event":"thread","discord_thread":"1"}
{"ts":"2026-11-01T00:01:00Z","task":"T2","event":"opened","path":"small"}
not JSON

{"ts":"2026-11-01T00:02:00Z","task":"T3","event":"asked","id":"a1","text":"which?"}
{"ts":"2026-11-01T00:03:00Z","event":"asked"}
{"ts":"2026-11-01T00:04:00Z","task":"T2","event":"closed"}
{"ts":"2026-11-01T00:05:00Z","task":"T2","event":"answered","id":"a1","by":"Daniel"}
LEDGER
  assert_equal "$status" 0
  assert_equal "$output" '{"total":8,"from":null,"bad":[{"line":5,"task":"T3","event":"asked","ts":"2026-11-01T00:02:00Z","problems":["T3 is not opened (no opened event), and it takes only thread and opened before its opened, not asked"]},{"line":8,"task":"T2","event":"answered","ts":"2026-11-01T00:05:00Z","problems":["T2 is closed, and a closed task takes no answered"]}]}'
}

@test "each typed park is ended by exactly the events its cause's row names, and by nothing else" {
  # Generated from lifecycle.json's causes: for each cause a park of its first kind (a blocked or
  # paused naming the builder's role), after an open ask a1 (the ask of a wait of cause ask), then
  # one event, the park ended exactly when the row says that event ends it.
  run jq -L "$REPO_ROOT/bin/lib" -nc 'include "ledger";
    [{ts: "2026-11-01T00:00:00Z", task: "T1", event: "opened", path: "feature"},
     {ts: "2026-11-01T00:01:00Z", task: "T1", event: "asked", id: "a1", text: "Which?"}] as $base
    | {"launch of its role": {event: "launch", role: "builder", session: "b9"},
       "launch of another role": {event: "launch", role: "reviewer", session: "r9"},
       "resumed id= of it": {event: "resumed", id: "@"},
       "resumed id= of it with discord_message": {event: "resumed", id: "@", discord_message: "1"},
       "resumed id= of another park": {event: "resumed", id: "paused-9"},
       "resumed all=true": {event: "resumed", all: true},
       "resumed brief= alone": {event: "resumed", brief: "brief-merge-base"},
       "its ask answered": {event: "answered", id: "a1"},
       "another ask answered": {event: "answered", id: "a2"}} as $cases
    | lifecycle_table.causes | to_entries | map(.key as $cause | .value as $row | $row.kinds[0] as $kind
      | ({reason: "r", cause: $cause}
         + if IN($kind; "blocked", "paused") then {role: "builder", session: "b1"} else {} end
         + if $kind == "waiting" then {on: "Daniel"} else {} end
         + if $kind == "held" then {discord_message: "1"} else {} end
         + if $cause == "ask" then {ask: "a1"} else {} end) as $fields
      | $cases | to_entries[] | .key as $case
      | ({ts: "2026-11-01T00:03:00Z", task: "T1"} + .value | if .id == "@" then .id = "\($kind)-1" else . end) as $e
      | ($base + [{ts: "2026-11-01T00:02:00Z", task: "T1", event: $kind} + $fields, $e] | lifecycle.parks == []) as $ended
      | {"launch of its role": IN($row.launch; "any", "role"),
         "launch of another role": ($row.launch == "any"),
         "resumed id= of it": ($row.resume == "id"),
         "resumed id= of it with discord_message": IN($row.resume; "id", "daniel"),
         "resumed id= of another park": false,
         "resumed all=true": $row.all,
         "resumed brief= alone": false,
         "its ask answered": ($cause == "ask"),
         "another ask answered": false}[$case] as $want
      | select($ended != $want) | "\($cause): \($case) \(if $ended then "ends" else "leaves" end) it")'
  assert_equal "$status" 0
  assert_equal "$output" "[]"
  # The rows as the spec gives them, so the generated test reads what the table says.
  assert_equal "$(fold_read 'lifecycle_table.causes | to_entries | map("\(.key) \(.value.launch) \(.value.resume) \(.value.all)") | join("; ")')" \
    "daniel-hold never daniel false; ask never never false; daniel any id true; outside any id true; task any id true; worker role id true; denial any id true; room role id true; stow role id true; coordinator-hold role id true; offline role id true; limit any id true; machine any id true; shutdown any id true"
}

@test "a typed park of role cause that names no role is ended by any launch" {
  opened feature
  on paused '{reason: "waiting for the gate", cause: "worker"}'
  on launch '{role: "reviewer", session: "r1", worktree: "/w/1", toolkits: []}'
  assert_equal "$(fold_read 'lifecycle.parks')" "[]"
}

@test "T278's A2: a resumed id= of a worker's block leaves Daniel's held standing" {
  opened feature
  on plan-approved '{by: "Daniel"}'
  on held '{reason: "Daniel: hold until I say", cause: "daniel-hold", discord_message: "1"}'
  on blocked '{reason: "builder: npm registry down", cause: "worker"}'
  on resumed '{id: "blocked-1"}'
  assert_equal "$(fold_read '[phase, (lifecycle.parks | map(.id))]')" '["held",["held-1"]]'
  # all=true leaves it too, and Daniel's word lifts it.
  on resumed '{all: true}'
  assert_equal "$(fold_read '[phase, (lifecycle.parks | map(.id))]')" '["held",["held-1"]]'
  on resumed '{id: "held-1", discord_message: "2"}'
  assert_equal "$(fold_read '[phase, (lifecycle.parks | map(.id))]')" '["building",[]]'
}

@test "T278's A3: a typed wait on an ask stands through a launch until the ask is answered" {
  opened feature
  on asked '{id: "door-data", text: "Which door data?"}'
  on waiting '{on: "Daniel", cause: "ask", ask: "door-data", reason: "ask door-data"}'
  builder_launch b3
  assert_equal "$(fold_read '[waiting.reason, (pending_asks | map(.id)), parked]')" '["ask door-data",["door-data"],true]'
  on answered '{id: "door-data", answer: "the old data"}'
  assert_equal "$(fold_read '[waiting, (pending_asks | map(.id)), parked]')" '[null,[],false]'
}

@test "an asked parks by itself from asked_parks_from: its wait stands through a launch, takes no resumed, and ends when the ask is answered" {
  assert_equal "$(fold_read 'lifecycle_table.asked_parks_from')" "2026-11-12T12:00:00Z"
  ON_FROM=2026-11-12T12:00:00Z
  opened feature
  on asked '{id: "door-data", text: "Which door data?"}'
  assert_equal "$(fold_read '[waiting.reason, (lifecycle.parks | map([.id, .kind, .cause, .ask, .on, .since])), parked]')" \
    '["ask door-data",[["asked-1","waiting","ask","door-data","Daniel","2026-11-12T12:01:00Z"]],true]'
  assert_equal "$(problems resumed '{id: "asked-1"}')" \
    "asked-1 is the wait on ask door-data, which ends when the ask is answered (team-answer), not with a resumed"
  builder_launch b3
  assert_equal "$(fold_read '[waiting.reason, parked]')" '["ask door-data",true]'
  # A later wait's id counts the waitings alone, as before.
  on waiting '{on: "CI", cause: "outside", reason: "the runner"}'
  assert_equal "$(fold_read 'lifecycle.parks | map(.id)')" '["asked-1","waiting-1"]'
  on answered '{id: "door-data", answer: "the old data"}'
  assert_equal "$(fold_read '[(lifecycle.parks | map(.id)), (pending_asks | map(.id))]')" '[["waiting-1"],[]]'
  # A launch past the ask passes its wait too.
  on asked '{id: "port", text: "Which port?"}'
  on launch '{role: "builder", session: "b4", worktree: "/w/1", toolkits: [], past_ask: ["port"]}'
  assert_equal "$(fold_read '[(lifecycle.parks | map([.id, .passed])), parked]')" '[[["asked-2",true]],false]'
}

@test "an old line's wait on an ask its asked parks already is that wait, keeping its id, and no second park" {
  ON_FROM=2026-11-12T12:00:00Z
  opened feature
  on asked '{id: "door-data", text: "Which door data?"}'
  on waiting '{on: "Daniel", cause: "ask", ask: "door-data", reason: "ask door-data"}'
  on waiting '{on: "CI", cause: "outside", reason: "the runner"}'
  assert_equal "$(fold_read 'lifecycle.parks | map([.id, .ask, .since])')" \
    '[["waiting-1","door-data","2026-11-12T12:02:00Z"],["waiting-2",null,"2026-11-12T12:03:00Z"]]'
  on answered '{id: "door-data", answer: "the old data"}'
  assert_equal "$(fold_read 'lifecycle.parks | map(.id)')" '["waiting-2"]'
}

@test "old untyped parks read as phase 1 did, and a resumed id= or all=true ends them too" {
  opened feature
  on held '{reason: "on hold by Daniel"}'
  on blocked '{reason: "a denied push"}'
  on resumed
  assert_equal "$(fold_read '[phase, lifecycle.parks]')" '["planning",[]]'
  # A resumed id= names an old park whatever its cause, as team-answer ends an old ask's wait;
  # all=true ends the old parks whose legacy_cause takes all, never an old held, Daniel's.
  on held '{reason: "on hold by Daniel"}'
  on waiting '{on: "Daniel", reason: "ask door-data"}'
  on waiting '{on: "CI", reason: "the runner"}'
  on resumed '{id: "waiting-1"}'
  assert_equal "$(fold_read 'lifecycle.parks | map(.id)')" '["held-2","waiting-2"]'
  on resumed '{all: true}'
  assert_equal "$(fold_read 'lifecycle.parks | map(.id)')" '["held-2"]'
  on resumed '{id: "held-2"}'
  assert_equal "$(fold_read 'lifecycle.parks')" '[]'
}

@test "a second held while Daniel's hold stands, and a resumed id= the fold would not end, break the table" {
  opened feature
  on asked '{id: "door-data", text: "Which door data?"}'
  on waiting '{on: "Daniel", cause: "ask", ask: "door-data", reason: "ask door-data"}'
  assert_equal "$(problems resumed '{id: "held-1"}')" "T1 has no standing park held-1; its standing parks: waiting-1"
  assert_equal "$(problems resumed '{id: "waiting-1"}')" \
    "waiting-1 is the wait on ask door-data, which ends when the ask is answered (team-answer), not with a resumed"
  on held '{reason: "Daniel: hold", cause: "daniel-hold", discord_message: "1"}'
  assert_equal "$(problems held '{reason: "again", cause: "daniel-hold", discord_message: "2"}')" \
    "T1 is on Daniel's hold already: held-1 since 2026-11-01T00:03:00Z"
  assert_equal "$(problems resumed '{id: "held-1"}')" "held-1 is Daniel's hold, which only a resumed with discord_message, Daniel's word, lifts"
  assert_equal "$(problems resumed '{id: "held-1", discord_message: "3"}')" ""
  assert_equal "$(problems resumed '{all: true}')" ""
  on answered '{id: "door-data", answer: "the old data"}'
  on resumed '{id: "held-1", discord_message: "3"}'
  assert_equal "$(problems resumed '{id: "held-1"}')" "T1 has no standing park held-1; its standing parks: none"
}

# refusal <role> [<past ids as JSON>]: launch_refusal's reasons over the events so far, one a line.
refusal() {
  fold_read "launch_refusal(\"T1\"; \"$1\"; ${2:-[]}; true)"
}

@test "launch_refusal refuses a closed or unopened task, Daniel's hold, an open ask and a feature task's build before its plan" {
  # Not opened: every role, ops too.
  on thread '{discord_thread: "1"}'
  assert_equal "$(refusal builder)" "T1 is not open: the ledger has no opened event for it"
  assert_equal "$(refusal ops)" "T1 is not open: the ledger has no opened event for it"
  events=()
  # A feature task's builder or reviewer waits for its plan; its planner, ops and a message do not.
  opened feature
  assert_equal "$(refusal builder)" "T1 is a feature task with no approved plan (no plan-approved), so it takes no builder yet"
  assert_equal "$(refusal reviewer)" "T1 is a feature task with no approved plan (no plan-approved), so it takes no reviewer yet"
  assert_equal "$(refusal planner)$(refusal ops)$(refusal '')" ""
  on plan-approved '{by: "Daniel"}'
  assert_equal "$(refusal builder)" ""
  # Daniel's hold refuses every role but ops, naming the word that lifts it.
  on held '{reason: "Daniel: not before the release", cause: "daniel-hold", discord_message: "1"}'
  assert_equal "$(refusal builder)" "T1 is on Daniel's hold since 2026-11-01T00:02:00Z (held-1): Daniel: not before the release; only Daniel's word lifts it: team-log T1 resumed id=held-1 discord_message=<their message id>"
  assert_equal "$(refusal '')" "$(refusal reviewer)"
  assert_equal "$(refusal ops)" ""
  on resumed '{id: "held-1", discord_message: "2"}'
  # An open ask refuses unless the launch names it; an id that is no open ask is refused.
  on asked '{id: "door-data", text: "Which door data?"}'
  assert_equal "$(refusal builder)" "T1 has an unanswered ask, door-data, since 2026-11-01T00:04:00Z; launch past it with --past-ask door-data"
  assert_equal "$(fold_read 'launch_refusal("T1"; ""; [])')" "T1 has an unanswered ask, door-data, since 2026-11-01T00:04:00Z"
  assert_equal "$(refusal builder '["door-data"]')" ""
  assert_equal "$(refusal builder '["door-data", "nope"]')" "--past-ask nope names no unanswered ask of T1"
  assert_equal "$(refusal ops)" ""
  # Closed: one reason, whatever stands.
  on closed '{archive: [], returned: [], kept: []}'
  assert_equal "$(refusal builder)" "T1 is closed"
}

@test "a withdrawn plan approval refuses a builder and a reviewer on every path and in every phase, until Daniel approves the plan again" {
  local withdrawn="T1's plan approval was withdrawn at 2026-11-01T00:05:00Z in Discord message 9, so it takes no"
  # A feature task between phases: merged-part, where a later phase's builder is launched by hand.
  opened feature
  on plan-approved '{by: "Daniel"}'
  on pr '{url: "https://github.com/owner/proj/pull/5", head: "1111111"}'
  on review '{verdict: "pass", head: "1111111"}'
  on merged '{pr: 5, merge: "fedcba9", head: "1111111", by: "Daniel", url: "https://github.com/owner/proj/pull/5", phases_left: [2]}'
  on plan-approval-withdrawn '{discord_message: "9"}'
  assert_equal "$(fold_read phase)" merged-part
  assert_equal "$(refusal builder)" "$withdrawn builder until Daniel approves the plan again (plan-approved by=Daniel)"
  assert_equal "$(refusal reviewer)" "$withdrawn reviewer until Daniel approves the plan again (plan-approved by=Daniel)"
  assert_equal "$(refusal planner)$(refusal ops)$(refusal '')" ""
  on plan-approved '{by: "Daniel", plan: {}}'
  assert_equal "$(refusal builder)$(refusal reviewer)" ""
  # A feature task building, which the withdrawal moves back to planning, names the withdrawal alone.
  events=()
  opened feature
  on plan-approved '{by: "Daniel"}'
  builder_launch b1
  on ticket-done '{ticket: "01"}'
  on plan-approval-withdrawn '{discord_message: "9"}'
  assert_equal "$(fold_read phase)" planning
  withdrawn=${withdrawn/00:05:00Z/00:04:00Z}
  assert_equal "$(refusal builder)" "$withdrawn builder until Daniel approves the plan again (plan-approved by=Daniel)"
  # A small task, which needs no plan to start, is stopped by a withdrawn one too.
  events=()
  opened small
  on plan-approved '{by: "coordinator"}'
  on ticket-done '{ticket: "01"}'
  on "done" '{role: "builder", session: "b1", report: "05"}'
  on plan-approval-withdrawn '{discord_message: "9"}'
  assert_equal "$(refusal builder)" "$withdrawn builder until Daniel approves the plan again (plan-approved by=Daniel)"
  assert_equal "$(refusal reviewer)" "$withdrawn reviewer until Daniel approves the plan again (plan-approved by=Daniel)"
}

@test "a research or small task's builder and reviewer go from its open" {
  local both='[launch_refusal("T1"; "builder"; []), launch_refusal("T1"; "reviewer"; [])] | length'
  opened research
  assert_equal "$(fold_read "$both")" 0
  events=()
  opened small
  assert_equal "$(fold_read "$both")" 0
}

@test "T278's A4b: team-worker's typed room refusal lists its role in refused_launches whatever its reason's words" {
  opened small
  builder_launch b1
  on paused '{reason: "the level is full", cause: "room", role: "reviewer", brief: "brief-review"}'
  assert_equal "$(fold_read '[parked, refused_launches.roles]')" '[true,["reviewer"]]'
  on launch '{role: "reviewer", session: "r1", worktree: "/w/1", toolkits: []}'
  assert_equal "$(fold_read refused_launches)" null
}

@test "the table's launch rule is launch_refusal's, by the launch's role and past_ask" {
  opened feature
  assert_equal "$(problems launch '{role: "builder", session: "b1", worktree: "/w/1", toolkits: []}')" \
    "T1 is a feature task with no approved plan (no plan-approved), so it takes no builder yet"
  on plan-approved '{by: "Daniel"}'
  on asked '{id: "door-data", text: "Which door data?"}'
  assert_equal "$(problems launch '{role: "builder", session: "b1", worktree: "/w/1", toolkits: []}')" \
    "T1 has an unanswered ask, door-data, since 2026-11-01T00:02:00Z"
  assert_equal "$(problems launch '{role: "builder", session: "b1", worktree: "/w/1", toolkits: [], past_ask: ["door-data"]}')" ""
  assert_equal "$(problems launch '{role: "ops", session: "o1", worktree: "/w/1", toolkits: []}')" ""
}

@test "T278's B5: a launch past an open ask marks it and its wait passed, which park nothing, and later launches go" {
  opened feature
  on plan-approved '{by: "Daniel"}'
  builder_launch b1
  on asked '{id: "q1", text: "which import?"}'
  on waiting '{on: "Daniel", cause: "ask", ask: "q1", reason: "ask q1"}'
  assert_equal "$(fold_read parked)" true
  on launch '{role: "builder", session: "b2", worktree: "/w/1", toolkits: [], brief: "brief-build-13", past_ask: ["q1"]}'
  assert_equal "$(fold_read '[parked, (pending_asks | map(.id)), (lifecycle | lifecycle_parks | map([.id, .passed]))]')" \
    '[false,["q1"],[["waiting-1",true]]]'
  assert_equal "$(fold_read 'lifecycle | lifecycle_hold_since(-1)')" "null"
  # The next hand-off's launch need not name it again, and the answer still ends the wait.
  assert_equal "$(refusal reviewer)" ""
  on answered '{id: "q1", answer: "the new one"}'
  assert_equal "$(fold_read '[parked, pending_asks, lifecycle.parks]')" '[false,[],[]]'
}

@test "Daniel's hold and an ask no launch passed hold a stow wherever they were logged; another park only after it" {
  opened feature
  on plan-approved '{by: "Daniel"}'
  builder_launch b1
  on held '{reason: "Daniel: hold", cause: "daniel-hold", discord_message: "1"}'
  on waiting '{on: "CI", cause: "outside", reason: "the runner"}'
  on stowed '{machine: "m", cause: "level", roles: ["builder"], worktrees: []}'
  assert_equal "$(fold_read stow_hold)" "held: Daniel: hold"
  on resumed '{id: "held-1", discord_message: "2"}'
  # The outside wait before the stow does not hold it (the stowed worker's own state).
  assert_equal "$(fold_read stow_hold)" "null"
  events=()
  opened feature
  on plan-approved '{by: "Daniel"}'
  builder_launch b1
  on asked '{id: "q1", text: "which import?"}'
  on stowed '{machine: "m", cause: "level", roles: ["builder"], worktrees: []}'
  assert_equal "$(fold_read stow_hold)" "unanswered ask q1: which import?"
  # A room refusal before the ask: the ask holds its relaunch too.
  events=()
  opened feature
  on plan-approved '{by: "Daniel"}'
  builder_launch b1
  on asked '{id: "q1", text: "which import?"}'
  on paused '{reason: "no room for session:reviewer", cause: "room", role: "reviewer"}'
  assert_equal "$(fold_read refused_launches.hold)" "unanswered ask q1: which import?"
}

@test "an ask that names tickets holds a stow or a room refusal only while all its work is those tickets' builders" {
  local prune='{id: "prune", text: "Prune phase 2?", tickets: ["03"]}'
  ticket_launch() {
    on launch "{role: \"builder\", session: \"b$1\", worktree: \"/w/1--$1\", ticket: \"$1\", toolkits: []}"
  }
  stowed_with() {
    events=()
    opened feature
    on plan-approved '{by: "Daniel"}'
    on worktree-added '{project: "proj", ticket: "03", branch: "feat/T1-tooling--03", worktree: "/w/1--03"}'
    "$@"
    on asked "$prune"
    on stowing '{machine: "m", cause: "level", roles: ["builder"]}'
    on stowed '{machine: "m", cause: "level", roles: ["builder"], worktrees: []}'
  }
  stowed_with ticket_launch 03
  assert_equal "$(fold_read stow_hold)" "unanswered ask prune: Prune phase 2?"
  # A builder of a ticket the ask does not name is not held, so the stow's resume goes.
  stowed_with eval 'ticket_launch 03; ticket_launch 05'
  assert_equal "$(fold_read stow_hold)" "null"
  # A builder in the task's worktree is the ticket of its build brief, its resume's too.
  stowed_with on launch '{role: "builder", session: "b1", worktree: "/w/1", toolkits: [], brief: "brief-resume-build-03"}'
  assert_equal "$(fold_read stow_hold)" "unanswered ask prune: Prune phase 2?"
  stowed_with on launch '{role: "builder", session: "b1", worktree: "/w/1", toolkits: [], brief: "brief-deliver"}'
  assert_equal "$(fold_read stow_hold)" "null"
  # A ticket's builder that ended before the stow is not its work.
  stowed_with eval 'ticket_launch 05; on ticket-done "{ticket: \"05\", commits: []}"; ticket_launch 03'
  assert_equal "$(fold_read stow_hold)" "unanswered ask prune: Prune phase 2?"
  # An ask logged after the stow holds it by the same rule, its wait no other way.
  events=()
  opened feature
  on plan-approved '{by: "Daniel"}'
  on launch '{role: "builder", session: "b1", worktree: "/w/1", toolkits: [], brief: "brief-build-05"}'
  on stowed '{machine: "m", cause: "level", roles: ["builder"], worktrees: []}'
  on asked "$prune"
  assert_equal "$(fold_read stow_hold)" "null"
  # A room refusal holds by the refused launch's ticket.
  events=()
  opened feature
  on plan-approved '{by: "Daniel"}'
  on asked "$prune"
  on paused '{reason: "no room for session:builder", cause: "room", role: "builder", brief: "brief-build-03"}'
  assert_equal "$(fold_read refused_launches.hold)" "unanswered ask prune: Prune phase 2?"
  on paused '{reason: "no room for session:builder", cause: "room", role: "builder", brief: "brief-build-05"}'
  assert_equal "$(fold_read refused_launches.hold)" "null"
}

@test "a stowing stands until its stowed or stow-failed, and a stow-failed reads as stowed with the stowing's roles until a launch" {
  opened feature
  on plan-approved '{by: "Daniel"}'
  builder_launch b1
  on stowing '{machine: "m1", cause: "level", roles: ["builder"]}'
  # A stow under way is no stow to resume, and plan_tasks names it.
  assert_equal "$(fold_read '[lifecycle.stow, stowed_awaiting_resume]')" \
    '[{"state":"stowing","cause":"level","roles":["builder"],"since":"2026-11-01T00:03:00Z","i":3},false]'
  assert_equal "$(fold_read '[plan_tasks([])[] | [.stowing, .stowed, .stowed_since]]')" \
    '[[{"since":"2026-11-01T00:03:00Z","cause":"level"},null,null]]'
  on stowed '{machine: "m1", worktrees: [], roles: ["builder"], cause: "level"}'
  assert_equal "$(fold_read '[lifecycle.stow.state, stowed_awaiting_resume, (plan_tasks([])[] | .stowing)]')" '["stowed",true,null]'

  # A failed stow keeps the stowing's roles and cause, so the plan resumes it as a stowed one.
  events=()
  opened feature
  on plan-approved '{by: "Daniel"}'
  builder_launch b1
  on stowing '{machine: "m1", cause: "handoff", roles: ["builder"]}'
  on stow-failed '{machine: "m1", reason: "the run stopped: checkpoint: failed"}'
  assert_equal "$(fold_read '[lifecycle.stow, stowed_awaiting_resume]')" \
    '[{"state":"failed","cause":"handoff","roles":["builder"],"since":"2026-11-01T00:04:00Z","i":4,"reason":"the run stopped: checkpoint: failed"},true]'
  assert_equal "$(fold_read '[plan_tasks([])[] | [.stowing, .stowed.roles, .stowed_since]]')" \
    '[[null,["builder"],"2026-11-01T00:04:00Z"]]'
  builder_launch b2
  assert_equal "$(fold_read '[lifecycle.stow, stowed_awaiting_resume]')" '[null,false]'
}

@test "a stowing while one stands, and a stowed or stow-failed with none standing, break the table" {
  opened feature
  assert_equal "$(problems stowed '{machine: "m1", worktrees: [], roles: []}')" "stowed with no stowing of T1 standing"
  assert_equal "$(problems stow-failed '{machine: "m1", reason: "x"}')" "stow-failed with no stowing of T1 standing"
  assert_equal "$(problems stowing '{machine: "m1", cause: "level", roles: []}')" ""
  on stowing '{machine: "m1", cause: "level", roles: []}'
  assert_equal "$(problems stowing '{machine: "m1", cause: "level", roles: []}')" "T1 is stowing already, since 2026-11-01T00:01:00Z"
  assert_equal "$(problems stowed '{machine: "m1", worktrees: [], roles: []}')" ""
  assert_equal "$(problems stow-failed '{machine: "m1", reason: "x"}')" ""
  on stow-failed '{machine: "m1", reason: "x"}'
  assert_equal "$(problems stow-failed '{machine: "m1", reason: "x"}')" "stow-failed with no stowing of T1 standing"
}

@test "T278's D5: a task crashed only for a machine other than the one its latest launch ran on, with no stow after it" {
  opened feature
  on plan-approved '{by: "Daniel"}'
  on launch '{role: "builder", session: "b1", worktree: "/w/1", toolkits: [], machine: "m"}'
  on "done" '{role: "builder", session: "b1"}'
  # Its latest launch ran on m, with no stow: m restarting is no crash, and resumes no snapshot over
  # the live worktree, while another machine taking it over finds m stopped without a handoff.
  assert_equal "$(fold_read '[crashed("m"), crashed("n"), snapshot_due("proj"; "m"), snapshot_due("proj"; "n")]')" \
    '[false,true,false,true]'

  # A launch on n that n stowed is a handoff, no crash, for any machine.
  events=()
  opened feature
  on plan-approved '{by: "Daniel"}'
  on launch '{role: "builder", session: "b1", worktree: "/w/1", toolkits: [], machine: "n"}'
  on stowed '{machine: "n", worktrees: [], roles: ["builder"], cause: "handoff"}'
  assert_equal "$(fold_read '[crashed("m"), crashed("n")]')" '[false,false]'

  # An old launch names no machine, so it crashed for any machine, as before.
  events=()
  opened feature
  on plan-approved '{by: "Daniel"}'
  builder_launch b1
  assert_equal "$(fold_read '[crashed("m"), crashed("n")]')" '[true,true]'
}

@test "T287's ticket parks: a ticket builder's park ends only at a launch of its ticket, and parks the task only while no other ticket builds" {
  opened feature
  on plan-approved '{by: "Daniel", parallel: "2"}'
  on worktree-added '{project: "proj", branch: "feat/T1-tooling--02", worktree: "/w/2", ticket: "02"}'
  on launch '{role: "builder", session: "b2", worktree: "/w/2", toolkits: [], brief: "brief-build-02", ticket: "02"}'
  on worktree-added '{project: "proj", branch: "feat/T1-tooling--03", worktree: "/w/3", ticket: "03"}'
  on launch '{role: "builder", session: "b3", worktree: "/w/3", toolkits: [], brief: "brief-build-03", ticket: "03"}'
  # T1-builder-03's PAUSED names its session, so it parks ticket 03's builder.
  on paused '{reason: "waiting on the gate", cause: "worker", role: "builder", session: "b3"}'
  assert_equal "$(fold_read 'lifecycle.parks | map([.id, .ticket])')" '[["paused-1","03"]]'
  # Ticket 02 still builds, so the task is not parked; a launch of ticket 02 ends nothing of 03's.
  assert_equal "$(fold_read parked)" false
  on launch '{role: "builder", session: "b2b", worktree: "/w/2", toolkits: [], brief: "brief-resume-build-02", ticket: "02"}'
  assert_equal "$(fold_read 'lifecycle.parks | map(.id)')" '["paused-1"]'
  # With ticket 02 done, the only ticket building is parked, and so is the task.
  on ticket-done '{ticket: "02", commits: ["abc1234"], head: "abc1234"}'
  assert_equal "$(fold_read parked)" true
  # A launch of ticket 03 ends it.
  on launch '{role: "builder", session: "b3b", worktree: "/w/3", toolkits: [], brief: "brief-resume-build-03", ticket: "03"}'
  assert_equal "$(fold_read '[parked, lifecycle.parks]')" '[false,[]]'

  # team-worker's room refusal of brief-build-04 while ticket 04's worktree is open is ticket 04's:
  # ticket 03's launch leaves it, ticket 04's ends it.
  on worktree-added '{project: "proj", branch: "feat/T1-tooling--04", worktree: "/w/4", ticket: "04"}'
  on paused '{reason: "no room for session:builder at minor (30%)", cause: "room", role: "builder", brief: "brief-build-04"}'
  assert_equal "$(fold_read '[(lifecycle.parks | map([.id, .ticket])), refused_launches.roles, parked]')" '[[["paused-2","04"]],["builder"],false]'
  on launch '{role: "builder", session: "b3c", worktree: "/w/3", toolkits: [], brief: "brief-resume-build-03", ticket: "03"}'
  assert_equal "$(fold_read 'lifecycle.parks | map(.id)')" '["paused-2"]'
  on launch '{role: "builder", session: "b4", worktree: "/w/4", toolkits: [], brief: "brief-build-04", ticket: "04"}'
  assert_equal "$(fold_read '[lifecycle.parks, refused_launches]')" '[[],null]'

  # A returned ticket worktree takes its ticket out: a room refusal of its brief is the task's, as
  # before T287, and any builder's launch ends it; so is a park naming a session no ticket launch had.
  on worktree-returned '{project: "proj", worktree: "/w/4", ticket: "04"}'
  on paused '{reason: "no room for session:builder", cause: "room", role: "builder", brief: "brief-build-04"}'
  on blocked '{reason: "the push was refused", cause: "worker", role: "builder", session: "t1"}'
  assert_equal "$(fold_read 'lifecycle.parks | map([.id, .ticket])')" '[["paused-3",null],["blocked-1",null]]'
  assert_equal "$(fold_read parked)" true
  on launch '{role: "builder", session: "b3d", worktree: "/w/3", toolkits: [], brief: "brief-resume-build-03", ticket: "03"}'
  assert_equal "$(fold_read lifecycle.parks)" '[]'
  # Old shapes keep T279's rules: a cap-1 builder's room refusal of brief-build-05 in the task
  # worktree ends at the next builder launch, whatever its brief.
  events=()
  opened feature
  on plan-approved '{by: "Daniel"}'
  builder_launch b1
  on paused '{reason: "no room for session:builder", cause: "room", role: "builder", brief: "brief-build-05"}'
  assert_equal "$(fold_read 'lifecycle.parks | map(.ticket)')" '[null]'
  on launch '{role: "builder", session: "b6", worktree: "/w/1", toolkits: [], brief: "brief-build-06"}'
  assert_equal "$(fold_read lifecycle.parks)" '[]'
}
