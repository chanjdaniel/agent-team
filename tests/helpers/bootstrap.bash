# shellcheck shell=bash
# shellcheck disable=SC2153 # TOOL_STUBS, CONVENTIONER and the other globals are helpers/doctor.bash's
# team-bootstrap*.bats' machine: a fresh machine set up stage by stage, on the machine tests/helpers/doctor.bash
# builds. Every installer is a stub that installs by making the tool's version stub answer its
# pin or min (mark_installed): brew, pacman (behind a sudo stub that runs nothing else), npm, the
# curl | bash installers and nvm's, the release archives (curl, sha256sum or shasum, tar), the
# fork's build (its clone, checkout, make build and install, logged to fork-build.log), the clones
# (git clone of a GitHub URL comes from the test's bare origin of the same name), the no-mistakes
# gate and claude's plugin commands. Nothing reaches this machine's own HOME, package
# managers or GitHub.
# Load it after helpers/common and helpers/doctor, and call bootstrap_machine after sandbox.

# The doctor's machine (doctor_machine) with the installers' stubs.
bootstrap_machine() {
  doctor_machine
  export REPO_ROOT SHELL=/bin/bash
  installers
}

# The installers' stubs (see the header).
installers() {
  local origins
  origins=$BATS_TEST_TMPDIR/origin
  stub_command brew pacman npm sudo xcode-select
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

# wrapper <command>: the version stub for <command> (tool_stub) first runs the Bash on stdin,
# which may handle the call and exit; $real is the real command.
wrapper() {
  tool_stub "$1"
  cat >"$TOOL_ANSWERS/$1.wrap.sh"
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
  rm -rf "$CODE_CHECKOUT/servers/node_modules"
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
  cat "$STUB_CALLS"/{git-clone,fork-build,no-mistakes-init,nvm,servers-install}.log 2>/dev/null || true
}

# What a run may change, listed with each file's size and modification time: HOME (the stubs'
# own logs and fixtures aside) and the team home.
footprint() {
  find "$HOME" "$TEAM_HOME" -path "$TEAM_HOME/.git" -prune -o -printf '%p %s %T@\n' | sort
  git -C "$TEAM_HOME" status --porcelain
}

# The install of no-mistakes: a build of Daniel's fork at its pinned commit, on either OS.
# shellcheck disable=SC2034 # read by the tests
FORK_BUILD='d=$(mktemp -d) && git clone -q https://github.com/chanjdaniel/no-mistakes "$d" && git -C "$d" checkout -q ac6b53fbbac10a4ca6c940b004fd9c5f557f983e && make -C "$d" build && mkdir -p ~/.no-mistakes/bin && install -m 755 "$d/bin/no-mistakes" ~/.no-mistakes/bin/no-mistakes && rm -rf "$d"'

# The lines of <stage> in the output, without the prefix.
stage_lines() {
  # shellcheck disable=SC2154 # bats' run sets output
  sed -n "s/^$1: //p" <<<"$output"
}

# The Arch packages of the lock, in its order.
# shellcheck disable=SC2034 # read by the tests
ARCH_PACKAGES="git jq tmux github-cli rsync docker docker-compose python bash go make unzip"

# run_in_terminal [-<status>] -- <command...>: bats' run in a pseudo-terminal, as Daniel's own.
run_in_terminal() {
  local opts=()
  while [[ $1 == -[0-9]* ]]; do opts+=("$1"); shift; done
  guard_sandbox || return 1
  run "${opts[@]}" python3 -I "$REPO_ROOT/tests/helpers/terminal.py" "$@"
}
