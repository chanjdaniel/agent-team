#!/usr/bin/env bats
# hooks/axi-banner: a team session's SessionStart banner for one axi tool, printed once, whether
# or not the user settings still print it in every session.

load helpers/common

setup() {
  sandbox
  stub_command gh-axi chrome-devtools-axi
  stub_reply gh-axi "gh-axi banner"
  stub_reply chrome-devtools-axi "chrome-devtools-axi banner"
  mkdir -p "$HOME/.claude"
}

# The guard the PR proposes for each banner in the user settings (machine/claude/settings.json):
# it prints nothing in a team session, which sets AGENT_TEAM_ROLE through its settings' env.
guarded() {
  printf '[ -n "$AGENT_TEAM_ROLE" ] || %s' "$1"
}

# user_settings <command>...: user settings whose SessionStart runs each command, as the machine's do.
user_settings() {
  jq -n '{hooks: {SessionStart: [$ARGS.positional[] | {matcher: "", hooks: [{type: "command", command: ., timeout: 10}]}],
    UserPromptSubmit: [{hooks: [{type: "command", command: "codegraph prompt-hook"}]}]}}' --args "$@" \
    >"$HOME/.claude/settings.json"
}

# banner <tool>: run the hook on a SessionStart event, as Claude Code sends it.
banner() {
  run_bin -0 --separate-stderr hooks/axi-banner "$1" \
    <<<'{"session_id": "3169fcbd-0000-4000-8000-000000000000", "hook_event_name": "SessionStart", "source": "startup"}'
}

@test "while the user settings print the banner in every session, it prints nothing" {
  user_settings gh-axi chrome-devtools-axi lavish-axi
  AGENT_TEAM_ROLE=builder banner gh-axi
  assert_equal "$output$stderr" ""
  assert_equal "$(stub_calls gh-axi)" ""
}

@test "once the user settings print it outside the team only, it prints the banner" {
  user_settings "$(guarded gh-axi)" "$(guarded chrome-devtools-axi)" "$(guarded lavish-axi)"
  AGENT_TEAM_ROLE=builder banner gh-axi
  assert_equal "$output" "gh-axi banner"
  AGENT_TEAM_ROLE=reviewer banner chrome-devtools-axi
  assert_equal "$output" "chrome-devtools-axi banner"
}

@test "with no user settings, or none that run the tool, it prints the banner" {
  AGENT_TEAM_ROLE=planner banner gh-axi
  assert_equal "$output" "gh-axi banner"
  user_settings lavish-axi
  AGENT_TEAM_ROLE=planner banner chrome-devtools-axi
  assert_equal "$output" "chrome-devtools-axi banner"
}

@test "a tool whose name only contains the banner's is not it" {
  user_settings gh-axi-extra "my-gh-axi"
  AGENT_TEAM_ROLE=builder banner gh-axi
  assert_equal "$output" "gh-axi banner"
}

@test "the user settings in CLAUDE_CONFIG_DIR are the ones read" {
  user_settings gh-axi
  mv "$HOME/.claude" "$HOME/config"
  CLAUDE_CONFIG_DIR=$HOME/config AGENT_TEAM_ROLE=builder banner gh-axi
  assert_equal "$output" ""
}

@test "an ops session, which has no shell, gets no banner" {
  AGENT_TEAM_ROLE=ops banner gh-axi
  assert_equal "$output$stderr" ""
  assert_equal "$(stub_calls gh-axi)" ""
}

@test "a tool not on PATH prints nothing and fails no session" {
  AGENT_TEAM_ROLE=builder banner no-such-axi
  assert_equal "$output$stderr" ""
}

@test "anything but one tool name is a usage error" {
  run_bin -2 hooks/axi-banner </dev/null
  run_bin -2 hooks/axi-banner gh-axi extra </dev/null
  run_bin -2 hooks/axi-banner 'gh-axi; rm -rf x' </dev/null
  assert_equal "$(stub_calls gh-axi)" ""
}

# The proposal itself: each guarded banner prints nothing in a team session and the banner outside.
@test "the proposed guard prints nothing when AGENT_TEAM_ROLE is set, and the banner when it is not" {
  run -0 env AGENT_TEAM_ROLE=coordinator sh -c "$(guarded gh-axi)"
  assert_equal "$output" ""
  run -0 env -u AGENT_TEAM_ROLE sh -c "$(guarded gh-axi)"
  assert_equal "$output" "gh-axi banner"
  run -0 env AGENT_TEAM_ROLE= sh -c "$(guarded gh-axi)"
  assert_equal "$output" "gh-axi banner"
}
