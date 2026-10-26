# github login  `gh auth status` for github.com.
# shellcheck shell=bash

if bounded 30 gh auth status --hostname github.com >/dev/null 2>&1 </dev/null; then
  report "github login" PASS "gh is signed in to github.com"
else
  report "github login" FAIL "gh auth status finds no working login for github.com" \
    "gh auth login --hostname github.com --git-protocol https --web"
fi
