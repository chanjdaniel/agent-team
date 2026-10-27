#!/usr/bin/env bats
# shellcheck disable=SC2153 # TOOL_STUBS, CONVENTIONER and the other globals are helpers/doctor.bash's
# team-bootstrap: a fresh machine set up stage by stage, on the machine tests/helpers/bootstrap.bash
# builds. This file: Daniel's steps, sudo among them, and --home.

load helpers/common
load helpers/doctor
load helpers/bootstrap

setup() {
  sandbox
  bootstrap_machine
}

@test "on Arch a step needing sudo is Daniel's without a terminal: one line naming it, exit 1, nothing tried" {
  fresh arch
  run_bin -1 team-bootstrap --name laptop
  assert_equal "$(tail -n1 <<<"$output")" "packages: Daniel: in your own terminal run $CODE_CHECKOUT/bin/team-bootstrap --stage packages, which runs pacman -S --needed $ARCH_PACKAGES with sudo and asks for your password; then team-bootstrap again"
  assert_equal "$(install_calls)" ""

  # Once Daniel has run it, the tools stage installs what needs no sudo and stops the same way
  # at what does: treehouse goes to /usr/local/bin, and op is 1Password's zip.
  # shellcheck disable=SC2086 # the list splits into packages
  installed_from "sudo pacman -S --needed " $ARCH_PACKAGES
  run_bin -1 team-bootstrap
  assert_equal "$(tail -n1 <<<"$output")" "tools: Daniel: in your own terminal run $CODE_CHECKOUT/bin/team-bootstrap --stage tools, which installs treehouse op with sudo and asks for your password; then team-bootstrap again"
  assert_equal "$(stub_calls npm | wc -l)" 6
  assert_contains "$output" "tools: running: $FORK_BUILD"
  assert_equal "$(stub_calls sudo)" ""
  [[ $output != *projects:* ]]
}

@test "on a fresh Arch without jq or Python the preflight asks for them first, before anything needs jq" {
  fresh arch
  local bin=$BATS_TEST_TMPDIR/without-jq dir dirs
  mkdir -p "$bin"
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    [[ -d $dir ]] && ln -s "$dir"/* "$bin/" 2>/dev/null || true
  done
  rm -f "$bin/jq" "$bin"/python3* "$bin/uname"
  # The sandbox's uname logs its calls with jq; this one only answers.
  printf '#!/bin/sh\necho Linux\n' >"$bin/uname"
  chmod +x "$bin/uname"
  PATH=$bin run_bin -1 team-bootstrap --name laptop
  assert_equal "$output" "preflight: Arch Linux
preflight: Daniel: in your own terminal run $CODE_CHECKOUT/bin/team-bootstrap --stage preflight, which runs pacman -S --needed jq python with sudo and asks for your password; then team-bootstrap again"
  assert_equal "$(install_calls)" ""
}

@test "on a fresh Mac without jq or Python the preflight installs them with brew, Python as the lock's formula" {
  fresh macos
  local bin=$BATS_TEST_TMPDIR/without-jq dir dirs formula
  mkdir -p "$bin"
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    [[ -d $dir ]] && ln -s "$dir"/* "$bin/" 2>/dev/null || true
  done
  rm -f "$bin/jq" "$bin"/python3* "$bin/uname" "$bin/xcode-select"
  # The sandbox's stubs log their calls with jq; these only answer.
  printf '#!/bin/sh\necho Darwin\n' >"$bin/uname"
  printf '#!/bin/sh\necho /Library/Developer/CommandLineTools\n' >"$bin/xcode-select"
  chmod +x "$bin/uname" "$bin/xcode-select"
  formula=$(jq -r '.tools[] | select(.name == "python") | .source.macos | ltrimstr("brew install ")' "$LOCK")
  PATH=$bin run_bin -1 team-bootstrap --name laptop --dry-run
  assert_equal "$(head -n2 <<<"$output")" "preflight: macOS
preflight: would run: brew install jq $formula"
  assert_equal "$(install_calls)" ""
}

@test "in Daniel's own terminal the sudo steps run, sudo asking for the password" {
  fresh arch
  run_in_terminal -1 -- "$CODE_CHECKOUT/bin/team-bootstrap" --name laptop
  assert_contains "$output" "packages: running: sudo pacman -S --needed --noconfirm $ARCH_PACKAGES"
  assert_equal "$(stub_calls sudo | jq -r '.[0]' | uniq | paste -sd ' ' -)" "pacman mkdir tar unzip groupadd chgrp chmod"
  assert_equal "$(stub_calls sudo | jq -c 'select(.[0] == "tar") | .[3:]')" '["-C","/usr/local/bin","treehouse"]'
  # Every tool line passes now; what is left is Daniel's own.
  assert_contains "$output" "check: summary: not set up yet: only Daniel's steps above are left; then team-bootstrap again"
  [[ $output != *"FAIL tool "* ]]
  # With no ~/agent-team-records there is nothing to name yet: the doctor's team home line says to clone it.
  [[ $output != *"team home: name"* ]]
  assert_contains "$output" "check: Daniel 1: docker: Daniel runs sudo systemctl enable --now docker.service ("
}

@test "each of Daniel's steps stops the run where it falls, with one line, without trying it" {
  # The Xcode tools, before anything else (the doctor is not even asked).
  fresh macos
  stub_reply xcode-select "xcode-select: error: unable to get active developer directory" 2
  : >"$STUB_CALLS/claude.log"
  run_bin -1 team-bootstrap --name laptop
  assert_equal "$output" "preflight: macOS
preflight: Daniel: install the Xcode Command Line Tools: run xcode-select --install and accept its dialog; then team-bootstrap again"
  assert_equal "$(stub_calls claude)" ""

  # Homebrew, where no brew is on PATH.
  stub_reply xcode-select /Library/Developer/CommandLineTools
  rm "$BATS_TEST_TMPDIR/stubs/brew"
  if ! command -v brew >/dev/null; then
    run_bin -1 team-bootstrap --name laptop
    assert_equal "$(tail -n1 <<<"$output")" "preflight: Daniel: install Homebrew as https://brew.sh says (it asks for your admin password), add the brew shellenv line it prints to ~/.zprofile, open a new terminal, then team-bootstrap again"
  fi
  stub_command brew

  # The machine's name.
  run_bin -1 team-bootstrap
  assert_equal "$(tail -n1 <<<"$output")" "machine: Daniel: name this machine for the team (laptop, home-pc: never the hostname), then run team-bootstrap --name <name>"
  assert_equal "$(install_calls)" ""

  # The GitHub login the clones need; the stages before it still run.
  stub_script gh <<'EOF2'
exit 1
EOF2
  run_bin -1 team-bootstrap --name laptop
  assert_equal "$(tail -n1 <<<"$output")" "projects: Daniel: sign gh in to GitHub, which the clones need: gh auth login --hostname github.com --git-protocol https --web, then gh auth setup-git; then team-bootstrap again"
  assert_contains "$output" "tools: running: "
  [[ ! -e $STUB_CALLS/git-clone.log ]]

  # A folder in a project's way.
  stub_script gh <<'EOF2'
echo "  - Token: gho_fakefakefakefake"
EOF2
  mkdir -p "$CONVENTIONER"
  run_bin -1 team-bootstrap
  assert_equal "$(tail -n1 <<<"$output")" "projects: Daniel: move it aside, then git clone https://github.com/chanjdaniel/Conventioner.git ~/projects/Conventioner (~/projects/Conventioner is not a git checkout)"
  [[ ! -e $STUB_CALLS/git-clone.log ]]
}

@test "an untrusted team home, where the coordinator starts, is one of Daniel's steps, and the only one" {
  tools_at arch
  echo "$TEAM_HOME" >"$STUB_FIXTURES/untrusted"
  run_bin -1 team-bootstrap --stage check
  assert_equal "$(stage_lines check | grep '^Daniel')" "Daniel 1: trust team home: Daniel runs claude once in $TEAM_HOME and accepts the trust dialog (claude --bg in $TEAM_HOME says Workspace not trusted)"
  assert_equal "$(stage_lines check | tail -n1)" "summary: not set up yet: only Daniel's steps above are left; then team-bootstrap again"
  # Every project root was probed too, and trusted.
  assert_equal "$(cat "$STUB_CALLS/claude-bg.pwd")" "$TEAM_HOME
$CONVENTIONER
$SITE"
}

@test "the dev guard and the records guard, off, are Daniel's steps, in that order" {
  tools_at arch
  git -C "$CODE_CHECKOUT" config --unset core.hooksPath
  git -C "$TEAM_HOME" config --unset core.hooksPath
  run_bin -1 team-bootstrap --stage check
  assert_equal "$(stage_lines check | grep '^Daniel')" "Daniel 1: git hooks: Daniel runs git -C $CODE_CHECKOUT config core.hooksPath bin/hooks/git (core.hooksPath is unset, so git runs none of bin/hooks/git)
Daniel 2: records hooks: Daniel runs git -C $TEAM_HOME config core.hooksPath $CODE_CHECKOUT/bin/hooks/records-git (the team home's core.hooksPath is unset, so git runs no data check on its commits)"
  assert_equal "$(stage_lines check | tail -n1)" "summary: not set up yet: only Daniel's steps above are left; then team-bootstrap again"
}

@test "two or more untrusted roots are one of Daniel's steps: the trust stage in their own terminal (report F2)" {
  tools_at arch
  printf '%s\n' "$TEAM_HOME" "$CONVENTIONER" >"$STUB_FIXTURES/untrusted"
  run_bin -1 team-bootstrap --stage check
  assert_equal "$(stage_lines check | grep '^Daniel')" "Daniel 1: trust: in your own terminal run $CODE_CHECKOUT/bin/team-bootstrap --stage trust, which starts claude in each untrusted root in turn for you to accept its trust dialog (trust team home, trust conventioner)"
  assert_equal "$(stage_lines check | tail -n1)" "summary: not set up yet: only Daniel's steps above are left; then team-bootstrap again"
}

@test "the trust stage refuses unless stdin and stdout are a terminal, before the doctor runs" {
  tools_at arch
  printf '%s\n' "$TEAM_HOME" "$CONVENTIONER" >"$STUB_FIXTURES/untrusted"
  : >"$STUB_CALLS/claude.log"
  run_bin -1 team-bootstrap --stage trust
  assert_equal "$output" "team-bootstrap: --stage trust runs only in Daniel's own terminal (stdin and stdout a terminal), never in an agent's shell: type $CODE_CHECKOUT/bin/team-bootstrap --stage trust there"
  # stdin a terminal, stdout not.
  run_in_terminal -1 -- bash -c '"$0" --stage trust >"$1"' "$CODE_CHECKOUT/bin/team-bootstrap" "$BATS_TEST_TMPDIR/out"
  assert_contains "$output" "--stage trust runs only in Daniel's own terminal"
  assert_equal "$(stub_calls claude)" ""
  # A dry run only says which roots it would start claude in.
  run_bin -0 team-bootstrap --stage trust --dry-run
  assert_equal "$output" "trust: would start claude in $TEAM_HOME (trust team home) for you to accept its trust dialog
trust: would start claude in ~/projects/Conventioner (trust conventioner) for you to accept its trust dialog"
  [[ ! -e $STUB_CALLS/claude-session.pwd ]]
}

@test "the trust stage starts claude in each untrusted root once, in the doctor's order, and ends done (report F2)" {
  tools_at arch
  printf '%s\n' "$SITE" "$TEAM_HOME" "$CONVENTIONER" >"$STUB_FIXTURES/untrusted"
  run_in_terminal -0 -- "$CODE_CHECKOUT/bin/team-bootstrap" --stage trust
  assert_equal "$(cat "$STUB_CALLS/claude-session.pwd")" "$TEAM_HOME
$CONVENTIONER
$SITE"
  assert_equal "$(stage_lines trust)" "1 of 3: $TEAM_HOME (trust team home): accept Claude Code's trust dialog, then type /exit
trusted: $TEAM_HOME
2 of 3: ~/projects/Conventioner (trust conventioner): accept Claude Code's trust dialog, then type /exit
trusted: ~/projects/Conventioner
3 of 3: ~/projects/site (trust site): accept Claude Code's trust dialog, then type /exit
trusted: ~/projects/site
done: claude trusts the team home and every project root"
  assert_equal "$(tail -n1 <<<"$output")" "trust: done: claude trusts the team home and every project root"
  # Each probe session is removed: the doctor's names, the re-probes after it.
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] == "--bg") | .[2]' | sort | uniq -c | awk '{ print $1, $2 }')" "2 team-doctor-home-trust
2 team-doctor-trust-conventioner
2 team-doctor-trust-site"

  # With every root trusted it starts no session, terminal or not.
  rm "$STUB_CALLS/claude-session.pwd"
  run_in_terminal -0 -- "$CODE_CHECKOUT/bin/team-bootstrap" --stage trust
  assert_equal "$output" "trust: done: claude trusts the team home and every project root"
  [[ ! -e $STUB_CALLS/claude-session.pwd ]]
}

@test "a root still untrusted after its session is said, the stage goes on, and exits 1" {
  tools_at arch
  printf '%s\n' "$TEAM_HOME" "$CONVENTIONER" "$SITE" >"$STUB_FIXTURES/untrusted"
  echo "$CONVENTIONER" >"$STUB_FIXTURES/declined"
  run_in_terminal -1 -- "$CODE_CHECKOUT/bin/team-bootstrap" --stage trust
  assert_equal "$(cat "$STUB_CALLS/claude-session.pwd")" "$TEAM_HOME
$CONVENTIONER
$SITE"
  assert_contains "$output" "trust: still not trusted: ~/projects/Conventioner (claude --bg in ~/projects/Conventioner says Workspace not trusted); on to the next"
  assert_contains "$output" "trust: trusted: ~/projects/site"
  assert_equal "$(tail -n1 <<<"$output")" "trust: not done: claude does not trust ~/projects/Conventioner yet; run $CODE_CHECKOUT/bin/team-bootstrap --stage trust again and accept its dialog"
}

@test "a trust line failing otherwise is said with the doctor's fix and left, and no session starts there" {
  tools_at arch
  printf '%s\n' "$TEAM_HOME" >"$STUB_FIXTURES/untrusted"
  echo "$SITE" >"$STUB_FIXTURES/no-session"
  run_in_terminal -1 -- "$CODE_CHECKOUT/bin/team-bootstrap" --stage trust
  assert_equal "$(cat "$STUB_CALLS/claude-session.pwd")" "$TEAM_HOME"
  assert_equal "$(stage_lines trust | head -n1)" "left: trust site: \`claude --bg\` in ~/projects/site printed no session id (exit 1): Error: something else went wrong; fix: the tool claude and claude login lines"
  assert_contains "$output" "trust: trusted: $TEAM_HOME"
  assert_equal "$(tail -n1 <<<"$output")" "trust: not done: claude does not trust ~/projects/site yet; run $CODE_CHECKOUT/bin/team-bootstrap --stage trust again and accept its dialog"
}

@test "--home writes the team home's setting once, relative to HOME, and never over another or for a missing checkout" {
  fresh arch
  # Until ~/agent-team-records is cloned the check stage asks for no setting, which --home would refuse.
  run_bin -1 team-bootstrap --stage check
  [[ $output != *"team home: name"* ]]
  run_bin -1 team-bootstrap --stage machine --name laptop --home agent-team-records
  assert_equal "$output" "machine: named this machine laptop (~/.config/agent-team/machine)
machine: ~/agent-team-records is not a directory: clone the team home there first, then team-bootstrap --home agent-team-records again"
  [[ ! -e $HOME/.config/agent-team/home ]]
  mkdir "$HOME/agent-team-records"
  run_bin -1 team-bootstrap --stage check
  assert_contains "$output" ": team home: name the team home's checkout for this machine: team-bootstrap --home agent-team-records (~/.config/agent-team/home is missing)"
  run_bin -0 team-bootstrap --stage machine --home agent-team-records
  assert_equal "$output" "machine: done: this machine is laptop
machine: named the team home ~/agent-team-records (~/.config/agent-team/home)
machine: done: the team home fetches only dev and lease"
  assert_equal "$(cat "$HOME/.config/agent-team/home")" agent-team-records
  # Once written, the same checkout (however named) is done, and another is left unused.
  run_bin -0 team-bootstrap --stage machine --home "$HOME/agent-team-records"
  assert_equal "$(stage_lines machine | sed -n 2p)" "done: ~/.config/agent-team/home names ~/agent-team-records"
  run_bin -0 team-bootstrap --stage machine --home "$(other_spelling "$HOME/agent-team-records")"
  assert_equal "$(stage_lines machine | sed -n 2p)" "done: ~/.config/agent-team/home names ~/agent-team-records"
  mkdir "$HOME/elsewhere"
  run_bin -0 team-bootstrap --stage machine --home elsewhere
  assert_equal "$(stage_lines machine | sed -n 2p)" "done: ~/.config/agent-team/home already names ~/agent-team-records; --home elsewhere is left unused"
  assert_equal "$(cat "$HOME/.config/agent-team/home")" agent-team-records
  # The check stage no longer lists it.
  run_bin -1 team-bootstrap --stage check
  [[ $output != *"team home: name"* ]]
}

@test "the setting --home writes is the team home for the rest of the run when TEAM_HOME is unset" {
  fresh arch
  tools_at arch
  echo laptop >"$HOME/.config/agent-team/machine"
  mv "$TEAM_HOME" "$HOME/agent-team-records"
  unset TEAM_HOME
  run -1 "$CODE_CHECKOUT/bin/team-bootstrap" --home agent-team-records
  assert_contains "$output" "machine: named the team home ~/agent-team-records (~/.config/agent-team/home)"
  assert_contains "$output" "check: doctor: "
  # The stages after it read the doctor on that team home: its projects are cloned.
  assert_equal "$(cat "$STUB_CALLS/git-clone.log")" "clone -q https://github.com/chanjdaniel/Conventioner.git $CONVENTIONER
clone -q https://github.com/owner/site.git $SITE"
  assert_contains "$output" "check: doctor: "
  [[ $output != *" team home: "* && $output != *" records: "* && $output != *"FAIL checkout "* ]]
}

@test "with nothing naming the team home, the machine stage stops on Daniel's step to clone and name it" {
  fresh arch
  tools_at arch
  echo laptop >"$HOME/.config/agent-team/machine"
  unset TEAM_HOME
  run -1 "$CODE_CHECKOUT/bin/team-bootstrap"
  assert_equal "$(tail -n1 <<<"$output")" "machine: Daniel: clone the team home, then name it for this machine: git clone --single-branch --branch dev https://github.com/chanjdaniel/agent-team-records.git ~/agent-team-records && git -C ~/agent-team-records remote set-branches --add origin lease && git -C ~/agent-team-records config core.hooksPath ~/agent-team/bin/hooks/records-git && team-bootstrap --home agent-team-records"
  [[ ! -e $STUB_CALLS/git-clone.log ]]
  # Once it is cloned, only naming it is left; the check stage says the same.
  mkdir "$HOME/agent-team-records"
  run -1 "$CODE_CHECKOUT/bin/team-bootstrap"
  assert_equal "$(tail -n1 <<<"$output")" "machine: Daniel: name the team home's checkout for this machine: team-bootstrap --home agent-team-records"
  rmdir "$HOME/agent-team-records"
  run -1 "$CODE_CHECKOUT/bin/team-bootstrap" --stage check
  assert_contains "$output" "check: Daniel 1: team home: clone the team home, then name it for this machine: git clone --single-branch --branch dev https://github.com/chanjdaniel/agent-team-records.git ~/agent-team-records && git -C ~/agent-team-records remote set-branches --add origin lease && git -C ~/agent-team-records config core.hooksPath ~/agent-team/bin/hooks/records-git && team-bootstrap --home agent-team-records (~/.config/agent-team/home is missing)"
  [[ $output != *"these failed: "*"team home"* ]]
}
