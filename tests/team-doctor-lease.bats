#!/usr/bin/env bats
# shellcheck disable=SC2153 # LOCK and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the clock, lease, salvage, offline and heartbeat lines.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
}

@test "a clock more than a minute off GitHub's warns; GitHub's Date unreadable warns too" {
  tools_at arch
  # The Date header is in whole seconds, so the skew read may be a second off the one set.
  clock_offset 300
  run_bin -0 team-doctor
  [[ $(line_of clock) =~ ^"WARN clock: this clock is "(299|300|301)" s behind GitHub's; fix: sudo timedatectl set-ntp true"$ ]]
  clock_offset -120
  on_macos
  tools_at macos
  run_bin -0 team-doctor
  [[ $(line_of clock) =~ ^"WARN clock: this clock is "(119|120|121)" s ahead of GitHub's; fix: sudo systemsetup -setusingnetworktime on"$ ]]
  clock_offset 30
  run_bin -0 team-doctor
  assert_equal "$(line_of clock)" "PASS clock: within 60 s of GitHub's"

  stub_script curl <<'EOF'
echo "curl: (6) Could not resolve host: api.github.com" >&2
exit 6
EOF
  run_bin -0 team-doctor
  assert_equal "$(line_of clock)" "WARN clock: cannot read the Date of https://api.github.com; fix: check the network, then run team-doctor again"
}

@test "GitHub's Date is read even when curl writes the headers after it in a later write" {
  tools_at arch
  # The later write fails with a broken pipe if the reader stopped at the Date line.
  stub_script curl <<'EOF'
printf 'HTTP/2 200\r\ndate: %s\r\n' "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"
sleep 0.5
printf 'server: github.com\r\n\r\n'
EOF
  run_bin -0 team-doctor
  assert_equal "$(line_of clock)" "PASS clock: within 60 s of GitHub's"
}

@test "the lease line: PASS held here, WARN held elsewhere or released, FAIL unreachable" {
  tools_at arch
  make_machine laptop
  # Not holding, the heartbeat belongs off.
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-doctor
  assert_equal "$(line_of lease)" "WARN lease: released, epoch 1; fix: team-lease take, with Daniel's yes"

  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  run_bin -0 team-doctor
  assert_equal "$(line_of lease)" "WARN lease: held by laptop, epoch 2, renewed 0 minutes ago; fix: hand off on laptop, then team-resume here"

  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 team-doctor
  assert_equal "$(line_of lease)" "FAIL lease: GitHub unreachable, so the lease is unconfirmed; fix: check the network, then run team-doctor again"

  git -C "$TEAM_HOME" remote remove origin
  run_bin -1 team-doctor
  assert_equal "$(line_of lease)" "FAIL lease: the team home $TEAM_HOME has no git remote origin, where the lease lives; fix: fix what team-lease names, then run team-doctor again"
}

@test "the lease line fails on a fenced machine, naming the holder it saw, reachable or not" {
  tools_at arch
  make_machine laptop
  steal_lease laptop home-pc
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 team-doctor
  assert_equal "$(line_of lease)" "FAIL lease: fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2); fix: hand off on the machine that holds the lease, then team-resume here (its take clears the fence)"
  assert_equal "$(line_of heartbeat)" "PASS heartbeat: disabled, and this machine does not hold the lease"

  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 team-doctor
  assert_equal "$(line_of lease)" "FAIL lease: fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2); fix: hand off on the machine that holds the lease, then team-resume here (its take clears the fence)"
}

@test "on a fenced machine, each open task's worktree holding what origin lacks gets a salvage line" {
  tools_at arch
  # Five tasks in site, each in a worktree of its own: T1 with a commit pushed only inside a
  # checkpoint's wip/site/T1 (as team-open --resume fetches it from the team home's origin), T2 with uncommitted changes, T3 clean, T4's worktree gone, T5 closed.
  local n wt=() slots=$HOME/site-wt
  for n in 1 2 3 4 5; do
    wt[n]=$slots/$n
    git -C "$SITE" worktree add -q -b "feat/T$n-x" "${wt[n]}" origin/main
    jq -cn --arg t "T$n" --arg wt "${wt[n]}" --arg b "feat/T$n-x" '{ts: "2026-10-23T09:00:00Z", task: $t,
      event: "opened", project: "site", path: "small", type: "feat", title: "x", branch: $b, base: "main",
      base_sha: "0000000", worktree: $wt}' >>"$TEAM_HOME/ledger.jsonl"
  done
  echo one >"${wt[1]}/one.txt"
  git -C "${wt[1]}" add one.txt
  git -C "${wt[1]}" commit -q -m "feat: one"
  git -C "$SITE" update-ref refs/remotes/team-home/wip/site/T1 \
    "$(git -C "${wt[1]}" commit-tree -p HEAD -m wip "$(git -C "${wt[1]}" rev-parse 'HEAD^{tree}')")"
  echo edited >"${wt[2]}/README.md"
  echo new >"${wt[2]}/new.txt"
  git -C "$SITE" worktree remove --force "${wt[4]}"
  echo stray >"${wt[5]}/stray.txt"
  echo '{"ts":"2026-10-23T10:00:00Z","task":"T5","event":"closed","archive":[],"returned":[],"kept":[]}' \
    >>"$TEAM_HOME/ledger.jsonl"

  # Not fenced: no salvage line at all.
  run_bin -0 team-doctor
  [[ $output != *salvage* ]]

  make_machine laptop
  steal_lease laptop home-pc
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 team-doctor
  # The salvage goes to the team home's origin, never the project's, which may be public.
  local team_origin
  team_origin=$(git -C "$TEAM_HOME" remote get-url origin)
  assert_equal "$(grep salvage <<<"$output")" \
"FAIL salvage T1 site: ~/site-wt/1 has 1 commit on no origin branch; fix: git -C ~/site-wt/1 push $team_origin HEAD:refs/heads/salvage/site/T1-home-pc
FAIL salvage T2 site: ~/site-wt/2 has uncommitted changes (changes to tracked files: README.md; untracked files: new.txt); fix: git -C ~/site-wt/2 add -A && git -C ~/site-wt/2 commit -m \"wip: salvage from home-pc\", then git -C ~/site-wt/2 push $team_origin HEAD:refs/heads/salvage/site/T2-home-pc"
  # Right after the lease line.
  assert_equal "$(checks | grep -A2 -x lease | paste -sd ,)" "lease,salvage T1 site,salvage T2 site"

  # Once Daniel has run both fixes, the work is on the team home's origin, none on site's, and the
  # line passes.
  local fix
  while IFS= read -r fix; do eval "$fix" >/dev/null 2>&1; done < <(grep '^FAIL salvage' <<<"$output" | sed 's/.*; fix: //; s/, then / \&\& /')
  assert_equal "$(git -C "$team_origin" rev-parse refs/heads/salvage/site/T1-home-pc)" "$(git -C "${wt[1]}" rev-parse HEAD)"
  assert_equal "$(git -C "$team_origin" rev-parse refs/heads/salvage/site/T2-home-pc)" "$(git -C "${wt[2]}" rev-parse HEAD)"
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/origin/site.git" for-each-ref refs/heads/salvage/)" ""
  run_bin -1 team-doctor
  assert_equal "$(grep salvage <<<"$output")" "PASS salvage: no task worktree here holds work that neither origin nor a salvage branch keeps"

  # A change after the salvage needs salvaging again.
  echo two >"${wt[1]}/two.txt"
  echo more >"${wt[2]}/new.txt"
  run_bin -1 team-doctor
  assert_equal "$(grep salvage <<<"$output" | cut -d: -f1)" "FAIL salvage T1 site
FAIL salvage T2 site"

  # A commit pushed to origin's branch, and clean, passes too.
  git -C "${wt[1]}" add two.txt
  git -C "${wt[1]}" commit -q -m "feat: two"
  git -C "${wt[2]}" checkout -q -- new.txt
  git -C "$SITE" update-ref refs/remotes/origin/feat/T1-x "$(git -C "${wt[1]}" rev-parse HEAD)"
  run_bin -1 team-doctor
  assert_equal "$(grep salvage <<<"$output")" "PASS salvage: no task worktree here holds work that neither origin nor a salvage branch keeps"
}

@test "the offline line warns with the outage's start and age while the heartbeat holds the team" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of offline)" "PASS offline: the team is not holding for an outage"
  jq -n '{since: (now - 35 * 60 | floor | todate), posted: true}' >"$HOME/.local/state/agent-team/offline"
  run_bin -0 team-doctor
  assert_equal "$(line_of offline)" "WARN offline: offline since $(jq -r .since "$HOME/.local/state/agent-team/offline") (35 minutes); fix: check this machine's network; the heartbeat resumes the team when GitHub answers"
}

@test "the heartbeat line: PASS enabled on the holder or disabled elsewhere, FAIL otherwise with the command" {
  tools_at arch
  make_machine laptop
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  run_bin -1 team-doctor
  assert_equal "$(line_of heartbeat)" "FAIL heartbeat: disabled, but this machine holds the lease; fix: team-timers enable"

  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-doctor
  assert_equal "$(line_of heartbeat)" "PASS heartbeat: disabled, and this machine does not hold the lease"

  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  "$REPO_ROOT/bin/team-timers" enable >/dev/null
  run_bin -1 team-doctor
  assert_equal "$(line_of heartbeat)" "FAIL heartbeat: enabled, but this machine does not hold the lease; fix: team-timers disable"

  # With the lease unconfirmed, the doctor cannot say which it should be.
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 team-doctor
  assert_equal "$(line_of heartbeat)" "WARN heartbeat: enabled, but whether it should be waits on the lease line; fix: the lease line's fix, then run team-doctor again"

  # A heartbeat team-timers cannot read fails with its reason.
  stub_reply uname FreeBSD
  run_bin -1 team-doctor
  assert_equal "$(line_of heartbeat)" "FAIL heartbeat: FreeBSD has neither systemd nor launchd; the heartbeat runs on Linux or macOS; fix: fix what team-timers names, then run team-doctor again"
}
