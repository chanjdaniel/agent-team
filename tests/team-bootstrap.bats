#!/usr/bin/env bats
# shellcheck disable=SC2153 # TOOL_STUBS, CONVENTIONER and the other globals are helpers/doctor.bash's
# team-bootstrap: a fresh machine set up stage by stage, on the machine tests/helpers/bootstrap.bash
# builds. This file: whole runs, --dry-run, --stage and the usage;
# team-bootstrap-*.bats hold the rest.

load helpers/common
load helpers/doctor
load helpers/bootstrap

setup() {
  sandbox
  bootstrap_machine
}
@test "on a set-up machine every stage is done, nothing is installed or changed, and the summary says so" {
  tools_at arch
  local before
  before=$(footprint)
  run_bin -0 team-bootstrap
  assert_equal "$(grep -v '^check: ' <<<"$output")" "preflight: Arch Linux
preflight: done: jq, git and Python 3.11 are installed
machine: done: this machine is home-pc
machine: done: ~/.config/agent-team/home names $TEAM_HOME
packages: done: every OS package is installed
tools: done: every tool is at its pin or above its minimum
projects: done: every project is cloned and set up
config: done: this machine's Claude config is the team home's
heartbeat: done: enabled, and this machine holds the lease"
  assert_contains "$output" "check: summary: set up, and this machine holds the lease"
  assert_equal "$(install_calls)" ""
  assert_equal "$(footprint)" "$before"
  # The doctor ran once: nothing changed, so check reads the same answer.
  assert_equal "$(grep -c '"auth","status","--json"' "$STUB_CALLS/claude.log")" 1

  # A WARN is passed on, as Daniel's step where it is one, and still changes nothing.
  rm "$TEAM_CHROME"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines check | grep -v '^doctor: [0-9]')" "Daniel 1: chrome: Daniel installs google-chrome from the AUR, or runs sudo pacman -S --needed chromium (neither Google Chrome nor Chromium is installed, so chrome-devtools-axi has no browser)
doctor: WARN chrome: neither Google Chrome nor Chromium is installed, so chrome-devtools-axi has no browser; fix: Daniel installs google-chrome from the AUR, or runs sudo pacman -S --needed chromium
summary: set up, and this machine holds the lease"
  assert_equal "$(install_calls)" ""
}

@test "a fresh Mac: every stage installs what its doctor lines lack, then Daniel's steps in order; a second run installs nothing" {
  fresh macos
  run_bin -1 team-bootstrap --name laptop --home "$TEAM_HOME"
  local sha
  sha=$(jq -r '.tools[] | select(.name == "treehouse") | .release.sha256["darwin-arm64"]' "$LOCK")
  assert_equal "$(stage_lines machine)" "named this machine laptop (~/.config/agent-team/machine)
named the team home $TEAM_HOME (~/.config/agent-team/home)"
  assert_equal "$(head -n1 "$HOME/.config/agent-team/machine")" laptop
  assert_equal "$(cat "$HOME/.config/agent-team/home")" "$TEAM_HOME"
  assert_equal "$(stage_lines packages)" "running: brew install 1password-cli git jq tmux gh rsync python bash go coreutils findutils gnu-sed grep flock
running: brew install --cask docker-desktop"
  assert_equal "$(stage_lines tools | sed -n '1,4p;11,13p')" "running: curl -fsSL https://claude.ai/install.sh | bash -s 2.1.308
running: curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
running: nvm install 22.19.0 && nvm alias default 22.19.0
running: npm install -g @colbymchenry/codegraph@1.6.0
running: f=\$(mktemp) && curl -fsSLo \"\$f\" https://github.com/kunchenguid/treehouse/releases/download/v3.1.5/treehouse-v3.1.5-darwin-arm64.tar.gz && echo \"$sha  \$f\" | shasum -a 256 -c && mkdir -p ~/.local/bin && tar -xzf \"\$f\" -C ~/.local/bin treehouse && rm -f \"\$f\"
running: $FORK_BUILD
running: mkdir -p ~/.no-mistakes/bin && install -m 755 $CODE_CHECKOUT/bin/lib/opencode-gate ~/.no-mistakes/bin/opencode-gate"
  # The build: the fork cloned into a new temporary directory (<d> here), built there and installed.
  assert_equal "$(sed -E 's#[^ ]*/tmp\.[[:alnum:]]+#<d>#g' "$STUB_CALLS/fork-build.log")" "clone -q https://github.com/chanjdaniel/no-mistakes <d>
git checkout -q ac6b53fbbac10a4ca6c940b004fd9c5f557f983e
make build
install -m 755 <d>/bin/no-mistakes $HOME/.no-mistakes/bin/no-mistakes"
  assert_equal "$(stage_lines tools | tail -n 2)" "running: add ~/.local/bin to PATH in ~/.zshrc
running: add ~/.no-mistakes/bin to PATH in ~/.zshrc"
  assert_equal "$(cat "$HOME/.zshrc")" "export PATH=\"\$HOME/.local/bin:\$PATH\" # team-bootstrap
export PATH=\"\$HOME/.no-mistakes/bin:\$PATH\" # team-bootstrap"
  assert_equal "$(cat "$STUB_CALLS/git-clone.log")" "clone -q https://github.com/chanjdaniel/Conventioner.git $CONVENTIONER
clone -q https://github.com/owner/site.git $SITE"
  assert_equal "$(stage_lines config)" "running: claude plugin marketplace add anthropics/claude-plugins-official
running: claude plugin install discord@claude-plugins-official --scope user
running: claude plugin install mongodb-atlas@claude-plugins-official --scope user
running: team-config apply
running: claude plugin disable discord@claude-plugins-official --scope user"
  assert_equal "$(stage_lines heartbeat)" "done: disabled until this machine takes the lease (team-resume enables it)"
  assert_equal "$(stage_lines check | grep '^Daniel')" "Daniel 1: docker: Daniel opens Docker Desktop once and accepts its license (\`docker info\` cannot reach the daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?)
Daniel 2: 1password: brew install --cask 1password, then turn on its Settings > Developer > Integrate with 1Password CLI (the 1Password app is not at $TEAM_1PASSWORD_APP, so team-secrets restore can only ask for each secret to be pasted)
Daniel 3: secrets: with the 1Password app signed in and its CLI integration on, in your own terminal, not through an agent: $CODE_CHECKOUT/bin/team-secrets restore (missing: discord-bot-env discord-access-json conventioner-env conventioner-front-end-env conventioner-back-end-env)
Daniel 4: opencode-gate: Daniel runs team-secrets restore in their own terminal (the secret no-mistakes-config) and sets agent_path_override: {opencode: $HOME/.no-mistakes/bin/opencode-gate} in it, as manual-steps.md's install of the no-mistakes fork says (~/.no-mistakes/config.yaml is not there)
Daniel 5: trust conventioner: Daniel runs claude once in ~/projects/Conventioner and accepts the trust dialog (claude --bg in ~/projects/Conventioner says Workspace not trusted)
Daniel 6: trust site: Daniel runs claude once in ~/projects/site and accepts the trust dialog (claude --bg in ~/projects/site says Workspace not trusted)
Daniel 7: chrome: brew install --cask google-chrome (Google Chrome is not installed, so chrome-devtools-axi has no browser)
Daniel 8: own settings: write this machine's own in ~/.claude/settings.json (\`claude auto-mode defaults\` shows the form); team-config keeps it (autoMode.environment not set here, so auto mode's classifier knows nothing of this machine)
Daniel 9: restart: exit this Claude Code session and run claude again in $CODE_CHECKOUT, so the new user settings, skills and plugins load"
  # Only Daniel's steps fail: every tool line passes, and so do the projects' and the config's.
  assert_equal "$(stage_lines check | sed -n 's/^doctor: FAIL \([^:]*\):.*/\1/p' | sed 's/^secret .*/secret/' | uniq)" "docker
secret
opencode-gate
trust conventioner
trust site"
  assert_equal "$(stage_lines check | tail -n1)" "summary: not set up yet: only Daniel's steps above are left; then team-bootstrap again"
  # The gate is Conventioner's alone, the task directories are ignored, the lease untouched.
  assert_equal "$(cat "$STUB_CALLS/no-mistakes-init.log")" "$CONVENTIONER"
  git -C "$CONVENTIONER" check-ignore -q .scratch/task/
  git -C "$SITE" check-ignore -q .scratch/task/
  assert_equal "$(lease_json | jq -r '"\(.holder) \(.epoch)"')" "home-pc 1"
  assert_equal "$(stub_calls op)" ""

  local calls
  calls=$(install_calls)
  run_bin -1 team-bootstrap
  assert_equal "$(install_calls)" "$calls"
  assert_equal "$(grep -v '^check: ' <<<"$output" | grep -vc ': done')" 1
  assert_equal "$(stage_lines preflight | head -n1)" "macOS"
  assert_equal "$(stage_lines check | grep -c '^Daniel')" 8
}

@test "--dry-run says what each stage would run and Daniel's steps, and changes nothing" {
  fresh macos
  local before
  before=$(footprint)
  run_bin -1 team-bootstrap --name laptop --home "$TEAM_HOME" --dry-run
  assert_equal "$(footprint)" "$before"
  assert_equal "$(install_calls)" ""
  assert_equal "$(stage_lines machine)" "would write laptop to ~/.config/agent-team/machine
would write $TEAM_HOME to ~/.config/agent-team/home"
  assert_equal "$(stage_lines packages)" "would run: brew install 1password-cli git jq tmux gh rsync python bash go coreutils findutils gnu-sed grep flock
would run: brew install --cask docker-desktop"
  assert_equal "$(stage_lines tools | sed -n '2,3p')" "would run: curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
would run: nvm install 22.19.0 && nvm alias default 22.19.0"
  assert_equal "$(stage_lines projects | head -n2)" "would run: git clone -q https://github.com/chanjdaniel/Conventioner.git ~/projects/Conventioner
would then set up conventioner's task directory exclude and its no-mistakes gate"
  assert_contains "$output" "check: Daniel 1: 1password: "

  # Docker and the config are the stages' to install, not Daniel's.
  [[ $output != *"Daniel 1: docker"* && $output != *": config: "* ]]

  # A step of Daniel's does not stop a dry run, and is listed with the rest.
  run_bin -1 team-bootstrap --dry-run
  assert_contains "$output" "machine: Daniel: name this machine"
  assert_contains "$output" "check: Daniel 1: machine: name this machine for the team: team-bootstrap --name <name> (laptop, home-pc: never the hostname)"
  [[ $output != *"team home: name"* && $output != *"these failed: "*lease* ]]
  assert_contains "$output" "packages: would run: brew install 1password-cli"
  assert_contains "$output" "check: summary: "
  assert_equal "$(footprint)" "$before"
}

@test "--stage runs that stage alone" {
  fresh arch
  run_bin -0 team-bootstrap --stage machine --name laptop
  assert_equal "$output" "machine: named this machine laptop (~/.config/agent-team/machine)"
  run_bin -1 team-bootstrap --stage packages
  assert_equal "$output" "packages: Daniel: in your own terminal run $CODE_CHECKOUT/bin/team-bootstrap --stage packages, which runs pacman -S --needed $ARCH_PACKAGES with sudo and asks for your password; then team-bootstrap again"
  run_bin -0 team-bootstrap --stage preflight
  assert_equal "$output" "preflight: Arch Linux
preflight: done: jq, git and Python 3.11 are installed"
  assert_equal "$(install_calls)" ""
}

@test "on a Mac without Homebrew's GNU tools the run starts again under them once the packages stage has them" {
  fresh macos
  rm -rf "$HOMEBREW_PREFIX/opt/coreutils" "$HOMEBREW_PREFIX/opt/grep"
  run_bin -1 team-bootstrap --name laptop
  assert_equal "$(grep -c '^preflight: macOS$' <<<"$output")" 2
  assert_contains "$output" "packages: Homebrew's GNU tools are installed: starting again under them"
  assert_contains "$output" "machine: done: this machine is laptop"
  [[ $output != *"FAIL homebrew"* ]]
}

@test "usage errors and --help" {
  run_bin -2 team-bootstrap --bogus
  assert_equal "$output" "team-bootstrap: usage: team-bootstrap [--name <name>] [--home <path>] [--stage <stage>] [--dry-run]"
  run_bin -2 team-bootstrap --name
  run_bin -2 team-bootstrap --name Home_PC
  assert_equal "$output" "team-bootstrap: --name Home_PC is not a lower-case kebab-case name like laptop or home-pc"
  run_bin -2 team-bootstrap --stage nope
  assert_equal "$output" "team-bootstrap: no stage nope; the stages are preflight machine packages tools projects config heartbeat check"
  run_bin -0 team-bootstrap --help
  assert_contains "$output" "Usage: team-bootstrap [--name <name>] [--home <path>] [--stage <stage>] [--dry-run]"
  # An OS the team does not run on is refused before anything.
  printf '%s\n' 'PRETTY_NAME="Ubuntu 24.04.3 LTS"' 'ID=ubuntu' >"$TEAM_OS_RELEASE"
  run_bin -1 team-bootstrap
  assert_equal "$output" "team-bootstrap: this machine runs neither Arch Linux nor macOS (Linux Ubuntu 24.04.3 LTS); the team runs on those two"
}
