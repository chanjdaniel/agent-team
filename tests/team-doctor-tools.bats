#!/usr/bin/env bats
# shellcheck disable=SC2153 # LOCK and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the tool lines, tools.lock and the OS; team-doctor*.bats hold the other lines.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
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
  # Nothing else fails: the doctor's own git, jq and date still work. Without op, the 1password
  # line warns too, without docker the docker line points at its tool line, and without opencode
  # the opencode-gate line does.
  if [[ $version == - ]]; then
    assert_contains "$(line_of 1password)" "WARN 1password: op is not installed,"
    assert_equal "$(line_of docker)" "FAIL docker: docker is not installed; fix: the tool docker line's fix"
    assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: opencode is not installed, so the wrapper has nothing to run; fix: the tool opencode line's fix"
  fi
  assert_equal "$(grep -v '^.... tool ' <<<"$output" | grep -v '^PASS ' | grep -v '^WARN 1password: op ' |
    grep -v '^FAIL docker: docker is not installed;' | grep -v '^FAIL opencode-gate: opencode is not installed,' || true)" ""
}

# <lock> (default bin/lib/tools.lock) has the shape bin/lib/tools.jq reads: each tool a name, a
# version_cmd, a pattern, and a pin or a min with its sources, or a GitHub release or fork.
lock_has_its_shape() {
  jq -e '.tools | length > 0 and all(.[];
      (.name | type == "string") and (.version_cmd | type == "string") and (.version_pattern | type == "string")
      and (.pin_mismatch // "FAIL" | IN("WARN", "FAIL"))
      and if has("from") then
        ([has("pin"), has("min"), has("source")] | any | not)
        and (.dir | type == "object" and length > 0 and (keys - ["arch", "macos"] == []))
        and (.from | IN("release", "fork")) and has(.from)
        and ((has("release") | not) or ((.release.repo | test("^[^/]+/[^/]+$")) and (.release.tag | test("^v[0-9]+(\\.[0-9]+)+$"))
          and (.release.sha256 | keys == ["darwin-amd64", "darwin-arm64", "linux-amd64"])
          and (.release.sha256 | all(.[]; test("^[0-9a-f]{64}$")))))
        # A fork is built at a commit past upstream'\''s release, so its version is git describe of
        # that commit: <tag without v>-<commits since>-g<the commit'\''s first 7>.
        and ((has("fork") | not) or (has("release") and (.fork.repo | test("^[^/]+/[^/]+$"))
          and (.fork.commit | test("^[0-9a-f]{40}$"))
          and ("^\(.release.tag | ltrimstr("v") | gsub("\\."; "\\."))-[0-9]+-g\(.fork.commit[:7])$" as $describe
            | .fork.version | test($describe))))
      else
        ([has("pin"), has("min")] | map(select(.)) | length == 1)
        and ((.pin // .min) | test("^[0-9]+(\\.[0-9]+)+"))
        and (.source | type == "object" and length > 0 and (keys - ["arch", "macos"] == []))
      end)' "${1:-$LOCK}"
}

@test "tools.lock lists every tool of the spec once per OS, each with a version_cmd, a pattern, a pin or a min, and its sources" {
  lock_has_its_shape
  local os both=(claude node codegraph gh-axi chrome-devtools-axi chrome-devtools-mcp lavish-axi opencode bun
    treehouse no-mistakes op git jq tmux gh rsync docker docker-compose python bash go)
  local mac_only=(coreutils findutils gnu-sed grep flock) arch_only=(make unzip)
  for os in arch macos; do
    local expected=("${both[@]}")
    if [[ $os == arch ]]; then expected+=("${arch_only[@]}"); else expected+=("${mac_only[@]}"); fi
    assert_equal "$(lock_tools "$os" | cut -f1 | sort)" "$(printf '%s\n' "${expected[@]}" | sort)"
  done
  # Pinned: the tools the bootstrap installs itself, op on Linux only; Claude Code only warns.
  assert_equal "$(jq -r '[.tools[] | select(.pin or .from) | .name] | join(" ")' "$LOCK")" \
    "claude node codegraph gh-axi chrome-devtools-axi chrome-devtools-mcp lavish-axi opencode bun treehouse no-mistakes op"
  # treehouse is a GitHub release, each archive's checksum recorded; no-mistakes is Daniel's fork,
  # built at a commit on its main past upstream's release (the next test holds its version to
  # both), and keeps upstream's release, which from = "release" would pin instead.
  assert_equal "$(jq -r '[.tools[] | select(.from) | "\(.name)=\(.from)"] | join(" ")' "$LOCK")" \
    "treehouse=release no-mistakes=fork"
  assert_equal "$(jq -r '[.tools[] | select(.release) | "\(.name)=\(.release.repo)"] | join(" ")' "$LOCK")" \
    "treehouse=kunchenguid/treehouse no-mistakes=kunchenguid/no-mistakes"
  assert_equal "$(jq -r '.tools[] | select(.fork) | "\(.name)=\(.fork.repo)"' "$LOCK")" "no-mistakes=chanjdaniel/no-mistakes"
  # The fork builds with Go (its go.mod's version) and make, from the OS packages.
  assert_equal "$(jq -r '[.tools[] | select(.name | IN("go", "make")) | "\(.name)>=\(.min):\(.source | keys | join(","))"] | join(" ")' "$LOCK")" \
    "go>=1.25.0:arch,macos make>=4.0:arch"
  assert_equal "$(jq -r '[.tools[] | select(.pin_mismatch) | "\(.name)=\(.pin_mismatch)"] | join(" ")' "$LOCK")" "claude=WARN"
  assert_equal "$(jq -r '.tools[] | select(.name == "docker-compose") | .min' "$LOCK")" 2.24.0
}

@test "a fork's version is git describe of its commit from upstream's release tag, so a half-bumped pin fails the lock's shape" {
  local lock=$BATS_TEST_TMPDIR/tools.lock commit version tag other
  commit=$(lock_of no-mistakes .fork.commit)
  version=$(lock_of no-mistakes .fork.version)
  tag=$(lock_of no-mistakes .release.tag)
  [[ $version == "${tag#v}-"+([0-9])"-g${commit:0:7}" ]]
  # Another commit, every digit of the lock's moved on by one, so it differs from it at each place.
  other=$(tr 0-9a-f 1-9a-f0 <<<"$commit")
  # The new commit and its version, consistently: the shape holds.
  jq --arg other "$other" '(.tools[] | select(.name == "no-mistakes")).fork |= (.commit = $other
    | .version = "\(.version | sub("-[0-9]+-g[0-9a-f]+$"; ""))-40-g\($other[:7])")' "$LOCK" >"$lock"
  lock_has_its_shape "$lock"
  # The commit changed without its version.
  jq --arg other "$other" '(.tools[] | select(.name == "no-mistakes")).fork.commit = $other' "$LOCK" >"$lock"
  run -1 lock_has_its_shape "$lock"
  # The version changed without its commit, or names another release than the lock's.
  jq --arg other "$other" '(.tools[] | select(.name == "no-mistakes")).fork.version |= sub("-g[0-9a-f]+$"; "-g\($other[:7])")' "$LOCK" >"$lock"
  run -1 lock_has_its_shape "$lock"
  jq '(.tools[] | select(.name == "no-mistakes")).release.tag = "v0.1.0"' "$LOCK" >"$lock"
  run -1 lock_has_its_shape "$lock"
  # A fork with no release to describe from.
  jq '(.tools[] | select(.name == "no-mistakes")) |= del(.release)' "$LOCK" >"$lock"
  run -1 lock_has_its_shape "$lock"
}

@test "on Arch with every tool at its version and everything set up, every line passes" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" ""
  local expected
  expected=$(printf '%s\n' os; lock_tools arch | cut -f1 | sed 's/^/tool /'
    printf '%s\n' docker chrome servers machine 'team home' 'team home fetch' 'team home pack' 'git hooks' 'records hooks' 'claude login' 'github login' config plugins memory discord 'own settings' 1password
    secret_ids | sed 's/^/secret /'
    echo 'discord access'
    echo 'interview channel'
    echo opencode-gate
    echo records
    echo 'trust team home'
    echo captures
    echo 'heavy runs'
    project_checks
    printf '%s\n' 'stack memory' clock lease heartbeat slots resources offline)
  assert_equal "$(checks)" "$expected"
  assert_equal "$(line_of os)" "PASS os: Arch Linux"
  assert_equal "$(line_of 'tool claude')" "PASS tool claude: $(lock_pin claude)"
  assert_equal "$(line_of 'tool jq')" "PASS tool jq: 1.7.1 (minimum 1.7.1)"
  assert_equal "$(line_of machine)" "PASS machine: home-pc"
  assert_equal "$(line_of 'team home')" "PASS team home: $TEAM_HOME, named by TEAM_HOME: a checkout of its own on dev, with an origin"
  assert_equal "$(line_of 'claude login')" "PASS claude login: signed in with a claude.ai account"
  assert_equal "$(line_of records)" "PASS records: the ledger meets its contract (0 lines), the registry passes (2 projects) and machine/secrets.md describes every enabled secret"
  assert_contains "$(line_of lease)" "PASS lease: held here, epoch 1"
  assert_equal "$(line_of heartbeat)" "PASS heartbeat: enabled, and this machine holds the lease"
}

@test "on macOS with every tool at its version, every line passes, Homebrew's included" {
  on_macos
  tools_at macos
  run_bin -0 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" ""
  local expected
  expected=$(printf '%s\n' os homebrew; lock_tools macos | cut -f1 | sed 's/^/tool /'
    printf '%s\n' docker chrome servers machine 'team home' 'team home fetch' 'team home pack' 'git hooks' 'records hooks' 'claude login' 'github login' config plugins memory discord 'own settings' 1password
    secret_ids | sed 's/^/secret /'
    echo 'discord access'
    echo 'interview channel'
    echo opencode-gate
    echo records
    echo 'trust team home'
    echo captures
    echo 'heavy runs'
    project_checks
    printf '%s\n' 'stack memory' clock lease heartbeat slots resources offline)
  assert_equal "$(checks)" "$expected"
  assert_equal "$(line_of os)" "PASS os: macOS"
}

@test "on Arch each missing tool fails its line with its Arch install command" {
  every_tool_fails arch -
  assert_equal "$(line_of 'tool jq')" "FAIL tool jq: not installed; fix: sudo pacman -S --needed jq"
}

@test "on Arch each tool below its minimum or off its pin fails its line; Claude Code's only warns" {
  local bun claude
  bun=$(lock_pin bun)
  claude=$(lock_pin claude)
  every_tool_fails arch 0.1.0
  assert_equal "$(line_of 'tool git')" "FAIL tool git: 0.1.0, below the minimum 2.40.0; fix: sudo pacman -S --needed git"
  assert_equal "$(line_of 'tool bun')" "FAIL tool bun: 0.1.0, not the pinned $bun; fix: curl -fsSL https://bun.sh/install | bash -s bun-v$bun"
  assert_equal "$(line_of 'tool claude')" "WARN tool claude: 0.1.0, not the pinned $claude; fix: curl -fsSL https://claude.ai/install.sh | bash -s $claude"
}

@test "a GitHub release's fix downloads this machine's archive and checks its recorded SHA-256 before unpacking it" {
  local sha tag
  tag=$(lock_of treehouse .release.tag)
  every_tool_fails arch -
  sha=$(lock_of treehouse '.release.sha256["linux-amd64"]')
  assert_equal "$(line_of 'tool treehouse')" "FAIL tool treehouse: not installed; fix: f=\$(mktemp) && curl -fsSLo \"\$f\" https://github.com/kunchenguid/treehouse/releases/download/$tag/treehouse-$tag-linux-amd64.tar.gz && echo \"$sha  \$f\" | sha256sum -c - && sudo mkdir -p /usr/local/bin && sudo tar -xzf \"\$f\" -C /usr/local/bin treehouse && rm -f \"\$f\""

  # An Intel Mac gets its own archive, checked with macOS's shasum.
  on_macos
  echo x86_64 >"$STUB_FIXTURES/uname-m.out"
  tools_at macos 0.1.0
  run_bin -1 team-doctor
  sha=$(lock_of treehouse '.release.sha256["darwin-amd64"]')
  assert_equal "$(line_of 'tool treehouse')" "FAIL tool treehouse: 0.1.0, not the pinned ${tag#v}; fix: f=\$(mktemp) && curl -fsSLo \"\$f\" https://github.com/kunchenguid/treehouse/releases/download/$tag/treehouse-$tag-darwin-amd64.tar.gz && echo \"$sha  \$f\" | shasum -a 256 -c && mkdir -p ~/.local/bin && tar -xzf \"\$f\" -C ~/.local/bin treehouse && rm -f \"\$f\""
}

@test "a machine type the lock records no archive for gets a fix that says so" {
  local tag
  tag=$(lock_of treehouse .release.tag)
  echo aarch64 >"$STUB_FIXTURES/uname-m.out"
  tools_at arch
  answer "treehouse --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'tool treehouse')" "FAIL tool treehouse: not installed; fix: bin/lib/tools.lock records no linux-arm64 archive of treehouse $tag; see https://github.com/kunchenguid/treehouse/releases/tag/$tag"
}

@test "no-mistakes is built from Daniel's fork at its pinned commit, on Arch and macOS alike" {
  local fix
  fix='d=$(mktemp -d) && git clone -q https://github.com/chanjdaniel/no-mistakes "$d" && git -C "$d" checkout -q '$(lock_of no-mistakes .fork.commit)' && make -C "$d" build && mkdir -p ~/.no-mistakes/bin && install -m 755 "$d/bin/no-mistakes" ~/.no-mistakes/bin/no-mistakes && rm -rf "$d"'
  every_tool_fails arch -
  assert_equal "$(line_of 'tool no-mistakes')" "FAIL tool no-mistakes: not installed; fix: $fix"
  assert_equal "$(line_of 'tool go')" "FAIL tool go: not installed; fix: sudo pacman -S --needed go"
  assert_equal "$(line_of 'tool make')" "FAIL tool make: not installed; fix: sudo pacman -S --needed make"
  # The build of an older commit (the fork's v1.37.0 build) is off the pin.
  tools_at arch
  answer "no-mistakes --version" "no-mistakes version v1.37.0-4-g389716a (389716a) 2026-07-14T22:29:23Z"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'tool no-mistakes')" "FAIL tool no-mistakes: 1.37.0-4-g389716a, not the pinned $(lock_pin no-mistakes); fix: $fix"

  on_macos
  tools_at macos
  answer "no-mistakes --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'tool no-mistakes')" "FAIL tool no-mistakes: not installed; fix: $fix"
  assert_equal "$(line_of 'tool go')" "PASS tool go: 1.25.0 (minimum 1.25.0)"
  [[ -z $(line_of 'tool make') ]]
}

@test "from = release pins upstream's release instead of the fork, a one-line change in tools.lock" {
  local lock=$BATS_TEST_TMPDIR/tools.lock line sha tag
  jq '(.tools[] | select(.name == "no-mistakes")).from = "release"' "$LOCK" >"$lock"
  assert_equal "$(diff "$LOCK" "$lock" | grep -c '^[<>]')" 2
  sha=$(lock_of no-mistakes '.release.sha256["linux-amd64"]')
  tag=$(lock_of no-mistakes .release.tag)
  line=$(jq -L "$REPO_ROOT/bin/lib" -r --arg os arch --arg machine x86_64 \
    'include "tools"; tools_for($os; $machine) | select(.name == "no-mistakes") | "\(.pin)\t\(.source)"' "$lock")
  assert_equal "$line" "${tag#v}	f=\$(mktemp) && curl -fsSLo \"\$f\" https://github.com/kunchenguid/no-mistakes/releases/download/$tag/no-mistakes-$tag-linux-amd64.tar.gz && echo \"$sha  \$f\" | sha256sum -c - && mkdir -p ~/.no-mistakes/bin && tar -xzf \"\$f\" -C ~/.no-mistakes/bin no-mistakes && rm -f \"\$f\""
  # The other tools resolve exactly as before.
  assert_equal "$(jq -L "$REPO_ROOT/bin/lib" -c --arg os arch --arg machine x86_64 'include "tools"; tools_for($os; $machine) | select(.name != "no-mistakes")' "$lock")" \
    "$(jq -L "$REPO_ROOT/bin/lib" -c --arg os arch --arg machine x86_64 'include "tools"; tools_for($os; $machine) | select(.name != "no-mistakes")' "$LOCK")"
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
  assert_equal "$(line_of 'heavy runs')" "WARN heavy runs: \`team-heavy status\` did not answer: missing Homebrew packages: gnu-sed flock; run \`brew install gnu-sed flock\`; fix: fix what it names, then run team-doctor again"
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

# version_command <dir> <name> <output>: <dir>/<name> answers --version with <output> and hands
# every other call to the real command, as an installed tool would.
version_command() {
  mkdir -p "$1"
  cat >"$1/$2" <<SH
#!$(command -v bash)
if [[ \$* == --version ]]; then echo '$3'; exit 0; fi
exec "\$(PATH=\$REAL_PATH command -v $2)" "\$@"
SH
  chmod +x "$1/$2"
}

@test "a plain doctor and the bootstrap's check give one verdict: the pinned Node in nvm's directory beats another node first on PATH" {
  tools_at arch
  rm "$TOOL_STUBS/node"
  # The shell's PATH starts with another Node; the pinned one is only in nvm's directory.
  local other=$BATS_TEST_TMPDIR/other-node node
  node=$(lock_pin node)
  version_command "$other" node v0.1.0
  version_command "$HOME/.nvm/versions/node/v$node/bin" node "v$node"
  PATH=$other:$PATH run_bin -0 team-doctor
  assert_equal "$(line_of 'tool node')" "PASS tool node: $node"
  PATH=$other:$PATH run_bin -0 team-bootstrap --stage check
  [[ $output != *"tool node"* ]]
}

@test "on macOS python3 is Homebrew's pinned Python before an older one first on PATH, and its line says which it found" {
  on_macos
  tools_at macos
  rm "$TOOL_STUBS/python3"
  local old=$BATS_TEST_TMPDIR/system-python brewed=$HOMEBREW_PREFIX/opt/python@3.12/libexec/bin
  version_command "$old" python3 "Python 3.9.6"
  PATH=$old:$PATH run_bin team-doctor
  assert_equal "$(line_of 'tool python')" "FAIL tool python: 3.9.6 at $old/python3, below the minimum 3.11.0; fix: brew install python@3.12"
  version_command "$brewed" python3 "Python 3.12.4"
  PATH=$old:$PATH run_bin team-doctor
  assert_equal "$(line_of 'tool python')" "PASS tool python: 3.12.4 at $brewed/python3 (minimum 3.11.0)"
}

# What lavish-axi prints, on stderr, when Node starts in a directory that no longer exists (report
# F5): only Node's version, in its install path.
lavish_crash="node:internal/bootstrap/switches/does_own_process_state:142
    cachedCwd = rawMethods.cwd();
                           ^

Error: ENOENT: no such file or directory, uv_cwd
    at process.wrappedCwd [as cwd] (node:internal/bootstrap/switches/does_own_process_state:142:28)
    at Object.<anonymous> (/Users/danielchan/.nvm/versions/node/v22.19.0/lib/node_modules/lavish-axi/node_modules/depd/index.js:23:24)"

@test "a version command that prints only another tool's version printed no version" {
  local lavish
  lavish=$(lock_pin lavish-axi)
  tools_at arch
  answer "lavish-axi --version" "$lavish_crash"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'tool lavish-axi')" \
    "FAIL tool lavish-axi: \`lavish-axi --version\` printed no version; fix: npm install -g lavish-axi@$lavish"
  # A line before the version, a warning say, does not hide it.
  answer "lavish-axi --version" "(node:4242) Warning: something is deprecated
$lavish"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'tool lavish-axi')" "PASS tool lavish-axi: $lavish"
}

@test "every version pattern starts at a line's start or names its tool, so another tool's version is never read as its own" {
  jq -e '.tools | all(.[]; .version_pattern | startswith("^") or test("[A-Za-z]"))' "$LOCK"
}

@test "a doctor started in a directory that no longer exists says so, runs from HOME and passes" {
  tools_at arch
  # Claude Code and the Node tools fail without a working directory, as on the laptop.
  local gone=$BATS_TEST_TMPDIR/load-check-wt claude lavish
  claude=$(lock_pin claude)
  lavish=$(lock_pin lavish-axi)
  printf '%s\n' "if [[ \$PWD -ef . ]]; then echo '$claude (Claude Code)'; else" \
    "  echo \"error: The current working directory was deleted, so that command didn't work.\" >&2; exit 1; fi" \
    >"$TOOL_ANSWERS/claude/--version.sh"
  printf '%s\n' "if [[ \$PWD -ef . ]]; then echo $lavish; else cat >&2 <<'CRASH'" "$lavish_crash" CRASH \
    'exit 1; fi' >"$TOOL_ANSWERS/lavish-axi/--version.sh"
  rm "$TOOL_ANSWERS/claude/--version" "$TOOL_ANSWERS/lavish-axi/--version"
  mkdir "$gone"
  guard_sandbox
  run -0 --separate-stderr bash -c 'cd "$1" && rmdir "$1" && exec "$2"' gone "$gone" "$CODE_CHECKOUT/bin/team-doctor"
  assert_contains "$stderr" "team-doctor: the current directory no longer exists; running from ~"
  assert_equal "$(line_of 'tool claude')" "PASS tool claude: $claude"
  assert_equal "$(line_of 'tool lavish-axi')" "PASS tool lavish-axi: $lavish"
  assert_equal "$(grep -v '^PASS ' <<<"$output" || true)" ""
}
