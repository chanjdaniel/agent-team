#!/usr/bin/env bats
# team-level: the team's resource level, its record in the team home's level.jsonl, the budget
# it gives on stored readings, and the limits it sets on the team's slice (the systemctl stub
# fake_service_managers makes) and on the team's containers (the docker stub).

load helpers/common
load helpers/docker

GIB=1073741824
RECORD='' UNITS='' SLICE_STATE=''

setup() {
  sandbox
  docker_stub
  fake_service_managers
  cp "$REPO_ROOT/tests/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  hold_lease home-pc >/dev/null
  RECORD=$TEAM_HOME/level.jsonl
  UNITS=$HOME/.config/systemd/user
  SLICE_STATE=$HOME/.fake-systemd/agent-team.slice
  mkdir -p "$UNITS" "$HOME/.fake-systemd"
  printf '%s\n' '[Unit]' 'Description=the team' '' '[Slice]' >"$UNITS/agent-team.slice"
  stub_reply claude '[]'
}

# reading <minutes ago> <others GiB> [<others cores>]: a stored reading of a 32 GiB, 12-core
# machine whose other programs use <others GiB> and <others cores> (no CPU read without them),
# the team using 3 GiB and 1.5 cores, with the stacks in $STACKS (a JSON array, default none).
reading() {
  local file=$HOME/.local/state/agent-team/capacity/readings.jsonl
  mkdir -p "${file%/*}"
  jq -cn --arg at "$(date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ)" --argjson others "$2" --arg cores "${3:-}" \
    --argjson stacks "${STACKS:-[]}" '
    (32 * 1073741824) as $total | ($others * 1073741824 | floor) as $others
    | {at: $at, os: "linux", docker: true,
       memory: {total: $total, available: ($total - $others - 3 * 1073741824), team: (3 * 1073741824), others: $others},
       cpu: (if $cores == "" then null else {cpus: 12, seconds: 300, team: 1.5, others: ($cores | tonumber)} end),
       systemd: true, sessions: true,
       tasks: [{task: "T7", memory: (3 * 1073741824), cpu: 1.5, cpu_nsec: null,
                sessions: [{id: "a1b2c3d4", role: "builder", memory: (536870912), peak: 536870912, cpu_seconds: 10}], stacks: []}],
       stacks: $stacks, gate: {running: false, memory: 0, cpu_seconds: 0}}' >>"$file"
}

# A level record: change <minutes ago> <mode> <level> [<by>, default Daniel]
change() {
  jq -cn --arg ts "$(date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ)" --arg mode "$2" --arg level "$3" --arg by "${4:-Daniel}" \
    '{ts: $ts, mode: $mode, level: $level, by: $by, machine: "home-pc"}' >>"$RECORD"
}

# The readings so far are gone.
no_readings() {
  rm -f "$HOME/.local/state/agent-team/capacity/readings.jsonl"
}

# The content of each post to #coordinator, one JSON string per line.
posts() {
  stub_calls curl | jq -c 'select(.[-1] == "https://discord.com/api/v10/channels/1562486564871995482/messages")
    | index("-d") as $i | select($i) | .[$i + 1] | fromjson | .content'
}

# Discord answers each post with a message id, or fails with <status> when given.
discord_answers() {
  if [[ -z ${1:-} ]]; then
    rm -f "$STUB_FIXTURES/curl.sh"
    stub_reply curl '{"id":"1563000000000000001"}'
  else
    stub_script curl <<EOF
echo "curl: (22) The requested URL returned error: $1" >&2
exit 22
EOF
  fi
}

# The level records' [level, by], one per line.
levels() {
  jq -c '[.level, .by]' "$RECORD"
}

# The slice's use, as the user manager reports its MemoryCurrent: slice_use <GiB>
slice_use() {
  jq -n --argjson g "$1" '$g * 1073741824 | floor' >"$SLICE_STATE.MemoryCurrent"
}

# The set-property calls made on the team's slice, one line each, its assignments joined by spaces.
slice_calls() {
  stub_calls systemctl | jq -r 'select(.[1] == "set-property") | .[4:] | join(" ")'
}

# The docker update calls made, one line each.
update_calls() {
  docker_calls | grep '^update' || true
}

@test "a malformed command line is a usage error" {
  run_bin -2 team-level nope
  assert_contains "$output" "unknown subcommand 'nope'"
  run_bin -2 team-level minor now
  assert_contains "$output" "unexpected argument 'now'"
  run_bin -2 team-level minor --message abc
  assert_contains "$output" "--message takes a Discord message id"
  run_bin -2 team-level status --yaml
  assert_contains "$output" "unexpected argument '--yaml'"
  run_bin -2 team-level auto --message x
  assert_contains "$output" "--message takes a Discord message id"
  run_bin -2 team-level tick now
  assert_contains "$output" "unexpected argument 'now'"
  [[ ! -e $RECORD ]]
}

@test "with no record the team is manual full" {
  reading 1 8 2
  run_bin -0 --separate-stderr team-level status --json
  assert_equal "$(jq -c '[.schema, .mode, .level, .share, .last_change]' <<<"$output")" '["team-level/1","manual","full",0.9,null]'
  run_bin -0 team-level
  assert_contains "$output" "Resources: manual, full (90%): "
  assert_contains "$output" "  last change: none recorded, so manual full"
}

@test "each manual word appends one line with by and its message, and a repeat appends none" {
  reading 1 8 2
  run_bin -0 team-level minor --message 1234567890
  assert_equal "$(wc -l <"$RECORD")" 1
  assert_equal "$(jq -c '[.mode, .level, .by, .machine, .discord_message]' "$RECORD")" '["manual","minor","Daniel","home-pc","1234567890"]'
  jq -e '.ts | fromdateiso8601 > now - 60' "$RECORD" >/dev/null
  assert_equal "$output" "Resources: manual, minor (30%): 9.6 GiB and 3.6 cores for the team; 0.5 GiB reserved."

  run_bin -0 team-level minor
  assert_equal "${lines[0]}" "Nothing recorded: the team is already manual, minor."
  assert_equal "$(wc -l <"$RECORD")" 1

  run_bin -0 team-level none
  run_bin -0 team-level full
  assert_equal "$(jq -c '[.level, has("discord_message")]' "$RECORD" | paste -sd' ')" '["minor",true] ["none",false] ["full",false]'

  # manual holds the current level, from automatic mode (written as ticket 05's tick writes it).
  jq -cn '{ts: (now | floor | todate), mode: "auto", level: "minor", by: "auto", machine: "home-pc"}' >>"$RECORD"
  run_bin -0 team-level manual --message 42
  assert_equal "$(tail -n 1 "$RECORD" | jq -c '[.mode, .level, .by, .discord_message]')" '["manual","minor","Daniel","42"]'
  run_bin -0 team-level manual
  assert_equal "${lines[0]}" "Nothing recorded: the team is already manual, minor."
  assert_equal "$(wc -l <"$RECORD")" 5

  run_bin -0 --separate-stderr team-level status --json
  assert_equal "$(jq -c '[.mode, .level, .last_change.by, .last_change.discord_message]' <<<"$output")" '["manual","minor","Daniel","42"]'
}

@test "the budget is the share capped by what the other programs leave, and none's is 0" {
  # 32 GiB and 12 cores; the others use 8 GiB and 2 cores, and 4 GiB and 1 core stay free for
  # them: they leave 20 GiB and 9 cores.
  reading 1 8 2
  run_bin -0 team-level full
  run_bin -0 --separate-stderr team-level status --json
  assert_equal "$(jq -c '[.share, .budget]' <<<"$output")" '[0.9,{"memory_bytes":21474836480,"cores":9,"bound_by":{"memory":"others","cores":"others"}}]'
  run_bin -0 team-level minor
  run_bin -0 --separate-stderr team-level status --json
  assert_equal "$(jq -c '[.share, .budget]' <<<"$output")" '[0.3,{"memory_bytes":10307921510,"cores":3.6,"bound_by":{"memory":"share","cores":"share"}}]'

  # Each bound wins in turn: the others now use 26 GiB, leaving 2, and 3 cores, leaving 8.
  reading 0 26 3
  run_bin -0 --separate-stderr team-level status --json
  assert_equal "$(jq -c '.budget' <<<"$output")" '{"memory_bytes":2147483648,"cores":3.6,"bound_by":{"memory":"others","cores":"share"}}'
  # Leaving less than nothing is 0; a newer reading without CPU keeps the newest one with it.
  reading 0 30
  run_bin -0 --separate-stderr team-level status --json
  assert_equal "$(jq -c '.budget' <<<"$output")" '{"memory_bytes":0,"cores":3.6,"bound_by":{"memory":"others","cores":"share"}}'

  run_bin -0 team-level none
  run_bin -0 --separate-stderr team-level status --json
  assert_equal "$(jq -c '[.share, .budget.memory_bytes, .budget.cores]' <<<"$output")" '[0,0,0]'
  run_bin -0 team-level status
  assert_contains "$output" "Resources: manual, none (0%): 0.0 GiB and 0.0 cores for the team"
  assert_contains "$output" "  last change: manual none by Daniel at "
}

@test "with no reading with CPU the cores are the share of the machine's" {
  reading 1 8
  run_bin -0 team-level minor
  run_bin -0 --separate-stderr team-level status --json
  assert_equal "$(jq -c '.budget | [.cores, .bound_by.cores]' <<<"$output")" '[3.6,"share"]'
  run_bin -0 team-level status
  assert_contains "$output" "  cores: 3.6, bound by the share (no reading of the CPU yet: 30% of 12)"
}

@test "a level change holds the slice and the team's containers to the budget" {
  STACKS='[{"name": "conventioner-2", "class": "team", "task": "T7", "project": "conventioner", "memory": 1073741824, "cpu": 0.1, "limits": 2147483648}]'
  reading 1 8 2
  slice_use 1
  run_bin -0 --separate-stderr team-level minor
  # MemoryHigh: minor's 9.6 GiB less the stack's 2 GiB reserved, MemoryMax 1 GiB above it.
  assert_equal "$(slice_calls)" "CPUQuota=360% MemoryHigh=$((10307921510 - 2 * GIB)) MemoryMax=$((10307921510 - GIB))"
  assert_equal "$(cat "$SLICE_STATE.CPUQuotaPerSecUSec")" "3.600000s"
  # Every running container labelled owner=agent-team, never the gate's or Daniel's.
  assert_equal "$(update_calls)" "update --cpus 3.6 $(jq -r '[.[] | select(.State.Running and .Config.Labels["io.github.chanjdaniel.team.owner"] == "agent-team")] | sort_by(.Created) | reverse | map(.Id) | join(" ")' "$DOCKER_STATE/containers.json")"
  assert_equal "$(jq -c '[.[] | select(.HostConfig.NanoCpus != null) | .Name]' "$DOCKER_STATE/containers.json")" '["/conventioner-2-mongodb-1","/conventioner-2-backend-1"]'
  assert_equal "$(jq -c '{mode, level, cpu_quota_percent, cpus}' "$HOME/.local/state/agent-team/level/applied.json")" '{"mode":"manual","level":"minor","cpu_quota_percent":360,"cpus":3.6}'
  assert_equal "$output" "Resources: manual, minor (30%): 9.6 GiB and 3.6 cores for the team; 2.5 GiB reserved."
  assert_equal "$stderr" ""

  # status splits what is reserved: the builder's use, its allowance (its 0.5 GiB seed less that
  # use) and the stack's 2 GiB of mem_limits.
  run_bin -0 --separate-stderr team-level status --json
  assert_equal "$(jq -c '.reserved_split' <<<"$output")" \
    "{\"sessions_use\":536870912,\"spike_allowance\":0,\"admissions\":0,\"stacks\":$((2 * GIB)),\"heavy_runs\":0,\"gates\":0}"
  run_bin -0 team-level status
  assert_contains "$output" "
  reserved 2.5 GiB: sessions' use 0.5 GiB, spike allowance 0.0 GiB, admissions 0.0 GiB, stacks 2.0 GiB, heavy runs 0.0 GiB, gates 0.0 GiB
"

  # apply says each limit it set.
  run_bin -0 team-level apply
  assert_equal "$output" "held agent-team.slice to CPUQuota=360% MemoryHigh=7.6 GiB MemoryMax=8.6 GiB
held 2 team containers to --cpus 3.6"
}

@test "MemoryMax is never below the slice's use plus 1 GiB, and MemoryHigh never throttles the use down" {
  reading 1 8 2
  slice_use 12
  run_bin -0 team-level minor
  # Over minor's 9.6 GiB: held at the use, 1 GiB above it, until stows bring it down.
  assert_equal "$(slice_calls)" "CPUQuota=360% MemoryHigh=$((12 * GIB)) MemoryMax=$((13 * GIB))"
  # The use falls: MemoryHigh follows it down; a use that grows again is not followed up.
  : >"$STUB_CALLS/systemctl.log"
  slice_use 10.5
  run_bin -0 team-level apply
  slice_use 11
  run_bin -0 team-level apply
  assert_equal "$(slice_calls)" "CPUQuota=360% MemoryHigh=$((21 * GIB / 2)) MemoryMax=$((23 * GIB / 2))
CPUQuota=360% MemoryHigh=$((21 * GIB / 2)) MemoryMax=$((12 * GIB))"
  # Under the budget: the budget's part.
  : >"$STUB_CALLS/systemctl.log"
  slice_use 3
  run_bin -0 team-level apply
  assert_equal "$(slice_calls)" "CPUQuota=360% MemoryHigh=10307921510 MemoryMax=$((10307921510 + GIB))"
}

@test "at none the CPU quota and the containers keep min_cores and an empty slice keeps min_gib" {
  reading 1 8 2
  slice_use 0
  run_bin -0 team-level none
  assert_equal "$(slice_calls)" "CPUQuota=100% MemoryHigh=$((2 * GIB)) MemoryMax=$((3 * GIB))"
  assert_equal "$(update_calls | cut -d' ' -f1-3)" "update --cpus 1"
  # The floors are capacity.json's.
  : >"$STUB_CALLS/systemctl.log"
  echo '{"min_cores": 0.5, "min_gib": 1}' >"$HOME/.config/agent-team/capacity.json"
  run_bin -0 team-level apply
  assert_equal "$(slice_calls)" "CPUQuota=50% MemoryHigh=$GIB MemoryMax=$((2 * GIB))"
  assert_equal "$(cat "$SLICE_STATE.CPUQuotaPerSecUSec")" "500ms"
}

@test "a slice that is not installed is said with its fix, and the containers are still held" {
  reading 1 8 2
  rm "$UNITS/agent-team.slice"
  run_bin -0 --separate-stderr team-level minor
  assert_equal "$stderr" "team-level: agent-team.slice is not installed, so the team's sessions, heavy runs and gate runs are not held; fix: team-capacity install (Daniel's yes)"
  assert_equal "$(slice_calls)" ""
  assert_equal "$(update_calls | cut -d' ' -f1-3)" "update --cpus 3.6"
  # apply too, and passes: there was nothing to set on the slice.
  run_bin -0 --separate-stderr team-level apply
  assert_equal "$output" "held 2 team containers to --cpus 3.6"
}

@test "a limit that cannot be set is said, the record stands, and apply fails" {
  reading 1 8 2
  docker_down
  run_bin -0 --separate-stderr team-level minor
  assert_contains "$stderr" "team-level: Docker does not answer, so no team container's CPU is held (Cannot connect to the Docker daemon"
  assert_equal "$(jq -r .level "$RECORD")" minor
  # Docker down holds nothing to hold; a refused set-property fails apply.
  run_bin -0 --separate-stderr team-level apply
  touch "$HOME/.fake-systemd/down"
  run_bin -1 --separate-stderr team-level apply
  assert_contains "$stderr" "team-level: could not set agent-team.slice's limits (systemctl --user set-property: Failed to connect to user scope bus"
}

@test "on macOS only the containers' CPU is held" {
  as_macos
  reading 1 8 2
  run_bin -0 --separate-stderr team-level minor
  assert_equal "$stderr" "team-level: no cgroups on macOS: only the team's containers' CPU is held"
  assert_equal "$(slice_calls)" ""
  assert_equal "$(update_calls | cut -d' ' -f1-3)" "update --cpus 3.6"
}

@test "a change and apply refuse on a machine that does not hold the lease; status still reads" {
  reading 1 8 2
  make_machine laptop
  steal_lease laptop home-pc
  run_bin -1 team-level minor
  assert_contains "$output" "laptop holds the lease"
  run_bin -1 team-level apply
  assert_contains "$output" "laptop holds the lease"
  [[ ! -e $RECORD ]]
  run_bin -0 team-level status
  assert_contains "$output" "Resources: manual, full (90%)"
}

@test "a line of level.jsonl that is not a level record is refused, naming it" {
  reading 1 8 2
  run_bin -0 team-level minor
  echo '{"mode": "manual", "level": "half"}' >>"$RECORD"
  echo 'not json' >>"$RECORD"
  run_bin -1 team-level status
  assert_equal "$output" "team-level: $RECORD has lines that are not level records ({ts, mode, level, by, machine}): line 2, 3; fix or remove them, then run it again"
  run_bin -1 team-level none
  assert_equal "$(wc -l <"$RECORD")" 3
}

@test "with no reading at all the budget is unknown and no limit is set" {
  run_bin -0 --separate-stderr team-level status --json --stored
  assert_equal "$(jq -c '[.budget.memory_bytes, .reading, .use]' <<<"$output")" '[null,null,{"memory_bytes":null,"cores":null}]'
  assert_equal "$(jq -r .says <<<"$output")" "manual, full (90%): no reading of the machine's load yet, so no budget"
  # A machine whose memory cannot be read gives no reading to take either.
  export TEAM_MEMINFO=$BATS_TEST_TMPDIR/no-meminfo
  run_bin -1 --separate-stderr team-level apply
  assert_contains "$stderr" "team-level: no reading of the machine's load, so no limit is set: team-capacity sample says why it takes none"
  assert_equal "$(slice_calls)" ""
}

# On reading's 32 GiB, 12-core machine, with 4 GiB and 1 core kept free for the other programs:
# 8 GiB and 2 cores leave (32 - 8 - 4) / 32 = 0.625 and (12 - 2 - 1) / 12 = 0.75, full;
# 16 GiB leave 0.375, minor; 25 GiB leave 0.09, none.

@test "auto records automatic mode at the level it picks now and acknowledges it" {
  reading 1 16 2
  run_bin -0 team-level auto --message 1234567890
  assert_equal "$output" "Resources: auto, now minor (30%): 9.6 GiB and 3.6 cores for the team; 0.5 GiB reserved."
  assert_equal "$(jq -c '[.mode, .level, .by, .machine, .discord_message, .reading.pick, .reading.free]' "$RECORD")" \
    '["auto","minor","Daniel","home-pc","1234567890","minor",0.38]'
  assert_equal "$(jq -r .reason "$RECORD")" "other programs use 16.0 GiB of 32.0 GiB and 2.0 of 12 cores"
  # It applies the new level's limits at once.
  assert_equal "$(slice_calls | cut -d' ' -f1)" "CPUQuota=360%"
  # Already automatic: the level is auto's to change, so nothing is recorded.
  reading 0 8 2
  run_bin -0 team-level auto
  assert_equal "${lines[0]}" "Nothing recorded: the team is already auto, now minor."
  assert_equal "$(wc -l <"$RECORD")" 1
  run_bin -0 team-level status
  assert_contains "$output" "Resources: auto, now minor (30%): "
  assert_contains "$output" "  last change: auto minor by Daniel at "
  # From manual none, on memory alone (the newest reading has no CPU): full.
  run_bin -0 team-level none
  reading 0 8
  run_bin -0 team-level auto
  assert_equal "$(tail -n 1 "$RECORD" | jq -c '[.mode, .level, .by, .reason]')" '["auto","full","Daniel","other programs use 8.0 GiB of 32.0 GiB"]'
}

@test "tick drops the level at once on one reading that picks lower, and posts the change" {
  discord_answers
  change 30 auto full
  reading 10 8 2
  reading 5 8 2
  reading 1 16 2
  run_bin -0 --separate-stderr team-level tick
  [[ $output =~ ^"Resources: auto lowered the team to minor (30%) at "[0-9]{2}:[0-9]{2}": other programs use 16.0 GiB of 32.0 GiB and 2.0 of 12 cores"$ ]]
  assert_equal "$(levels | paste -sd' ')" '["full","Daniel"] ["minor","auto"]'
  assert_equal "$(tail -n 1 "$RECORD" | jq -c '[.mode, .reason, .reading.others_memory, .reading.pick]')" \
    "[\"auto\",\"other programs use 16.0 GiB of 32.0 GiB and 2.0 of 12 cores\",$((16 * GIB)),\"minor\"]"
  assert_equal "$(posts)" "$(jq -n --arg s "$output" '$s')"
  # The new level's limits are applied in the same step.
  assert_equal "$(slice_calls | cut -d' ' -f1)" "CPUQuota=360%"
  # Another reading picking none drops again, at once, though the last change is a minute old.
  reading 0 25 2
  run_bin -0 --separate-stderr team-level tick
  [[ $output =~ ^"Resources: auto lowered the team to none (0%) at "[0-9:]{5}": other programs use 25.0 GiB of 32.0 GiB and 2.0 of 12 cores"$ ]]
  assert_equal "$(levels | tail -n 1)" '["none","auto"]'
  assert_equal "$(posts | wc -l)" 2
  # A reading that picks the same level changes nothing and posts nothing.
  reading 0 25 2
  run_bin -0 --separate-stderr team-level tick
  assert_equal "$output" ""
  assert_equal "$(wc -l <"$RECORD")" 3
  assert_equal "$(posts | wc -l)" 2
}

@test "tick raises the level only after rise_minutes of readings above it, to the lowest of their picks" {
  discord_answers
  change 60 auto none auto
  # Higher picks for less than rise_minutes (15): the reading 20 minutes ago still picks none.
  reading 20 25 2
  reading 14 8 2
  reading 10 8 2
  reading 5 8 2
  reading 1 8 2
  run_bin -0 --separate-stderr team-level tick
  assert_equal "$output" ""
  assert_equal "$(wc -l <"$RECORD")" 1
  # No reading rise_minutes old: one spike never raises it.
  no_readings
  reading 1 8 2
  run_bin -0 --separate-stderr team-level tick
  assert_equal "$output" ""
  assert_equal "$(wc -l <"$RECORD")" 1
  # Readings picking higher for rise_minutes: raised to the lowest pick among them, minor.
  no_readings
  reading 20 8 2
  reading 15 16 3
  reading 10 8 2
  reading 5 8 2
  reading 1 8 2
  run_bin -0 --separate-stderr team-level tick
  [[ $output =~ ^"Resources: auto raised the team to minor (30%) at "[0-9:]{5}": other programs use 16.0 GiB of 32.0 GiB and 3.0 of 12 cores"$ ]]
  assert_equal "$(levels | tail -n 1)" '["minor","auto"]'
  assert_equal "$(posts | wc -l)" 1
  # The change is less than rise_minutes old, so full's readings wait.
  no_readings
  reading 20 8 2
  reading 10 8 2
  reading 1 8 2
  run_bin -0 --separate-stderr team-level tick
  assert_equal "$output" ""
  assert_equal "$(levels | tail -n 1)" '["minor","auto"]'
  # Once it is, they raise it to full; rise_minutes is capacity.json's.
  change 16 auto minor auto
  echo '{"rise_minutes": 30}' >"$HOME/.config/agent-team/capacity.json"
  run_bin -0 --separate-stderr team-level tick
  assert_equal "$output" ""
  rm "$HOME/.config/agent-team/capacity.json"
  run_bin -0 --separate-stderr team-level tick
  [[ $output =~ ^"Resources: auto raised the team to full (90%) at "[0-9:]{5}": other programs use 8.0 GiB of 32.0 GiB and 2.0 of 12 cores"$ ]]
  assert_equal "$(levels | tail -n 1)" '["full","auto"]'
}

@test "a post that fails is said, kept, and posted once on a later tick" {
  discord_answers 503
  change 30 auto full
  reading 1 16 2
  run_bin -1 --separate-stderr team-level tick
  [[ $output =~ ^"Resources: auto lowered the team to minor (30%) at "[0-9:]{5}": " ]]
  local said=$output
  assert_equal "$stderr" "team-level: the post to #coordinator failed (curl: (22) The requested URL returned error: 503); it is tried again on the next tick"
  # The change stands, and its limits are applied.
  assert_equal "$(levels | tail -n 1)" '["minor","auto"]'
  assert_equal "$(slice_calls | cut -d' ' -f1)" "CPUQuota=360%"
  assert_equal "$(jq -c '.pending | length' "$HOME/.local/state/agent-team/level/posted.json")" 1
  # Discord answers: the kept post goes, once, and the tick has nothing new to say.
  : >"$STUB_CALLS/curl.log"
  discord_answers
  run_bin -0 --separate-stderr team-level tick
  assert_equal "$output" ""
  assert_equal "$(posts)" "$(jq -n --arg s "$said" '$s')"
  run_bin -0 --separate-stderr team-level tick
  assert_equal "$(posts | wc -l)" 1
  assert_equal "$(jq -c '.pending' "$HOME/.local/state/agent-team/level/posted.json")" '[]'
}

@test "in manual mode tick changes no level and still applies the limits" {
  stub_reply curl "curl must not be called" 99
  change 30 manual minor
  reading 1 25 2
  run_bin -0 --separate-stderr team-level tick
  assert_equal "$output" ""
  assert_equal "$(levels)" '["minor","Daniel"]'
  assert_equal "$(slice_calls | cut -d' ' -f1)" "CPUQuota=360%"
  assert_equal "$(stub_calls curl)" ""
  # With no record at all: manual full's limits, and still no record.
  rm "$RECORD"
  : >"$STUB_CALLS/systemctl.log"
  run_bin -0 --separate-stderr team-level tick
  [[ ! -e $RECORD ]]
  assert_equal "$(slice_calls | cut -d' ' -f1)" "CPUQuota=900%"
}

@test "with no reading of the last 15 minutes tick changes no level and says so" {
  stub_reply curl "curl must not be called" 99
  change 60 auto full auto
  reading 20 25 2
  run_bin -0 --separate-stderr team-level tick
  assert_equal "$output" "no reading of the machine's load in the last 15 minutes, so auto keeps the team at full"
  assert_equal "$(wc -l <"$RECORD")" 1
  # The limits are still applied, from the newest reading.
  assert_equal "$(slice_calls | cut -d' ' -f1)" "CPUQuota=900%"
  # tick takes no reading itself: the heartbeat's capacity step does.
  assert_equal "$(wc -l <"$HOME/.local/state/agent-team/capacity/readings.jsonl")" 1
}

@test "tick refuses on a machine that does not hold the lease" {
  change 30 auto full
  reading 1 25 2
  make_machine laptop
  steal_lease laptop home-pc
  run_bin -1 team-level tick
  assert_contains "$output" "laptop holds the lease"
  assert_equal "$(wc -l <"$RECORD")" 1
}
