#!/usr/bin/env bats
# shellcheck disable=SC2153 # LOCK and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.

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

@test "tools.lock lists every tool of the spec once per OS, each with a version_cmd, a pattern, a pin or a min, and its sources" {
  jq -e '.tools | length > 0 and all(.[];
      (.name | type == "string") and (.version_cmd | type == "string") and (.version_pattern | type == "string")
      and (.pin_mismatch // "FAIL" | IN("WARN", "FAIL"))
      and if has("from") then
        ([has("pin"), has("min"), has("source")] | any | not)
        and (.dir | type == "object" and length > 0 and (keys - ["arch", "macos"] == []))
        and if .from == "release" then
          (.release.repo | test("^[^/]+/[^/]+$")) and (.release.tag | test("^v[0-9]+(\\.[0-9]+)+$"))
          and (.release.sha256 | keys == ["darwin-amd64", "darwin-arm64", "linux-amd64"])
          and (.release.sha256 | all(.[]; test("^[0-9a-f]{64}$")))
        else .from == "fork" end
        and ((has("fork") | not) or ((.fork.repo | test("^[^/]+/[^/]+$")) and (.fork.commit | test("^[0-9a-f]{40}$"))
          and (.fork.version | test("^[0-9]+(\\.[0-9]+)+"))))
      else
        ([has("pin"), has("min")] | map(select(.)) | length == 1)
        and ((.pin // .min) | test("^[0-9]+(\\.[0-9]+)+"))
        and (.source | type == "object" and length > 0 and (keys - ["arch", "macos"] == []))
      end)' "$LOCK"
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
  # built at the commit on its main that merged upstream v1.84.0, and keeps upstream's release,
  # which from = "release" would pin instead.
  assert_equal "$(jq -r '[.tools[] | select(.from) | "\(.name)=\(.from)"] | join(" ")' "$LOCK")" \
    "treehouse=release no-mistakes=fork"
  assert_equal "$(jq -r '[.tools[] | select(.release) | "\(.name)=\(.release.repo)@\(.release.tag)"] | join(" ")' "$LOCK")" \
    "treehouse=kunchenguid/treehouse@v3.1.5 no-mistakes=kunchenguid/no-mistakes@v1.84.0"
  assert_equal "$(jq -r '.tools[] | select(.fork) | "\(.name)=\(.fork.repo)@\(.fork.commit[:7]) \(.fork.version)"' "$LOCK")" \
    "no-mistakes=chanjdaniel/no-mistakes@ac6b53f 1.84.0-13-gac6b53f"
  # The fork builds with Go (its go.mod's version) and make, from the OS packages.
  assert_equal "$(jq -r '[.tools[] | select(.name | IN("go", "make")) | "\(.name)>=\(.min):\(.source | keys | join(","))"] | join(" ")' "$LOCK")" \
    "go>=1.25.0:arch,macos make>=4.0:arch"
  assert_equal "$(jq -r '[.tools[] | select(.pin_mismatch) | "\(.name)=\(.pin_mismatch)"] | join(" ")' "$LOCK")" "claude=WARN"
  assert_equal "$(jq -r '.tools[] | select(.name == "docker-compose") | .min' "$LOCK")" 2.24.0
}

@test "on Arch with every tool at its version and everything set up, every line passes" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" ""
  local expected
  expected=$(printf '%s\n' os; lock_tools arch | cut -f1 | sed 's/^/tool /'
    printf '%s\n' docker chrome servers machine 'team home' 'git hooks' 'claude login' 'github login' config plugins memory discord 'own settings' 1password
    secret_ids | sed 's/^/secret /'
    echo opencode-gate
    echo records
    project_checks
    printf '%s\n' clock lease heartbeat offline)
  assert_equal "$(checks)" "$expected"
  assert_equal "$(line_of os)" "PASS os: Arch Linux"
  assert_equal "$(line_of 'tool claude')" "PASS tool claude: 2.1.310"
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
    printf '%s\n' docker chrome servers machine 'team home' 'git hooks' 'claude login' 'github login' config plugins memory discord 'own settings' 1password
    secret_ids | sed 's/^/secret /'
    echo opencode-gate
    echo records
    project_checks
    printf '%s\n' clock lease heartbeat offline)
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
  assert_equal "$(line_of 'tool claude')" "WARN tool claude: 0.1.0, not the pinned 2.1.310; fix: curl -fsSL https://claude.ai/install.sh | bash -s 2.1.310"
}

@test "a GitHub release's fix downloads this machine's archive and checks its recorded SHA-256 before unpacking it" {
  local sha
  every_tool_fails arch -
  sha=$(jq -r '.tools[] | select(.name == "treehouse") | .release.sha256["linux-amd64"]' "$LOCK")
  assert_equal "$(line_of 'tool treehouse')" "FAIL tool treehouse: not installed; fix: f=\$(mktemp) && curl -fsSLo \"\$f\" https://github.com/kunchenguid/treehouse/releases/download/v3.1.5/treehouse-v3.1.5-linux-amd64.tar.gz && echo \"$sha  \$f\" | sha256sum -c - && sudo mkdir -p /usr/local/bin && sudo tar -xzf \"\$f\" -C /usr/local/bin treehouse && rm -f \"\$f\""

  # An Intel Mac gets its own archive, checked with macOS's shasum.
  on_macos
  echo x86_64 >"$STUB_FIXTURES/uname-m.out"
  tools_at macos 0.1.0
  run_bin -1 team-doctor
  sha=$(jq -r '.tools[] | select(.name == "treehouse") | .release.sha256["darwin-amd64"]' "$LOCK")
  assert_equal "$(line_of 'tool treehouse')" "FAIL tool treehouse: 0.1.0, not the pinned 3.1.5; fix: f=\$(mktemp) && curl -fsSLo \"\$f\" https://github.com/kunchenguid/treehouse/releases/download/v3.1.5/treehouse-v3.1.5-darwin-amd64.tar.gz && echo \"$sha  \$f\" | shasum -a 256 -c && mkdir -p ~/.local/bin && tar -xzf \"\$f\" -C ~/.local/bin treehouse && rm -f \"\$f\""
}

@test "a machine type the lock records no archive for gets a fix that says so" {
  echo aarch64 >"$STUB_FIXTURES/uname-m.out"
  tools_at arch
  answer "treehouse --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'tool treehouse')" "FAIL tool treehouse: not installed; fix: bin/lib/tools.lock records no linux-arm64 archive of treehouse v3.1.5; see https://github.com/kunchenguid/treehouse/releases/tag/v3.1.5"
}

@test "no-mistakes is built from Daniel's fork at its pinned commit, on Arch and macOS alike" {
  local fix='d=$(mktemp -d) && git clone -q https://github.com/chanjdaniel/no-mistakes "$d" && git -C "$d" checkout -q ac6b53fbbac10a4ca6c940b004fd9c5f557f983e && make -C "$d" build && mkdir -p ~/.no-mistakes/bin && install -m 755 "$d/bin/no-mistakes" ~/.no-mistakes/bin/no-mistakes && rm -rf "$d"'
  every_tool_fails arch -
  assert_equal "$(line_of 'tool no-mistakes')" "FAIL tool no-mistakes: not installed; fix: $fix"
  assert_equal "$(line_of 'tool go')" "FAIL tool go: not installed; fix: sudo pacman -S --needed go"
  assert_equal "$(line_of 'tool make')" "FAIL tool make: not installed; fix: sudo pacman -S --needed make"
  # The build of an older commit (the fork's v1.37.0 build) is off the pin.
  tools_at arch
  answer "no-mistakes --version" "no-mistakes version v1.37.0-4-g389716a (389716a) 2026-07-14T22:29:23Z"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'tool no-mistakes')" "FAIL tool no-mistakes: 1.37.0-4-g389716a, not the pinned 1.84.0-13-gac6b53f; fix: $fix"

  on_macos
  tools_at macos
  answer "no-mistakes --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'tool no-mistakes')" "FAIL tool no-mistakes: not installed; fix: $fix"
  assert_equal "$(line_of 'tool go')" "PASS tool go: 1.25.0 (minimum 1.25.0)"
  [[ -z $(line_of 'tool make') ]]
}

@test "from = release pins upstream's release instead of the fork, a one-line change in tools.lock" {
  local lock=$BATS_TEST_TMPDIR/tools.lock line sha
  jq '(.tools[] | select(.name == "no-mistakes")).from = "release"' "$LOCK" >"$lock"
  assert_equal "$(diff "$LOCK" "$lock" | grep -c '^[<>]')" 2
  sha=$(jq -r '.tools[] | select(.name == "no-mistakes") | .release.sha256["linux-amd64"]' "$LOCK")
  line=$(jq -L "$REPO_ROOT/bin/lib" -r --arg os arch --arg machine x86_64 \
    'include "tools"; tools_for($os; $machine) | select(.name == "no-mistakes") | "\(.pin)\t\(.source)"' "$lock")
  assert_equal "$line" "1.84.0	f=\$(mktemp) && curl -fsSLo \"\$f\" https://github.com/kunchenguid/no-mistakes/releases/download/v1.84.0/no-mistakes-v1.84.0-linux-amd64.tar.gz && echo \"$sha  \$f\" | sha256sum -c - && mkdir -p ~/.no-mistakes/bin && tar -xzf \"\$f\" -C ~/.no-mistakes/bin no-mistakes && rm -f \"\$f\""
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

@test "the git hooks line fails unless the code checkout's own core.hooksPath is bin/hooks/git, with Daniel's command" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 'git hooks')" "PASS git hooks: core.hooksPath is bin/hooks/git"
  local fix="fix: Daniel runs git -C $CODE_CHECKOUT config core.hooksPath bin/hooks/git"
  git -C "$CODE_CHECKOUT" config core.hooksPath .git/hooks
  run_bin -1 team-doctor
  assert_equal "$(line_of 'git hooks')" "FAIL git hooks: core.hooksPath is .git/hooks, not bin/hooks/git; $fix"
  # Set only globally, it does not count: the guard is the code checkout's.
  git -C "$CODE_CHECKOUT" config --unset core.hooksPath
  git config --global core.hooksPath bin/hooks/git
  run_bin -1 team-doctor
  assert_equal "$(line_of 'git hooks')" "FAIL git hooks: core.hooksPath is unset, so git runs none of bin/hooks/git; $fix"
  git config --global --unset core.hooksPath
  # Nor in the team home: the code checkout is the one the line reads.
  git -C "$TEAM_HOME" config core.hooksPath bin/hooks/git
  run_bin -1 team-doctor
  assert_equal "$(line_of 'git hooks')" "FAIL git hooks: core.hooksPath is unset, so git runs none of bin/hooks/git; $fix"
  # Under HOME, the command names the code checkout from ~.
  mv "$CODE_CHECKOUT" "$HOME/agent-team"
  CODE_CHECKOUT=$HOME/agent-team run_bin -1 team-doctor
  assert_equal "$(line_of 'git hooks')" \
    "FAIL git hooks: core.hooksPath is unset, so git runs none of bin/hooks/git; fix: Daniel runs git -C ~/agent-team config core.hooksPath bin/hooks/git"
}

@test "the team home line names the team home and what named it: TEAM_HOME or ~/.config/agent-team/home" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home')" "PASS team home: $TEAM_HOME, named by TEAM_HOME: a checkout of its own on dev, with an origin"
  # The setting, relative to HOME: the doctor finds the team home as every script does.
  mv "$TEAM_HOME" "$HOME/agent-team-records"
  echo agent-team-records >"$HOME/.config/agent-team/home"
  unset TEAM_HOME
  run "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "PASS team home: ~/agent-team-records, named by ~/.config/agent-team/home: a checkout of its own on dev, with an origin"
  # TEAM_HOME wins over the setting.
  echo elsewhere >"$HOME/.config/agent-team/home"
  TEAM_HOME=$HOME/agent-team-records run "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "PASS team home: ~/agent-team-records, named by TEAM_HOME: a checkout of its own on dev, with an origin"
}

@test "with neither TEAM_HOME nor the setting, the team home line warns that the team home is the code checkout" {
  tools_at arch
  rm "$HOME/.config/agent-team/home"
  git -C "$CODE_CHECKOUT" remote add origin https://github.com/chanjdaniel/agent-team.git
  unset TEAM_HOME
  run -1 "$CODE_CHECKOUT/bin/team-doctor"
  # With no ~/agent-team-records the fix clones it first, since the setting would name a missing directory.
  assert_equal "$(line_of 'team home')" \
    "WARN team home: $CODE_CHECKOUT, the code checkout, since neither TEAM_HOME nor ~/.config/agent-team/home names one; fix: clone the team home: git clone https://github.com/chanjdaniel/agent-team-records.git ~/agent-team-records, then team-bootstrap --home agent-team-records"
  mkdir "$HOME/agent-team-records"
  run -1 "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "WARN team home: $CODE_CHECKOUT, the code checkout, since neither TEAM_HOME nor ~/.config/agent-team/home names one; fix: name the team home's checkout, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  rmdir "$HOME/agent-team-records"
  # It is still checked: without an origin it fails.
  git -C "$CODE_CHECKOUT" remote remove origin
  run -1 "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $CODE_CHECKOUT, the code checkout, has no remote origin; fix: git -C $CODE_CHECKOUT remote add origin <the team home's repository URL>"
}

@test "a team home that is missing, no checkout of its own, without an origin or on a detached HEAD fails the team home line" {
  tools_at arch
  local home=$TEAM_HOME named="named by TEAM_HOME" tmp
  tmp=$BATS_TEST_TMPDIR
  # Missing, named by the variable or by the setting (which no other script gets past).
  TEAM_HOME=$tmp/gone run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $tmp/gone, $named, is not a directory; fix: clone the team home to $tmp/gone, or set TEAM_HOME to its checkout"
  echo agent-team-records >"$HOME/.config/agent-team/home"
  run -1 env -u TEAM_HOME "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: ~/agent-team-records, named by ~/.config/agent-team/home, is not a directory; fix: clone the team home to ~/agent-team-records, or name the team home's checkout, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  : >"$HOME/.config/agent-team/home"
  run -1 env -u TEAM_HOME "$CODE_CHECKOUT/bin/team-doctor"
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: the setting ~/.config/agent-team/home names no team home; fix: name the team home's checkout, relative to your home directory: echo agent-team-records > ~/.config/agent-team/home"
  # A plain directory, a subdirectory of a checkout, and a worktree of another checkout.
  mkdir -p "$tmp/plain" "$home/tasks"
  TEAM_HOME=$tmp/plain run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $tmp/plain, $named, is not a git checkout of its own; fix: move it aside, then clone the team home to $tmp/plain"
  TEAM_HOME=$home/tasks run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $home/tasks, $named, is not a git checkout of its own; fix: move it aside, then clone the team home to $home/tasks"
  git -C "$home" worktree add -q "$tmp/wt"
  TEAM_HOME=$tmp/wt run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $tmp/wt, $named, is a worktree of $home, not a checkout of its own; fix: move it aside, then clone the team home to $tmp/wt"
  # No origin, then a detached HEAD.
  git -C "$home" remote rename origin elsewhere
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $home, $named, has no remote origin; fix: git -C $home remote add origin <the team home's repository URL>"
  git -C "$home" remote rename elsewhere origin
  git -C "$home" checkout -q --detach
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home')" \
    "FAIL team home: $home, $named, is on a detached HEAD, so its records would be committed on no branch; fix: git -C $home switch dev"
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

@test "the config line warns on each difference but the plugins, with team-config's commands" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of config)" "PASS config: this machine's Claude config is the team home's"
  echo '{"model": "sonnet"}' >"$HOME/.claude/settings.json"
  rm -r "$HOME/.claude/skills/tdd"
  echo '[{"id": "discord@claude-plugins-official", "scope": "user", "enabled": false}]' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of config)" "WARN config: settings.json differs, skill tdd missing; fix: team-config diff --full, then team-config apply (take the team home's) or team-config capture (keep this machine's)"
  # Without the team home's config, the line says what team-config said.
  rm -r "$TEAM_HOME/machine/claude"
  run_bin -1 team-doctor
  assert_equal "$(line_of config)" "WARN config: no machine/claude/ in $TEAM_HOME; run team-config capture on the machine whose config the team shares; fix: fix what team-config names, then run team-doctor again"
  assert_contains "$(line_of plugins)" "FAIL plugins: unknown, since team-config diff did not answer: no machine/claude/"
}

@test "the plugins line fails on each marketplace or plugin of plugins.txt missing here, with the commands that add them" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of plugins)" "PASS plugins: every marketplace and plugin of plugins.txt is installed"
  echo '[]' >"$STUB_FIXTURES/marketplaces.json"
  echo '[{"id": "discord@claude-plugins-official", "scope": "user", "enabled": false},
    {"id": "ponder@claude-plugins-official", "scope": "user", "enabled": true}]' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of plugins)" "FAIL plugins: missing marketplace anthropics/claude-plugins-official, plugin mongodb-atlas@claude-plugins-official; fix: claude plugin marketplace add anthropics/claude-plugins-official; claude plugin install mongodb-atlas@claude-plugins-official --scope user"
  # A plugin installed here only is a config difference, not a failure.
  assert_equal "$(line_of config)" "WARN config: plugin ponder@claude-plugins-official not in plugins.txt; fix: team-config diff --full, then team-config apply (take the team home's) or team-config capture (keep this machine's)"
  echo 'not json' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of plugins)" "FAIL plugins: \`claude plugin list\` did not answer; fix: install Claude Code and sign in (the tool claude and claude login lines)"
}

@test "the memory line warns on each project whose auto memory is not in the team home, with team-config apply" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of memory)" "PASS memory: every project here keeps its auto memory in the team home"
  local conv=$HOME/projects/conv key
  register conv owner/conv direct-pr git
  key=${conv//[^A-Za-z0-9]/-}
  mkdir -p "$HOME/.claude/projects/$key/memory"
  echo "Deploys go through CI." >"$HOME/.claude/projects/$key/memory/deploys.md"
  run_bin -0 team-doctor
  assert_equal "$(line_of memory)" "WARN memory: memory conv setting missing, memory conv settings.local.json not ignored by git, memory conv notes left in ~/.claude/projects/$key/memory/; fix: team-config apply"
  # The config line is about the Claude config alone.
  assert_equal "$(line_of config)" "PASS config: this machine's Claude config is the team home's"
  "$REPO_ROOT/bin/team-config" apply >/dev/null
  run_bin -0 team-doctor
  assert_equal "$(line_of memory)" "PASS memory: every project here keeps its auto memory in the team home"
  # team-config not answering leaves the line unknown.
  echo 'junk = [' >>"$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_contains "$(line_of memory)" "WARN memory: unknown, since team-config diff did not answer: "
}

@test "the discord line fails while user settings turn the Discord plugin on, and asks claude from /" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of discord)" "PASS discord: the Discord plugin is off in user settings"
  echo '[{"id": "discord@claude-plugins-official", "scope": "user", "enabled": true},
    {"id": "mongodb-atlas@claude-plugins-official", "scope": "user", "enabled": true}]' >"$STUB_FIXTURES/plugins.json"
  echo 'echo "$PWD" >>"$STUB_CALLS/claude.pwd"' >>"$STUB_FIXTURES/claude.sh"
  run_bin -1 team-doctor
  assert_equal "$(line_of discord)" "FAIL discord: the Discord plugin is on in user settings, so every session logs in to Discord; fix: claude plugin disable discord@claude-plugins-official --scope user"
  grep -qx / "$STUB_CALLS/claude.pwd"
  echo '[{"id": "mongodb-atlas@claude-plugins-official", "scope": "user", "enabled": true}]' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of discord)" "PASS discord: the Discord plugin is not installed, so it is off (the plugins line says whether it should be)"
  echo 'not json' >"$STUB_FIXTURES/plugins.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of discord)" "FAIL discord: \`claude plugin list\` printed no plugin list (exit 0); fix: install Claude Code and sign in (the tool claude and claude login lines)"
}

@test "the own settings line warns while this machine has no autoMode.environment of its own" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of 'own settings')" "PASS own settings: autoMode.environment set for this machine"
  echo '{"model": "opus"}' >"$HOME/.claude/settings.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'own settings')" "WARN own settings: autoMode.environment not set here, so auto mode's classifier knows nothing of this machine; fix: write this machine's own in ~/.claude/settings.json (\`claude auto-mode defaults\` shows the form); team-config keeps it"
  echo 'not json' >"$HOME/.claude/settings.json"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'own settings')" "WARN own settings: $HOME/.claude/settings.json is not JSON; fix: fix what team-config names, then run team-doctor again"
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

@test "the opencode-gate line fails while the gate's opencode wrapper is missing, stale or not executable, opencode is missing, or config.yaml does not run the gate on it" {
  local wrapper=$HOME/.no-mistakes/bin/opencode-gate config=$HOME/.no-mistakes/config.yaml
  local install="mkdir -p ~/.no-mistakes/bin && install -m 755 $CODE_CHECKOUT/bin/lib/opencode-gate ~/.no-mistakes/bin/opencode-gate"
  local setting="agent_path_override: {opencode: $wrapper}" step="as manual-steps.md's install of the no-mistakes fork says"
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of opencode-gate)" "PASS opencode-gate: ~/.no-mistakes/bin/opencode-gate is the code's bin/lib/opencode-gate, config.yaml runs the gate on opencode through it, and opencode is installed"
  # The flow form, quoted, is read too; a comment after it is not part of the path.
  printf '%s\n' 'agent: opencode' "agent_path_override: {codex: /x/codex, opencode: \"$wrapper\"} # the gate's" >"$config"
  run_bin -0 team-doctor
  assert_contains "$(line_of opencode-gate)" "PASS opencode-gate: "

  printf '%s\n' 'agent: opencode' 'agent_path_override:' '  opencode: /usr/bin/opencode' 'log_level: info' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent_path_override does not name ~/.no-mistakes/bin/opencode-gate for opencode, so the gate's opencode reads Claude Code's config and not the gate's own; fix: Daniel sets $setting in ~/.no-mistakes/config.yaml, $step"
  # A key of that name under another block is not the setting.
  printf '%s\n' 'agent: opencode' 'agent_args_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_contains "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent_path_override does not name"
  # The gate's agent must be opencode: auto, another agent or none runs the gate on whatever
  # no-mistakes finds first, never through the wrapper.
  local agent_fix="Daniel sets agent: opencode in ~/.no-mistakes/config.yaml, $step"
  printf '%s\n' 'agent: auto # first found' 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent is auto, not opencode, so the gate runs on whichever agent no-mistakes finds first and not through the wrapper; fix: $agent_fix"
  printf '%s\n' 'agent: [claude, opencode]' 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -1 team-doctor
  assert_contains "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml's agent is [claude, opencode], not opencode,"
  printf '%s\n' 'agent_path_override:' "  opencode: $wrapper" 'review:' '  agent: opencode' >"$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml names no agent, so the gate runs on whichever agent no-mistakes finds first and not through the wrapper; fix: $agent_fix"
  printf '%s\n' "agent: 'opencode'" 'agent_path_override:' "  opencode: $wrapper" >"$config"
  run_bin -0 team-doctor
  assert_contains "$(line_of opencode-gate)" "PASS opencode-gate: "
  # opencode itself missing: the wrapper has nothing to run, whatever config.yaml says.
  answer "opencode --version"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: opencode is not installed, so the wrapper has nothing to run; fix: the tool opencode line's fix"
  assert_equal "$(line_of 'tool opencode')" "FAIL tool opencode: not installed; fix: npm install -g opencode-ai@1.18.30"
  tools_at arch
  rm "$config"
  run_bin -1 team-doctor
  assert_equal "$(line_of opencode-gate)" "FAIL opencode-gate: ~/.no-mistakes/config.yaml is not there; fix: Daniel runs team-secrets restore in their own terminal (the secret no-mistakes-config) and sets $setting in it, $step"

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

@test "the servers line fails while servers/node_modules is missing or not the install of servers/package-lock.json" {
  local fix="$CODE_CHECKOUT/servers/install"
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of servers)" "PASS servers: servers/node_modules is the install of servers/package-lock.json"
  echo '{"lockfileVersion": 3}' >"$CODE_CHECKOUT/servers/package-lock.json"
  run_bin -1 team-doctor
  assert_equal "$(line_of servers)" "FAIL servers: servers/node_modules is not the install of servers/package-lock.json, so a toolkit or chrome-devtools-axi may run another server; fix: $fix"
  rm -r "$CODE_CHECKOUT/servers/node_modules"
  run_bin -1 team-doctor
  assert_equal "$(line_of servers)" "FAIL servers: servers/node_modules is missing, so the toolkits' servers and the sessions' chrome-devtools-mcp cannot start; fix: $fix"
  assert_equal "$(grep -v '^PASS ' <<<"$output" || true)" "$(line_of servers)"
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

@test "GitHub's Date is read even when curl writes the headers after it in a later write" {
  tools_at arch
  # The later write fails with a broken pipe if the reader stopped at the Date line.
  stub_script curl <<'EOF'
printf 'HTTP/2 200\r\ndate: %s\r\n' "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"
sleep 0.5
printf 'server: github.com\r\n\r\n'
EOF
  run_bin -0 team-doctor
  assert_equal "$(line_of clock)" "PASS clock: within 60 s of GitHub's"
}

@test "the lease line: PASS held here, WARN held elsewhere or released, FAIL unreachable" {
  tools_at arch
  make_machine laptop
  # Not holding, the heartbeat belongs off.
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
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

@test "the lease line fails on a fenced machine, naming the holder it saw, reachable or not" {
  tools_at arch
  make_machine laptop
  steal_lease laptop home-pc
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 team-doctor
  assert_equal "$(line_of lease)" "FAIL lease: fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2); fix: hand off on the machine that holds the lease, then team-resume here (its take clears the fence)"
  assert_equal "$(line_of heartbeat)" "PASS heartbeat: disabled, and this machine does not hold the lease"

  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 team-doctor
  assert_equal "$(line_of lease)" "FAIL lease: fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2); fix: hand off on the machine that holds the lease, then team-resume here (its take clears the fence)"
}

@test "on a fenced machine, each open task's worktree holding what origin lacks gets a salvage line" {
  tools_at arch
  # Five tasks in site, each in a worktree of its own: T1 with a commit pushed only inside a
  # checkpoint's wip/site/T1 (as team-open --resume fetches it from the team home's origin), T2 with uncommitted changes, T3 clean, T4's worktree gone, T5 closed.
  local n wt=() slots=$HOME/site-wt
  for n in 1 2 3 4 5; do
    wt[n]=$slots/$n
    git -C "$SITE" worktree add -q -b "feat/T$n-x" "${wt[n]}" origin/main
    jq -cn --arg t "T$n" --arg wt "${wt[n]}" --arg b "feat/T$n-x" '{ts: "2026-10-23T09:00:00Z", task: $t,
      event: "opened", project: "site", path: "small", type: "feat", title: "x", branch: $b, base: "main",
      base_sha: "0000000", worktree: $wt}' >>"$TEAM_HOME/ledger.jsonl"
  done
  echo one >"${wt[1]}/one.txt"
  git -C "${wt[1]}" add one.txt
  git -C "${wt[1]}" commit -q -m "feat: one"
  git -C "$SITE" update-ref refs/remotes/team-home/wip/site/T1 \
    "$(git -C "${wt[1]}" commit-tree -p HEAD -m wip "$(git -C "${wt[1]}" rev-parse 'HEAD^{tree}')")"
  echo edited >"${wt[2]}/README.md"
  echo new >"${wt[2]}/new.txt"
  git -C "$SITE" worktree remove --force "${wt[4]}"
  echo stray >"${wt[5]}/stray.txt"
  echo '{"ts":"2026-10-23T10:00:00Z","task":"T5","event":"closed","archive":[],"returned":[],"kept":[]}' \
    >>"$TEAM_HOME/ledger.jsonl"

  # Not fenced: no salvage line at all.
  run_bin -0 team-doctor
  [[ $output != *salvage* ]]

  make_machine laptop
  steal_lease laptop home-pc
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  run_bin -1 team-doctor
  # The salvage goes to the team home's origin, never the project's, which may be public.
  local team_origin
  team_origin=$(git -C "$TEAM_HOME" remote get-url origin)
  assert_equal "$(grep salvage <<<"$output")" \
"FAIL salvage T1 site: ~/site-wt/1 has 1 commit on no origin branch; fix: git -C ~/site-wt/1 push $team_origin HEAD:refs/heads/salvage/site/T1-home-pc
FAIL salvage T2 site: ~/site-wt/2 has uncommitted changes (changes to tracked files: README.md; untracked files: new.txt); fix: git -C ~/site-wt/2 add -A && git -C ~/site-wt/2 commit -m \"wip: salvage from home-pc\", then git -C ~/site-wt/2 push $team_origin HEAD:refs/heads/salvage/site/T2-home-pc"
  # Right after the lease line.
  assert_equal "$(checks | grep -A2 -x lease | paste -sd ,)" "lease,salvage T1 site,salvage T2 site"

  # Once Daniel has run both fixes, the work is on the team home's origin, none on site's, and the
  # line passes.
  local fix
  while IFS= read -r fix; do eval "$fix" >/dev/null 2>&1; done < <(grep '^FAIL salvage' <<<"$output" | sed 's/.*; fix: //; s/, then / \&\& /')
  assert_equal "$(git -C "$team_origin" rev-parse refs/heads/salvage/site/T1-home-pc)" "$(git -C "${wt[1]}" rev-parse HEAD)"
  assert_equal "$(git -C "$team_origin" rev-parse refs/heads/salvage/site/T2-home-pc)" "$(git -C "${wt[2]}" rev-parse HEAD)"
  assert_equal "$(git -C "$BATS_TEST_TMPDIR/origin/site.git" for-each-ref refs/heads/salvage/)" ""
  run_bin -1 team-doctor
  assert_equal "$(grep salvage <<<"$output")" "PASS salvage: no task worktree here holds work that neither origin nor a salvage branch keeps"

  # A change after the salvage needs salvaging again.
  echo two >"${wt[1]}/two.txt"
  echo more >"${wt[2]}/new.txt"
  run_bin -1 team-doctor
  assert_equal "$(grep salvage <<<"$output" | cut -d: -f1)" "FAIL salvage T1 site
FAIL salvage T2 site"

  # A commit pushed to origin's branch, and clean, passes too.
  git -C "${wt[1]}" add two.txt
  git -C "${wt[1]}" commit -q -m "feat: two"
  git -C "${wt[2]}" checkout -q -- new.txt
  git -C "$SITE" update-ref refs/remotes/origin/feat/T1-x "$(git -C "${wt[1]}" rev-parse HEAD)"
  run_bin -1 team-doctor
  assert_equal "$(grep salvage <<<"$output")" "PASS salvage: no task worktree here holds work that neither origin nor a salvage branch keeps"
}

@test "the offline line warns with the outage's start and age while the heartbeat holds the team" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(line_of offline)" "PASS offline: the team is not holding for an outage"
  jq -n '{since: (now - 35 * 60 | floor | todate), posted: true}' >"$HOME/.local/state/agent-team/offline"
  run_bin -0 team-doctor
  assert_equal "$(line_of offline)" "WARN offline: offline since $(jq -r .since "$HOME/.local/state/agent-team/offline") (35 minutes); fix: check this machine's network; the heartbeat resumes the team when GitHub answers"
}

@test "the heartbeat line: PASS enabled on the holder or disabled elsewhere, FAIL otherwise with the command" {
  tools_at arch
  make_machine laptop
  "$REPO_ROOT/bin/team-timers" disable >/dev/null
  run_bin -1 team-doctor
  assert_equal "$(line_of heartbeat)" "FAIL heartbeat: disabled, but this machine holds the lease; fix: team-timers enable"

  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-doctor
  assert_equal "$(line_of heartbeat)" "PASS heartbeat: disabled, and this machine does not hold the lease"

  on_machine laptop run -0 "$REPO_ROOT/bin/team-lease" take
  "$REPO_ROOT/bin/team-timers" enable >/dev/null
  run_bin -1 team-doctor
  assert_equal "$(line_of heartbeat)" "FAIL heartbeat: enabled, but this machine does not hold the lease; fix: team-timers disable"

  # With the lease unconfirmed, the doctor cannot say which it should be.
  git -C "$TEAM_HOME" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 team-doctor
  assert_equal "$(line_of heartbeat)" "WARN heartbeat: enabled, but whether it should be waits on the lease line; fix: the lease line's fix, then run team-doctor again"

  # A heartbeat team-timers cannot read fails with its reason.
  stub_reply uname FreeBSD
  run_bin -1 team-doctor
  assert_equal "$(line_of heartbeat)" "FAIL heartbeat: FreeBSD has neither systemd nor launchd; the heartbeat runs on Linux or macOS; fix: fix what team-timers names, then run team-doctor again"
}

@test "each registered project's lines pass for a correct clone; Conventioner's pool is Conventioner-d4c77a" {
  tools_at arch
  run_bin -0 team-doctor
  assert_equal "$(grep -E '^.... [a-z ]+ (conventioner|site): ' <<<"$output")" "PASS checkout conventioner: ~/projects/Conventioner, a primary checkout
PASS origin conventioner: https://github.com/chanjdaniel/Conventioner.git
PASS task dir conventioner: git ignores .scratch/task/
PASS gate conventioner: no-mistakes has a gate for it
PASS slots conventioner: every slot is in the pool Conventioner-d4c77a, as treehouse names it from origin
PASS trust conventioner: claude starts background sessions in ~/projects/Conventioner
PASS branches conventioner: every local branch is on origin
PASS changes conventioner: the primary checkout is clean
PASS checkout site: ~/projects/site, a primary checkout
PASS origin site: https://github.com/owner/site.git
PASS task dir site: git ignores .scratch/task/
PASS trust site: claude starts background sessions in ~/projects/site
PASS branches site: every local branch is on origin
PASS changes site: the primary checkout is clean"
  # The gate was asked in its checkout, which the doctor left as it was.
  assert_equal "$(git -C "$CONVENTIONER" status --porcelain)" ""
}

@test "a missing clone fails its checkout line with the clone command, and its other lines are skipped" {
  tools_at arch
  local clone="git clone https://github.com/owner/site.git ~/projects/site"
  rm -rf "$SITE"
  run_bin -1 team-doctor
  assert_equal "$(grep -E ' site: ' <<<"$output")" "FAIL checkout site: ~/projects/site is missing; fix: $clone"
  # A folder that is no git checkout, or a worktree of another checkout, is no primary checkout.
  mkdir -p "$SITE"
  run_bin -1 team-doctor
  assert_equal "$(grep -E ' site: ' <<<"$output")" "FAIL checkout site: ~/projects/site is not a git checkout; fix: move it aside, then $clone"
  rmdir "$SITE"
  git -C "$CONVENTIONER" worktree add -q --detach "$SITE"
  run_bin -1 team-doctor
  assert_equal "$(grep -E ' site: ' <<<"$output")" "FAIL checkout site: ~/projects/site is a worktree of ~/projects/Conventioner, not a primary checkout; fix: move it aside, then $clone"
  # Nothing else fails; team-config sees the worktree as site's checkout, with no memory set up.
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v ' site: ' || true)" "WARN memory: memory site setting missing; fix: team-config apply"
}

@test "an origin other than https://github.com/<repo>.git fails, and so does a treehouse pool named from it" {
  tools_at arch
  local url
  for url in git@github.com:owner/site.git https://github.com/owner/site; do
    git -C "$SITE" remote set-url origin "$url"
    run_bin -1 team-doctor
    assert_equal "$(line_of 'origin site')" "FAIL origin site: origin is $url, not https://github.com/owner/site.git; fix: git -C ~/projects/site remote set-url origin https://github.com/owner/site.git"
  done
  git -C "$SITE" remote remove origin
  run_bin -1 team-doctor
  assert_equal "$(line_of 'origin site')" "FAIL origin site: no remote origin; fix: git -C ~/projects/site remote add origin https://github.com/owner/site.git"

  url=git@github.com:chanjdaniel/Conventioner.git
  git -C "$CONVENTIONER" remote set-url origin "$url"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "FAIL slots conventioner: not in the pool Conventioner-$(printf '%s' "$url" | sha256sum | cut -c1-6), as treehouse names it from origin $url: ~/.treehouse/Conventioner-d4c77a/1/Conventioner, ~/.treehouse/Conventioner-d4c77a/2/Conventioner; fix: the origin line's fix"
  git -C "$CONVENTIONER" remote remove origin
  run_bin -1 team-doctor
  assert_equal "$(line_of 'slots conventioner')" "FAIL slots conventioner: unknown, since treehouse names the pool from origin, which is missing; fix: the origin line's fix"
}

@test "a treehouse slot outside the pool its origin names fails the slots line" {
  tools_at arch
  sed -i 's#\.treehouse/Conventioner-d4c77a/2/#.treehouse/Conventioner-8e12e0/2/#' "$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL slots conventioner: not in the pool Conventioner-d4c77a, as treehouse names it from origin: ~/.treehouse/Conventioner-8e12e0/2/Conventioner; fix: put conventioner's pool.slots in projects.toml under the pool's directory, ~/.treehouse/Conventioner-d4c77a/ unless its treehouse.toml sets another root"
}

@test "a task directory git does not ignore fails, with the exclude line that ignores it" {
  tools_at arch
  sed -i '\#^/\.scratch/task/$#d' "$SITE/.git/info/exclude"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL task dir site: git does not ignore .scratch/task/; fix: echo /.scratch/task/ >> ~/projects/site/.git/info/exclude"
  # Ignored by the project's own .gitignore, it passes.
  echo .scratch/ >"$SITE/.gitignore"
  git -C "$SITE" add .gitignore
  git -C "$SITE" commit -q -m "chore: ignore the scratch"
  git -C "$SITE" push -q origin HEAD 2>/dev/null || git -C "$SITE" update-ref refs/remotes/origin/main HEAD
  run_bin -0 team-doctor
  assert_equal "$(line_of 'task dir site')" "PASS task dir site: git ignores .scratch/task/"
}

@test "a no-mistakes project without a gate fails the gate line with no-mistakes init; a direct-pr project has no gate line" {
  tools_at arch
  : >"$STUB_FIXTURES/gates"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL gate conventioner: no-mistakes has no gate for ~/projects/Conventioner; fix: cd ~/projects/Conventioner && no-mistakes init"
  assert_equal "$(checks | grep -c '^gate ')" 1
  answer "no-mistakes status"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'gate conventioner')" "FAIL gate conventioner: no-mistakes is not installed; fix: the tool no-mistakes line's fix, then cd ~/projects/Conventioner && no-mistakes init"
  answer "no-mistakes status" "daemon not running"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'gate conventioner')" "FAIL gate conventioner: \`no-mistakes status\` printed no gate: daemon not running; fix: cd ~/projects/Conventioner && no-mistakes init"
}

@test "trust: a promptless claude --bg in each root, FAIL on Workspace not trusted, the probe session removed either way" {
  tools_at arch
  echo "$SITE" >"$STUB_FIXTURES/untrusted"
  # A probe an earlier run left behind is found by its name, and goes too.
  echo '[{"id": "0badc0de", "name": "team-doctor-trust-site", "state": "idle"},
    {"id": "abcdef12", "name": "T9-builder", "state": "working"}]' >"$STUB_FIXTURES/agents.json"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "FAIL trust site: claude --bg in ~/projects/site says Workspace not trusted; fix: Daniel runs claude once in ~/projects/site and accepts the trust dialog"
  assert_equal "$(cat "$STUB_CALLS/claude-bg.pwd")" "$CONVENTIONER
$SITE"
  local probe
  probe=$(printf '%s' "$CONVENTIONER" | sha256sum | cut -c1-8)
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] | IN("--bg", "stop", "rm")) | join(" ")')" "--bg --name team-doctor-trust-conventioner
stop $probe
rm $probe
--bg --name team-doctor-trust-site
stop 0badc0de
rm 0badc0de"

  # A probe session that cannot be removed turns a pass into a warning naming it.
  rm "$STUB_FIXTURES/untrusted" "$STUB_FIXTURES/agents.json"
  sed -i "s/^  'stop '\\* | 'rm '\\*) ;;/  'stop '*) ;;\\n  'rm '*) echo 'no such session' >\\&2; exit 1 ;;/" "$STUB_FIXTURES/claude.sh"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'trust site')" "WARN trust site: claude starts background sessions in ~/projects/site, but its probe session $(printf '%s' "$SITE" | sha256sum | cut -c1-8) is left; fix: claude rm $(printf '%s' "$SITE" | sha256sum | cut -c1-8)"

  # Neither a session nor the trust error: the doctor cannot tell, and says what claude said.
  stub_script claude <<'EOF'
case $* in
  'auth status --json') echo '{"loggedIn": true, "authMethod": "claude.ai"}' ;;
  'plugin list --json') cat "$STUB_FIXTURES/plugins.json" ;;
  'plugin marketplace list --json') cat "$STUB_FIXTURES/marketplaces.json" ;;
  'agents --json') echo '[]' ;;
  *) echo "error: unknown option '--bg'" >&2; exit 3 ;;
esac
EOF
  run_bin -1 team-doctor
  assert_equal "$(line_of 'trust site')" "FAIL trust site: \`claude --bg\` in ~/projects/site printed no session id (exit 3): error: unknown option '--bg'; fix: the tool claude and claude login lines"
}

@test "unpushed local branches and a dirty primary checkout warn, each by name" {
  tools_at arch
  # Pushed with no upstream, as team-open makes a task's branch: nothing to warn about.
  git -C "$SITE" branch feat/pushed
  git -C "$SITE" update-ref refs/remotes/origin/feat/pushed feat/pushed
  # On no origin branch: a branch of its own, and one ahead of its upstream.
  git -C "$SITE" switch -q -c wip
  git -C "$SITE" commit -q --allow-empty -m "wip: one"
  git -C "$SITE" switch -q -c feat/ahead --track origin/main
  git -C "$SITE" commit -q --allow-empty -m "feat: one"
  git -C "$SITE" commit -q --allow-empty -m "feat: two"
  # A checkpoint's wip/site/T7 holding feat/ahead's head is no origin branch, whether fetched from
  # the team home's origin by team-open --resume or on origin (a project whose origin is the team
  # home's): it still warns.
  git -C "$SITE" update-ref refs/remotes/team-home/wip/site/T7 feat/ahead
  git -C "$SITE" update-ref refs/remotes/origin/wip/site/T7 feat/ahead
  git -C "$SITE" switch -q main
  echo changed >>"$SITE/README.md"
  echo note >"$SITE/notes.txt"
  run_bin -0 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output")" "WARN branches site: feat/ahead (2 commits), wip (1 commit) on no origin branch; fix: push each (git -C ~/projects/site push -u origin <branch>) or delete it
WARN changes site: changes to tracked files: README.md; untracked files: notes.txt; fix: commit, stash or remove them in ~/projects/site"
}

@test "without a registry, or with a broken one, the projects line fails with team-project's reason" {
  tools_at arch
  rm "$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_equal "$(grep -v '^PASS ' <<<"$output" | grep -v -e '^WARN memory' -e '^FAIL records' || true)" "FAIL projects: no registry at $TEAM_HOME/projects.toml; fix: fix what team-project names (team-project --check), then run team-doctor again"
  assert_contains "$(line_of records)" "FAIL records: no registry at $TEAM_HOME/projects.toml;"
  echo '[broken]' >"$TEAM_HOME/projects.toml"
  run_bin -1 team-doctor
  assert_contains "$(line_of projects)" "FAIL projects: $TEAM_HOME/projects.toml: broken: missing required key 'repo'"
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
  for secret in sk-ant-oat-fake-secret daniel@example.invalid org-secret-0000 gho_fakefakefakefake "$FAKE_DISCORD_TOKEN" dummy-secret-value; do
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
