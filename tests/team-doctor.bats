#!/usr/bin/env bats
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs. Every tool in
# machine/tools.lock is a version stub on PATH that answers its version_cmd as the real tool does
# and hands every other call to the real command (or the sandbox's logging stub), so the doctor's
# own git, jq and date keep working while a tool reads as missing or old. A stubbed uname picks
# the OS: Linux with an Arch os-release file, or Darwin with a fake Homebrew prefix.

load helpers/common

LOCK=$BATS_TEST_DIRNAME/../machine/tools.lock

# What each tool prints for its version_cmd, %s being the version, as the real tool does.
declare -gA FORMAT=(
  [claude]='%s (Claude Code)'
  [node]='v%s'
  [codegraph]='%s'
  [gh-axi]='%s'
  [chrome-devtools-axi]='%s'
  [lavish-axi]='%s'
  [quota-axi]='quota-axi %s'
  [tasks-axi]='%s'
  [bun]='%s'
  [treehouse]='v%s'
  [no-mistakes]='no-mistakes version v%s (389716a) 2026-07-14T22:29:23Z'
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
  [coreutils]='date (GNU coreutils) %s'
  [findutils]='find (GNU findutils) %s'
  [gnu-sed]='sed (GNU sed) %s'
  [grep]='grep (GNU grep) %s'
  [flock]='flock %s'
)

setup() {
  sandbox
  hold_lease home-pc >/dev/null

  # The OS: Linux, from an Arch os-release file, until a test says Darwin.
  cp "$REPO_ROOT/tests/helpers/stub" "$BATS_TEST_TMPDIR/stubs/uname"
  stub_reply uname Linux
  export TEAM_OS_RELEASE=$BATS_TEST_TMPDIR/os-release
  printf '%s\n' 'NAME="Arch Linux"' 'PRETTY_NAME="Arch Linux"' 'ID=arch' >"$TEAM_OS_RELEASE"

  # Version stubs go first on PATH; anything else they are asked goes to what PATH had before.
  tools=$BATS_TEST_TMPDIR/tools
  mkdir -p "$tools/answers"
  export REAL_PATH=$PATH TOOL_ANSWERS=$tools/answers PATH=$tools:$PATH

  # Signed in everywhere, the clock right.
  stub_script claude <<'EOF'
case $* in
  'auth status --json')
    echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "daniel@example.invalid", "orgId": "org-secret-0000", "subscriptionType": "pro"}' ;;
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

# The version stub for <command>, made once: it answers an argument list it has an answer for,
# exits 127 as a missing command for one marked missing, and runs the real command otherwise.
tool_stub() {
  [[ ! -e $tools/$1 ]] || return 0
  mkdir -p "$TOOL_ANSWERS/$1"
  cat >"$tools/$1" <<EOF
#!$(PATH=$REAL_PATH command -v bash)
key=\$*
answer=\$TOOL_ANSWERS/$1/\${key// /_}
if [[ -f \$answer.missing ]]; then echo "$1: command not found" >&2; exit 127; fi
if [[ -f \$answer ]]; then cat "\$answer"; exit 0; fi
real=\$(PATH=\$REAL_PATH command -v $1) || { echo "$1: command not found" >&2; exit 127; }
exec "\$real" "\$@"
EOF
  chmod +x "$tools/$1"
}

# answer <version_cmd> <output>: the command answers those words with <output>; with no output
# it is missing for them.
answer() {
  local words key file
  read -ra words <<<"$1"
  tool_stub "${words[0]}"
  key=${1#* }
  file=$TOOL_ANSWERS/${words[0]}/${key// /_}
  rm -f "$file" "$file.missing"
  if (($# > 1)); then printf '%s\n' "$2" >"$file"; else : >"$file.missing"; fi
}

# The tools of <os> (arch, macos), one "name<TAB>version_cmd<TAB>pin or min<TAB>source" each.
lock_tools() {
  jq -r --arg os "$1" '.tools[] | select(.source[$os]) | [.name, .version_cmd, (.pin // .min), .source[$os]] | @tsv' "$LOCK"
}

# Every tool of <os> answers at <version> (default its pin or min), or is missing (version "-").
tools_at() {
  local os=$1 name cmd version source
  while IFS=$'\t' read -r name cmd version source; do
    version=${2:-$version}
    if [[ $version == - ]]; then
      answer "$cmd"
    else
      answer "$cmd" "${FORMAT[$name]//%s/$version}"
    fi
  done < <(lock_tools "$os")
}

# The sandbox runs as macOS: a stubbed Darwin and a fake Homebrew with the GNU tools' directories.
on_macos() {
  stub_reply uname Darwin
  export HOMEBREW_PREFIX=$BATS_TEST_TMPDIR/brew
  local dir
  for dir in coreutils/libexec/gnubin findutils/libexec/gnubin gnu-sed/libexec/gnubin \
    grep/libexec/gnubin flock/bin; do
    mkdir -p "$HOMEBREW_PREFIX/opt/$dir"
  done
}

# The line of check <name> in the output.
line_of() {
  grep -E "^(PASS|WARN|FAIL) $1: " <<<"$output"
}

# The checks of the output, one name per line.
checks() {
  sed -E 's/^(PASS|WARN|FAIL) ([^:]+): .*/\2/' <<<"$output"
}

# Every tool line of <os> fails, naming that OS's install command, when every tool is <version>
# ("-" for missing); Claude Code's pin mismatch only warns.
every_tool_fails() {
  local os=$1 version=$2 name source line verdict
  tools_at "$os" "$version"
  run_bin -1 team-doctor
  while IFS=$'\t' read -r name _ _ source; do
    line=$(line_of "tool $name")
    verdict=FAIL
    [[ $version == - || $name != claude ]] || verdict=WARN
    if [[ $version == - ]]; then
      assert_equal "$line" "FAIL tool $name: not installed; fix: $source"
    else
      [[ $line == "$verdict tool $name: "*"; fix: $source" ]] ||
        { echo "tool $name: $line" >&2; return 1; }
    fi
  done < <(lock_tools "$os")
  # Nothing else fails: the doctor's own git, jq and date still work.
  assert_equal "$(grep -v '^.... tool ' <<<"$output" | grep -cv '^PASS ')" 0
}

@test "tools.lock lists every tool of the spec once per OS, each with a version_cmd, a pattern, a pin or a min, and its sources" {
  jq -e '.tools | length > 0 and all(.[];
      (.name | type == "string") and (.version_cmd | type == "string") and (.version_pattern | type == "string")
      and ([has("pin"), has("min")] | map(select(.)) | length == 1)
      and ((.pin // .min) | test("^[0-9]+(\\.[0-9]+)+"))
      and (.pin_mismatch // "FAIL" | IN("WARN", "FAIL"))
      and (.source | type == "object" and length > 0 and (keys - ["arch", "macos"] == [])))' "$LOCK"
  local os both=(claude node codegraph gh-axi chrome-devtools-axi lavish-axi quota-axi tasks-axi bun
    treehouse no-mistakes op git jq tmux gh rsync docker docker-compose python bash)
  local mac_only=(coreutils findutils gnu-sed grep flock)
  for os in arch macos; do
    local expected=("${both[@]}")
    [[ $os == arch ]] || expected+=("${mac_only[@]}")
    assert_equal "$(lock_tools "$os" | cut -f1 | sort)" "$(printf '%s\n' "${expected[@]}" | sort)"
  done
  # Pinned: the tools the bootstrap installs itself, op on Linux only; Claude Code only warns.
  assert_equal "$(jq -r '[.tools[] | select(.pin) | .name] | join(" ")' "$LOCK")" \
    "claude node codegraph gh-axi chrome-devtools-axi lavish-axi quota-axi tasks-axi bun treehouse no-mistakes op"
  assert_equal "$(jq -r '[.tools[] | select(.pin_mismatch) | "\(.name)=\(.pin_mismatch)"] | join(" ")' "$LOCK")" "claude=WARN"
  assert_equal "$(jq -r '.tools[] | select(.name == "docker-compose") | .min' "$LOCK")" 2.24.0
}

@test "on Arch with every tool at its version and everything set up, every line passes" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(grep -cv '^PASS ' <<<"$output")" 0
  local expected
  expected=$(printf '%s\n' os; lock_tools arch | cut -f1 | sed 's/^/tool /'
    printf '%s\n' machine 'claude login' 'github login' clock lease)
  assert_equal "$(checks)" "$expected"
  assert_equal "$(line_of os)" "PASS os: Arch Linux"
  assert_equal "$(line_of 'tool claude')" "PASS tool claude: 2.1.308"
  assert_equal "$(line_of 'tool jq')" "PASS tool jq: 1.7.1 (minimum 1.7.1)"
  assert_equal "$(line_of machine)" "PASS machine: home-pc"
  assert_equal "$(line_of 'claude login')" "PASS claude login: signed in with a claude.ai account"
  assert_contains "$(line_of lease)" "PASS lease: held here, epoch 1"
}

@test "on macOS with every tool at its version, every line passes, Homebrew's included" {
  on_macos
  tools_at macos
  run_bin -0 team-doctor
  assert_equal "$(grep -cv '^PASS ' <<<"$output")" 0
  local expected
  expected=$(printf '%s\n' os homebrew; lock_tools macos | cut -f1 | sed 's/^/tool /'
    printf '%s\n' machine 'claude login' 'github login' clock lease)
  assert_equal "$(checks)" "$expected"
  assert_equal "$(line_of os)" "PASS os: macOS"
}

@test "on Arch each missing tool fails its line with its Arch install command" {
  every_tool_fails arch -
  assert_equal "$(line_of 'tool jq')" "FAIL tool jq: not installed; fix: sudo pacman -S --needed jq"
}

@test "on Arch each tool below its minimum or off its pin fails its line; Claude Code's only warns" {
  every_tool_fails arch 0.1.0
  assert_equal "$(line_of 'tool git')" "FAIL tool git: 0.1.0, below the minimum 2.40.0; fix: sudo pacman -S --needed git"
  assert_equal "$(line_of 'tool bun')" "FAIL tool bun: 0.1.0, not the pinned 1.3.14; fix: curl -fsSL https://bun.sh/install | bash -s bun-v1.3.14"
  assert_equal "$(line_of 'tool claude')" "WARN tool claude: 0.1.0, not the pinned 2.1.308; fix: curl -fsSL https://claude.ai/install.sh | bash -s 2.1.308"
}

@test "on macOS each missing tool fails its line with its Homebrew or install command" {
  on_macos
  every_tool_fails macos -
  assert_equal "$(line_of 'tool gnu-sed')" "FAIL tool gnu-sed: not installed; fix: brew install gnu-sed"
}

@test "on macOS each old tool fails its line with its Homebrew or install command" {
  on_macos
  every_tool_fails macos 0.1.0
  assert_equal "$(line_of 'tool coreutils')" "FAIL tool coreutils: 0.1, below the minimum 9.0; fix: brew install coreutils"
}

@test "one old tool fails only its own line; a version it cannot read fails too" {
  tools_at arch
  answer "jq --version" "jq-1.6"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL tool jq: 1.6, below the minimum 1.7.1; fix: sudo pacman -S --needed jq"

  answer "tmux -V" "tmux next-3.9"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'tool tmux')" 'FAIL tool tmux: `tmux -V` printed no version; fix: sudo pacman -S --needed tmux'
}

@test "macOS without the GNU tools: the Homebrew line fails with the brew install line, and the doctor goes on" {
  on_macos
  tools_at macos
  rm -r "$HOMEBREW_PREFIX/opt/gnu-sed" "$HOMEBREW_PREFIX/opt/flock"
  run_bin -1 team-doctor
  assert_equal "$(line_of homebrew)" 'FAIL homebrew: missing Homebrew packages: gnu-sed flock; fix: run `brew install gnu-sed flock`'
  assert_equal "$(line_of machine)" "PASS machine: home-pc"
  # team-lease refuses without them.
  assert_contains "$(line_of lease)" "FAIL lease: missing Homebrew packages: gnu-sed flock"
}

@test "an OS other than Arch or macOS fails, and its tools go unchecked; an Arch derivative passes" {
  tools_at arch
  printf '%s\n' 'PRETTY_NAME="Ubuntu 24.04.3 LTS"' 'ID=ubuntu' 'ID_LIKE=debian' >"$TEAM_OS_RELEASE"
  run_bin -1 team-doctor
  assert_equal "$(line_of os)" "FAIL os: Ubuntu 24.04.3 LTS is neither Arch Linux nor macOS, so no tool is checked; fix: run the team on Arch Linux or macOS"
  assert_equal "$(checks | grep -c '^tool ')" 0
  assert_equal "$(line_of machine)" "PASS machine: home-pc"

  printf '%s\n' 'PRETTY_NAME="EndeavourOS"' 'ID="endeavouros"' 'ID_LIKE="arch"' >"$TEAM_OS_RELEASE"
  run_bin -0 team-doctor
  assert_equal "$(line_of os)" "PASS os: EndeavourOS, an Arch Linux"

  stub_reply uname FreeBSD
  run_bin -1 team-doctor
  assert_equal "$(line_of os)" "FAIL os: FreeBSD is neither Arch Linux nor macOS, so no tool is checked; fix: run the team on Arch Linux or macOS"
}

@test "without a machine name the machine line fails with the command that writes one" {
  tools_at arch
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 team-doctor
  assert_equal "$(line_of machine)" "FAIL machine: this machine has no team name; fix: echo <name> > ~/.config/agent-team/machine"
  assert_equal "$(line_of lease)" "FAIL lease: this machine has no team name to read the lease with; fix: the machine line's fix, then run team-doctor again"
  echo Home_PC >"$HOME/.config/agent-team/machine"
  run_bin -1 team-doctor
  assert_equal "$(line_of machine)" "FAIL machine: ~/.config/agent-team/machine names 'Home_PC', not a lower-case kebab-case name like home-pc; fix: echo <name> > ~/.config/agent-team/machine"
}

@test "Claude Code signed out, or signed in without a claude.ai account, fails the claude login line" {
  tools_at arch
  stub_script claude <<'EOF'
echo '{"loggedIn": false, "authMethod": "none"}'
exit 1
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'claude login')" "FAIL claude login: not signed in; fix: claude auth login --claudeai"

  stub_script claude <<'EOF'
echo '{"loggedIn": true, "authMethod": "api_key", "apiProvider": "firstParty"}'
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'claude login')" "FAIL claude login: signed in through api_key, not a claude.ai account; fix: claude auth logout, then claude auth login --claudeai"

  stub_script claude <<'EOF'
echo "unexpected" >&2
exit 3
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'claude login')" "FAIL claude login: \`claude auth status\` did not answer (exit 3); fix: install Claude Code (see tool claude), then claude auth login --claudeai"
}

@test "gh signed out fails the github login line" {
  tools_at arch
  stub_script gh <<'EOF'
echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
exit 1
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'github login')" "FAIL github login: gh auth status finds no working login for github.com; fix: gh auth login --hostname github.com --git-protocol https --web"
}

@test "a clock more than a minute off GitHub's warns; GitHub's Date unreadable warns too" {
  tools_at arch
  # The Date header is in whole seconds, so the skew read may be a second off the one set.
  clock_offset 300
  run_bin -0 team-doctor
  [[ $(line_of clock) =~ ^"WARN clock: this clock is "(299|300|301)" s behind GitHub's; fix: sudo timedatectl set-ntp true"$ ]]
  clock_offset -120
  on_macos
  tools_at macos
  run_bin -0 team-doctor
  [[ $(line_of clock) =~ ^"WARN clock: this clock is "(119|120|121)" s ahead of GitHub's; fix: sudo systemsetup -setusingnetworktime on"$ ]]
  clock_offset 30
  run_bin -0 team-doctor
  assert_equal "$(line_of clock)" "PASS clock: within 60 s of GitHub's"

  stub_script curl <<'EOF'
echo "curl: (6) Could not resolve host: api.github.com" >&2
exit 6
EOF
  run_bin -0 team-doctor
  assert_equal "$(line_of clock)" "WARN clock: cannot read the Date of https://api.github.com; fix: check the network, then run team-doctor again"
}

@test "the lease line: PASS held here, WARN held elsewhere or released, FAIL unreachable" {
  tools_at arch
  make_machine laptop
  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-doctor
  assert_equal "$(line_of lease)" "WARN lease: released, epoch 1; fix: team-lease take, with Daniel's yes"

  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  run_bin -0 team-doctor
  assert_equal "$(line_of lease)" "WARN lease: held by laptop, epoch 2, renewed 0 minutes ago; fix: hand off on laptop, then team-resume here"

  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 team-doctor
  assert_equal "$(line_of lease)" "FAIL lease: GitHub unreachable, so the lease is unconfirmed; fix: check the network, then run team-doctor again"

  git -C "$TEAM_HOME" remote remove origin
  run_bin -1 team-doctor
  assert_equal "$(line_of lease)" "FAIL lease: the team home $TEAM_HOME has no git remote origin, where the lease lives; fix: fix what team-lease names, then run team-doctor again"
}

@test "--json prints one array of {check, verdict, reason, fix}, the same verdicts as the lines" {
  tools_at arch
  answer "jq --version" "jq-1.6"
  run_bin -1 team-doctor
  local text=$output
  run_bin -1 --separate-stderr team-doctor --json
  jq -e 'type == "array" and all(.[]; keys == ["check", "fix", "reason", "verdict"] and (.verdict | IN("PASS", "WARN", "FAIL")))' <<<"$output"
  assert_equal "$(jq -r '.[] | "\(.verdict) \(.check)"' <<<"$output")" "$(sed -E 's/^(....) ([^:]+): .*/\1 \2/' <<<"$text")"
  jq -e '.[] | select(.check == "tool jq") == {check: "tool jq", verdict: "FAIL", reason: "1.6, below the minimum 1.7.1", fix: "sudo pacman -S --needed jq"}' <<<"$output"
  jq -e '.[] | select(.check == "machine") == {check: "machine", verdict: "PASS", reason: "home-pc", fix: ""}' <<<"$output"
}

@test "no line carries a secret, and the doctor reads no credential file, ~/.claude.json or ~/.claude/channels/" {
  tools_at arch
  echo '{"claudeAiOauth": {"accessToken": "sk-ant-oat-fake-secret"}}' >"$HOME/.claude/.credentials.json"
  echo '{"oauthAccount": {"emailAddress": "daniel@example.invalid"}}' >"$HOME/.claude.json"
  mkdir -p "$HOME/.config/gh"
  echo 'github.com: {oauth_token: gho_fakefakefakefake}' >"$HOME/.config/gh/hosts.yml"
  run_bin -0 team-doctor
  local text=$output
  run_bin -0 team-doctor --json
  local secret
  for secret in sk-ant-oat-fake-secret daniel@example.invalid org-secret-0000 gho_fakefakefakefake "$FAKE_DISCORD_TOKEN"; do
    [[ $text$output != *"$secret"* ]] || { echo "the doctor printed $secret" >&2; return 1; }
  done
  # The code, its comments aside, names none of them.
  run -1 grep -nE 'credentials|\.claude\.json|channels|hosts\.yml|discord_|[Kk]eychain|security find' \
    <(grep -v '^[[:space:]]*#' "$REPO_ROOT/bin/team-doctor")
}

@test "team-doctor refuses arguments other than --json" {
  run_bin -2 --separate-stderr team-doctor --yes
  assert_equal "$stderr" "team-doctor: usage: team-doctor [--json]"
}
