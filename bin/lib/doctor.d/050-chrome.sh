# chrome        Google Chrome or Chromium is installed, for chrome-devtools-axi; warns.
# shellcheck shell=bash
# reads state from: 010-os.sh

# By bin/lib/chrome.sh's lookup, which team-tickets --graph takes too: its app on macOS, its
# command on Arch, or TEAM_CHROME.
# shellcheck source=bin/lib/chrome.sh
source "$TEAM_LIB/chrome.sh"
if [[ -n $os ]]; then
  browser=$(chrome_path)
  if [[ -n $browser ]]; then
    report chrome PASS "$(tilde "$browser")"
  elif [[ $os == macos ]]; then
    report chrome WARN "Google Chrome is not installed, so chrome-devtools-axi has no browser" "brew install --cask google-chrome"
  else
    report chrome WARN "neither Google Chrome nor Chromium is installed, so chrome-devtools-axi has no browser" \
      "Daniel installs google-chrome from the AUR, or runs sudo pacman -S --needed chromium"
  fi
fi
