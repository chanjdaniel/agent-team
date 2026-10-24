#!/usr/bin/env bats
# shellcheck disable=SC2153 # TOOL_STUBS, CONVENTIONER and the other globals are helpers/doctor.bash's
# team-bootstrap: a fresh machine set up stage by stage, on the machine tests/helpers/doctor.bash
# builds. Every installer is a stub that installs by making the tool's version stub answer its
# pin or min (mark_installed): brew, pacman (behind a sudo stub that runs nothing else), npm, the
# curl | bash installers and nvm's, the release archives (curl, sha256sum or shasum, tar), the
# fork's build (its clone, checkout, make build and install, logged to fork-build.log), the clones
# (git clone of a GitHub URL comes from the test's bare origin of the same name), the no-mistakes
# gate and claude's plugin commands. Nothing reaches this machine's own HOME, package
# managers or GitHub.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
  export REPO_ROOT SHELL=/bin/bash
  installers
}

# The installers' stubs (see the header).
installers() {
  local cmd origins
  origins=$(realpath "$BATS_TEST_TMPDIR")/origin
  for cmd in brew pacman npm sudo xcode-select; do cp "$REPO_ROOT/tests/helpers/stub" "$BATS_TEST_TMPDIR/stubs/$cmd"; done
  stub_reply xcode-select /Library/Developer/CommandLineTools

  # A package manager installs each tool of the lock whose packages it was given, all of them.
  stub_script pacman <<'EOF'
source "$REPO_ROOT/tests/helpers/doctor.bash"
[[ $1 == -S && $2 == --needed && $3 == --noconfirm ]] || { echo "pacman stub: unplanned call: $*" >&2; exit 1; }
installed_from "sudo pacman -S --needed " "${@:4}"
EOF
  stub_script brew <<'EOF'
source "$REPO_ROOT/tests/helpers/doctor.bash"
case $1 in install | upgrade) ;; *) echo "brew stub: unplanned call: $*" >&2; exit 1 ;; esac
if [[ $2 == --cask ]]; then installed_from "brew install --cask " "${@:3}"; exit 0; fi
installed_from "brew install " "${@:2}"
# Homebrew's GNU tools, where bin/lib/platform.sh looks for them.
for package in "${@:2}"; do
  case $package in
    coreutils | findutils | gnu-sed | grep) mkdir -p "$HOMEBREW_PREFIX/opt/$package/libexec/gnubin" ;;
    flock) mkdir -p "$HOMEBREW_PREFIX/opt/flock/bin" ;;
  esac
done
EOF
  stub_script npm <<'EOF'
source "$REPO_ROOT/tests/helpers/doctor.bash"
[[ $1 == install && $2 == -g ]] || { echo "npm stub: unplanned call: $*" >&2; exit 1; }
installed_from "npm install -g " "$3"
EOF
  # sudo runs pacman and installs what tar or unzip would unpack; it runs nothing else.
  stub_script sudo <<'EOF'
source "$REPO_ROOT/tests/helpers/doctor.bash"
case $1 in
  pacman) exec pacman "${@:2}" ;;
  tar | unzip) mark_installed "${!#}" ;;
esac
EOF

  # curl: the installers' scripts, and nothing for an archive (sha256sum and tar never read it);
  # anything else is the doctor's clock.
  mv "$STUB_FIXTURES/curl.sh" "$STUB_FIXTURES/curl-doctor.sh"
  stub_script curl <<'EOF'
case $* in
  '-fsSL https://claude.ai/install.sh') echo 'source "$REPO_ROOT/tests/helpers/doctor.bash"; mark_installed claude' ;;
  '-fsSL https://bun.sh/install') echo 'source "$REPO_ROOT/tests/helpers/doctor.bash"; mark_installed bun' ;;
  '-fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh')
    cat <<'NVM'
mkdir -p "$NVM_DIR"
cat >"$NVM_DIR/nvm.sh" <<'SH'
nvm() {
  echo "nvm $*" >>"$STUB_CALLS/nvm.log"
  if [[ $1 == install ]]; then source "$REPO_ROOT/tests/helpers/doctor.bash"; mark_installed node; fi
}
SH
NVM
    ;;
  -fsSLo\ *) ;;
  *) source "$STUB_FIXTURES/curl-doctor.sh" ;;
esac
EOF

  # claude's plugin commands change what it lists.
  mv "$STUB_FIXTURES/claude.sh" "$STUB_FIXTURES/claude-doctor.sh"
  stub_script claude <<'EOF'
case $* in
  'plugin marketplace add '*)
    jq --arg repo "$4" '. + [{name: ($repo | split("/")[1]), source: "github", repo: $repo}]' \
      "$STUB_FIXTURES/marketplaces.json" >"$STUB_FIXTURES/m.json"
    mv "$STUB_FIXTURES/m.json" "$STUB_FIXTURES/marketplaces.json" ;;
  'plugin install '*' --scope user')
    jq --arg id "$3" '. + [{id: $id, scope: "user", enabled: true}]' "$STUB_FIXTURES/plugins.json" >"$STUB_FIXTURES/p.json"
    mv "$STUB_FIXTURES/p.json" "$STUB_FIXTURES/plugins.json" ;;
  'plugin disable '*' --scope user')
    jq --arg id "$3" 'map(if .id == $id then .enabled = false else . end)' "$STUB_FIXTURES/plugins.json" >"$STUB_FIXTURES/p.json"
    mv "$STUB_FIXTURES/p.json" "$STUB_FIXTURES/plugins.json" ;;
  *) source "$STUB_FIXTURES/claude-doctor.sh" ;;
esac
EOF

  # no-mistakes init gives the checkout a gate.
  cat >"$TOOL_ANSWERS/no-mistakes/init.sh" <<'EOF'
echo "$PWD" >>"$STUB_FIXTURES/gates"
echo "$PWD" >>"$STUB_CALLS/no-mistakes-init.log"
EOF

  # Version stubs that also stand in for what the release archives' commands and the fork's
  # build do: the fork's clone is an empty directory its checkout and make build go along with.
  wrapper git <<EOF
if [[ \${1:-} == clone && \${3:-} == https://github.com/chanjdaniel/no-mistakes ]]; then
  echo "\$*" >>"\$STUB_CALLS/fork-build.log"
  mkdir -p "\${!#}" && : >"\${!#}/.fork"
  exit
fi
if [[ \${1:-} == -C && -f \${2:-}/.fork ]]; then
  echo "git \${*:3}" >>"\$STUB_CALLS/fork-build.log"
  exit
fi
if [[ \${1:-} == clone && \${3:-} == https://github.com/* ]]; then
  echo "\$*" >>"\$STUB_CALLS/git-clone.log"
  url=\$3
  "\$real" clone -q "$origins/\${url##*/}" "\${!#}" && "\$real" -C "\${!#}" remote set-url origin "\$url"
  exit
fi
EOF
  wrapper tar <<'EOF'
if [[ $1 == -xzf ]]; then mark_installed "${!#}"; exit 0; fi
EOF
  wrapper make <<'EOF'
if [[ $1 == -C && -f $2/.fork ]]; then echo "make ${*:3}" >>"$STUB_CALLS/fork-build.log"; exit 0; fi
EOF
  wrapper install <<'EOF'
if [[ ${!#} == "$HOME/.no-mistakes/bin/no-mistakes" ]]; then
  echo "install $*" >>"$STUB_CALLS/fork-build.log"
  mark_installed no-mistakes
  exit 0
fi
EOF
  wrapper sha256sum <<'EOF'
if [[ $1 == -c ]]; then cat >/dev/null; echo "-: OK"; exit 0; fi
EOF
  wrapper shasum <<'EOF'
if [[ " $* " == *" -c "* ]]; then cat >/dev/null; echo "-: OK"; exit 0; fi
EOF
}

# wrapper <command>: a version stub for <command> (as tool_stub makes) that first runs the Bash on
# stdin, which may handle the call and exit; $real is the real command.
wrapper() {
  mkdir -p "$TOOL_ANSWERS/$1"
  {
    echo "#!$(PATH=$REAL_PATH command -v bash)"
    echo "real=\$(PATH=\$REAL_PATH command -v $1)"
    echo 'source "$REPO_ROOT/tests/helpers/doctor.bash"'
    echo "key=\$*"
    echo "answer=\$TOOL_ANSWERS/$1/\${key// /_}"
    echo "if [[ -f \$answer.missing ]]; then echo \"$1: command not found\" >&2; exit 127; fi"
    echo "if [[ -f \$answer ]]; then cat \"\$answer\"; exit 0; fi"
    cat
    echo "exec \"\$real\" \"\$@\""
  } >"$TOOL_STUBS/$1"
  chmod +x "$TOOL_STUBS/$1"
}

# A machine fresh from Daniel's first steps, running <os> (arch or macos): no tool of the lock,
# no team name or team home setting, no lease record or heartbeat, none of the team's Claude config or plugins, no
# project cloned, no secret, no 1Password app or browser, and the Docker daemon not reachable.
# The team home is cloned with its dev guard on, and home-pc holds the lease.
fresh() {
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  rm -rf "$HOME/.local/state/agent-team" "$HOME/.config/agent-team/machine" "$HOME/.config/agent-team/home"
  if [[ $1 == macos ]]; then
    on_macos
    "$REPO_ROOT/bin/team-timers" disable >/dev/null
    export SHELL=/bin/zsh
  fi
  tools_at "$1" -
  rm -rf "$HOME/.claude/settings.json" "$HOME/.claude/skills" "$HOME/.no-mistakes" "$CONVENTIONER" "$SITE"
  echo '[]' >"$STUB_FIXTURES/plugins.json"
  echo '[]' >"$STUB_FIXTURES/marketplaces.json"
  : >"$STUB_FIXTURES/gates"
  local target
  while IFS= read -r target; do rm -f "$HOME/$target"; done < <(jq -r '.secrets[].target' "$TEAM_HOME/machine/secrets.json")
  rm -f "$TEAM_1PASSWORD_APP" "$TEAM_CHROME"
  printf 'echo %q >&2\nexit 1\n' "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" \
    >"$TOOL_ANSWERS/docker/info_--format_{{.ServerVersion}}.sh"
  printf '%s\n' "$CONVENTIONER" "$SITE" >"$STUB_FIXTURES/untrusted"
}

# Every call an installer stub logged, one per line: what a run that installs nothing leaves empty.
install_calls() {
  local cmd
  for cmd in brew pacman npm sudo; do stub_calls "$cmd" | sed "s/^/$cmd /"; done
  stub_calls curl | grep -v '"-sSI"' | sed 's/^/curl /' || true
  stub_calls claude | grep -E '^\["plugin","(marketplace","add|install|disable)"' | sed 's/^/claude /' || true
  cat "$STUB_CALLS"/{git-clone,fork-build,no-mistakes-init,nvm}.log 2>/dev/null || true
}

# What a run may change, listed with each file's size and modification time: HOME (the stubs'
# own logs and fixtures aside) and the team home.
footprint() {
  find "$HOME" "$TEAM_HOME" -path "$TEAM_HOME/.git" -prune -o -printf '%p %s %T@\n' | sort
  git -C "$TEAM_HOME" status --porcelain
}

# The install of no-mistakes: a build of Daniel's fork at its pinned commit, on either OS.
FORK_BUILD='d=$(mktemp -d) && git clone -q https://github.com/chanjdaniel/no-mistakes "$d" && git -C "$d" checkout -q ac6b53fbbac10a4ca6c940b004fd9c5f557f983e && make -C "$d" build && mkdir -p ~/.no-mistakes/bin && install -m 755 "$d/bin/no-mistakes" ~/.no-mistakes/bin/no-mistakes && rm -rf "$d"'

# The lines of <stage> in the output, without the prefix.
stage_lines() {
  sed -n "s/^$1: //p" <<<"$output"
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

# The Arch packages of the lock, in its order.
ARCH_PACKAGES="git jq tmux github-cli rsync docker docker-compose python bash go make unzip"

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

@test "in Daniel's own terminal the sudo steps run, sudo asking for the password" {
  fresh arch
  run_in_terminal -1 -- "$CODE_CHECKOUT/bin/team-bootstrap" --name laptop
  assert_contains "$output" "packages: running: sudo pacman -S --needed --noconfirm $ARCH_PACKAGES"
  assert_equal "$(stub_calls sudo | jq -r '.[0]' | uniq | paste -sd ' ' -)" "pacman mkdir tar unzip groupadd chgrp chmod"
  assert_equal "$(stub_calls sudo | jq -c 'select(.[0] == "tar") | .[3:]')" '["-C","/usr/local/bin","treehouse"]'
  # Every tool line passes now; what is left is Daniel's own.
  assert_contains "$output" "check: summary: not set up yet: only Daniel's steps above are left; then team-bootstrap again"
  [[ $output != *"FAIL tool "* ]]
  # With no ~/agent-team-records the code checkout is the team home, and nothing is to be named.
  [[ $output != *"team home: name"* ]]
  assert_contains "$output" "check: Daniel 1: docker: Daniel runs sudo systemctl enable --now docker.service ("
}

# run_in_terminal [-<status>] -- <command...>: bats' run in a pseudo-terminal, as Daniel's own.
run_in_terminal() {
  local opts=()
  while [[ $1 == -[0-9]* ]]; do opts+=("$1"); shift; done
  guard_sandbox || return 1
  run "${opts[@]}" python3 -I "$REPO_ROOT/tests/helpers/terminal.py" "$@"
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
  cp "$REPO_ROOT/tests/helpers/stub" "$BATS_TEST_TMPDIR/stubs/brew"

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

@test "projects are cloned from https://github.com/<repo>.git to their registry paths; a task directory git ignores is left alone; the gate is only no-mistakes'" {
  tools_at arch
  # site ignores its task directory itself.
  local work=$BATS_TEST_TMPDIR/site-work
  git clone -q "$BATS_TEST_TMPDIR/origin/site.git" "$work"
  echo /.scratch/ >"$work/.gitignore"
  git -C "$work" add .gitignore
  git -C "$work" commit -q -m "chore: ignore the task directory"
  git -C "$work" push -q origin HEAD
  rm -rf "$CONVENTIONER" "$SITE"
  : >"$STUB_FIXTURES/gates"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines projects)" "running: git clone -q https://github.com/chanjdaniel/Conventioner.git ~/projects/Conventioner
running: echo /.scratch/task/ >>~/projects/Conventioner/.git/info/exclude
running: cd ~/projects/Conventioner && no-mistakes init
conventioner is set up in ~/projects/Conventioner
running: git clone -q https://github.com/owner/site.git ~/projects/site
site is set up in ~/projects/site"
  assert_equal "$(git -C "$CONVENTIONER" remote get-url origin)" https://github.com/chanjdaniel/Conventioner.git
  assert_equal "$(git -C "$SITE" remote get-url origin)" https://github.com/owner/site.git
  assert_equal "$(cat "$SITE/.git/info/exclude" | grep -c scratch)" 0
  assert_equal "$(git -C "$CONVENTIONER" status --porcelain)$(git -C "$SITE" status --porcelain)" ""
  # The new clones keep their auto memory in the team home, which the config stage sets up.
  assert_equal "$(stage_lines config)" "running: team-config apply"
  assert_equal "$(jq -r .autoMemoryDirectory "$SITE/.claude/settings.local.json")" "$TEAM_HOME/memory/site"
  [[ $output != *"WARN memory"* ]]

  # An origin set elsewhere is put back to the exact URL treehouse names its pool from.
  git -C "$SITE" remote set-url origin git@github.com:owner/site.git
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines projects)" "running: git -C ~/projects/site remote set-url origin https://github.com/owner/site.git
site is set up in ~/projects/site"
}

@test "a git pool's slots inside the checkout are ignored there once, so they never show as untracked in it" {
  tools_at arch
  register fork owner/fork direct-pr git projects/fork/.claude/worktrees/1 projects/fork/.claude/worktrees/2
  local fork=$HOME/projects/fork
  rm -rf "$fork"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines projects)" "running: git clone -q https://github.com/owner/fork.git ~/projects/fork
running: echo /.scratch/task/ >>~/projects/fork/.git/info/exclude
running: echo /.claude/worktrees/ >>~/projects/fork/.git/info/exclude
fork is set up in ~/projects/fork"
  git -C "$fork" worktree add -q "$fork/.claude/worktrees/1"
  assert_equal "$(git -C "$fork" status --porcelain)" ""
  # A pool outside the checkout (site's) adds nothing.
  assert_equal "$(grep -c worktrees "$SITE/.git/info/exclude" || true)" 0
  # A dry run says so before the clone.
  rm -rf "$fork"
  run_bin -1 team-bootstrap --dry-run
  assert_contains "$output" "projects: would then set up fork's task directory exclude, its pool slots' exclude"
}

@test "config: the plugins first, apply only to add what is missing, and Discord off; a file changed here is Daniel's call" {
  tools_at arch
  # Discord on, mongodb-atlas missing.
  echo '[{"id": "discord@claude-plugins-official", "scope": "user", "enabled": true}]' >"$STUB_FIXTURES/plugins.json"
  rm -rf "$HOME/.claude/skills/tdd"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines config)" "running: claude plugin install mongodb-atlas@claude-plugins-official --scope user
running: team-config apply
running: claude plugin disable discord@claude-plugins-official --scope user"
  [[ -f $HOME/.claude/skills/tdd/SKILL.md ]]
  assert_contains "$output" "check: Daniel 1: restart: exit this Claude Code session"

  # settings.json changed here: apply would replace it, so nothing is applied and it is listed.
  echo '{"model": "sonnet"}' >"$HOME/.claude/settings.json"
  rm -rf "$HOME/.claude/skills/tdd"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines config)" "left as it is: settings.json differs here, and whether to apply or capture is Daniel's call
nothing to add: what differs is Daniel's call (the check stage lists it)"
  [[ ! -e $HOME/.claude/skills/tdd ]]
  assert_equal "$(jq -r .model "$HOME/.claude/settings.json")" sonnet
  assert_contains "$output" "check: Daniel 2: config: team-config diff --full, then team-config apply (take the team home's) or team-config capture (keep this machine's) (settings.json differs, skill tdd missing)"
}

@test "the heartbeat is left disabled on a machine that does not hold the lease, and the lease is never taken" {
  tools_at arch
  make_machine laptop
  "$REPO_ROOT/bin/team-lease" release >/dev/null
  on_machine laptop "$REPO_ROOT/bin/team-lease" take >/dev/null
  local lease
  lease=$(git -C "$BATS_TEST_TMPDIR/origin/agent-team.git" rev-parse lease)
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines heartbeat)" "running: team-timers disable"
  [[ ! -e $HOME/.config/systemd/user/agent-team-heartbeat.timer ]]
  assert_equal "$(tail -n1 <<<"$output")" "check: summary: ready as a standby; team-load-check proves a worker here, and to move the team here say \"hand off\" to the coordinator on laptop, then run team-resume here"
  run_bin -0 team-bootstrap
  assert_equal "$(stage_lines heartbeat)" "done: disabled until this machine takes the lease (team-resume enables it)"
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/origin/agent-team.git" rev-parse lease)" "$lease"
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
machine: named the team home ~/agent-team-records (~/.config/agent-team/home)"
  assert_equal "$(cat "$HOME/.config/agent-team/home")" agent-team-records
  # Once written, the same checkout (however named) is done, and another is left unused.
  run_bin -0 team-bootstrap --stage machine --home "$HOME/agent-team-records"
  assert_equal "$(stage_lines machine | tail -n1)" "done: ~/.config/agent-team/home names ~/agent-team-records"
  mkdir "$HOME/elsewhere"
  run_bin -0 team-bootstrap --stage machine --home elsewhere
  assert_equal "$(stage_lines machine | tail -n1)" "done: ~/.config/agent-team/home already names ~/agent-team-records; --home elsewhere is left unused"
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
