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
#   PLATFORM_FIX, with whatever GNU tools there are put first on PATH.
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
# shellcheck disable=SC2034 # read by the script that set platform_report
PLATFORM_PROBLEM='' PLATFORM_FIX=''
team_platform_path() {
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
  # A script run by another one finds them first already.
  [[ $PATH == "$front"* ]] || PATH=$front$PATH
  export PATH
}
team_platform_path
