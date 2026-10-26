# homebrew      macOS only: Homebrew's GNU tools first on PATH, as bin/lib/platform.sh puts them.
# shellcheck shell=bash
# shellcheck disable=SC2154 # os, from the os check

if [[ $os == macos ]]; then
  if [[ -n $PLATFORM_PROBLEM ]]; then
    report homebrew FAIL "$PLATFORM_PROBLEM" "$PLATFORM_FIX"
  else
    report homebrew PASS "Homebrew's GNU tools are first on PATH"
  fi
fi
