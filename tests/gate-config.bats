#!/usr/bin/env bats
# bin/lib/gate-config.awk: ~/.no-mistakes/config.yaml's agent_path_override.opencode, read for
# team-doctor's opencode-gate line and set by team-bootstrap's tools stage, every other byte of
# the file kept. The configs here hold a fake token, which no read may print.

load helpers/common

setup() {
  sandbox
  config=$BATS_TEST_TMPDIR/config.yaml
  wrapper=/Users/someone/.no-mistakes/bin/opencode-gate
}

# The key's value in $config.
read_key() {
  awk -f "$REPO_ROOT/bin/lib/gate-config.awk" "$config"
}

# $config with the key set to $wrapper, into $BATS_TEST_TMPDIR/out; extra arguments go to awk.
set_key() {
  awk -v set="$wrapper" "$@" -f "$REPO_ROOT/bin/lib/gate-config.awk" "$config" >"$BATS_TEST_TMPDIR/out"
}

@test "in block form the opencode line's value is replaced, its indent and comment kept, and nothing else changes" {
  printf '%s\n' 'agent: opencode' 'api_token: fake-token-123' 'agent_path_override:' \
    '    claude: /usr/bin/claude' '    opencode: "/home/danielc/.no-mistakes/bin/opencode-gate"  # the gate'"'"'s' \
    '' '# model routing' 'agent_model:' '  opencode:' '    review: deepseek/deepseek-flash' >"$config"
  run -0 read_key
  assert_equal "$output" /home/danielc/.no-mistakes/bin/opencode-gate
  set_key
  assert_equal "$(diff "$config" "$BATS_TEST_TMPDIR/out" || true)" "5c5
<     opencode: \"/home/danielc/.no-mistakes/bin/opencode-gate\"  # the gate's
---
>     opencode: $wrapper  # the gate's"
  cp "$BATS_TEST_TMPDIR/out" "$config"
  run -0 read_key
  assert_equal "$output" "$wrapper"
}

@test "a block without an opencode line gains one under its header, at its children's indent" {
  printf '%s\n' 'agent_path_override:' '    claude: /usr/bin/claude' 'agent_model:' '  opencode:' '    review: x' >"$config"
  run -0 read_key
  assert_equal "$output" ""
  set_key
  assert_equal "$(cat "$BATS_TEST_TMPDIR/out")" "agent_path_override:
    opencode: $wrapper
    claude: /usr/bin/claude
agent_model:
  opencode:
    review: x"
  # An empty block: two spaces.
  printf '%s\n' 'agent_path_override:  # wrappers' 'log_level: info' >"$config"
  set_key
  assert_equal "$(cat "$BATS_TEST_TMPDIR/out")" "agent_path_override:  # wrappers
  opencode: $wrapper
log_level: info"
}

@test "a flow mapping on one line has its opencode value replaced, or gains one" {
  printf '%s\n' 'agent: opencode' "agent_path_override: {codex: /x/codex, opencode: '/old' } # wrappers" >"$config"
  run -0 read_key
  assert_equal "$output" /old
  set_key
  assert_equal "$(cat "$BATS_TEST_TMPDIR/out")" "agent: opencode
agent_path_override: {codex: /x/codex, opencode: $wrapper } # wrappers"
  printf '%s\n' 'agent_path_override: {codex: /x/codex}' >"$config"
  set_key
  assert_equal "$(cat "$BATS_TEST_TMPDIR/out")" "agent_path_override: {opencode: $wrapper, codex: /x/codex}"
  printf '%s\n' 'agent_path_override: { }' >"$config"
  set_key
  assert_equal "$(cat "$BATS_TEST_TMPDIR/out")" "agent_path_override: {opencode: $wrapper}"
}

@test "a config without the key has it appended, and a file without a last newline keeps that" {
  printf 'agent: opencode\napi_token: fake-token-123' >"$config"
  run -0 read_key
  assert_equal "$output" ""
  set_key
  assert_equal "$(od -c "$BATS_TEST_TMPDIR/out")" "$(printf 'agent: opencode\napi_token: fake-token-123\nagent_path_override:\n  opencode: %s\n' "$wrapper" | od -c)"
  printf 'agent_path_override:\n  opencode: /old\napi_token: fake-token-123' >"$config"
  set_key -v eol=0
  assert_equal "$(od -c "$BATS_TEST_TMPDIR/out")" "$(printf 'agent_path_override:\n  opencode: %s\napi_token: fake-token-123' "$wrapper" | od -c)"
  : >"$config"
  set_key
  assert_equal "$(cat "$BATS_TEST_TMPDIR/out")" "agent_path_override:
  opencode: $wrapper"
}

@test "a path that needs quotes is double-quoted, and reads back" {
  wrapper='/Users/some one/.no-mistakes/bin/opencode-gate'
  printf '%s\n' 'agent_path_override:' '  opencode: /old' >"$config"
  set_key
  assert_equal "$(tail -n1 "$BATS_TEST_TMPDIR/out")" "  opencode: \"$wrapper\""
  cp "$BATS_TEST_TMPDIR/out" "$config"
  run -0 read_key
  assert_equal "$output" "$wrapper"
}

@test "a flow mapping over several lines, a scalar, or a path with a quote is refused with exit 3" {
  printf '%s\n' 'agent_path_override: {codex: /x,' '  opencode: /old}' >"$config"
  run -3 set_key
  printf '%s\n' 'agent_path_override: null' >"$config"
  run -3 set_key
  run -0 read_key
  assert_equal "$output" ""
  printf '%s\n' 'agent_path_override:' '  opencode: /old' >"$config"
  wrapper='/Users/a"b/opencode-gate'
  run -3 set_key
}
