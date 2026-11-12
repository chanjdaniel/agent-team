#!/usr/bin/env bats
# lib/chrome.sh: the one Chrome lookup, which team-doctor's chrome line and team-tickets --graph
# both take. Each case calls chrome_path with a PATH of this test's stubs alone, so the
# machine's own Chrome never answers for the one a case puts on it.

load helpers/common

setup() {
  sandbox
  # shellcheck source=bin/lib/chrome.sh
  source "$REPO_ROOT/bin/lib/chrome.sh"
  export TEAM_KERNEL=Linux
  # What look passes as TEAM_CHROME: none while it is empty.
  team_chrome=''
  bin_dir=$BATS_TEST_TMPDIR/chrome-bin
  mkdir -p "$bin_dir"
}

# A browser command on the stubs' PATH: browser <name>...
browser() {
  local name
  for name; do ln -f "$(shared stub)" "$bin_dir/$name"; done
}

# chrome_path, then chrome_binary of what it printed, with the stubs alone on PATH: look
look() {
  output=$(PATH=$bin_dir TEAM_CHROME=$team_chrome chrome_path)
  binary=''
  [[ -z $output ]] || binary=$(PATH=$bin_dir chrome_binary "$output")
}

@test "on Linux each command is found in the doctor's order, chromium-browser last" {
  local names=(google-chrome-stable google-chrome chromium chromium-browser) i
  browser "${names[@]}"
  for i in "${!names[@]}"; do
    look
    assert_equal "$output" "$bin_dir/${names[i]}"
    assert_equal "$binary" "$output"
    rm "$bin_dir/${names[i]}"
  done
  look
  assert_equal "$output" ""
}

@test "a command on PATH that is not executable is no Chrome" {
  touch "$bin_dir/chromium"
  look
  assert_equal "$output" ""
}

@test "TEAM_CHROME is taken as it is named when it runs, and never falls back when it does not" {
  browser google-chrome-stable
  team_chrome=$BATS_TEST_TMPDIR/chrome
  ln -f "$(shared stub)" "$team_chrome"
  look
  assert_equal "$output" "$team_chrome"
  rm "$team_chrome"
  touch "$team_chrome"
  look
  assert_equal "$output" ""
  rm "$team_chrome"
  look
  assert_equal "$output" ""
}

@test "a .app directory is named as the app and run as the executable inside it" {
  local app="$BATS_TEST_TMPDIR/Fake Chrome.app"
  team_chrome=$app/
  mkdir -p "$app/Contents/MacOS"
  look
  assert_equal "$output" ""
  ln -f "$(shared stub)" "$app/Contents/MacOS/Fake Chrome"
  look
  assert_equal "$output" "$app/"
  assert_equal "$binary" "$app/Contents/MacOS/Fake Chrome"
}

@test "on macOS it looks only at Google Chrome's app in /Applications" {
  [[ ! -e "/Applications/Google Chrome.app" ]] || skip "this machine has Google Chrome in /Applications"
  browser google-chrome-stable
  TEAM_KERNEL=Darwin look
  assert_equal "$output" ""
}
