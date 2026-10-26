# chrome        Google Chrome or Chromium is installed, for chrome-devtools-axi; warns.
# shellcheck shell=bash

# By its app on macOS, by its command on Arch.
if [[ -n $os ]]; then
  if [[ -n ${TEAM_CHROME:-} ]]; then
    browser=$TEAM_CHROME
    [[ -e $browser ]] || browser=''
  elif [[ $os == macos ]]; then
    browser=/Applications/Google\ Chrome.app
    [[ -e $browser ]] || browser=''
  else
    browser=$(command -v google-chrome-stable google-chrome chromium | head -n 1 || true)
  fi
  if [[ -n $browser ]]; then
    report chrome PASS "$(tilde "$browser")"
  elif [[ $os == macos ]]; then
    report chrome WARN "Google Chrome is not installed, so chrome-devtools-axi has no browser" "brew install --cask google-chrome"
  else
    report chrome WARN "neither Google Chrome nor Chromium is installed, so chrome-devtools-axi has no browser" \
      "Daniel installs google-chrome from the AUR, or runs sudo pacman -S --needed chromium"
  fi
fi
