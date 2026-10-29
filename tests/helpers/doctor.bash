# A machine as team-doctor sees it, for the tests of the doctor and of what acts on its lines
# (team-bootstrap): load it after helpers/common, and call doctor_machine after sandbox. run_bin
# then runs a copy of bin/ in a code checkout of its own ($CODE_CHECKOUT), whose git config the
# git hooks line reads, never this checkout's. Every
# tool in bin/lib/tools.lock is then a version stub on PATH ($TOOL_STUBS) that answers its
# version_cmd as the real tool does and hands every other call to the real command (or the
# sandbox's logging stub), so the doctor's own git, jq and date keep working while a tool reads as
# missing or old. A stubbed uname picks the OS: Linux with an Arch os-release file, or Darwin with
# a fake Homebrew prefix. The stubs' own scripts may source this file too, for mark_installed.
# shellcheck shell=bash

LOCK=$REPO_ROOT/bin/lib/tools.lock

# What each tool prints for its version_cmd, %s being the version, as the real tool does.
declare -gA FORMAT=(
  [claude]='%s (Claude Code)'
  [node]='v%s'
  [codegraph]='%s'
  [gh-axi]='%s'
  [chrome-devtools-axi]='%s'
  [chrome-devtools-mcp]='%s'
  [lavish-axi]='%s'
  [opencode]='%s'
  [bun]='%s'
  [treehouse]='v%s'
  [no-mistakes]='no-mistakes version v%s (ac6b53f) 2026-10-24T07:09:23Z'
  [op]='%s'
  [git]='git version %s'
  [jq]='jq-%s'
  [tmux]='tmux %s'
  [gh]=$'gh version %s (2026-09-30)\nhttps://github.com/cli/cli/releases/tag/v%s'
  [rsync]='rsync  version %s  protocol version 33'
  [docker]='Docker version %s, build a82e528901'
  [docker-compose]='Docker Compose version v%s'
  [python]='Python %s'
  [bash]='GNU bash, version %s(1)-release (x86_64-pc-linux-gnu)'
  [go]='go version go%s linux/amd64'
  [make]=$'GNU Make %s\nBuilt for x86_64-pc-linux-gnu'
  [unzip]=$'UnZip %s of 20 April 2009, by Debian. Original by Info-ZIP.\n\nLatest sources and executables are at ftp://ftp.info-zip.org/pub/infozip/ ;'
  [coreutils]='date (GNU coreutils) %s'
  [findutils]='find (GNU findutils) %s'
  [gnu-sed]='sed (GNU sed) %s'
  [grep]='grep (GNU grep) %s'
  [flock]='flock %s'
)

# Set up the doctor's machine (team-doctor*.bats' every test starts here): home-pc holds the lease
# with its heartbeat enabled, every tool answers nothing yet (tools_at gives them versions), the
# team's Claude config and plugins are installed, so are the pinned MCP servers, every secret is
# in place, the gate's opencode wrapper is installed and config.yaml runs the gate on it, two
# projects are registered and cloned as the bootstrap clones them,
# ~/.config/agent-team/home names the team home, and its core.hooksPath the code's records-git;
# slots.json sets a cap of 10, and a reading of the machine's load was just taken.
doctor_machine() {
  hold_lease home-pc >/dev/null
  fake_service_managers
  # shellcheck disable=SC2153 # sandbox sets TEAM_HOME
  echo "$TEAM_HOME" >"$HOME/.config/agent-team/home"
  # The team home's git ignores UI captures, as its .gitignore says (a record, so excluded here).
  echo 'tasks/*/ui/' >>"$TEAM_HOME/.git/info/exclude"
  # The code checkout, with the dev guard on, as Daniel turns it on.
  export CODE_CHECKOUT
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  # The pinned MCP servers, installed: servers/install here is a stub that stamps the install as
  # the real one does (its own tests are servers-install.bats) and logs that it ran.
  mkdir -p "$CODE_CHECKOUT/servers"
  cp "$REPO_ROOT/servers/package.json" "$REPO_ROOT/servers/package-lock.json" "$CODE_CHECKOUT/servers/"
  cat >"$CODE_CHECKOUT/servers/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$dir/node_modules"
cat "$dir/package.json" "$dir/package-lock.json" | sha256sum | cut -d' ' -f1 >"$dir/node_modules/.installed-from"
echo "servers/install $*" >>"$STUB_CALLS/servers-install.log"
EOF
  chmod +x "$CODE_CHECKOUT/servers/install"
  "$CODE_CHECKOUT/servers/install"
  rm "$STUB_CALLS/servers-install.log"
  git init -q "$CODE_CHECKOUT"
  git -C "$CODE_CHECKOUT" config core.hooksPath bin/hooks/git
  # The team home, with the records guard on, as Daniel turns it on.
  git -C "$TEAM_HOME" config core.hooksPath "$CODE_CHECKOUT/bin/hooks/records-git"

  # The OS: Linux, from an Arch os-release file, until a test says Darwin.
  stub_command uname
  stub_reply uname Linux
  # uname -m answers the machine type (x86_64 until a test says otherwise), anything else the OS.
  stub_script uname <<'EOF'
if [[ ${1:-} == -m ]]; then cat "$STUB_FIXTURES/uname-m.out" 2>/dev/null || echo x86_64; else cat "$STUB_FIXTURES/uname.out"; fi
EOF
  export TEAM_OS_RELEASE=$BATS_TEST_TMPDIR/os-release
  printf '%s\n' 'NAME="Arch Linux"' 'PRETTY_NAME="Arch Linux"' 'ID=arch' >"$TEAM_OS_RELEASE"

  # Version stubs go first on PATH; anything else they are asked goes to what PATH had before.
  export TOOL_STUBS=$BATS_TEST_TMPDIR/tools
  mkdir -p "$TOOL_STUBS/answers"
  export REAL_PATH=$PATH TOOL_ANSWERS=$TOOL_STUBS/answers PATH=$TOOL_STUBS:$PATH

  # The gate's opencode wrapper, installed and named by config.yaml as the install step says.
  mkdir -p "$HOME/.no-mistakes/bin"
  install -m 755 "$REPO_ROOT/bin/lib/opencode-gate" "$HOME/.no-mistakes/bin/opencode-gate"
  printf '%s\n' 'agent: opencode' 'agent_path_override:' "  opencode: $HOME/.no-mistakes/bin/opencode-gate" \
    'log_level: info' >"$HOME/.no-mistakes/config.yaml"

  # The team home's Claude config, installed here; the plugins with Discord off.
  mkdir -p "$TEAM_HOME/machine/claude/skills/tdd" "$HOME/.claude/skills"
  echo '{"model": "opus"}' >"$TEAM_HOME/machine/claude/settings.json"
  echo "Red, green, refactor." >"$TEAM_HOME/machine/claude/skills/tdd/SKILL.md"
  printf '%s\n' 'marketplace anthropics/claude-plugins-official' 'plugin discord@claude-plugins-official' \
    'plugin mongodb-atlas@claude-plugins-official' >"$TEAM_HOME/machine/claude/plugins.txt"
  echo '{"model": "opus", "autoMode": {"environment": ["**Organization**: None configured"]}}' \
    >"$HOME/.claude/settings.json"
  cp -R "$TEAM_HOME/machine/claude/skills/tdd" "$HOME/.claude/skills/"
  echo '[{"id": "discord@claude-plugins-official", "scope": "user", "enabled": false},
    {"id": "mongodb-atlas@claude-plugins-official", "scope": "user", "enabled": true}]' >"$STUB_FIXTURES/plugins.json"
  echo '[{"name": "claude-plugins-official", "source": "github", "repo": "anthropics/claude-plugins-official"}]' \
    >"$STUB_FIXTURES/marketplaces.json"

  # Signed in everywhere, the clock right.
  stub_script claude <<'EOF'
case $* in
  'auth status --json')
    echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "daniel@example.invalid", "orgId": "org-secret-0000", "subscriptionType": "pro"}' ;;
  'plugin list --json') cat "$STUB_FIXTURES/plugins.json" ;;
  'plugin marketplace list --json') cat "$STUB_FIXTURES/marketplaces.json" ;;
  '--bg --name team-doctor-'*)
    # A promptless background session: refused in a root listed in $STUB_FIXTURES/untrusted, and
    # failing otherwise in one listed in $STUB_FIXTURES/no-session.
    echo "$PWD" >>"$STUB_CALLS/claude-bg.pwd"
    if grep -qxF "$PWD" "$STUB_FIXTURES/no-session" 2>/dev/null; then
      echo "Error: something else went wrong" >&2
      exit 1
    fi
    if grep -qxF "$PWD" "$STUB_FIXTURES/untrusted" 2>/dev/null; then
      echo "Error: Workspace not trusted. Run claude here once and accept the trust dialog." >&2
      exit 1
    fi
    echo "Started background session $(printf '%s' "$PWD" | sha256sum | cut -c1-8). It is waiting: send a prompt to start." ;;
  'agents --json') cat "$STUB_FIXTURES/agents.json" 2>/dev/null || echo '[]' ;;
  'stop '* | 'rm '*) ;;
  *) echo "claude stub: unplanned call: $*" >&2; exit 127 ;;
esac
EOF
  stub_script gh <<'EOF'
case $* in
  'auth status --hostname github.com') echo "  - Token: gho_fakefakefakefake" ;;
  *) echo "gh stub: unplanned call: $*" >&2; exit 127 ;;
esac
EOF
  clock_offset 0
  # The team home's secrets manifest and its description (fixtures shaped like the real ones),
  # every secret in place with its mode, holding a dummy value; the 1Password app installed.
  cp "$BATS_TEST_DIRNAME/fixtures/secrets.json" "$BATS_TEST_DIRNAME/fixtures/secrets.md" "$TEAM_HOME/machine/"
  local target
  while IFS= read -r target; do
    mkdir -p "$(dirname "$HOME/$target")"
    echo "TOKEN=dummy-secret-value" >"$HOME/$target"
    chmod 600 "$HOME/$target"
  done < <(jq -r '.secrets[] | select(.enabled != false) | .target' "$TEAM_HOME/machine/secrets.json")
  export TEAM_1PASSWORD_APP=$BATS_TEST_TMPDIR/1Password
  touch "$TEAM_1PASSWORD_APP"
  # The Docker daemon answers, and a browser is installed.
  answer "docker info --format {{.ServerVersion}}" "28.3.3"
  export TEAM_CHROME=$BATS_TEST_TMPDIR/chrome
  touch "$TEAM_CHROME"
  # The heartbeat runs, as it should on the holder.
  "$REPO_ROOT/bin/team-timers" enable >/dev/null

  # Two projects, cloned as the bootstrap clones them: Conventioner gated by no-mistakes with a
  # treehouse pool, site with a git pool; no-mistakes has a gate for each checkout listed in
  # $STUB_FIXTURES/gates, and each keeps its auto memory in the team home.
  register conventioner chanjdaniel/Conventioner no-mistakes treehouse \
    .treehouse/Conventioner-d4c77a/1/Conventioner .treehouse/Conventioner-d4c77a/2/Conventioner
  register site owner/site direct-pr git projects/site-slots/1
  # shellcheck disable=SC2034 # read by the tests
  CONVENTIONER=$HOME/projects/Conventioner SITE=$HOME/projects/site
  echo "$CONVENTIONER" >"$STUB_FIXTURES/gates"
  # treehouse status --json answers with $STUB_FIXTURES/pool.json: nothing leased, until a test
  # writes it (leased_slots).
  echo '[]' >"$STUB_FIXTURES/pool.json"
  tool_stub treehouse
  echo 'cat "$STUB_FIXTURES/pool.json"' >"$TOOL_ANSWERS/treehouse/status_--json.sh"
  tool_stub no-mistakes
  cat >"$TOOL_ANSWERS/no-mistakes/status.sh" <<'EOF'
if grep -qxF "$PWD" "$STUB_FIXTURES/gates"; then
  printf '    repo:  %s\n  remote:  %s\n    gate:  %s\n  daemon:  ● running\n\n  no active run\n' \
    "$PWD" "$(git remote get-url origin)" "$HOME/.no-mistakes/repos/af267dfa548d.git"
else
  echo "repo not initialized (run 'no-mistakes init' first)"
fi
EOF
  "$REPO_ROOT/bin/team-config" apply >/dev/null
  # The machine's slots set as home-pc's, and a reading of its load just taken, as its heartbeat
  # takes them.
  echo '{"cap": 10}' >"$HOME/.config/agent-team/slots.json"
  slots_reading 0 8 1
}

# slots_reading <minutes> <others GiB> [<others cores>]: append a reading of the machine's load
# taken <minutes> ago on a machine shaped like home-pc (30.6 GiB, 12 cores), other programs using
# <others GiB> and <others cores> busy (no CPU read without it).
slots_reading() {
  local file=$HOME/.local/state/agent-team/slots/readings.jsonl
  mkdir -p "${file%/*}"
  jq -cn --arg at "$(date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ)" --argjson others "$2" --arg cores "${3:-}" '
    (30.6 * 1073741824 | floor) as $total | ($others * 1073741824 | floor) as $others
    | {at: $at, os: "linux", docker: true,
       memory: {total: $total, available: ($total - $others - 1073741824), team: 1073741824, others: $others},
       cpu: (if $cores == "" then null else {cpus: 12, seconds: 300, team: 0.5, others: ($cores | tonumber)} end)}' >>"$file"
}

# register <project> <repo> <delivery> <provider> [<slot>...]: a project in projects.toml whose
# primary checkout is ~/projects/<repo's name>, a clone of a bare origin (make_repo) with its
# origin set to the URL the bootstrap clones from, https://github.com/<repo>.git (its
# remote-tracking branches stay), and git ignoring its task directory.
register() {
  local project=$1 repo=$2 delivery=$3 provider=$4 clone slot slots=''
  clone=$(make_repo "${repo#*/}")
  git -C "$clone" remote set-url origin "https://github.com/$repo.git"
  echo /.scratch/task/ >>"$clone/.git/info/exclude"
  for slot in "${@:5}"; do slots+="\"$slot\", "; done
  {
    printf '[%s]\n' "$project"
    printf '%s\n' "repo = \"$repo\"" "path = \"projects/${repo#*/}\"" 'base = "main"' "delivery = \"$delivery\"" \
      'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []'
    printf '[%s.pool]\nprovider = "%s"\n' "$project" "$provider"
    [[ $provider != treehouse ]] || printf '%s\n' 'lease = "scripts/th-lease.sh"' 'return = "scripts/th-return.sh"'
    printf 'slots = [%s]\n' "${slots%, }"
  } >>"$TEAM_HOME/projects.toml"
}

# The project lines of the setup's two projects, one check name per line, in order.
project_checks() {
  printf '%s conventioner\n' checkout origin 'task dir' gate slots leases trust branches changes
  printf '%s site\n' checkout origin 'task dir' trust branches changes
}

# leased_slots <slot> <holder>...: treehouse status --json reports each Conventioner slot <slot>
# (relative to HOME) leased to its <holder>, and nothing else.
leased_slots() {
  while (($#)); do
    jq -cn --arg path "$HOME/$1" --arg holder "$2" \
      '{name: ($path | split("/") | .[-2]), path: $path, status: "leased", branch: "", lease_holder: $holder}'
    shift 2
  done | jq -s . >"$STUB_FIXTURES/pool.json"
}

# GitHub's API answers HEAD with a Date header <seconds> away from this clock.
clock_offset() {
  echo "$1" >"$STUB_FIXTURES/clock-offset"
  stub_script curl <<'EOF'
offset=$(cat "$STUB_FIXTURES/clock-offset")
printf 'HTTP/2 200\r\ndate: %s\r\nserver: github.com\r\n\r\n' \
  "$(LC_ALL=C date -u -d "@$(($(date +%s) + offset))" '+%a, %d %b %Y %H:%M:%S GMT')"
EOF
}

# The version stub for <command>, made once: it answers an argument list it has an answer for
# (an <args>.sh answer is a script, sourced), exits 127 as a missing command for one marked
# missing, and runs the real command otherwise, after $TOOL_ANSWERS/<command>.wrap.sh when there
# is one (helpers/bootstrap.bash's wrappers), which may handle the call itself. Every version stub is
# one shared script (helpers/common's shared), named as its command.
tool_stub() {
  [[ ! -e $TOOL_STUBS/$1 ]] || return 0
  mkdir -p "$TOOL_ANSWERS/$1"
  ln "$(shared tool-stub <<EOF
#!$(PATH=$REAL_PATH command -v bash)
name=\${0##*/}
key=\$*
answer=\$TOOL_ANSWERS/\$name/\${key// /_}
if [[ -f \$answer.missing ]]; then echo "\$name: command not found" >&2; exit 127; fi
if [[ -f \$answer.sh ]]; then source "\$answer.sh"; exit 0; fi
if [[ -f \$answer ]]; then cat "\$answer"; exit 0; fi
real=\$(PATH=\$REAL_PATH command -v "\$name") || real=''
if [[ -f \$TOOL_ANSWERS/\$name.wrap.sh ]]; then
  source "\$REPO_ROOT/tests/helpers/doctor.bash"
  source "\$TOOL_ANSWERS/\$name.wrap.sh"
fi
[[ -n \$real ]] || { echo "\$name: command not found" >&2; exit 127; }
exec "\$real" "\$@"
EOF
)" "$TOOL_STUBS/$1"
}

# answer <version_cmd> <output>: the command answers those words with <output>; with no output
# it is missing for them.
answer() {
  local words key file
  read -ra words <<<"$1"
  tool_stub "${words[0]}"
  key=${1#* }
  file=$TOOL_ANSWERS/${words[0]}/${key// /_}
  rm -f "$file" "$file.missing" "$file.sh"
  if (($# > 1)); then printf '%s\n' "$2" >"$file"; else : >"$file.missing"; fi
}

# The tools of <os> (arch, macos) on this machine type, one "name<TAB>version_cmd<TAB>pin or
# min<TAB>source" each, as bin/lib/tools.jq resolves them for the doctor.
lock_tools() {
  local machine
  machine=$(cat "$STUB_FIXTURES/uname-m.out" 2>/dev/null || echo x86_64)
  jq -L "$REPO_ROOT/bin/lib" -r --arg os "$1" --arg machine "$machine" \
    'include "tools"; tools_for($os; $machine) | [.name, .version_cmd, .pin + .min, .source] | @tsv' "$LOCK"
}

# Every tool of <os> answers at <version> (default its pin or min), or is missing (version "-").
tools_at() {
  local os=$1 name cmd version
  while IFS=$'\t' read -r name cmd version _; do
    version=${2:-$version}
    if [[ $version == - ]]; then
      answer "$cmd"
    else
      answer "$cmd" "${FORMAT[$name]//%s/$version}"
    fi
  done < <(lock_tools "$os")
}

# The sandbox runs as macOS (as_macos), with the heartbeat's LaunchAgents enabled.
on_macos() {
  as_macos
  echo arm64 >"$STUB_FIXTURES/uname-m.out"
  "$REPO_ROOT/bin/team-timers" enable >/dev/null
}

# The ids of the manifest's enabled secrets, in order.
secret_ids() {
  jq -r '.secrets[] | select(.enabled != false) | .id' "$BATS_TEST_DIRNAME/fixtures/secrets.json"
}

# The line of check <name> in the output.
line_of() {
  # shellcheck disable=SC2154 # bats' run sets output
  grep -E "^(PASS|WARN|FAIL) $1: " <<<"$output"
}

# The checks of the output, one name per line.
checks() {
  sed -E 's/^(PASS|WARN|FAIL) ([^:]+): .*/\2/' <<<"$output"
}

# Whether <word> is one of the other arguments: among <word> <word>...
# A loop, not printf | grep -q: under pipefail, grep leaving at its match can kill printf with
# SIGPIPE before it is done, which reads as no match on a busy machine.
among() {
  local word
  for word in "${@:2}"; do [[ $word != "$1" ]] || return 0; done
  return 1
}

# The tool <name> of the sandbox's OS (Darwin or not, by the uname stub) answers its version_cmd
# at its pin or min from now on, as if just installed: mark_installed <name>...
mark_installed() {
  local os=arch name cmd version
  [[ $(cat "$STUB_FIXTURES/uname.out" 2>/dev/null) != Darwin ]] || os=macos
  while IFS=$'\t' read -r name cmd version _; do
    if among "$name" "$@"; then answer "$cmd" "${FORMAT[$name]//%s/$version}"; fi
  done < <(lock_tools "$os")
}

# Each tool of the sandbox's OS whose lock source is <prefix> and packages all among <package>...
# answers as installed (mark_installed), as a package manager given those packages would leave
# it: installed_from <prefix> <package>...
installed_from() {
  local prefix=$1 os=arch name source pkg all
  shift
  [[ $(cat "$STUB_FIXTURES/uname.out" 2>/dev/null) != Darwin ]] || os=macos
  while IFS=$'\t' read -r name _ _ source; do
    [[ $source == "$prefix"* ]] || continue
    all=1
    for pkg in ${source#"$prefix"}; do among "$pkg" "$@" || all=0; done
    ((!all)) || mark_installed "$name"
  done < <(lock_tools "$os")
}
