#!/usr/bin/env bats
# shellcheck disable=SC2153 # LOCK and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: each registered project's lines, and the projects line.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
}

@test "each registered project's lines pass for a correct clone; Conventioner's pool is Conventioner-d4c77a" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(grep -E '^.... [a-z ]+ (conventioner|site): ' <<<"$output")" "PASS checkout conventioner: ~/projects/Conventioner, a primary checkout
PASS origin conventioner: https://github.com/chanjdaniel/Conventioner.git
PASS task dir conventioner: git ignores .scratch/task/
PASS gate conventioner: no-mistakes has a gate for it
PASS slots conventioner: every slot is in the pool Conventioner-d4c77a, as treehouse names it from origin
PASS leases conventioner: no slot of the pool is leased
PASS trust conventioner: claude starts background sessions in ~/projects/Conventioner
PASS branches conventioner: every local branch is on origin
PASS changes conventioner: the primary checkout is clean
PASS checkout site: ~/projects/site, a primary checkout
PASS origin site: https://github.com/owner/site.git
PASS task dir site: git ignores .scratch/task/
PASS trust site: claude starts background sessions in ~/projects/site
PASS branches site: every local branch is on origin
PASS changes site: the primary checkout is clean"
  # The gate was asked in its checkout, which the doctor left as it was.
  assert_equal "$(git -C "$CONVENTIONER" status --porcelain)" ""
}

@test "a missing clone fails its checkout line with the clone command, and its other lines are skipped" {
  tools_at arch
  local clone="git clone https://github.com/owner/site.git ~/projects/site"
  rm -rf "$SITE"
  run_bin -1 team-doctor
  assert_equal "$(grep -E ' site: ' <<<"$output")" "FAIL checkout site: ~/projects/site is missing; fix: $clone"
  # A folder that is no git checkout, or a worktree of another checkout, is no primary checkout.
  mkdir -p "$SITE"
  run_bin -1 team-doctor
  assert_equal "$(grep -E ' site: ' <<<"$output")" "FAIL checkout site: ~/projects/site is not a git checkout; fix: move it aside, then $clone"
  rmdir "$SITE"
  git -C "$CONVENTIONER" worktree add -q --detach "$SITE"
  run_bin -1 team-doctor
  assert_equal "$(grep -E ' site: ' <<<"$output")" "FAIL checkout site: ~/projects/site is a worktree of ~/projects/Conventioner, not a primary checkout; fix: move it aside, then $clone"
  # Nothing else fails; team-config sees the worktree as site's checkout, with no memory set up.
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v ' site: ' || true)" "WARN memory: memory site setting missing; fix: team-config apply"
}

@test "an origin other than https://github.com/<repo>.git fails, and so does a treehouse pool named from it" {
  tools_at arch
  local url
  for url in git@github.com:owner/site.git https://github.com/owner/site; do
    git -C "$SITE" remote set-url origin "$url"
    run_bin -1 team-doctor
    assert_equal "$(line_of 'origin site')" "FAIL origin site: origin is $url, not https://github.com/owner/site.git; fix: git -C ~/projects/site remote set-url origin https://github.com/owner/site.git"
  done
  git -C "$SITE" remote remove origin
  run_bin -1 team-doctor
  assert_equal "$(line_of 'origin site')" "FAIL origin site: no remote origin; fix: git -C ~/projects/site remote add origin https://github.com/owner/site.git"

  url=git@github.com:chanjdaniel/Conventioner.git
  git -C "$CONVENTIONER" remote set-url origin "$url"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "FAIL slots conventioner: not in the pool Conventioner-$(printf '%s' "$url" | sha256sum | cut -c1-6), as treehouse names it from origin $url: ~/.treehouse/Conventioner-d4c77a/1/Conventioner, ~/.treehouse/Conventioner-d4c77a/2/Conventioner; fix: the origin line's fix"
  git -C "$CONVENTIONER" remote remove origin
  run_bin -1 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "FAIL slots conventioner: unknown, since treehouse names the pool from origin, which is missing; fix: the origin line's fix"
}

@test "a treehouse slot outside the pool its origin names fails the slots line" {
  tools_at arch
  sed -i 's#\.treehouse/Conventioner-d4c77a/2/#.treehouse/Conventioner-8e12e0/2/#' "$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL slots conventioner: not in the pool Conventioner-d4c77a, as treehouse names it from origin: ~/.treehouse/Conventioner-8e12e0/2/Conventioner; fix: put conventioner's pool.slots in projects.toml under the pool's directory, ~/.treehouse/Conventioner-d4c77a/ unless its treehouse.toml sets another root"
}

@test "slots: a slot that is a worktree of another clone of the same origin warns, naming it and how many slots are the team's (report F13)" {
  tools_at arch
  local pool=$HOME/.treehouse/Conventioner-d4c77a other=$HOME/firstmate/projects/Conventioner shown remove
  # Slot 2 is this checkout's worktree and slot 1 does not exist: both pass, as treehouse makes 1.
  git -C "$CONVENTIONER" worktree add -q --detach "$pool/2/Conventioner"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "PASS slots conventioner: every slot is in the pool Conventioner-d4c77a, as treehouse names it from origin"

  # Another clone with the same folder name and origin shares the pool, and owns slot 1.
  git clone -q "$CONVENTIONER" "$other"
  git -C "$other" remote set-url origin https://github.com/chanjdaniel/Conventioner.git
  git -C "$other" worktree add -q --detach "$pool/1/Conventioner"
  # shellcheck disable=SC2088 # the doctor's lines name HOME as ~
  shown='~/.treehouse/Conventioner-d4c77a'
  remove="git -C ~/firstmate/projects/Conventioner worktree remove"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "WARN slots conventioner: slot 1 is a worktree of ~/firstmate/projects/Conventioner, so 1 of 2 slots are the team's; fix: Daniel's, once nothing in it is needed by that clone: $remove $shown/1/Conventioner"

  # Its slot 3, which the registry does not list, is the pool's too.
  git -C "$other" worktree add -q --detach "$pool/3/Conventioner"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "WARN slots conventioner: slot 1 is a worktree of ~/firstmate/projects/Conventioner; slot 3 is a worktree of ~/firstmate/projects/Conventioner, so 1 of 3 slots are the team's; fix: Daniel's, once nothing in it is needed by that clone: $remove $shown/1/Conventioner; $remove $shown/3/Conventioner"
  # The doctor only looked.
  assert_equal "$(git -C "$other" worktree list --porcelain | grep -c '^worktree ')" 3
}

@test "slots: a slot that is an empty folder, or holds no worktree, warns (T45)" {
  tools_at arch
  # shellcheck disable=SC2088 # the doctor's lines name HOME as ~
  local pool=$HOME/.treehouse/Conventioner-d4c77a shown='~/.treehouse/Conventioner-d4c77a'
  # A removed worktree leaves its numbered folder, which treehouse does not make a slot in again.
  mkdir -p "$pool/1" "$pool/2/Conventioner" "$pool/4"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "WARN slots conventioner: slot 1 is an empty folder, so treehouse numbers new slots past it; slot 2 is an empty folder, so treehouse numbers new slots past it; slot 4 is an empty folder, so treehouse numbers new slots past it; fix: rmdir $shown/1; rmdir $shown/2/Conventioner $shown/2; rmdir $shown/4"

  # A folder holding something that is no worktree is Daniel's to look at.
  rmdir "$pool/1" "$pool/4"
  touch "$pool/2/Conventioner/notes.txt"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "WARN slots conventioner: slot 2 holds no git worktree; fix: Daniel looks at $shown/2/Conventioner and moves it aside"

  rm -r "$pool/2"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "PASS slots conventioner: every slot is in the pool Conventioner-d4c77a, as treehouse names it from origin"
}

# ledger_opened <task> <slot>: <task> opened in Conventioner, in its slot <slot> (relative to HOME).
ledger_opened() {
  jq -cn --arg task "$1" --arg wt "$HOME/$2" '{ts: "2026-10-24T10:00:00Z", task: $task, event: "opened",
    project: "conventioner", path: "feature", type: "feat", title: "Work", branch: "feat/\($task)-work",
    base: "main", base_sha: "0000000", worktree: $wt}' >>"$TEAM_HOME/ledger.jsonl"
}

@test "leases: each slot the pool leases is an open task's worktree there, or a WARN naming it with the return" {
  tools_at arch
  local pool=.treehouse/Conventioner-d4c77a fix
  ledger_opened T1 "$pool/1/Conventioner"
  ledger_opened T2 "$pool/2/Conventioner"
  leased_slots "$pool/1/Conventioner" T1 "$pool/2/Conventioner" T2
  run_bin -0 team-doctor
  assert_equal "$(line_of 'leases conventioner')" "PASS leases conventioner: every leased slot (2) is an open task's worktree here"
  # The lease is asked of treehouse in the checkout.
  assert_equal "$(git -C "$CONVENTIONER" status --porcelain)" ""

  # A closed task, an open task whose worktree is elsewhere (a lease a failed team-open left), and
  # a holder that is no task: each is named, with the return for Daniel.
  jq -cn '{ts: "2026-10-24T11:00:00Z", task: "T1", event: "closed", archive: [], returned: [], kept: []}' >>"$TEAM_HOME/ledger.jsonl"
  leased_slots "$pool/1/Conventioner" T1 "$pool/3/Conventioner" T2 "$pool/4/Conventioner" agent
  run_bin -0 team-doctor
  fix="cd ~/projects/Conventioner && ~/projects/Conventioner/scripts/th-return.sh"
  assert_equal "$(line_of 'leases conventioner')" "WARN leases conventioner: ~/$pool/1/Conventioner is leased to T1, which is closed; ~/$pool/3/Conventioner is leased to T2, whose worktree in conventioner is not there; ~/$pool/4/Conventioner is leased to agent, no task of the ledger; fix: once nothing in it is needed, Daniel returns each in their own terminal, which asks before discarding changes: $fix ~/$pool/1/Conventioner; $fix ~/$pool/3/Conventioner; $fix ~/$pool/4/Conventioner"

  # A worktree-moved to the leased slot makes it the task's again.
  jq -cn --arg from "$HOME/$pool/2/Conventioner" --arg wt "$HOME/$pool/3/Conventioner" '{ts: "2026-10-24T12:00:00Z",
    task: "T2", event: "worktree-moved", project: "conventioner", branch: "feat/T2-work", from: $from, worktree: $wt,
    machine: "laptop"}' >>"$TEAM_HOME/ledger.jsonl"
  leased_slots "$pool/3/Conventioner" T2
  run_bin -0 team-doctor
  assert_equal "$(line_of 'leases conventioner')" "PASS leases conventioner: every leased slot (1) is an open task's worktree here"

  # The ledger spells T5's slot otherwise than treehouse does: one directory (report F6).
  local other
  mkdir -p "$HOME/$pool/5/Conventioner"
  other=$(other_spelling "$HOME/.treehouse")
  ledger_opened T5 "${other##*/}/Conventioner-d4c77a/5/Conventioner"
  leased_slots "$pool/3/Conventioner" T2 "$pool/5/Conventioner" T5
  run_bin -0 team-doctor
  assert_equal "$(line_of 'leases conventioner')" "PASS leases conventioner: every leased slot (2) is an open task's worktree here"
}

@test "leases: a treehouse that does not answer warns; a git pool has no leases line" {
  tools_at arch
  echo 'echo "not in a git or jj repository" >&2; exit 1' >"$TOOL_ANSWERS/treehouse/status_--json.sh"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'leases conventioner')" "WARN leases conventioner: \`treehouse status --json\` in ~/projects/Conventioner did not answer; fix: the tool treehouse line's fix"
  echo 'echo "not json"' >"$TOOL_ANSWERS/treehouse/status_--json.sh"
  run_bin -0 team-doctor
  assert_contains "$(line_of 'leases conventioner')" "did not answer"
  [[ -z $(line_of 'leases site') ]]
}

@test "a task directory git does not ignore fails, with the exclude line that ignores it" {
  tools_at arch
  sed -i '\#^/\.scratch/task/$#d' "$SITE/.git/info/exclude"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL task dir site: git does not ignore .scratch/task/; fix: echo /.scratch/task/ >> ~/projects/site/.git/info/exclude"
  # Ignored by the project's own .gitignore, it passes.
  echo .scratch/ >"$SITE/.gitignore"
  git -C "$SITE" add .gitignore
  git -C "$SITE" commit -q -m "chore: ignore the scratch"
  git -C "$SITE" push -q origin HEAD 2>/dev/null || git -C "$SITE" update-ref refs/remotes/origin/main HEAD
  run_bin -0 team-doctor
  assert_equal "$(line_of 'task dir site')" "PASS task dir site: git ignores .scratch/task/"
}

@test "a no-mistakes project without a gate fails the gate line with no-mistakes init; a direct-pr project has no gate line" {
  tools_at arch
  : >"$STUB_FIXTURES/gates"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL gate conventioner: no-mistakes has no gate for ~/projects/Conventioner; fix: cd ~/projects/Conventioner && no-mistakes init"
  assert_equal "$(checks | grep -c '^gate ')" 1
  answer "no-mistakes status"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'gate conventioner')" "FAIL gate conventioner: no-mistakes is not installed; fix: the tool no-mistakes line's fix, then cd ~/projects/Conventioner && no-mistakes init"
  answer "no-mistakes status" "daemon not running"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'gate conventioner')" "FAIL gate conventioner: \`no-mistakes status\` printed no gate: daemon not running; fix: cd ~/projects/Conventioner && no-mistakes init"
}

@test "trust: a promptless claude --bg in each root, FAIL on Workspace not trusted, the probe session removed either way" {
  tools_at arch
  echo "$SITE" >"$STUB_FIXTURES/untrusted"
  # A probe an earlier run left behind is found by its name, and goes too.
  echo '[{"id": "0badc0de", "name": "team-doctor-trust-site", "state": "idle"},
    {"id": "abcdef12", "name": "T9-builder", "state": "working"}]' >"$STUB_FIXTURES/agents.json"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL trust site: claude --bg in ~/projects/site says Workspace not trusted; fix: Daniel runs claude once in ~/projects/site and accepts the trust dialog"
  assert_equal "$(cat "$STUB_CALLS/claude-bg.pwd")" "$TEAM_HOME
$CONVENTIONER
$SITE"
  local home probe
  home=$(printf '%s' "$TEAM_HOME" | sha256sum | cut -c1-8)
  probe=$(printf '%s' "$CONVENTIONER" | sha256sum | cut -c1-8)
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] | IN("--bg", "stop", "rm")) | join(" ")')" "--bg --name team-doctor-home-trust
stop $home
rm $home
--bg --name team-doctor-trust-conventioner
stop $probe
rm $probe
--bg --name team-doctor-trust-site
stop 0badc0de
rm 0badc0de"

  # A probe session that cannot be removed turns a pass into a warning naming it.
  rm "$STUB_FIXTURES/untrusted" "$STUB_FIXTURES/agents.json"
  sed -i "s/^  'stop '\\* | 'rm '\\*) ;;/  'stop '*) ;;\\n  'rm '*) echo 'no such session' >\\&2; exit 1 ;;/" "$STUB_FIXTURES/claude.sh"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'trust site')" "WARN trust site: claude starts background sessions in ~/projects/site, but its probe session $(printf '%s' "$SITE" | sha256sum | cut -c1-8) is left; fix: claude rm $(printf '%s' "$SITE" | sha256sum | cut -c1-8)"

  # Neither a session nor the trust error: the doctor cannot tell, and says what claude said.
  stub_script claude <<'EOF'
case $* in
  'auth status --json') echo '{"loggedIn": true, "authMethod": "claude.ai"}' ;;
  'plugin list --json') cat "$STUB_FIXTURES/plugins.json" ;;
  'plugin marketplace list --json') cat "$STUB_FIXTURES/marketplaces.json" ;;
  'agents --json') echo '[]' ;;
  *) echo "error: unknown option '--bg'" >&2; exit 3 ;;
esac
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'trust site')" "FAIL trust site: \`claude --bg\` in ~/projects/site printed no session id (exit 3): error: unknown option '--bg'; fix: the tool claude and claude login lines"
}

@test "trust team home: probed in the team home, where the coordinator starts, unless a project's trust line covers it" {
  tools_at arch
  local shown=${TEAM_HOME/#"$HOME"/\~}
  echo "$TEAM_HOME" >"$STUB_FIXTURES/untrusted"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL trust team home: claude --bg in $shown says Workspace not trusted; fix: Daniel runs claude once in $shown and accepts the trust dialog"
  # Before the projects' lines, after the records'.
  assert_equal "$(checks | grep -A1 -B1 '^trust team home$')" "records
trust team home
captures"
  [[ $(checks | grep -n '^trust team home$' | cut -d: -f1) -lt $(checks | grep -n '^checkout conventioner$' | cut -d: -f1) ]]

  # A team home that is a registered project's primary checkout (the code checkout, agent-team's,
  # where no records were split off) is that project's trust line's to probe.
  cp "$TEAM_HOME/projects.toml" "$SITE/"
  echo "$SITE" >"$STUB_FIXTURES/untrusted"
  : >"$STUB_CALLS/claude-bg.pwd"
  TEAM_HOME=$SITE run_bin -1 team-doctor
  assert_equal "$(line_of 'trust team home')" "PASS trust team home: not probed apart, since ~/projects/site is site's primary checkout, which the trust site line probes"
  assert_equal "$(line_of 'trust site')" "FAIL trust site: claude --bg in ~/projects/site says Workspace not trusted; fix: Daniel runs claude once in ~/projects/site and accepts the trust dialog"
  assert_equal "$(cat "$STUB_CALLS/claude-bg.pwd")" "$CONVENTIONER
$SITE"

  # No directory to probe: the team home line fails, and this one only says so.
  : >"$STUB_CALLS/claude-bg.pwd"
  TEAM_HOME=$BATS_TEST_TMPDIR/gone run_bin -1 team-doctor
  assert_equal "$(line_of 'trust team home')" "WARN trust team home: not probed, since $BATS_TEST_TMPDIR/gone is not a directory; fix: the team home line's fix"
  assert_equal "$(cat "$STUB_CALLS/claude-bg.pwd")" ""
}

@test "unpushed local branches and a dirty primary checkout warn, each by name" {
  tools_at arch
  # Pushed with no upstream, as team-open makes a task's branch: nothing to warn about.
  git -C "$SITE" branch feat/pushed
  git -C "$SITE" update-ref refs/remotes/origin/feat/pushed feat/pushed
  # On no origin branch: a branch of its own, and one ahead of its upstream.
  git -C "$SITE" switch -q -c wip
  git -C "$SITE" commit -q --allow-empty -m "wip: one"
  git -C "$SITE" switch -q -c feat/ahead --track origin/main
  git -C "$SITE" commit -q --allow-empty -m "feat: one"
  git -C "$SITE" commit -q --allow-empty -m "feat: two"
  # A checkpoint's wip/site/T7 holding feat/ahead's head is no origin branch, whether fetched from
  # the team home's origin by team-open --resume or on origin (a project whose origin is the team
  # home's): it still warns.
  git -C "$SITE" update-ref refs/remotes/team-home/wip/site/T7 feat/ahead
  git -C "$SITE" update-ref refs/remotes/origin/wip/site/T7 feat/ahead
  git -C "$SITE" switch -q main
  echo changed >>"$SITE/README.md"
  echo note >"$SITE/notes.txt"
  run_bin -0 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "WARN branches site: feat/ahead (2 commits), wip (1 commit) on no origin branch; fix: push each (git -C ~/projects/site push -u origin <branch>) or delete it
WARN changes site: changes to tracked files: README.md; untracked files: notes.txt; fix: commit, stash or remove them in ~/projects/site"
}

@test "without a registry, or with a broken one, the projects line fails with team-project's reason" {
  tools_at arch
  rm "$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v -e '^WARN memory' -e '^FAIL records' || true)" "FAIL projects: no registry at $TEAM_HOME/projects.toml; fix: fix what team-project names (team-project --check), then run team-doctor again"
  assert_contains "$(line_of records)" "FAIL records: no registry at $TEAM_HOME/projects.toml;"
  echo '[broken]' >"$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_contains "$(line_of projects)" "FAIL projects: $TEAM_HOME/projects.toml: broken: missing required key 'repo'"
}

@test "a checkout and the team home named by another spelling of their paths pass as the directory they are (report F6)" {
  tools_at arch
  local site home
  site=$(other_spelling "$SITE")
  sed -i "s#^path = \"projects/site\"#path = \"projects/${site##*/}\"#" "$TEAM_HOME/projects.toml"
  home=$(other_spelling "$TEAM_HOME")
  TEAM_HOME=$home run_bin -0 team-doctor
  assert_equal "$(line_of 'checkout site')" "PASS checkout site: ~/projects/${site##*/}, a primary checkout"
  assert_equal "$(line_of 'team home')" "PASS team home: $home, named by TEAM_HOME: a checkout of its own on dev, with an origin"

  # A team home that is a project's primary checkout is so however either is spelled.
  cp "$TEAM_HOME/projects.toml" "$SITE/"
  TEAM_HOME=$SITE run_bin -1 team-doctor
  assert_equal "$(line_of 'trust team home')" "PASS trust team home: not probed apart, since ~/projects/site is site's primary checkout, which the trust site line probes"

  # Still by identity: a worktree of another checkout is no primary checkout, however spelled.
  rm -rf "$SITE"
  git -C "$CONVENTIONER" worktree add -q --detach "$SITE"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'checkout site')" "FAIL checkout site: ~/projects/${site##*/} is a worktree of ~/projects/Conventioner, not a primary checkout; fix: move it aside, then git clone https://github.com/owner/site.git ~/projects/${site##*/}"
}
