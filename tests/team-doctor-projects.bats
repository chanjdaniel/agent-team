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
  assert_equal "$(cat "$STUB_CALLS/claude-bg.pwd")" "$CONVENTIONER
$SITE"
  local probe
  probe=$(printf '%s' "$CONVENTIONER" | sha256sum | cut -c1-8)
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] | IN("--bg", "stop", "rm")) | join(" ")')" "--bg --name team-doctor-trust-conventioner
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

# A stack block for <project>, with its primary checkout <path>: its wrapper, committed there,
# prints a config of one service per <mem_limit> (in bytes) and logs each call's directory,
# TH_DIR, COMPOSE_PROJECT_NAME, TH_PORTS, TH_WEB_PORT and arguments in $BATS_TEST_TMPDIR/compose-calls;
# it fails when $BATS_TEST_TMPDIR/<project>-config.fail exists. give_stack <project> <path> <mem_limit>...
give_stack() {
  local project=$1 path=$2 services
  services=$(printf '%s\n' "${@:3}" | jq -sc 'to_entries | map({key: "s\(.key)", value: {mem_limit: (.value | tostring)}}) | from_entries')
  mkdir -p "$path/scripts"
  cat >"$path/scripts/compose.sh" <<SCRIPT
#!/usr/bin/env bash
echo "\$PWD \$TH_DIR \$COMPOSE_PROJECT_NAME \$TH_PORTS \${TH_WEB_PORT-unset} \$*" >>"$BATS_TEST_TMPDIR/compose-calls"
echo "compose.sh: project=\$COMPOSE_PROJECT_NAME, ports=auto" >&2
if [[ -e "$BATS_TEST_TMPDIR/$project-config.fail" ]]; then echo "compose.sh: no docker-compose.yml in '\$TH_DIR'" >&2; exit 1; fi
jq -n --arg name "\$COMPOSE_PROJECT_NAME" '{name: \$name, services: $services}'
SCRIPT
  chmod +x "$path/scripts/compose.sh"
  git -C "$path" add scripts/compose.sh
  git -C "$path" commit -q -m "feat: add the stack's wrapper"
  git -C "$path" update-ref refs/remotes/origin/main HEAD
  printf '\n[%s.stack]\ncompose = "scripts/compose.sh"\nseed = "scripts/seed.sh"\nlog_services = ["s0"]\n' "$project" \
    >>"$TEAM_HOME/projects.toml"
}

@test "with no registered project's stack block, the stack memory line says so and passes" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 'stack memory')" "PASS stack memory: no registered project has a stack block"
}

@test "on macOS the stack memory line weighs Docker's VM's MemTotal less each stack's mem_limits against the floor, half the VM unless memory_floor_gib is set" {
  on_macos
  tools_at macos
  # Daniel's laptop's VM, and a Conventioner stack's 2.75 GiB of mem_limits.
  give_stack conventioner "$CONVENTIONER" 805306368 1073741824 1073741824
  answer "docker info --format {{.MemTotal}}" 8319770624
  COMPOSE_PROJECT_NAME=other TH_PORTS='' TH_WEB_PORT=5000 run_bin -0 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" ""
  assert_equal "$(line_of 'stack memory')" "PASS stack memory: with nothing else running, Docker's VM's 7.7 GiB leaves at least the floor after a stack of each project (floor 3.9 GiB, the macOS default: half of Docker's VM's 7.7 GiB): conventioner's 2.8 GiB of mem_limits leaves 5.0 GiB"
  # The wrapper was asked for its config in the primary checkout, as a project of its own whose
  # ports Docker assigns, the caller's stack identity cleared.
  assert_equal "$(cat "$BATS_TEST_TMPDIR/compose-calls")" "$CONVENTIONER $CONVENTIONER team-doctor-conventioner auto unset config --format json"

  # A set floor that leaves room for no stack warns, never fails.
  echo '{"memory_floor_gib": 6}' >"$HOME/.config/agent-team/stack.json"
  run_bin -0 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "WARN stack memory: with nothing else running, Docker's VM's 7.7 GiB leaves less than the floor after a stack of conventioner (floor 6 GiB, memory_floor_gib in stack.json), so team-stack up refuses it: conventioner's 2.8 GiB of mem_limits leaves 5.0 GiB; fix: Daniel gives Docker Desktop more memory (Settings, Resources) or sets a lower memory_floor_gib in ~/.config/agent-team/stack.json"
  echo '{"memory_floor_gib": 1}' >"$HOME/.config/agent-team/stack.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'stack memory')" "PASS stack memory: with nothing else running, Docker's VM's 7.7 GiB leaves at least the floor after a stack of each project (floor 1 GiB, memory_floor_gib in stack.json): conventioner's 2.8 GiB of mem_limits leaves 5.0 GiB"

  # Docker not answering: the line says so and passes.
  printf 'echo %q >&2\nexit 1\n' "Cannot connect to the Docker daemon at unix:///Users/daniel/.docker/run/docker.sock." \
    >"$TOOL_ANSWERS/docker/info_--format_{{.MemTotal}}.sh"
  run_bin team-doctor
  assert_equal "$(line_of 'stack memory')" "PASS stack memory: unknown, since docker info does not answer (the docker line)"
}

@test "on Linux the stack memory line reads the host's MemTotal against 6 GiB, names each project a stack of which leaves less, and says which it cannot weigh" {
  tools_at arch
  export TEAM_MEMINFO=$BATS_TEST_TMPDIR/meminfo
  printf 'MemTotal:        8388608 kB\nMemFree:          1048576 kB\nMemAvailable:    4194304 kB\n' >"$TEAM_MEMINFO"
  give_stack conventioner "$CONVENTIONER" 805306368 1073741824 1073741824
  give_stack site "$SITE" 536870912
  run_bin -0 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "WARN stack memory: with nothing else running, this machine's 8.0 GiB (MemTotal) leaves less than the floor after a stack of conventioner (floor 6 GiB, the Linux default), so team-stack up refuses it: conventioner's 2.8 GiB of mem_limits leaves 5.3 GiB; fix: Daniel sets a lower memory_floor_gib in ~/.config/agent-team/stack.json, or gives this machine more memory"
  echo '{"memory_floor_gib": 5}' >"$HOME/.config/agent-team/stack.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'stack memory')" "PASS stack memory: with nothing else running, this machine's 8.0 GiB (MemTotal) leaves at least the floor after a stack of each project (floor 5 GiB, memory_floor_gib in stack.json): conventioner's 2.8 GiB of mem_limits leaves 5.3 GiB, site's 0.5 GiB leaves 7.5 GiB"

  # A wrapper whose config fails, or that is not there, leaves its project unweighed.
  touch "$BATS_TEST_TMPDIR/site-config.fail"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'stack memory')" "PASS stack memory: with nothing else running, this machine's 8.0 GiB (MemTotal) leaves at least the floor after a stack of each project (floor 5 GiB, memory_floor_gib in stack.json): conventioner's 2.8 GiB of mem_limits leaves 5.3 GiB; unknown for site, since scripts/compose.sh config --format json failed: compose.sh: no docker-compose.yml in '$SITE'"
  git -C "$CONVENTIONER" rm -q scripts/compose.sh
  git -C "$CONVENTIONER" commit -q -m "chore: drop the wrapper"
  git -C "$CONVENTIONER" update-ref refs/remotes/origin/main HEAD
  run_bin -0 team-doctor
  assert_equal "$(line_of 'stack memory')" "PASS stack memory: unknown for conventioner, since its checkout has no scripts/compose.sh; unknown for site, since scripts/compose.sh config --format json failed: compose.sh: no docker-compose.yml in '$SITE'"

  # A stack.json team-stack would refuse warns with its problems.
  echo '{"memory_floor_gib": "1", "stack_caps": 2}' >"$HOME/.config/agent-team/stack.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'stack memory')" "WARN stack memory: ~/.config/agent-team/stack.json: memory_floor_gib must be a number of 0 or more, not \"1\"; stack_caps is not a setting (they are: stack_cap, memory_floor_gib, disk_floor_gb, wait_minutes, idle_minutes, heartbeat_sweep, heartbeat_janitor); fix: correct it as team-stack --help describes, since team-stack up refuses it too"
}
