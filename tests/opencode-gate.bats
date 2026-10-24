#!/usr/bin/env bats
# bin/lib/opencode-gate: the gate's opencode, installed as ~/.no-mistakes/bin/opencode-gate and
# named by config.yaml's agent_path_override, run here with a fake opencode on PATH.

load helpers/common

setup() {
  sandbox
  cp "$REPO_ROOT/tests/helpers/stub" "$BATS_TEST_TMPDIR/stubs/opencode"
  stub_script opencode <<'EOF'
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG-unset}"
printf 'OPENCODE_DISABLE_CLAUDE_CODE=%s\n' "${OPENCODE_DISABLE_CLAUDE_CODE-unset}"
printf 'arg=%s\n' "$@"
EOF
  install -m 755 "$REPO_ROOT/bin/lib/opencode-gate" "$BATS_TEST_TMPDIR/opencode-gate"
}

@test "it runs opencode with the gate-only config and without Claude Code's, every argument passed as it came" {
  run -0 env OPENCODE_CONFIG=/elsewhere.json "$BATS_TEST_TMPDIR/opencode-gate" serve --hostname 127.0.0.1 'a b'
  assert_equal "$output" "OPENCODE_CONFIG=$HOME/.no-mistakes/opencode-gate.json
OPENCODE_DISABLE_CLAUDE_CODE=1
arg=serve
arg=--hostname
arg=127.0.0.1
arg=a b"
}

@test "it is opencode itself once started: its exit code is opencode's" {
  stub_script opencode <<'EOF'
exit 3
EOF
  run -3 "$BATS_TEST_TMPDIR/opencode-gate" run
}
