#!/usr/bin/env bats
# The two-machine drill: the plan's acceptance test of moving the team, end to end through the
# real commands. Each test starts from a fresh pair of machines on one bare team-home origin and
# one bare project origin: home-pc (this sandbox's HOME) holds the lease with its heartbeat
# enabled, its coordinator started by claude-coordinator, and T1 opened in the git pool project
# home with a builder launched by team-worker and its first commit made; laptop (make_machine) is
# the machine the team moves to. claude, gh, curl and op are the sandbox's stubs (claude keeps
# each machine's sessions under its own HOME), and team-resume's doctor is a stub that passes
# (TEAM_DOCTOR): the doctor's own lines are tests/team-doctor*.bats', and the crash test runs the
# real one on home-pc for its salvage lines.
# Scenarios: a clean handoff and resume, a handoff of a worker that never answered STOW, a stale
# lease stolen, a crash between checkpoints, and a GitHub outage held in offline mode.

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
  # The team's Claude config, captured earlier: each machine has it, or applies it on resume.
  mkdir -p "$TEAM_HOME/machine/claude" "$HOME/.claude"
  echo "Shared instructions." >"$TEAM_HOME/machine/claude/CLAUDE.md"
  cp "$TEAM_HOME/machine/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  team_origin=$(hold_lease home-pc)

  # Discord answers every post and thread with an id.
  stub_reply curl '{"id":"1563000000000000001"}'
  fake_service_managers
  # claude: each machine's sessions in its own HOME's sessions.json; --bg starts one, its id from
  # the machine and the name; stop marks it stopped, rm takes it off; no plugins.
  stub_script claude <<'SH'
list=$HOME/sessions.json
[[ -e $list ]] || echo '[]' >"$list"
case $1 in
  agents) cat "$list" ;;
  stop) jq --arg id "$2" 'map(if .id == $id then .status = "stopped" else . end)' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  rm) jq --arg id "$2" 'map(select(.id != $id))' "$list" >"$list.next" && mv "$list.next" "$list" ;;
  plugin) echo '[]' ;;
  --bg)
    name='' prev=''
    for arg in "$@"; do
      if [[ $prev == --name ]]; then name=$arg; fi
      prev=$arg
    done
    id=$(printf '%s %s' "$HOME" "$name" | sha256sum | cut -c1-8)
    jq --arg id "$id" --arg name "$name" '. + [{id: $id, name: $name, status: "busy", state: "working"}]' \
      "$list" >"$list.next" && mv "$list.next" "$list"
    echo "Started background session $id ($name). Attach with: claude attach $id" ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 64 ;;
esac
SH
  export TEAM_DOCTOR=$BATS_TEST_TMPDIR/doctor
  cat >"$TEAM_DOCTOR" <<'SH'
#!/usr/bin/env bash
echo '[{"check": "machine", "verdict": "PASS", "reason": "named", "fix": ""}]'
SH
  chmod +x "$TEAM_DOCTOR"

  # home-pc runs the team: the heartbeat, the coordinator, T1 and its builder.
  "$REPO_ROOT/bin/team-timers" enable >/dev/null
  run_bin -0 claude-coordinator "$TEAM_HOME"
  coordinator=$(session_id coordinator)
  run_bin -0 team-open home feature feat work "Do the work"
  wt=$HOME/slots/home/1
  run_bin -0 team-thread T1 home "Do the work"
  run_bin -0 team-worker T1 builder "$wt" -- "Read your brief"
  builder=$output
  # The builder's first commit, and the task directory it works from.
  echo "spec" >"$wt/.scratch/task/spec.md"
  echo "a" >"$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m "feat: a"

  make_machine laptop
  laptop=$BATS_TEST_TMPDIR/machines/laptop
  code_checkout
  lt=$laptop/home/slots/home/1
  report=$laptop/team/tasks/resume-$(date +%F).json
  state=$HOME/.local/state/agent-team
}

# The id of home-pc's session named <name>.
session_id() {
  jq -r --arg name "$1" '.[] | select(.name == $name) | .id' "$HOME/sessions.json"
}

# Each claude --bg call laptop made (one naming a file under its HOME), as JSON arguments.
laptop_launches() {
  stub_calls claude | jq -c --arg home "$laptop/home/" 'select(.[0] == "--bg" and any(.[]; startswith($home)))'
}

# The status of each of home-pc's sessions, "<name> <status>", one per line.
home_pc_sessions() {
  jq -r '.[] | "\(.name) \(.status)"' "$HOME/sessions.json"
}

# The ledger's events of <kind> on <machine>'s team home, compact, without their times.
events_of() {
  jq -c --arg kind "$1" 'select(.event == $kind) | del(.ts)' "$2/ledger.jsonl"
}

# Steal on laptop, as Daniel would: team-resume --steal, typing home-pc's name on its terminal.
resume_by_stealing() {
  local tty=$BATS_TEST_TMPDIR/steal-tty
  echo home-pc >"$tty"
  TEAM_LEASE_TTY=$tty on_machine laptop run_bin -0 --separate-stderr team-resume --steal
}

# home-pc's lease-fence hook on a call to <tool> with <input> (JSON), as Claude Code sends it:
# fence_hook <status> <tool> <input>
fence_hook() {
  run_bin "$1" --separate-stderr hooks/lease-fence <<<"$(jq -cn --arg tool "$2" --argjson input "$3" \
    '{hook_event_name: "PreToolUse", cwd: env.HOME, tool_name: $tool, tool_input: $input}')"
}

# The content of each post to #coordinator, one JSON string per line.
posts() {
  stub_calls curl | jq -c 'select(.[-1] == "https://discord.com/api/v10/channels/1562486564871995482/messages")
    | .[index("-d") + 1] | fromjson | .content'
}

@test "handoff and resume: home-pc stows T1 and releases; laptop takes the lease at epoch 2, T1's worktree and its coordinator" {
  # On STOW the builder commits what is unfinished and writes handoff.md; the handoff pushes it.
  echo "half" >"$wt/b.txt"
  git -C "$wt" add b.txt
  git -C "$wt" commit -q -m "wip: b is half done"
  echo "next: finish b" >"$wt/.scratch/task/handoff.md"
  local head
  head=$(git -C "$wt" rev-parse HEAD)

  run_bin -0 team-handoff
  [[ ${lines[-2]} == "Released at "*" from home-pc. The \`team-resume --wait\` started on the other machine takes the team now; with none running there, run \`team-resume\` there." ]]
  assert_equal "${lines[-1]}" "Config captured: nothing."
  assert_equal "$(git -C "$home_origin" rev-parse feat/T1-work)" "$head"
  # Only the builder's session went; the coordinator retires itself after posting.
  assert_equal "$(home_pc_sessions)" "coordinator busy"

  on_machine laptop run_bin -0 --separate-stderr team-resume
  assert_equal "$stderr" ""
  assert_contains "$output" "lease: laptop holds the lease, epoch 2"
  assert_equal "$(lease_json | jq -c '[.holder, .epoch, .state, .stolen_from]')" '["laptop",2,"held",null]'

  # laptop's worktree is at home-pc's pushed head, with home-pc's scratch and the builder's note.
  assert_equal "$(git -C "$lt" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$lt" branch --show-current)" "feat/T1-work"
  assert_equal "$(git -C "$lt" status --porcelain)" ""
  assert_equal "$(cat "$lt/.scratch/task/spec.md")" "spec"
  assert_equal "$(cat "$lt/.scratch/task/handoff.md")" "next: finish b"

  # The ledger, as laptop has it: home-pc's stowed, then laptop's move of the worktree (the
  # sandbox's paths are not under /home/<name>, so the slot is laptop's own, not re-rooted).
  assert_equal "$(events_of stowed "$laptop/team")" \
    "{\"task\":\"T1\",\"event\":\"stowed\",\"machine\":\"home-pc\",\"worktrees\":[{\"project\":\"home\",\"branch\":\"feat/T1-work\",\"head\":\"$head\"}],\"roles\":[\"builder\"],\"sessions\":[\"builder\"]}"
  assert_equal "$(events_of worktree-moved "$laptop/team")" \
    "{\"task\":\"T1\",\"event\":\"worktree-moved\",\"project\":\"home\",\"branch\":\"feat/T1-work\",\"from\":\"$wt\",\"worktree\":\"$lt\",\"machine\":\"laptop\"}"

  # laptop's heartbeat runs, and its coordinator was started with the resume skill and the report.
  on_machine laptop run -0 "$REPO_ROOT/bin/team-timers" status --json
  assert_equal "$(jq -c '[.installed, .enabled]' <<<"$output")" "[true,true]"
  assert_equal "$(laptop_launches | wc -l)" 1
  assert_equal "$(laptop_launches | jq -r '.[1:3] | join(" ")')" "--name coordinator"
  assert_equal "$(laptop_launches | jq -r last)" \
    "You are the coordinator, resuming the team on laptop. Follow the \`resume\` skill with the report $report."
  assert_equal "$(jq -c '.tasks | map({task, roles: .stowed.roles, crashed, failures})' "$report")" \
    '[{"task":"T1","roles":["builder"],"crashed":null,"failures":[]}]'
}

@test "a worker that never answers STOW: the handoff stops it, then checkpoints; laptop resumes with its uncommitted work, and its first checkpoint keeps it" {
  # The builder pushed its commit, then edits a.txt and adds b.txt, and never stows.
  git -C "$wt" push -q origin HEAD:refs/heads/feat/T1-work
  local head
  head=$(git -C "$wt" rev-parse HEAD)
  echo "edited" >"$wt/a.txt"
  echo "b" >"$wt/b.txt"

  run_bin -0 team-handoff
  [[ $output == *"sessions: stopped and removed T1-builder ($builder)"*"checkpoint: T1 home: pushed wip/home/T1 "* ]]
  assert_contains "$output" "stowed: T1 roles builder; home feat/T1-work at ${head:0:7} with uncommitted changes"
  assert_equal "$(home_pc_sessions)" "coordinator busy"

  on_machine laptop run_bin -0 --separate-stderr team-resume
  assert_equal "$stderr" ""
  assert_contains "$output" "T1 home: applied wip/home/T1 "
  # laptop's worktree is the pushed branch with the builder's uncommitted work, as it left it.
  assert_equal "$(git -C "$lt" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$lt" status --porcelain)" "$(printf '%s\n' " M a.txt" "?? b.txt")"
  assert_equal "$(cat "$lt/a.txt")" "edited"
  assert_equal "$(jq -c '.tasks[0] | {crashed, roles: .stowed.roles, applied: [.worktrees[].snapshot.applied]}' "$report")" \
    '{"crashed":null,"roles":["builder"],"applied":[true]}'

  # laptop's first checkpoint finds that very work in its worktree, so wip/home/T1 keeps it.
  local wip
  wip=$(git -C "$team_origin" rev-parse wip/home/T1)
  on_machine laptop run_bin -0 team-checkpoint --force
  assert_contains "$output" "T1 home: wip/home/T1 is up to date (${wip:0:7})"
  assert_equal "$(git -C "$team_origin" rev-parse wip/home/T1)" "$wip"
  assert_equal "$(git -C "$team_origin" rev-parse "$wip^")" "$head"
  assert_equal "$(git -C "$team_origin" show "$wip:a.txt")" "edited"
  assert_equal "$(git -C "$team_origin" show "$wip:b.txt")" "b"
}

@test "stale lease: laptop takes it only once it is stale and with --steal; home-pc's next heartbeat fences it, and its hook blocks a reply and a push" {
  on_machine laptop run_bin -1 --separate-stderr team-lease take
  assert_contains "$stderr" "the lease is held by home-pc (epoch 1), fresh: renewed 0 minutes ago"

  age_lease 61
  on_machine laptop run_bin -1 --separate-stderr team-lease take
  assert_contains "$stderr" "the lease is held by home-pc (epoch 1), stale: renewed 61 minutes ago"
  assert_equal "$(lease_json | jq -c '[.holder, .epoch]')" '["home-pc",1]'

  steal_lease laptop home-pc
  assert_equal "$(lease_json | jq -c '[.holder, .epoch, .state, .stolen_from]')" '["laptop",2,"held","home-pc"]'

  # home-pc's heartbeat fires: it fences home-pc, stops its coordinator and its builder, turns
  # itself off and posts nothing.
  : >"$STUB_CALLS/curl.log"
  run_bin -0 team-timers run
  assert_contains "$output" "lease: home-pc no longer holds the lease: laptop holds it (epoch 2); fenced home-pc: stopped coordinator ($coordinator), T1-builder ($builder)"
  jq -e '.holder == "laptop" and .epoch == 2' "$state/fenced"
  assert_equal "$(home_pc_sessions)" "$(printf '%s\n' "coordinator stopped" "T1-builder stopped")"
  run -0 "$REPO_ROOT/bin/team-timers" status --json
  assert_equal "$(jq -c '[.installed, .enabled]' <<<"$output")" "[false,false]"
  assert_equal "$(stub_calls curl)" ""
  assert_equal "$(lease_json | jq -c '[.holder, .epoch]')" '["laptop",2]'

  # Were the coordinator to reply on Discord, or the builder to push, home-pc's hook blocks it.
  fence_hook -2 mcp__plugin_discord_discord__reply '{"chat_id": "1563", "text": "on it"}'
  assert_contains "$stderr" "Blocked: home-pc is fenced since "
  fence_hook -2 Bash "$(jq -cn --arg c "git -C $wt push origin HEAD" '{command: $c}')"
  assert_contains "$stderr" "Blocked: home-pc is fenced since "
}

@test "crash: home-pc checkpoints, works on and dies; laptop steals and resumes from the checkpoint, and home-pc's doctor lists the rest to salvage" {
  git -C "$wt" push -q origin HEAD:refs/heads/feat/T1-work
  local head
  head=$(git -C "$wt" rev-parse HEAD)
  # The builder edits a.txt and adds b.txt; home-pc's heartbeat checkpoints them.
  echo "edited" >"$wt/a.txt"
  echo "b" >"$wt/b.txt"
  run_bin -0 team-timers run
  assert_contains "$output" "checkpoint: T1 home: pushed wip/home/T1 "
  # It works on (a commit and an edit no checkpoint saw), then dies: no handoff, no heartbeat.
  echo "c" >"$wt/c.txt"
  git -C "$wt" add c.txt
  git -C "$wt" commit -q -m "feat: c"
  echo "later" >"$wt/a.txt"
  age_lease 75

  resume_by_stealing
  assert_equal "$stderr" ""
  assert_equal "$(lease_json | jq -c '[.holder, .epoch, .stolen_from]')" '["laptop",2,"home-pc"]'
  assert_contains "$output" "T1: crashed on home-pc, with no handoff since its last launch; resuming from the checkpoint of "
  # laptop's worktree is the pushed branch with the checkpoint's changes uncommitted, none later.
  assert_equal "$(git -C "$lt" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "$lt" status --porcelain)" "$(printf '%s\n' " M a.txt" "?? b.txt")"
  assert_equal "$(cat "$lt/a.txt")" "edited"
  [[ ! -e $lt/c.txt ]]
  assert_equal "$(cat "$lt/.scratch/task/spec.md")" "spec"
  assert_equal "$(laptop_launches | wc -l)" 1

  # home-pc comes back: its heartbeat fences it, and its doctor fails, listing what only home-pc
  # holds (the later commit and edit) with the commands that push it to a salvage branch.
  run -0 "$REPO_ROOT/bin/team-timers" run
  [[ -e $state/fenced ]]
  run -1 --separate-stderr "$REPO_ROOT/bin/team-doctor" --json
  assert_equal "$(jq -c '.[] | select(.check | startswith("salvage")) | [.check, .verdict, .reason, .fix]' <<<"$output")" \
    "$(jq -cn --arg url "$team_origin" '["salvage T1 home", "FAIL",
      "~/slots/home/1 has 1 commit on no origin branch and uncommitted changes (changes to tracked files: a.txt; untracked files: b.txt)",
      "git -C ~/slots/home/1 add -A && git -C ~/slots/home/1 commit -m \"wip: salvage from home-pc\", then git -C ~/slots/home/1 push \($url) HEAD:refs/heads/salvage/home/T1-home-pc"]')"
  # Daniel runs it: the work is on the team home's origin only, and the line passes.
  local fix
  fix=$(jq -r '.[] | select(.check == "salvage T1 home") | .fix' <<<"$output")
  eval "${fix%%, then *}" >/dev/null 2>&1
  eval "${fix#*, then }" >/dev/null 2>&1
  assert_equal "$(git -C "$team_origin" rev-parse refs/heads/salvage/home/T1-home-pc)" "$(git -C "$wt" rev-parse HEAD)"
  assert_equal "$(git -C "$team_origin" show refs/heads/salvage/home/T1-home-pc:a.txt)" "later"
  assert_equal "$(git -C "$home_origin" for-each-ref refs/heads/salvage/)" ""
  run -1 --separate-stderr "$REPO_ROOT/bin/team-doctor" --json
  assert_equal "$(jq -c '.[] | select(.check | startswith("salvage")) | [.check, .verdict]' <<<"$output")" '["salvage","PASS"]'
}

@test "outage: home-pc's heartbeat holds the team offline, posting once and changing nothing on origin; when GitHub is back it renews, clears the hold and posts the window" {
  # The probe's 60-second wait returns at once; the uname stub keeps the sandbox's stubs ahead
  # of Homebrew's GNU sleep on macOS (as in tests/team-timers.bats).
  stub_command sleep
  stub_script sleep </dev/null
  stub_command uname
  stub_reply uname Linux
  # A renewal and a checkpoint are both due: the builder has uncommitted work.
  echo "edited" >"$wt/a.txt"
  age_lease 20
  local lease dev origin
  lease=$(lease_json)
  dev=$(git -C "$team_origin" rev-parse dev)
  origin=$(git -C "$TEAM_HOME" remote get-url origin)
  : >"$STUB_CALLS/curl.log"

  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -75 team-timers run
  assert_contains "$output" "probe: GitHub unreachable since "
  assert_contains "$output" "the team is holding; #coordinator is told"
  local since
  since=$(jq -r .since "$state/offline")
  run_bin -75 team-timers run
  assert_contains "$output" "the team is still holding"
  assert_equal "$(posts)" "$(jq -n --arg t "GitHub unreachable since $(date -d "$since" +%H:%M) on home-pc; holding the team" '$t')"

  # The builder's push and gh are held by the hook, with the hold's instructions.
  fence_hook -2 Bash "$(jq -cn --arg c "git -C $wt push origin HEAD" '{command: $c}')"
  assert_contains "$stderr" "the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait."
  fence_hook -2 Bash '{"command": "gh pr view 6"}'
  assert_contains "$stderr" "the team is holding"
  fence_hook -0 Bash '{"command": "git -C . commit -m wip"}'

  # Nothing changed on origin: no checkpoint (no wip ref, no team-home commit), the same lease.
  run -1 git -C "$team_origin" rev-parse -q --verify refs/heads/wip/home/T1
  assert_equal "$(git -C "$team_origin" rev-parse dev)" "$dev"
  assert_equal "$(lease_json)" "$lease"

  # GitHub is back: the next heartbeat renews at once, clears the flag and posts the window, then
  # checkpoints.
  git -C "$TEAM_HOME" remote set-url origin "$origin"
  run_bin -0 team-timers run
  local back
  back=$(sed -nE 's/.* GitHub back at ([^ ]+) .*/\1/p' <<<"$output")
  [[ ! -e $state/offline ]]
  lease_json | jq -e '.holder == "home-pc" and .epoch == 1 and (.renewed_at | fromdateiso8601) > now - 120'
  assert_equal "$(posts | sed -n 2p)" \
    "$(jq -n --arg t "GitHub back at $(date -d "$back" +%H:%M) (unreachable from $(date -d "$since" +%H:%M)); resuming T1" '$t')"
  assert_equal "$(posts | wc -l)" 2
  git -C "$team_origin" rev-parse -q --verify refs/heads/wip/home/T1
}
