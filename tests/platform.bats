#!/usr/bin/env bats
# bin/lib/platform.sh, through the library: Bash 5, Python 3.11 for team-project, and on macOS
# Homebrew's GNU tools first on PATH; and the library's tool directories from bin/lib/tools.lock,
# first on PATH after them. A stubbed uname drives the macOS branch on Linux, and
# $HOMEBREW_PREFIX points it at a fake Homebrew. The old-interpreter tests need a real one: macOS
# has Bash 3.2 at /bin/bash and Python 3.9 at /usr/bin/python3, so the macos CI job runs them.

load helpers/common

setup() {
  sandbox
  stub_command uname
  brew=$BATS_TEST_TMPDIR/brew
  export HOMEBREW_PREFIX=$brew
  local dir
  for dir in coreutils/libexec/gnubin findutils/libexec/gnubin gnu-sed/libexec/gnubin \
    grep/libexec/gnubin flock/bin; do
    mkdir -p "$brew/opt/$dir"
  done
  gnu_path=$brew/opt/coreutils/libexec/gnubin:$brew/opt/findutils/libexec/gnubin:$brew/opt/gnu-sed/libexec/gnubin:$brew/opt/grep/libexec/gnubin:$brew/opt/flock/bin
  # Arch, when uname says Linux: the tool directories are the lock's for arch or macos only.
  export TEAM_OS_RELEASE=$BATS_TEST_TMPDIR/os-release
  printf '%s\n' 'NAME="Arch Linux"' 'ID=arch' >"$TEAM_OS_RELEASE"
}

# Print the library's tool directories, one per line.
library_tool_dirs() {
  bash -c 'source "$1/bin/lib/team.sh"; tool_dirs' library_tool_dirs "$REPO_ROOT"
}

# $bare: a directory holding only links to Bash 5 and jq, which a PATH of system directories
# lacks on macOS.
bare_bin() {
  bare=$BATS_TEST_TMPDIR/bare
  mkdir -p "$bare"
  ln -sf "$(command -v bash)" "$bare/bash"
  ln -sf "$(command -v jq)" "$bare/jq"
}

# installed <dir> <name>...: an executable <name> in <dir> that prints where it is.
installed() {
  local dir=$1 name
  mkdir -p "$dir"
  for name in "${@:2}"; do
    printf '#!/bin/sh\necho "$0"\n' >"$dir/$name"
    chmod +x "$dir/$name"
  done
}

# Print PATH as a script sees it once the library is sourced.
library_path() {
  bash -c 'source "$1/bin/lib/team.sh"; printf "%s\n" "$PATH"' library_path "$REPO_ROOT"
}

@test "on Linux the library leaves PATH as it is" {
  stub_reply uname Linux
  run -0 library_path
  assert_equal "$output" "$PATH"
}

@test "on macOS the library puts Homebrew's GNU tools and flock first on PATH, once" {
  stub_reply uname Darwin
  run -0 library_path
  assert_equal "$output" "$gnu_path:$PATH"
  # A script run by another one does not add them again.
  PATH=$output run -0 library_path
  assert_equal "$output" "$gnu_path:$PATH"
}

@test "the tool directories are the lock's for this OS: under HOME, nvm's pinned Node, and on macOS Homebrew's pinned Python" {
  stub_reply uname Linux
  run -0 library_tool_dirs
  assert_equal "$output" "$HOME/.local/bin
$HOME/.nvm/versions/node/v24.22.1/bin
$HOME/.bun/bin
$TEAM_SYSTEM_ROOT/usr/local/bin
$HOME/.no-mistakes/bin"
  stub_reply uname Darwin
  NVM_DIR=$BATS_TEST_TMPDIR/nvm run -0 library_tool_dirs
  assert_equal "$output" "$HOME/.local/bin
$BATS_TEST_TMPDIR/nvm/versions/node/v24.22.1/bin
$HOME/.bun/bin
$HOME/.no-mistakes/bin
$brew/opt/python@3.12/libexec/bin"
  # The OS has none: the team runs on Arch and macOS only.
  stub_reply uname Linux
  printf '%s\n' 'ID=ubuntu' >"$TEAM_OS_RELEASE"
  run -0 library_tool_dirs
  assert_equal "$output" ""
}

@test "the lock's Python formula on macOS is the one whose directory goes on PATH" {
  local source path
  source=$(jq -r '.tools[] | select(.name == "python") | .source.macos // empty' "$REPO_ROOT/bin/lib/tools.lock")
  path=$(jq -r '.tools[] | select(.name == "python") | .path.macos // empty' "$REPO_ROOT/bin/lib/tools.lock")
  assert_equal "$source" "brew install python@3.12"
  assert_equal "$path" "@HOMEBREW_PREFIX@/opt/python@3.12/libexec/bin"
}

@test "a script run with a bare PATH finds the pinned Node, Bun, treehouse and Python first" {
  stub_reply uname Darwin
  installed "$HOME/.nvm/versions/node/v24.22.1/bin" node
  installed "$HOME/.bun/bin" bun
  installed "$HOME/.local/bin" treehouse
  installed "$brew/opt/python@3.12/libexec/bin" python3
  # Another Node, an older Python, and nothing else but Bash, jq and uname: the shell's PATH.
  bare_bin
  installed "$bare" node python3
  printf '#!/bin/sh\necho Darwin\n' >"$bare/uname"
  chmod +x "$bare/uname"
  run -0 env PATH="$bare:/usr/bin:/bin" bash -c \
    'source "$1/bin/lib/team.sh"; for tool in node bun treehouse python3; do "$tool"; done' bare "$REPO_ROOT"
  assert_equal "$output" "$HOME/.nvm/versions/node/v24.22.1/bin/node
$HOME/.bun/bin/bun
$HOME/.local/bin/treehouse
$brew/opt/python@3.12/libexec/bin/python3"
}

@test "the tool directories that exist go first on PATH, after Homebrew's GNU tools, once; a system one is added last when missing" {
  stub_reply uname Darwin
  mkdir -p "$HOME/.bun/bin" "$HOME/.no-mistakes/bin"
  run -0 library_path
  assert_equal "$output" "$gnu_path:$HOME/.bun/bin:$HOME/.no-mistakes/bin:$PATH"
  # A script run by another one does not add them again.
  PATH=$output run -0 library_path
  assert_equal "$output" "$gnu_path:$HOME/.bun/bin:$HOME/.no-mistakes/bin:$PATH"
  # On Arch /usr/local/bin, where treehouse goes (the sandbox's, under TEAM_SYSTEM_ROOT), keeps
  # its place, or comes last when PATH lacks it.
  stub_reply uname Linux
  bare_bin
  local stubs=$BATS_TEST_TMPDIR/stubs system=$TEAM_SYSTEM_ROOT/usr/local/bin
  mkdir -p "$system"
  PATH=$stubs:$bare:$system:/usr/bin:/bin run -0 library_path
  assert_equal "$output" "$HOME/.bun/bin:$HOME/.no-mistakes/bin:$stubs:$bare:$system:/usr/bin:/bin"
  PATH=$stubs:$bare:/usr/bin:/bin run -0 library_path
  assert_equal "$output" "$HOME/.bun/bin:$HOME/.no-mistakes/bin:$stubs:$bare:/usr/bin:/bin:$system"
}

@test "TEAM_PATH_FIRST stays first on PATH, ahead of Homebrew's GNU tools and the tool directories, once" {
  stub_reply uname Darwin
  mkdir -p "$HOME/.bun/bin"
  local first=$BATS_TEST_TMPDIR/first
  TEAM_PATH_FIRST=$first run -0 library_path
  assert_equal "$output" "$first:$gnu_path:$HOME/.bun/bin:$PATH"
  # Already first, or elsewhere on PATH, it is moved there, never added twice; nor are the others.
  PATH=$output TEAM_PATH_FIRST=$first run -0 library_path
  assert_equal "$output" "$first:$gnu_path:$HOME/.bun/bin:$PATH"
  PATH=$PATH:$first TEAM_PATH_FIRST=$first run -0 library_path
  assert_equal "$output" "$first:$gnu_path:$HOME/.bun/bin:$PATH"
}

@test "in the sandbox a trimmed PATH regains no directory outside the test's own, so never the machine's 1Password CLI" {
  [[ $TEAM_SYSTEM_ROOT == "$BATS_TEST_TMPDIR"/* ]]
  # As team-secrets' tests trim it: one folder of links to every command on PATH but the CLI.
  local stubs=$BATS_TEST_TMPDIR/stubs links=$BATS_TEST_TMPDIR/links trimmed os entry entries dir dirs
  mkdir -p "$links"
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    [[ -d $dir && $dir != "$stubs" ]] && ln -s "$dir"/* "$links/" 2>/dev/null || true
  done
  rm -f "$links/op"
  for os in Linux Darwin; do
    stub_reply uname "$os"
    trimmed=$(PATH=$stubs:$links library_path)
    IFS=: read -ra entries <<<"$trimmed"
    for entry in "${entries[@]}"; do
      [[ $entry == "$BATS_TEST_TMPDIR"/* ]] || { echo "$os: the library added $entry to the trimmed PATH" >&2; return 1; }
    done
  done
}

@test "on macOS a script refuses, naming the brew install line, while a GNU tool is missing" {
  stub_reply uname Darwin
  rm -r "$brew/opt/gnu-sed" "$brew/opt/flock"
  run_bin -1 --separate-stderr team-state --help
  assert_equal "$output" ""
  assert_equal "$stderr" 'team-state: missing Homebrew packages: gnu-sed flock; run `brew install gnu-sed flock`'
}

@test "on macOS the Homebrew prefix comes from brew --prefix when no standard prefix holds brew" {
  [[ ! -x /opt/homebrew/bin/brew && ! -x /usr/local/bin/brew ]] ||
    skip "a standard Homebrew prefix holds brew here, so it wins"
  stub_reply uname Darwin
  stub_command brew
  stub_reply brew "$brew"
  unset HOMEBREW_PREFIX
  run -0 library_path
  assert_equal "$output" "$gnu_path:$PATH"
  assert_equal "$(stub_calls brew)" '["--prefix"]'
}

@test "on macOS without Homebrew a script refuses, naming where to get it" {
  [[ ! -x /opt/homebrew/bin/brew && ! -x /usr/local/bin/brew ]] ||
    skip "a standard Homebrew prefix holds brew here"
  stub_reply uname Darwin
  unset HOMEBREW_PREFIX
  # PATH without any brew, but with what the script needs.
  local bin=$BATS_TEST_TMPDIR/bin tool
  mkdir -p "$bin"
  for tool in bash cat dirname jq; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  run -1 --separate-stderr env PATH="$BATS_TEST_TMPDIR/stubs:$bin" "$REPO_ROOT/bin/team-state" --help
  assert_equal "$stderr" 'team-state: Homebrew is not installed; install it from https://brew.sh, then run `brew install bash coreutils findutils gnu-sed grep flock`'
}

@test "a script refuses under Bash older than 5, naming the fix" {
  local old=/bin/bash
  "$old" -c '((BASH_VERSINFO[0] < 5))' 2>/dev/null ||
    skip "no Bash older than 5 at $old (macOS has 3.2 there)"
  run -1 --separate-stderr "$old" "$REPO_ROOT/bin/team-state" --help
  assert_equal "$output" ""
  assert_contains "$stderr" "team-state: needs Bash 5 or later, but runs under Bash $("$old" -c 'echo "$BASH_VERSION"') ($old);"
  assert_contains "$stderr" 'run `brew install bash` and put Homebrew'"'"'s bin first on PATH'
}

@test "team-project refuses Python older than 3.11, naming the fix" {
  local old='' candidate
  for candidate in /usr/bin/python3 python3.10 python3.9; do
    candidate=$(command -v "$candidate") || continue
    if "$candidate" -c 'import sys; sys.exit(sys.version_info >= (3, 11))' 2>/dev/null; then
      old=$candidate && break
    fi
  done
  [[ -n $old ]] || skip "no Python older than 3.11 here (macOS has 3.9 at /usr/bin/python3)"
  run -1 --separate-stderr "$old" -I "$REPO_ROOT/bin/team-project" --list
  assert_equal "$output" ""
  assert_contains "$stderr" "team-project: needs Python 3.11 or later (tomllib), but runs under Python "
  assert_contains "$stderr" 'on macOS run `brew install python@3.12`, whose python3 the team'"'"'s scripts put first on PATH'
}
