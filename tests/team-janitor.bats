#!/usr/bin/env bats
# team-janitor: the daily reap, report and alerts, on the stub docker (tests/helpers/docker.bash),
# whose fixture machine the reaper finds three stacks to remove on (a team stack whose worktree is
# gone and two expired gate stacks), and Discord stubbed (curl).

load helpers/common
load helpers/docker

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stack_project shop
  docker_stub "$STACK_WORKTREE"
  reap_machine
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  discord_answers
  JANITOR=$HOME/.local/state/agent-team/janitor
  TODAY=$(date +%F)
  REPORT=$JANITOR/$TODAY.md
}

# Fail when any docker call of the test pruned: every removal names its object.
teardown() {
  if [[ -n ${DOCKER_STATE:-} ]] && docker_calls | grep -E '(system|volume|image|network|builder|buildx|container) prune'; then
    echo "a docker call pruned" >&2
    return 1
  fi
}

# Discord answers each post (curl) with a message id, or with <status> and an error when given.
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

# The content of each post to #coordinator, one per line.
posts() {
  stub_calls curl | jq -r 'select(.[-1] == "https://discord.com/api/v10/channels/1562486564871995482/messages")
    | .[index("-d") + 1] | fromjson | .content'
}

# The section <title> of the report <file> (default the day's): its lines between its heading
# and the next, without the blank lines.
section() {
  awk -v title="## $1" '$0 == title { on = 1; next } /^## / { on = 0 } on && NF' "${2:-$REPORT}"
}

# The report's section headings, in order.
headings() {
  grep '^## ' "${1:-$REPORT}"
}

# A disk with <gb> GB free of the stub df's 1024 GB (999999999 1024-byte blocks).
disk_free_gb() {
  machine_disk_free $(($1 * 1000000000 / 1024))
}

# Add an admission wait of <minutes> that ended <ago> minutes ago to waits.jsonl.
wait_for() {
  mkdir -p "$HOME/.local/state/agent-team/stacks"
  jq -cn --argjson m "$1" --argjson ago "$2" '{start: (now - ($ago + $m) * 60 | floor | todate),
    end: (now - $ago * 60 | floor | todate), project: "shop-1", task: "T22", admitted: true, reasons: ["6 of 6 stacks running (stack_cap 6)"]}' \
    >>"$HOME/.local/state/agent-team/stacks/waits.jsonl"
}

@test "team-janitor answers --help with its header and refuses a malformed command line" {
  run_bin -0 team-janitor --help
  assert_contains "$output" "Usage: team-janitor [--dry-run]"
  run_bin -2 --separate-stderr team-janitor --apply
  assert_equal "$stderr" "team-janitor: usage: team-janitor [--dry-run]"
  assert_equal "$(docker_calls)" ""
}

# Every removal names its object, so no team script prunes (sops/docker.md).
@test "team-janitor runs no prune command" {
  if grep -nE 'docker[^|;&]*(system|volume|image|network|builder|buildx|container) prune' "$REPO_ROOT/bin/team-janitor"; then
    echo "bin/team-janitor prunes" >&2
    return 1
  fi
}

@test "with no alert, the janitor reaps, writes the day's report with every section, alerts first, prints its summary and posts nothing" {
  run_bin -0 --separate-stderr team-janitor
  assert_equal "$stderr" ""
  local gone=$HOME/.treehouse/Conventioner-d4c77a/4/Conventioner
  # The reaper ran for real, with this team home.
  docker_calls | grep -qx 'compose -p nmtest-1895520 down -v --remove-orphans'
  assert_equal "$(headings)" "## Alerts
## Disk
## Docker's totals
## Stacks
## Removed
## Kept as not the team's"
  assert_equal "$(head -n 1 "$REPORT")" "# Docker on home-pc, $TODAY"
  [[ $(sed -n 3p "$REPORT") =~ ^Written\ by\ team-janitor\ at\ [0-9]{2}:[0-9]{2},\ after\ team-stack\ reap\ --apply\.$ ]]
  assert_equal "$(section Alerts)" "None."
  assert_equal "$(section Disk)" "214.7 GB free and 102.4 GB used of 1.0 TB (21.0% free), on the file system of /var/lib/docker."
  assert_equal "$(section "Docker's totals" | head -n 3)" "| Type | Count | Active | Size | Reclaimable |
| - | - | - | - | - |
| Images | 7 | 3 | 3.903GB | 1.862GB (47%) |"
  [[ $(section "Docker's totals" | sed -n 4p) == '| Containers | '* ]]
  [[ $(section "Docker's totals" | sed -n 5p) == '| Local Volumes | '* ]]
  # The stacks left after the reap, running and stopped, with class, task, kind, age and memory.
  local stacks
  stacks=$(section Stacks)
  assert_equal "$(sed -n 1,2p <<<"$stacks")" "| Project | Status | Class | Task | Kind | Age | Memory |
| - | - | - | - | - | - | - |"
  [[ $(sed -n 3p <<<"$stacks") =~ ^\|\ conventioner\ \|\ exited\(2\)\ \|\ unowned\ \|\ -\ \|\ -\ \|\ [0-9]+[smhd]\ \|\ -\ \|$ ]]
  [[ $(sed -n 4p <<<"$stacks") =~ ^\|\ conventioner-2\ \|\ running\(2\)\ \|\ team\ \|\ T7\ \|\ dev\ \|\ [0-9]+[smhd]\ \|\ 599.8\ MiB\ \|$ ]]
  [[ $(sed -n 5p <<<"$stacks") == '| conventioner-3 | running(1) | unowned |'* ]]
  assert_equal "$(wc -l <<<"$stacks")" 5
  local removed
  removed=$(section Removed)
  assert_equal "$(sed -n 1p <<<"$removed")" "- stack conventioner-4 (team, 0 B): its worktree $gone is gone; its logs in $HOME/.local/state/agent-team/stacks/logs/conventioner-4-$TODAY"
  assert_equal "$(sed -n 2,3p <<<"$removed")" "- stack nmtest-12822 (gate, 0 B): it has no expires and was created at 2026-10-21T08:00:00Z, over 2 hours ago
- stack nmtest-1895520 (gate, 509.1 MB): it expired at 2026-10-24T12:55:00Z"
  assert_equal "$(sed -n 4p <<<"$removed")" "Removed 3 objects, 509.1 MB: 1 team stack (0 B), 2 gate stacks (509.1 MB); kept 14 objects that are not the team's, 4.7 GB."
  [[ $(section "Kept as not the team's" | head -n 1) =~ ^-\ stack\ conventioner\ \(unowned,\ 1.5\ GB,\ [0-9]+[smhd]\ old\)$ ]]
  assert_equal "$(section "Kept as not the team's" | wc -l)" 14
  # One paragraph on stdout, alerts first.
  assert_equal "${#lines[@]}" 1
  assert_equal "$output" "No alerts. Removed 3 objects, 509.1 MB: 1 team stack (0 B), 2 gate stacks (509.1 MB); kept 14 objects that are not the team's, 4.7 GB. Disk: 214.7 GB free of 1.0 TB (21.0%). Stacks: 2 running, 1 stopped. Report: ~/.local/state/agent-team/janitor/$TODAY.md."
  assert_equal "$(stub_calls curl)" ""
  [[ ! -e $JANITOR/posted-$TODAY.json ]]
}

@test "free disk under 50 GB or under 15% is an alert, posted to #coordinator with a timeout and remembered for the day" {
  disk_free_gb 40
  run_bin -0 --separate-stderr team-janitor
  assert_equal "$stderr" ""
  local alert="disk: 40.0 GB free of 1.0 TB (3.9%) on the file system of /var/lib/docker, under 15% or 50 GB"
  assert_equal "$(section Alerts)" "- $alert; posted to #coordinator"
  assert_equal "$(posts)" "Docker on home-pc: $alert. The day's report: ~/.local/state/agent-team/janitor/$TODAY.md"
  stub_calls curl | jq -e '.[index("--max-time") + 1] == "20"' >/dev/null
  jq -e 'keys == ["disk"] and (.disk | fromdateiso8601)' "$JANITOR/posted-$TODAY.json" >/dev/null
  [[ $output == "1 alert: $alert. Removed 3 objects"* ]]
  # Over 50 GB but under 15% of the disk is an alert too.
  rm "$JANITOR/posted-$TODAY.json"
  disk_free_gb 120
  run_bin -0 team-janitor
  assert_equal "$(section Alerts)" "- disk: 120.0 GB free of 1.0 TB (11.7%) on the file system of /var/lib/docker, under 15% or 50 GB; posted to #coordinator"
}

@test "on macOS the disk is the home directory's, where Docker Desktop keeps its disk image" {
  as_macos
  disk_free_gb 40
  run_bin -0 team-janitor
  [[ $(section Disk) == *"on the file system of $HOME." ]]
  [[ $(section Alerts) == *"on the file system of $HOME, under 15% or 50 GB; posted to #coordinator" ]]
}

@test "a container killed for memory in the last 24 hours is an alert, naming it and when" {
  docker_event oom conventioner-2-backend-1 3600
  docker_event oom conventioner-3-backend-1 $((25 * 3600))
  docker_event die conventioner-2-mongodb-1 60
  run_bin -0 team-janitor
  local at
  at=$(date -d "@$(jq -r '.[0].time' "$DOCKER_STATE/events.json")" +%H:%M)
  local alert="oom: 1 container killed for memory in the last 24 hours: conventioner-2-backend-1 at $at"
  assert_equal "$(section Alerts)" "- $alert; posted to #coordinator"
  assert_equal "$(posts)" "Docker on home-pc: $alert. The day's report: ~/.local/state/agent-team/janitor/$TODAY.md"
  # The last 24 hours, by the clock.
  local since until
  read -r since until < <(docker_calls | sed -n -E 's/^events --since ([0-9]+) --until ([0-9]+) --filter event=oom --format json$/\1 \2/p')
  assert_equal "$((until - since))" 86400
}

@test "admission waits adding up to more than an hour in the last 24 hours are an alert; an hour or less is not" {
  wait_for 40 30
  wait_for 20 600
  wait_for 120 $((25 * 60))
  run_bin -0 team-janitor
  assert_equal "$(section Alerts)" "None."
  # A wait that began before the last 24 hours counts only its part inside them.
  wait_for 120 $((24 * 60 - 5))
  run_bin -0 team-janitor
  assert_equal "$(section Alerts)" "- waits: stacks waited 65 minutes for room in the last 24 hours, over an hour (3 waits, 0 not admitted); posted to #coordinator"
}

@test "a failed removal is an alert, posted with Docker's reason as it gave it, the others still made, and the run exits 1" {
  # A backslash in the reason reaches the report and the post unescaped.
  docker_fail 'compose down' 'Error response from daemon: removal of container nmtest-12822-backend-1 is already in progress on \\.\pipe\docker_engine'
  run_bin -1 --separate-stderr team-janitor
  local alert='removal: 3 removals failed: stack conventioner-4 (team, 0 B): docker compose down of conventioner-4 failed: Error response from daemon: removal of container nmtest-12822-backend-1 is already in progress on \\.\pipe\docker_engine'

  [[ $(section Alerts) == "- $alert; "*"; posted to #coordinator" ]]
  assert_equal "$(section Removed | grep -c '^- could not remove ')" 3
  assert_equal "$(section Removed | tail -n 1)" "Removed nothing; 3 removals failed; kept 14 objects that are not the team's, 4.7 GB."
  [[ $(posts) == "Docker on home-pc: $alert; "* ]]
  assert_contains "$stderr" "team-stack: could not remove stack conventioner-4 (team, 0 B): docker compose down of conventioner-4 failed"
  [[ $output == "1 alert: $alert; "* ]]
}

@test "a reaper that fails says why in the report, and a part of the report that cannot be read says why too, exit 1" {
  docker_fail 'system df' "Error response from daemon: a disk usage operation is already running"
  run_bin -1 --separate-stderr team-janitor
  local reason="Error response from daemon: a disk usage operation is already running"
  assert_equal "$(section Removed)" "The reaper failed: docker system df failed: $reason."
  assert_equal "$(section "Kept as not the team's")" "None."
  assert_equal "$(section "Docker's totals")" "Could not be read: docker system df: $reason."
  # The rest is still reported.
  [[ $(section Stacks | sed -n 3p) == '| conventioner | '* ]]
  assert_equal "$stderr" "team-stack: docker system df failed: $reason"
  [[ $output == "No alerts. The reaper failed: docker system df failed: $reason. Disk: "* ]]
}

@test "a second run on the same day replaces the day's report and posts no alert kind already posted that day" {
  disk_free_gb 40
  run_bin -0 team-janitor
  assert_equal "$(posts | wc -l)" 1
  docker_event oom conventioner-2-backend-1 60
  run_bin -0 team-janitor
  assert_equal "$(ls "$JANITOR")" "$TODAY.md
posted-$TODAY.json"
  assert_equal "$(section Alerts | sed -E 's/: .*;/:;/')" "- disk:; already posted today
- oom:; posted to #coordinator"
  # The second run's reaper found nothing left to remove.
  assert_equal "$(section Removed)" "Nothing to remove; kept 14 objects that are not the team's, 4.7 GB."
  assert_equal "$(posts | wc -l)" 2
  [[ $(posts | tail -n 1) == "Docker on home-pc: oom: "* ]]
  jq -e 'keys == ["disk", "oom"]' "$JANITOR/posted-$TODAY.json" >/dev/null
}

@test "a failed post is in the report and on stderr, is tried again on the next run, and fails nothing" {
  disk_free_gb 40
  discord_answers 503
  run_bin -0 --separate-stderr team-janitor
  local reason="curl: (22) The requested URL returned error: 503"
  [[ $(section Alerts) == "- disk: "*"; the post to #coordinator failed: $reason" ]]
  assert_equal "$stderr" "team-janitor: the post of the disk alert to #coordinator failed: $reason"
  [[ ! -e $JANITOR/posted-$TODAY.json ]]
  discord_answers
  run_bin -0 team-janitor
  [[ $(section Alerts) == "- disk: "*"; posted to #coordinator" ]]
}

@test "Docker not answering is in the report and the summary, nothing posted, exit 1" {
  disk_free_gb 40
  docker_down
  run_bin -1 --separate-stderr team-janitor
  local reason="Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
  assert_equal "$(section Alerts)" "- Docker does not answer ($reason), so nothing was reaped and nothing of Docker is reported"
  assert_equal "$(headings)" "## Alerts"
  assert_equal "$output" "Docker does not answer ($reason), so nothing was reaped and nothing of Docker is reported. Report: ~/.local/state/agent-team/janitor/$TODAY.md."
  assert_equal "$stderr" "team-janitor: Docker does not answer: $reason"
  assert_equal "$(stub_calls curl)" ""
}

@test "--dry-run runs the reaper's dry run, writes the day's dry-run report beside the real one, and posts nothing" {
  run_bin -0 team-janitor
  local real
  real=$(cat "$REPORT")
  : >"$STUB_CALLS/docker.log"
  # Back to the fixture's machine, so the dry run has stacks to remove.
  docker_stub "$STACK_WORKTREE"
  reap_machine
  disk_free_gb 40
  run_bin -0 team-janitor --dry-run
  local dry=$JANITOR/$TODAY-dry-run.md
  assert_equal "$(head -n 1 "$dry")" "# Docker on home-pc, $TODAY (dry run)"
  [[ $(sed -n 3p "$dry") == *", after team-stack reap --dry-run, which removed nothing." ]]
  assert_equal "$(headings "$dry")" "## Alerts
## Disk
## Docker's totals
## Stacks
## Would remove
## Kept as not the team's"
  [[ $(section Alerts "$dry") == "- disk: "*"; not posted (a dry run)" ]]
  assert_equal "$(section 'Would remove' "$dry" | tail -n 1)" "Would remove 3 objects, 509.1 MB: 1 team stack (0 B), 2 gate stacks (509.1 MB); kept 14 objects that are not the team's, 4.7 GB."
  [[ $output == "1 alert: disk: "*". Would remove 3 objects, "*"Report: ~/.local/state/agent-team/janitor/$TODAY-dry-run.md." ]]
  # Nothing removed, nothing posted, the real report untouched.
  if docker_calls | grep -E '^(compose -p [^ ]+ (down|stop)|volume rm|image rm|network rm)'; then return 1; fi
  assert_equal "$(stub_calls curl)" ""
  [[ ! -e $JANITOR/posted-$TODAY.json ]]
  assert_equal "$(cat "$REPORT")" "$real"
}
