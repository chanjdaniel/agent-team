# The platform rules every team script and test runs under; bin/lib/team.sh sources it before
# anything else, and tests/helpers/common.bash does too.
#
# - Bash 5 or later, or exit 1 naming the fix: macOS's own /bin/bash is 3.2.
# - On macOS (uname -s is Darwin), the gnubin directories of Homebrew's coreutils, findutils,
#   gnu-sed and grep, and Homebrew's flock, go first on PATH, so scripts use the GNU tools under
#   their plain names; a missing package exits 1 naming the brew install line. The Homebrew
#   prefix is $HOMEBREW_PREFIX, else /opt/homebrew or /usr/local when it holds bin/brew, else
#   `brew --prefix`. Linux is untouched. A script that sets platform_report before sourcing
#   (team-doctor) is not refused: it gets the problem in PLATFORM_PROBLEM and its fix in
#   PLATFORM_FIX, with whatever GNU tools there are put first on PATH. TEAM_BREW_PREFIX is the
#   prefix found and TEAM_PLATFORM_FRONT the directories put first ("" for each on Linux), which
#   the library's tool directories follow. TEAM_CALLER_PATH is PATH as the script was started
#   with, before this file or the library changed it.
# - TEAM_PATH_FIRST, when set, is a directory taken off PATH here and put back first by the
#   library's team_tool_path, ahead of the GNU tools and the tool directories: a test seam for a
#   directory of stand-ins that must win over the machine's own tools (tests/compaction-drill's
#   stubs, whose real session's hooks run with the real HOME).
# This file is read by Bash 3.2 too, so it uses nothing newer until the version check passes.
# shellcheck shell=bash

if ((BASH_VERSINFO[0] < 5)); then
  echo "${0##*/}: needs Bash 5 or later, but runs under Bash $BASH_VERSION ($BASH);" \
    "on macOS run \`brew install bash\` and put Homebrew's bin first on PATH (eval \"\$(brew shellenv)\")" >&2
  exit 1
fi

# Refuse with <problem> and <fix>, or record them for a script that reports them itself.
team_platform_refuse() {
  if [[ -n ${platform_report:-} ]]; then
    PLATFORM_PROBLEM=$1 PLATFORM_FIX=$2
    return 0
  fi
  echo "${0##*/}: $1; $2" >&2
  exit 1
}

# The macOS PATH rule above; nothing on Linux.
# shellcheck disable=SC2034 # read by the script that set platform_report, and by the library
PLATFORM_PROBLEM='' PLATFORM_FIX='' TEAM_BREW_PREFIX='' TEAM_PLATFORM_FRONT='' TEAM_CALLER_PATH=$PATH
# PATH without TEAM_PATH_FIRST, wherever and however often it is on it.
team_path_without_first() {
  [[ -n ${TEAM_PATH_FIRST:-} ]] || return 0
  local path=:$PATH:
  while [[ $path == *:"$TEAM_PATH_FIRST":* ]]; do path=${path//:"$TEAM_PATH_FIRST":/:}; done
  path=${path#:}
  PATH=${path%:}
}
team_platform_path() {
  team_path_without_first
  [[ $(uname -s) == Darwin ]] || return 0
  local prefix=${HOMEBREW_PREFIX:-} dir
  if [[ -z $prefix ]]; then
    for dir in /opt/homebrew /usr/local; do
      if [[ -x $dir/bin/brew ]]; then prefix=$dir && break; fi
    done
  fi
  if [[ -z $prefix ]] && command -v brew >/dev/null; then prefix=$(brew --prefix); fi
  if [[ -z $prefix ]]; then
    team_platform_refuse "Homebrew is not installed" \
      "install it from https://brew.sh, then run \`brew install bash coreutils findutils gnu-sed grep flock\`"
    return 0
  fi
  # shellcheck disable=SC2034 # read by the library
  TEAM_BREW_PREFIX=$prefix

  local -A dirs=(
    [coreutils]=$prefix/opt/coreutils/libexec/gnubin
    [findutils]=$prefix/opt/findutils/libexec/gnubin
    [gnu-sed]=$prefix/opt/gnu-sed/libexec/gnubin
    [grep]=$prefix/opt/grep/libexec/gnubin
    [flock]=$prefix/opt/flock/bin
  )
  local package missing=() front=''
  for package in coreutils findutils gnu-sed grep flock; do
    if [[ -d ${dirs[$package]} ]]; then front+=${dirs[$package]}:; else missing+=("$package"); fi
  done
  if ((${#missing[@]})); then
    team_platform_refuse "missing Homebrew packages: ${missing[*]}" "run \`brew install ${missing[*]}\`"
  fi
  # shellcheck disable=SC2034 # read by the library
  TEAM_PLATFORM_FRONT=$front
  # A script run by another one finds them first already.
  [[ $PATH == "$front"* ]] || PATH=$front$PATH
  export PATH
}
team_platform_path
