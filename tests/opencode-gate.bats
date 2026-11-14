#!/usr/bin/env bats
# bin/lib/opencode-gate: the gate's opencode, installed as ~/.no-mistakes/bin/opencode-gate and
# named by config.yaml's agent_path_override, run here with a fake opencode on PATH; and
# bin/lib/opencode-guard.js, the command-guard plugin it loads, whose tool.execute.before handler
# a node driver calls as opencode does, with this checkout's command-guard or a stand-in.

load helpers/common

setup() {
  sandbox
  stub_command opencode
  stub_script opencode <<'EOF'
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG-unset}"
printf 'OPENCODE_CONFIG_CONTENT=%s\n' "${OPENCODE_CONFIG_CONTENT-unset}"
printf 'OPENCODE_DISABLE_CLAUDE_CODE=%s\n' "${OPENCODE_DISABLE_CLAUDE_CODE-unset}"
printf 'OPENCODE_PURE=%s\n' "${OPENCODE_PURE-unset}"
printf 'arg=%s\n' "$@"
EOF
  install -m 755 "$REPO_ROOT/bin/lib/opencode-gate" "$BATS_TEST_TMPDIR/opencode-gate"
  PLUGIN=$HOME/agent-team/bin/lib/opencode-guard.js
  mkdir -p "${PLUGIN%/*}"
  cp "$REPO_ROOT/bin/lib/opencode-guard.js" "$PLUGIN"
  WT=$BATS_TEST_TMPDIR/worktree
  mkdir -p "$WT/build" "$WT/src"
  # The driver: load the plugin at <plugin> as opencode does, with the session's <directory> and
  # <worktree>, call its handler on one <tool> call with <args> (JSON), and print "passed" or
  # "refused: <the error's message>".
  DRIVER=$BATS_TEST_TMPDIR/driver.mjs
  cat >"$DRIVER" <<'EOF'
const [plugin, directory, worktree, tool, args] = process.argv.slice(2);
const mod = await import(plugin);
const hooks = [];
for (const fn of Object.values(mod)) hooks.push(await fn({ directory, worktree }));
try {
  for (const h of hooks) await h["tool.execute.before"]({ tool, sessionID: "s", callID: "c" }, { args: JSON.parse(args) });
  console.log("passed");
} catch (error) {
  console.log(`refused: ${error.message}`);
}
EOF
}

# The plugin's handler on a bash call of <command> in the worktree, with this checkout's guard:
# handle <command> [<workdir>]
handle() {
  run -0 node "$DRIVER" "$REPO_ROOT/bin/lib/opencode-guard.js" "$WT" "$WT" bash \
    "$(jq -cn --arg c "$1" --arg w "${2-}" '{command: $c, description: "d"} + if $w == "" then {} else {workdir: $w} end')"
}

# A stand-in command-guard beside a copy of the plugin, running <body> after it saves its input
# and environment: fake_guard <body>
fake_guard() {
  local code=$BATS_TEST_TMPDIR/code
  mkdir -p "$code/bin/lib" "$code/bin/hooks"
  cp "$REPO_ROOT/bin/lib/opencode-guard.js" "$code/bin/lib/"
  { echo '#!/usr/bin/env bash'; echo "cat >'$BATS_TEST_TMPDIR/input.json'; env >'$BATS_TEST_TMPDIR/env.txt'"; echo "$1"; } >"$code/bin/hooks/command-guard"
  chmod +x "$code/bin/hooks/command-guard"
  FAKE_PLUGIN=$code/bin/lib/opencode-guard.js
}

@test "it runs opencode with the gate-only config, the command-guard plugin and without Claude Code's, every argument passed as it came" {
  run -0 env OPENCODE_CONFIG=/elsewhere.json OPENCODE_CONFIG_CONTENT='{"plugin":[]}' OPENCODE_PURE=1 \
    "$BATS_TEST_TMPDIR/opencode-gate" serve --hostname 127.0.0.1 'a b'
  assert_equal "$output" "OPENCODE_CONFIG=$HOME/.no-mistakes/opencode-gate.json
OPENCODE_CONFIG_CONTENT={\"plugin\":[\"$PLUGIN\"]}
OPENCODE_DISABLE_CLAUDE_CODE=1
OPENCODE_PURE=unset
arg=serve
arg=--hostname
arg=127.0.0.1
arg=a b"
  run -0 jq -r '.plugin[0]' <<<"$(sed -n 's/^OPENCODE_CONFIG_CONTENT=//p' <<<"$output")"
  assert_equal "$output" "$PLUGIN"
}

@test "it is opencode itself once started: its exit code is opencode's" {
  stub_script opencode <<'EOF'
exit 3
EOF
  run -3 "$BATS_TEST_TMPDIR/opencode-gate" run
}

@test "it starts no opencode that would run the gate's agents unguarded: no plugin, --pure, or a HOME the JSON cannot hold" {
  run -1 --separate-stderr "$BATS_TEST_TMPDIR/opencode-gate" serve --pure
  assert_equal "$stderr" "opencode-gate: --pure loads no plugin, so the gate's agents would run without command-guard"
  assert_equal "$output" ""
  rm "$PLUGIN"
  run -1 --separate-stderr "$BATS_TEST_TMPDIR/opencode-gate" serve
  assert_equal "$stderr" "opencode-gate: no command-guard plugin at $PLUGIN, so the gate's agents would run unguarded; the code checkout is ~/agent-team"
  assert_equal "$output" ""
  local odd=$BATS_TEST_TMPDIR/'odd"home'
  mkdir -p "$odd/agent-team/bin/lib"
  cp "$REPO_ROOT/bin/lib/opencode-guard.js" "$odd/agent-team/bin/lib/"
  run -1 --separate-stderr env HOME="$odd" "$BATS_TEST_TMPDIR/opencode-gate" serve
  assert_equal "$stderr" "opencode-gate: HOME ($odd) holds a quote or a backslash, so it cannot name the command-guard plugin $odd/agent-team/bin/lib/opencode-guard.js; the gate's agents would run unguarded"
  assert_equal "$output" ""
}

@test "the plugin refuses a bash call command-guard refuses, with its stderr and the gate agent's suffix, even with a worker's role set" {
  AGENT_TEAM_ROLE=builder handle 'killall load-check-probe-no-such-process'
  assert_contains "$output" "refused: Blocked by command-guard: a kill by name or pattern (killall), "
  assert_contains "$output" ". A guardrail: do not reach it another way."
  handle 'pgrep -f "vite preview" | xargs -r kill'
  assert_contains "$output" "refused: Blocked by command-guard: a kill of PIDs read from input"
  handle 'rm -r /load-check-probe-no-such-dir'
  assert_contains "$output" "refused: Blocked by command-guard: a recursive delete of /load-check-probe-no-such-dir, which is outside your worktree and your job's tmp"
  CLAUDE_JOB_DIR=$BATS_TEST_TMPDIR handle "rm -r $BATS_TEST_TMPDIR/tmp/x"
  assert_contains "$output" "refused: Blocked by command-guard: a recursive delete of $BATS_TEST_TMPDIR/tmp/x, which is outside your worktree"
}

@test "the plugin passes a bash call command-guard passes, judged in the session's worktree and the call's workdir, and another tool's call" {
  handle 'git status'
  assert_equal "$output" passed
  handle 'rm -r build'
  assert_equal "$output" passed
  handle 'rm -r ../src' build
  assert_equal "$output" passed
  handle 'rm -r ../../outside' build
  assert_contains "$output" "refused: Blocked by command-guard: a recursive delete of $BATS_TEST_TMPDIR/outside, which is outside"
  run -0 node "$DRIVER" "$REPO_ROOT/bin/lib/opencode-guard.js" "$WT" "$WT" read '{"filePath":"/etc/hosts"}'
  assert_equal "$output" passed
}

@test "the plugin gives command-guard a Claude-shaped input, the session's worktree and no role or job tmp" {
  fake_guard 'exit 0'
  run -0 env AGENT_TEAM_ROLE=builder AGENT_TEAM_TASK=T1 CLAUDE_JOB_DIR=/job CLAUDE_PROJECT_DIR=/elsewhere \
    node "$DRIVER" "$FAKE_PLUGIN" "$WT" "$WT" bash '{"command":"ls","workdir":"src"}'
  assert_equal "$output" passed
  run -0 jq -c . "$BATS_TEST_TMPDIR/input.json"
  assert_equal "$output" "$(jq -cn --arg d "$WT/src" '{tool_name: "Bash", tool_input: {command: "ls"}, cwd: $d}')"
  run -0 grep -E '^(AGENT_TEAM_ROLE|AGENT_TEAM_TASK|CLAUDE_JOB_DIR|CLAUDE_PROJECT_DIR)=' "$BATS_TEST_TMPDIR/env.txt"
  assert_equal "$output" "CLAUDE_PROJECT_DIR=$WT"
  # opencode names / as the worktree of a directory outside git: command-guard finds its own.
  run -0 env CLAUDE_PROJECT_DIR=/elsewhere node "$DRIVER" "$FAKE_PLUGIN" "$WT" / bash '{"command":"ls","workdir":"/abs"}'
  assert_equal "$output" passed
  assert_equal "$(jq -r .cwd "$BATS_TEST_TMPDIR/input.json")" /abs
  run -1 grep '^CLAUDE_PROJECT_DIR=' "$BATS_TEST_TMPDIR/env.txt"
}

@test "the plugin refuses when command-guard cannot decide: another exit, a signal, no guard to start, or a command that is not a string" {
  local suffix="; a guardrail, so do not reach it another way."
  fake_guard 'echo "python3: not found" >&2; exit 1'
  run -0 node "$DRIVER" "$FAKE_PLUGIN" "$WT" "$WT" bash '{"command":"ls"}'
  assert_equal "$output" "refused: Blocked by command-guard: it exited 1: python3: not found$suffix"
  fake_guard 'exit 2'
  run -0 node "$DRIVER" "$FAKE_PLUGIN" "$WT" "$WT" bash '{"command":"ls"}'
  assert_equal "$output" "refused: Blocked by command-guard: it exited 2$suffix"
  fake_guard 'kill -9 $$'
  run -0 node "$DRIVER" "$FAKE_PLUGIN" "$WT" "$WT" bash '{"command":"ls"}'
  assert_equal "$output" "refused: Blocked by command-guard: it was ended by SIGKILL$suffix"
  chmod -x "$BATS_TEST_TMPDIR/code/bin/hooks/command-guard"
  run -0 node "$DRIVER" "$FAKE_PLUGIN" "$WT" "$WT" bash '{"command":"ls"}'
  assert_contains "$output" "refused: Blocked by command-guard: it could not start (spawn $BATS_TEST_TMPDIR/code/bin/hooks/command-guard EACCES)$suffix"
  run -0 node "$DRIVER" "$REPO_ROOT/bin/lib/opencode-guard.js" "$WT" "$WT" bash '{"command":["ls"]}'
  assert_equal "$output" "refused: Blocked by command-guard: it could not read the bash call's command (args.command, a string)$suffix"
}

@test "the plugin module exports only functions, since opencode loads every export as a plugin" {
  run -0 node --input-type=module -e "const m = await import('$REPO_ROOT/bin/lib/opencode-guard.js'); console.log(Object.entries(m).map(([k, v]) => k + ':' + typeof v).join(' '))"
  assert_equal "$output" "CommandGuard:function"
}
