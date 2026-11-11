# The one lookup of the Chrome a team machine runs, for team-doctor's chrome line and
# team-tickets --graph, sourced after the library:
#
#   # shellcheck source=bin/lib/chrome.sh
#   source "$TEAM_LIB/chrome.sh"
#
# It provides:
#   chrome_path            prints the Chrome found, as found: the file or .app directory
#                          TEAM_CHROME names when it is set, else on macOS (TEAM_KERNEL Darwin)
#                          /Applications/Google Chrome.app, else the first of
#                          google-chrome-stable, google-chrome, chromium and chromium-browser on
#                          PATH; nothing when it finds none, or when what it finds does not run (no
#                          executable file, or a .app directory with none inside), a TEAM_CHROME
#                          that does not run never falling back to the others.
#   chrome_binary <path>   prints the executable a path chrome_path printed runs: a .app
#                          directory's Contents/MacOS/<its name less .app>, else the path itself.
# Both run only builtins once TEAM_KERNEL is set, as the library sets it, so a test may call them
# with a PATH of its stubs alone.
# shellcheck shell=bash

chrome_binary() {
  local path=${1%/} name
  if [[ $path == *.app && -d $path ]]; then
    name=${path##*/}
    printf '%s\n' "$path/Contents/MacOS/${name%.app}"
  else
    printf '%s\n' "$path"
  fi
}

chrome_path() {
  local chrome='' binary name
  if [[ -n ${TEAM_CHROME:-} ]]; then
    chrome=$TEAM_CHROME
  elif [[ ${TEAM_KERNEL:-$(uname -s)} == Darwin ]]; then
    chrome='/Applications/Google Chrome.app'
  else
    for name in google-chrome-stable google-chrome chromium chromium-browser; do
      ! chrome=$(command -v -- "$name") || break
    done
  fi
  [[ -n $chrome ]] || return 0
  binary=$(chrome_binary "$chrome")
  [[ ! -f $binary || ! -x $binary ]] || printf '%s\n' "$chrome"
}
