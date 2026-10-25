#!/usr/bin/env bats
# bin/lib/platform.sh, through the library: Bash 5, Python 3.11 for team-project, and on macOS
# Homebrew's GNU tools first on PATH. A stubbed uname drives the macOS branch on Linux, and
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
  assert_contains "$stderr" 'run `brew install python` and put Homebrew'"'"'s bin first on PATH'
}
