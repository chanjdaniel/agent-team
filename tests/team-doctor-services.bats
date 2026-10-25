#!/usr/bin/env bats
# shellcheck disable=SC2153 # LOCK and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the docker, chrome, 1password, secret, opencode-gate and records lines.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
}

# docker info fails as the CLI does when it cannot reach the daemon: daemon_refuses <stderr line>
daemon_refuses() {
  printf 'echo %q >&2\nexit 1\n' "$1" >"$TOOL_ANSWERS/docker/info_--format_{{.ServerVersion}}.sh"
}

@test "the docker line fails while the daemon does not answer this user, with Daniel's step for the OS" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of docker)" "PASS docker: the Docker daemon answers (server 28.3.3)"
  daemon_refuses "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.51/info\": dial unix /var/run/docker.sock: connect: permission denied"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL docker: \`docker info\` cannot reach the daemon: permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.51/info\": dial unix /var/run/docker.sock: connect: permission denied; fix: Daniel runs sudo usermod -aG docker \$USER, then logs out and in"
  daemon_refuses "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
  run_bin -1 team-doctor
  assert_equal "$(line_of docker)" "FAIL docker: \`docker info\` cannot reach the daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?; fix: Daniel runs sudo systemctl enable --now docker.service"
  on_macos
  tools_at macos
  run_bin -1 team-doctor
  assert_equal "$(line_of docker)" "FAIL docker: \`docker info\` cannot reach the daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?; fix: Daniel opens Docker Desktop once and accepts its license"
}

@test "the chrome line warns without Google Chrome or Chromium, with this OS's install" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of chrome)" "PASS chrome: $TEAM_CHROME"
  rm "$TEAM_CHROME"
  run_bin -0 team-doctor
  assert_equal "$(line_of chrome)" "WARN chrome: neither Google Chrome nor Chromium is installed, so chrome-devtools-axi has no browser; fix: Daniel installs google-chrome from the AUR, or runs sudo pacman -S --needed chromium"
  # Without the seam, Arch looks for the browser's command.
  unset TEAM_CHROME
  printf '#!/bin/sh\n' >"$TOOL_STUBS/google-chrome-stable"
  chmod +x "$TOOL_STUBS/google-chrome-stable"
  run_bin -0 team-doctor
  assert_equal "$(line_of chrome)" "PASS chrome: $TOOL_STUBS/google-chrome-stable"
  on_macos
  tools_at macos
  run_bin -0 team-doctor
  [[ -e "/Applications/Google Chrome.app" ]] ||
    assert_equal "$(line_of chrome)" "WARN chrome: Google Chrome is not installed, so chrome-devtools-axi has no browser; fix: brew install --cask google-chrome"
}

@test "the 1password line warns without op or the app, never asking the vault" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 1password)" "PASS 1password: op and the 1Password app are installed (the vault is not asked)"
  rm "$TEAM_1PASSWORD_APP"
  run_bin -0 team-doctor
  assert_equal "$(line_of 1password)" "WARN 1password: the 1Password app is not at $TEAM_1PASSWORD_APP, so team-secrets restore can only ask for each secret to be pasted; fix: install the native 1password package from the AUR (not the Snap or Flatpak), then turn on its Settings > Developer > Integrate with 1Password CLI"
  answer "op --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of 1password)" "WARN 1password: op is not installed and the 1Password app is not at $TEAM_1PASSWORD_APP, so team-secrets restore can only ask for each secret to be pasted; fix: the tool op line's fix; install the native 1password package from the AUR (not the Snap or Flatpak), then turn on its Settings > Developer > Integrate with 1Password CLI"
  on_macos
  tools_at macos
  touch "$TEAM_1PASSWORD_APP"
  run_bin -0 team-doctor
  assert_equal "$(line_of 1password)" "PASS 1password: op and the 1Password app are installed (the vault is not asked)"
  unset TEAM_1PASSWORD_APP
  run_bin -0 team-doctor
  [[ -e /Applications/1Password.app ]] ||
    assert_equal "$(line_of 1password)" "WARN 1password: the 1Password app is not at /Applications/1Password.app, so team-secrets restore can only ask for each secret to be pasted; fix: brew install --cask 1password, then turn on its Settings > Developer > Integrate with 1Password CLI"
  # op was asked its version alone, by its tool line, never the vault.
  assert_equal "$(stub_calls op)" ""
}

@test "the secret lines fail per missing, empty, open or misplaced secret with team-secrets restore; a broken manifest fails" {
  tools_at arch
  rm "$HOME/.claude/channels/discord/.env"
  : >"$HOME/.claude/channels/discord/access.json"
  chmod 644 "$HOME/Documents/projects/personal/Conventioner/.env"
  rm "$HOME/Documents/projects/personal/Conventioner/back-end/.env"
  mkdir "$HOME/Documents/projects/personal/Conventioner/back-end/.env"
  run_bin -1 team-doctor
  assert_equal "$(grep -E '^.... secret' <<<"$output")" "FAIL secret discord-bot-env: missing; fix: Daniel runs team-secrets restore in their own terminal
FAIL secret discord-access-json: empty; fix: Daniel runs team-secrets restore in their own terminal
FAIL secret conventioner-env: mode 644; fix: Daniel runs team-secrets restore in their own terminal
PASS secret conventioner-front-end-env: in place
FAIL secret conventioner-back-end-env: not a file; fix: move aside what is at its target in machine/secrets.json, then Daniel runs team-secrets restore in their own terminal"
  # Nothing else fails.
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^FAIL secret ' || true)" ""
  echo '[]' >"$TEAM_HOME/machine/secrets.json"
  run_bin -1 team-doctor
  assert_equal "$(grep -E '^.... secret' <<<"$output")" "FAIL secrets: machine/secrets.json: it has no secrets array; fix: fix what team-secrets names, then run team-doctor again"
  rm "$TEAM_HOME/machine/secrets.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of secrets)" "FAIL secrets: no machine/secrets.json in $TEAM_HOME; fix: fix what team-secrets names, then run team-doctor again"
}

@test "the opencode-gate line fails while the gate's opencode wrapper is missing, stale or not executable, or config.yaml does not name it" {
  local wrapper=$HOME/.no-mistakes/bin/opencode-gate config=$HOME/.no-mistakes/config.yaml
  local install="mkdir -p ~/.no-mistakes/bin && install -m 755 $CODE_CHECKOUT/bin/lib/opencode-gate ~/.no-mistakes/bin/opencode-gate"
  local setting="agent_path_override: {opencode: $wrapper}" tools="$CODE_CHECKOUT/bin/team-bootstrap --stage tools"
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of opencode-gate)" "PASS opencode-gate: ~/.no-mistakes/bin/opencode-gate is the code's bin/lib/opencode-gate, and config.yaml's agent_path_override names it for opencode"
  # The flow form, quoted, is read too; a comment after it is not part of the path.
  printf '%s\n' 'agent: opencode' "agent_path_override: {codex: /x/codex, opencode: \"$wrapper\"} # the gate's" >"$config"
  run_bin -0 team-doctor
  assert_contains "$(line_of opencode-gate)" "PASS opencode-gate: "

  printf '%s\n' 'agent: opencode' 'agent_path_override:' '  opencode: /usr/bin/opencode' 'log_level: info' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent_path_override does not name ~/.no-mistakes/bin/opencode-gate for opencode, so the gate's opencode reads Claude Code's config and not the gate's own; fix: $tools, which sets $setting in ~/.no-mistakes/config.yaml, that key alone"
  # A key of that name under another block is not the setting.
  printf '%s\n' 'agent: opencode' 'agent_args_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_contains "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent_path_override does not name"
  rm "$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml is not there; fix: Daniel runs team-secrets restore in their own terminal (the secret no-mistakes-config), then $tools sets $setting in it"

  chmod 644 "$wrapper"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/bin/opencode-gate is not executable; fix: $install"
  echo 'exec opencode "$@"' >>"$wrapper"
  chmod 755 "$wrapper"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/bin/opencode-gate is not the code's bin/lib/opencode-gate; fix: $install"
  rm "$wrapper"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/bin/opencode-gate is not installed; fix: $install"
  # Nothing else fails, on macOS alike.
  assert_equal "$(grep -v '^PASS ' <<<"$output" || true)" "$(line_of opencode-gate)"
  on_macos
  tools_at macos
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/bin/opencode-gate is not installed; fix: $install"
}

# The records line's fix, after the problems it names.
RECORDS_FIX="fix what it names in the team home (team-log --check and team-project --check list every problem), then run team-doctor again"

@test "the records line fails on a ledger that breaks its contract, naming its first problem and the count" {
  tools_at arch
  printf '%s\n' '{"ts": "2026-10-24T01:00:00Z", "task": "T1", "event": "launch", "role": "builder", "session": "a1", "worktree": "/w"}' \
    'not json' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: $TEAM_HOME/ledger.jsonl:1: launch needs toolkits (2 of 2 lines break the ledger contract); fix: $RECORDS_FIX"
  # Nothing else fails.
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^FAIL records: ' || true)" ""
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: no ledger at $TEAM_HOME/ledger.jsonl; fix: $RECORDS_FIX"
}

@test "the records line fails on a registry team-project --check refuses, naming its first problem and the count" {
  tools_at arch
  sed -i 's/^base = "main"$/base = 5/' "$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: $TEAM_HOME/projects.toml: conventioner.base: must be a string (2 problems); fix: $RECORDS_FIX"
  # team-config diff and the projects line refuse the same registry; nothing else fails.
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^FAIL records: ' | cut -d: -f1 | paste -sd , || true)" \
    "WARN config,FAIL plugins,WARN memory,FAIL projects"
}

@test "the records line fails on each enabled secret machine/secrets.md has no row for; a disabled one needs none" {
  tools_at arch
  sed -i -e '/^| `conventioner-env` |/d' -e '/^| `discord-bot-env` |/d' -e '/^| `hub-env` |/d' "$TEAM_HOME/machine/secrets.md"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: machine/secrets.md has no row for discord-bot-env, conventioner-env; fix: $RECORDS_FIX"
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v '^FAIL records: ' || true)" ""
  # Every problem at once, one after another.
  echo 'not json' >>"$TEAM_HOME/ledger.jsonl"
  rm "$TEAM_HOME/machine/secrets.md"
  run_bin -1 team-doctor
  assert_equal "$(line_of records)" "FAIL records: $TEAM_HOME/ledger.jsonl:1: not JSON (1 of 1 lines break the ledger contract); no machine/secrets.md in $TEAM_HOME; fix: $RECORDS_FIX"
}
