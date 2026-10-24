#!/usr/bin/env bats
# team-handoff: the machine being left stops its workers' sessions, checkpoints, pushes its task
# branches, stows each open task in the ledger, captures its Claude config, commits and pushes the
# team home, disables its heartbeat and releases the lease; then --retire removes the coordinator.
# One git-pool project, home, on a bare origin; home-pc holds the lease on the team home's bare
# origin with its heartbeat enabled, and T1 is open there with a live builder (stubbed claude).

load helpers/common

setup() {
  sandbox
  home=$(make_repo home)
  printf '.scratch/\n' >"$home/.gitignore"
  git -C "$home" add .gitignore
  git -C "$home" commit -q -m "chore: ignore scratch"
  git -C "$home" push -q origin main
  home_origin=$BATS_TEST_TMPDIR/origin/home.git
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[home]
repo = "owner/home"
path = "projects/home"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[home.pool]
provider = "git"
slots = ["slots/home/1", "slots/home/2"]
TOML
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  team_origin=$(hold_lease home-pc)
  stub_reply curl '{"id":"1563000000000000001"}'
  fake_service_managers
  "$REPO_ROOT/bin/team-timers" enable >/dev/null
  state=$HOME/.local/state/agent-team
  mkdir -p "$HOME/.claude"
  echo "Shared instructions." >"$HOME/.claude/CLAUDE.md"

  # claude: agents --json from sessions.json; stop marks a session stopped, rm takes it off the
  # list; no plugins and no marketplaces.
  cat >"$BATS_TEST_TMPDIR/sessions.json" <<'JSON'
[{"id": "3169fcbd", "sessionId": "3169fcbd-1111", "name": "coordinator", "status": "busy", "state": "working"},
 {"id": "81f08540", "sessionId": "81f08540-1111", "name": "T1-builder", "status": "idle", "state": "done"},
 {"id": "22222222", "sessionId": "22222222-1111", "name": "coordinator-notes", "status": "idle", "state": "done"},
 {"id": "44444444", "sessionId": "44444444-1111", "name": "my-T1-builder", "status": "idle", "state": "done"}]
JSON
  stub_script claude <<'SH'
list=$BATS_TEST_TMPDIR/sessions.json
case "$*" in
  'agents --json') cat "$list" ;;
  'stop '*) jq --arg id "$2" 'map(if .id == $id then .status = "stopped" else . end)' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  'rm '*) jq --arg id "$2" 'map(select(.id != $id))' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  'plugin list --json' | 'plugin marketplace list --json') echo '[]' ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 64 ;;
esac
SH

  run_bin -0 team-open home feature feat work "Do the work"
  wt=$HOME/slots/home/1
  echo "spec" >"$wt/.scratch/task/spec.md"
  echo "a" >"$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m "feat: a"
  head=$(git -C "$wt" rev-parse HEAD)
}

# The claude stop and rm calls, one "<verb> <id>" per line.
stops_and_removes() {
  stub_calls claude | jq -r 'select(.[0] == "stop" or .[0] == "rm") | join(" ")'
}

# The ledger's stowed events, compact, one per line.
stowed_events() {
  jq -c 'select(.event == "stowed")' "$TEAM_HOME/ledger.jsonl"
}

# The subjects of the commits on the team home's origin, newest first.
team_subjects() {
  git -C "$team_origin" log --format=%s dev
}

# Everything a refused handoff must leave as it was: the ledger, the team home's HEAD and status,
# every ref on both origins, the session list and the heartbeat's units.
untouched_state() {
  cat "$TEAM_HOME/ledger.jsonl"
  git -C "$TEAM_HOME" rev-parse HEAD
  git -C "$TEAM_HOME" status --porcelain
  git -C "$team_origin" for-each-ref --format='%(objectname) %(refname)'
  git -C "$home_origin" for-each-ref --format='%(objectname) %(refname)'
  cat "$BATS_TEST_TMPDIR/sessions.json"
  find "$HOME/.config/systemd" -type f | sort
}

# Interrupt a handoff right after step <n>, run it again, and check it finished exactly once:
# one stowed, one handoff commit, one release, one stop and one rm; a third run changes nothing.
interrupt_after() {
  local lease_commits
  TEAM_HANDOFF_STOP_AFTER=$1 run_bin -1 --separate-stderr team-handoff
  assert_contains "$stderr" "team-handoff: stopped after step $1 (TEAM_HANDOFF_STOP_AFTER)"

  run_bin -0 team-handoff
  [[ ${lines[-2]} == "Released at "* ]]
  assert_equal "${lines[-1]}" "Config captured: CLAUDE.md (new)."
  assert_equal "$(stowed_events | jq -c 'del(.ts)')" \
    "{\"task\":\"T1\",\"event\":\"stowed\",\"machine\":\"home-pc\",\"worktrees\":[{\"project\":\"home\",\"branch\":\"feat/T1-work\",\"head\":\"$head\"}],\"roles\":[\"builder\"]}"
  assert_equal "$(team_subjects | grep -c '^chore: handoff from home-pc$')" 1
  # The stowed lands in the handoff's own commit, whatever step was interrupted.
  assert_contains "$(git -C "$team_origin" show "$(git -C "$team_origin" log --format=%H --grep '^chore: handoff' dev)" -- ledger.jsonl)" '"event":"stowed"'
  assert_equal "$(git -C "$team_origin" log --format=%s lease | grep -c release)" 1
  assert_equal "$(stops_and_removes)" "stop 81f08540
rm 81f08540"
  assert_equal "$(git -C "$home_origin" rev-parse feat/T1-work)" "$head"
  assert_equal "$(lease_json | jq -r .state)" released

  lease_commits=$(git -C "$team_origin" rev-parse lease dev)
  run_bin -0 team-handoff
  assert_equal "${lines[0]}" "lease: released by this handoff already, epoch 1"
  [[ ${lines[-2]} == "Released at "* ]]
  assert_equal "${lines[-1]}" "Config captured: CLAUDE.md (new)."
  assert_equal "$(git -C "$team_origin" rev-parse lease dev)" "$lease_commits"
  assert_equal "$(stowed_events | wc -l)" 1
}

@test "a handoff pushes the task branch, stows the task, stops only its worker, commits the records and releases the lease" {
  git -C "$TEAM_HOME" config core.hooksPath "$REPO_ROOT/bin/hooks/git"
  make_machine laptop

  run_bin -0 --separate-stderr team-handoff
  assert_equal "$stderr" ""
  assert_equal "${lines[0]}" "lease: home-pc holds the lease, epoch 1"
  assert_contains "$output" "checkpoint: T1 home: archived .scratch/task to tasks/T1/scratch"
  assert_contains "$output" "branches: T1 home: pushed feat/T1-work at ${head:0:7}"
  assert_contains "$output" "stowed: T1 roles builder; home feat/T1-work at ${head:0:7}"
  assert_contains "$output" "config: captured CLAUDE.md (new)"
  assert_contains "$output" "sessions: stopped and removed T1-builder (81f08540)"
  assert_contains "$output" "team home: committed $(git -C "$TEAM_HOME" rev-parse --short HEAD) chore: handoff from home-pc and pushed dev"
  assert_contains "$output" "heartbeat: "
  assert_contains "$output" "lease: home-pc released the lease, epoch 1"
  [[ ${lines[-2]} =~ ^"Released at "[0-9]{2}:[0-9]{2}" from home-pc. On the other machine run \`team-resume\`."$ ]]
  assert_equal "${lines[-1]}" "Config captured: CLAUDE.md (new)."
  # The workers stop before the checkpoint, so it holds their worktrees' last state.
  [[ $output == *"sessions: stopped and removed T1-builder"*"checkpoint: T1 home: "* ]]

  # Origin has the task branch at the worktree's commit.
  assert_equal "$(git -C "$home_origin" rev-parse feat/T1-work)" "$head"

  # One stowed, with that head and the live builder's role.
  assert_equal "$(stowed_events | jq -c 'del(.ts)')" \
    "{\"task\":\"T1\",\"event\":\"stowed\",\"machine\":\"home-pc\",\"worktrees\":[{\"project\":\"home\",\"branch\":\"feat/T1-work\",\"head\":\"$head\"}],\"roles\":[\"builder\"]}"

  # The worker's session alone was stopped and removed; the coordinator stays for --retire.
  assert_equal "$(stops_and_removes)" "stop 81f08540
rm 81f08540"

  # The team home's origin: the handoff's commit holds the stowed ledger, the scratch, the plan
  # and the captured config, and the checkout is clean.
  assert_equal "$(team_subjects | head -n 1)" "chore: handoff from home-pc"
  assert_contains "$(git -C "$team_origin" show dev:ledger.jsonl)" '"event":"stowed"'
  assert_equal "$(git -C "$team_origin" show dev:tasks/T1/scratch/spec.md)" "spec"
  assert_equal "$(git -C "$team_origin" show dev:machine/claude/CLAUDE.md)" "Shared instructions."
  git -C "$team_origin" cat-file -e dev:tasks/T1/plan.md
  assert_equal "$(git -C "$TEAM_HOME" status --porcelain)" ""

  # The heartbeat is disabled and the lease released.
  run -0 "$REPO_ROOT/bin/team-timers" status --json
  assert_equal "$(jq -c '[.installed, .enabled]' <<<"$output")" "[false,false]"
  assert_equal "$(lease_json | jq -c '[.holder, .epoch, .state]')" '["home-pc",1,"released"]'

  # The other machine takes the lease and finds everything there.
  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  assert_equal "$(lease_json | jq -c '[.holder, .epoch, .state]')" '["laptop",2,"held"]'
  on_machine laptop git -C "$BATS_TEST_TMPDIR/machines/laptop/team" pull -q
  assert_equal "$(jq -r 'select(.event == "stowed") | .worktrees[0].head' "$BATS_TEST_TMPDIR/machines/laptop/team/ledger.jsonl")" "$head"
}

@test "a worker that never stowed is stopped before the checkpoint, and its uncommitted changes are stowed as wip/home/T1 on the team home's origin" {
  # The builder edits, adds a file and a secret, and never answers STOW; stopping its session is
  # the last thing that happens to its worktree before the checkpoint.
  echo "edited" >"$wt/a.txt"
  echo "b" >"$wt/b.txt"
  echo "TOKEN=x" >"$wt/.env.local"
  stub_script claude <<'SH'
list=$BATS_TEST_TMPDIR/sessions.json
case "$*" in
  'agents --json') cat "$list" ;;
  'stop '*) jq --arg id "$2" 'map(if .id == $id then .status = "stopped" else . end)' "$list" >"$list.next" && mv "$list.next" "$list"
    echo "late" >"$HOME/slots/home/1/late.txt" ;;
  'rm '*) jq --arg id "$2" 'map(select(.id != $id))' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  'plugin list --json' | 'plugin marketplace list --json') echo '[]' ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 64 ;;
esac
SH

  run_bin -0 --separate-stderr team-handoff
  assert_contains "$output" "checkpoint: T1 home: left out of wip/home/T1, as files that may hold a secret: .env.local"
  assert_contains "$output" "branches: T1 home: uncommitted changes in $wt go with the checkpoint's wip/home/T1, which team-resume applies"
  assert_contains "$output" "branches: T1 home: untracked files that may hold a secret, left out of wip/home/T1, stay on home-pc: .env.local"
  assert_contains "$output" "stowed: T1 roles builder; home feat/T1-work at ${head:0:7} with uncommitted changes"

  # The snapshot holds what the session left as it stopped, the secret aside.
  local wip
  wip=$(git -C "$team_origin" rev-parse wip/home/T1)
  assert_equal "$(git -C "$team_origin" rev-parse "$wip^")" "$head"
  assert_equal "$(git -C "$team_origin" show "$wip:a.txt")" "edited"
  assert_equal "$(git -C "$team_origin" show "$wip:late.txt")" "late"
  assert_equal "$(git -C "$team_origin" ls-tree --name-only "$wip" | paste -sd ' ')" ".gitignore README.md a.txt b.txt late.txt"
  assert_equal "$(stowed_events | jq -c 'del(.ts)')" "$(jq -cn --arg h "$head" --arg wt "$wt" '{task: "T1", event: "stowed",
    machine: "home-pc", worktrees: [{project: "home", branch: "feat/T1-work", head: $h, uncommitted: true}],
    roles: ["builder"], note: "untracked files left out of wip/home/T1 stay on home-pc in \($wt): .env.local"}')"
}

@test "the final message lists the config captured and what was left to Daniel, again on a run after the release" {
  jq -n '{env: {API_TOKEN: "x"}}' >"$HOME/.claude/settings.json"
  run_bin -0 --separate-stderr team-handoff
  assert_contains "$stderr" "team-handoff: config: team-config capture did not capture everything; the handoff goes on
team-handoff: config: settings.json left to Daniel: it has an env key, which may hold a secret"
  assert_equal "$(printf '%s\n' "${lines[@]: -2}")" "Config captured: CLAUDE.md (new).
Config: settings.json left to Daniel: it has an env key, which may hold a secret."
  [[ ! -e $TEAM_HOME/machine/claude/settings.json ]]

  run_bin -0 team-handoff
  assert_equal "$(printf '%s\n' "${lines[@]: -2}")" "Config captured: CLAUDE.md (new).
Config: settings.json left to Daniel: it has an env key, which may hold a secret."
}

@test "a live ops session is ended with team-ops-end, its transcript and answer deleted, and never stowed" {
  # T1's ops session, on Daniel's request, beside its builder: a transcript and an answer file.
  local uuid=6f93fe38-4a6e-4b35-8f39-776a26bc624b transcript
  transcript=$HOME/.claude/projects/-slots-home-1/$uuid.jsonl
  mkdir -p "${transcript%.jsonl}" "$wt/.scratch"
  echo '{"query": "results"}' >"$transcript"
  echo "42 markets" >"$wt/.scratch/answer.md"
  jq --arg uuid "$uuid" --arg wt "$wt" '. + [{id: "6f93fe38", sessionId: $uuid, name: "T1-ops", status: "idle",
    state: "done", cwd: $wt}]' "$BATS_TEST_TMPDIR/sessions.json" >"$BATS_TEST_TMPDIR/sessions.next"
  mv "$BATS_TEST_TMPDIR/sessions.next" "$BATS_TEST_TMPDIR/sessions.json"
  stub_script claude <<'SH'
list=$BATS_TEST_TMPDIR/sessions.json
case "$*" in
  'agents --json' | 'agents --json --all') cat "$list" ;;
  'stop '*) jq --arg id "$2" 'map(if .id == $id then .status = "stopped" else . end)' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  'rm '*) jq --arg id "$2" 'map(select(.id != $id))' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  'plugin list --json' | 'plugin marketplace list --json') echo '[]' ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 64 ;;
esac
SH

  run_bin -0 --separate-stderr team-handoff
  assert_contains "$output" "sessions: ended T1-ops with team-ops-end, its transcript and answer deleted; if its answer had not reached Daniel, Daniel asks again on the other machine"
  assert_contains "$output" "sessions: stopped and removed T1-builder (81f08540)"
  [[ ! -e $transcript && ! -e ${transcript%.jsonl} && ! -e $wt/.scratch/answer.md ]]
  assert_equal "$(stowed_events | jq -c .roles)" '["builder"]'
  assert_equal "$(jq -r '.[].name' "$BATS_TEST_TMPDIR/sessions.json")" "coordinator
coordinator-notes
my-T1-builder"
}

@test "an ops session team-ops-end cannot end refuses the handoff, naming it, with nothing released" {
  jq '. + [{id: "6f93fe38", name: "T1-ops", status: "idle", state: "done"}]' "$BATS_TEST_TMPDIR/sessions.json" \
    >"$BATS_TEST_TMPDIR/sessions.next"
  mv "$BATS_TEST_TMPDIR/sessions.next" "$BATS_TEST_TMPDIR/sessions.json"
  stub_script claude <<'SH'
list=$BATS_TEST_TMPDIR/sessions.json
case "$*" in
  'agents --json' | 'agents --json --all') cat "$list" ;;
  'stop '*) jq --arg id "$2" 'map(if .id == $id then .status = "stopped" else . end)' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  'rm '*) jq --arg id "$2" 'map(select(.id != $id))' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 64 ;;
esac
SH
  run_bin -1 --separate-stderr team-handoff
  assert_equal "$stderr" "team-handoff: sessions: could not end T1-ops with team-ops-end (cannot resolve the full session uuid of T1-ops (6f93fe38); nothing deleted); end it, then run team-handoff again; nothing was released"
  assert_equal "$(lease_json | jq -r .state)" held
  assert_equal "$(stowed_events)" ""
}

@test "--json prints the facts, with the step lines on stderr" {
  run_bin -0 --separate-stderr team-handoff --json
  assert_contains "$stderr" "stowed: T1 roles builder"
  assert_equal "$(jq -c '{machine, epoch, tasks}' <<<"$output")" \
    "{\"machine\":\"home-pc\",\"epoch\":1,\"tasks\":[{\"task\":\"T1\",\"worktrees\":[{\"project\":\"home\",\"branch\":\"feat/T1-work\",\"head\":\"$head\"}],\"roles\":[\"builder\"]}]}"
  [[ $(jq -r .released_at <<<"$output") =~ ^[0-9-]+T[0-9:]+Z$ ]]
  assert_contains "$(jq -r .message <<<"$output")" "from home-pc. On the other machine run \`team-resume\`."
  assert_equal "$(jq -c .captured <<<"$output")" '["Config captured: CLAUDE.md (new)."]'
}

@test "a task branch that has diverged from origin refuses the handoff before anything is pushed or released" {
  git -C "$wt" push -q origin feat/T1-work
  git -C "$wt" reset -q --hard HEAD~1
  echo "b" >"$wt/b.txt"
  git -C "$wt" add b.txt
  git -C "$wt" commit -q -m "feat: b"
  local ours
  ours=$(git -C "$wt" rev-parse HEAD)

  run_bin -1 --separate-stderr team-handoff
  assert_contains "$stderr" "team-handoff: the handoff stops here, before anything is pushed or released:
  T1: feat/T1-work (home) has diverged from origin: 1 commits here and 1 there"
  assert_equal "$(git -C "$home_origin" rev-parse feat/T1-work)" "$head"
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$ours"
  assert_equal "$(stowed_events)" ""
  assert_equal "$(stops_and_removes)" ""
  assert_equal "$(lease_json | jq -r .state)" held
  run -0 "$REPO_ROOT/bin/team-timers" status --json
  assert_equal "$(jq -c .enabled <<<"$output")" true
}

@test "interrupted after step 1, a run again finishes the handoff once" { interrupt_after 1; }
@test "interrupted after step 2, a run again finishes the handoff once" { interrupt_after 2; }
@test "interrupted after step 3, a run again finishes the handoff once" { interrupt_after 3; }
@test "interrupted after step 4, a run again finishes the handoff once" { interrupt_after 4; }
@test "interrupted after step 5, a run again finishes the handoff once" { interrupt_after 5; }
@test "interrupted after step 6, a run again finishes the handoff once" { interrupt_after 6; }
@test "interrupted after step 7, a run again finishes the handoff once" { interrupt_after 7; }
@test "interrupted after step 8, a run again finishes the handoff once" { interrupt_after 8; }
@test "interrupted after step 9, a run again finishes the handoff once" { interrupt_after 9; }

@test "a machine that does not hold the lease, or cannot reach GitHub, refuses and changes nothing" {
  local before
  before=$(untouched_state)
  make_machine laptop
  on_machine laptop run_bin -1 --separate-stderr team-handoff --check
  assert_contains "$stderr" "team-handoff: laptop does not hold the lease: home-pc holds it"
  assert_contains "$stderr" "; nothing changed"
  on_machine laptop run_bin -1 --separate-stderr team-handoff
  assert_contains "$stderr" "team-handoff: laptop does not hold the lease: home-pc holds it"
  assert_equal "$(untouched_state)" "$before"

  # The holder's own --check passes and changes nothing.
  run_bin -0 team-handoff --check
  assert_equal "$output" "lease: home-pc holds the lease, epoch 1"
  assert_equal "$(untouched_state)" "$before"

  # Released by hand, not by a handoff: refused.
  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -1 --separate-stderr team-handoff
  assert_contains "$stderr" "the lease is released (last held by home-pc, epoch 1)"
  run -0 "$REPO_ROOT/bin/team-lease" take

  # Offline.
  before=$(untouched_state)
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -75 --separate-stderr team-handoff --check
  assert_contains "$stderr" "team-handoff: GitHub unreachable; no handoff while offline"
  run_bin -75 --separate-stderr team-handoff
  assert_contains "$stderr" "team-handoff: GitHub unreachable; no handoff while offline"
  git -C "$TEAM_HOME" remote set-url origin "$team_origin"
  assert_equal "$(untouched_state)" "$before"
  assert_equal "$(stops_and_removes)" ""
}

@test "--retire returns at once, then stops and removes the coordinator's session" {
  run_bin -1 --separate-stderr team-handoff --retire
  assert_equal "$stderr" "team-handoff: home-pc still holds the lease; run team-handoff first"
  run_bin -0 team-handoff
  : >"$STUB_CALLS/claude.log"

  local start=$SECONDS
  run_bin -0 team-handoff --retire
  assert_contains "$output" "the coordinator (3169fcbd) is stopped and removed in 3s"
  ((SECONDS - start < 3))
  assert_equal "$(stops_and_removes)" ""

  local tries=0
  until [[ $(stops_and_removes) == *"rm 3169fcbd"* ]] || ((tries++ > 100)); do sleep 0.1; done
  assert_equal "$(stops_and_removes)" "stop 3169fcbd
rm 3169fcbd"
  assert_contains "$(cat "$state/retire.log")" "retiring 3169fcbd"
}

@test "it needs a machine name, and refuses a malformed command line" {
  run_bin -2 team-handoff --now
  assert_equal "$output" "team-handoff: usage: team-handoff [--check | --json | --retire]"
  run_bin -2 team-handoff --check --json
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 team-handoff --check
  assert_contains "$output" "this machine has no team name"
}
