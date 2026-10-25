#!/usr/bin/env bats
# servers/install: installs the pinned MCP servers with npm ci --ignore-scripts, staged and swapped
# in, and does nothing when the install already matches package.json and the lock.

load helpers/common

setup() {
  sandbox
  # A copy of this checkout's servers/ and the library it sources, so the test installs there.
  co=$BATS_TEST_TMPDIR/checkout
  mkdir -p "$co/servers" "$co/bin"
  cp "$REPO_ROOT/servers/install" "$REPO_ROOT/servers/package.json" "$REPO_ROOT/servers/package-lock.json" "$co/servers/"
  cp -r "$REPO_ROOT/bin/lib" "$co/bin/"
  stub_command npm
  # npm ci, as far as the script can tell: a node_modules beside the package files it was given.
  stub_script npm <<'EOF'
[[ -f package.json && -f package-lock.json ]] || { echo "npm stub: no package files in $PWD" >&2; exit 1; }
mkdir -p node_modules/mongodb-mcp-server
echo "installed in ${PWD##*/}" >node_modules/mongodb-mcp-server/from
EOF
}

# run_install <status> [arguments]: run the copy's servers/install with bats' `run`.
run_install() {
  guard_sandbox
  run "$1" "$co/servers/install" "${@:2}"
}

@test "installs with npm ci --ignore-scripts from a staging copy, then swaps it in" {
  run_install -0
  assert_equal "$output" "servers: installed from package-lock.json"
  assert_equal "$(stub_calls npm)" '["ci","--ignore-scripts","--no-audit","--no-fund","--loglevel=error"]'
  [[ $(cat "$co/servers/node_modules/mongodb-mcp-server/from") == "installed in .staging."* ]]
  # Nothing of the staging is left.
  assert_equal "$(cd "$co/servers" && find . -maxdepth 1 -name '.staging.*' -o -maxdepth 1 -name '.old.*')" ""
}

@test "does nothing on a second run, and reinstalls when the lock changes or with --force" {
  run_install -0
  run_install -0
  assert_equal "$output" "servers: up to date"
  assert_equal "$(stub_calls npm | wc -l)" 1

  echo ' ' >>"$co/servers/package-lock.json"
  run_install -0
  assert_equal "$output" "servers: installed from package-lock.json"
  assert_equal "$(stub_calls npm | wc -l)" 2

  run_install -0 --force
  assert_equal "$(stub_calls npm | wc -l)" 3
}

@test "a failed npm ci leaves the previous install in place" {
  run_install -0
  before=$(cat "$co/servers/node_modules/mongodb-mcp-server/from")
  stub_script npm <<<'echo "npm ERR! network" >&2; exit 1'
  run_install -1 --force
  assert_contains "$output" "install: npm ci failed; the previous install, if any, is unchanged"
  assert_equal "$(cat "$co/servers/node_modules/mongodb-mcp-server/from")" "$before"
  assert_equal "$(cd "$co/servers" && find . -maxdepth 1 -name '.staging.*')" ""
}

@test "refuses any argument but --force" {
  run_install -2 --yes
  assert_equal "$output" "install: usage: servers/install [--force]"
  [[ ! -e $co/servers/node_modules ]]
}
