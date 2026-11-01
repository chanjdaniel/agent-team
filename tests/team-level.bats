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

@test "a malformed command line is a usage error, and automatic mode is not built yet" {
  run_bin -2 team-level nope
  assert_contains "$output" "unknown subcommand 'nope'"
  run_bin -2 team-level minor now
  assert_contains "$output" "unexpected argument 'now'"
  run_bin -2 team-level minor --message abc
  assert_contains "$output" "--message takes a Discord message id"
  run_bin -2 team-level status --yaml
  assert_contains "$output" "unexpected argument '--yaml'"
  run_bin -1 team-level auto
  assert_equal "$output" "team-level: automatic mode is not built yet: set a level with team-level full, minor or none"
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
